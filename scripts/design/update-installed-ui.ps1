# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
<#
Local design replacement, not a release installer. No service, network, registry
or per-user storage writes. Close ExVPN normally before applying. CheckOnly is
read-only and returns the bundle hash required by the elevated invocation.

Directory renames and install-state replacement are individually atomic; Windows
does not offer a single transaction across both. A protected journal records
intent first. Caught errors restore the previous UI/state. Power loss requires
inspection of the retained transaction before further package maintenance.
#>
[CmdletBinding(DefaultParameterSetName = 'Update')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Update')][string]$SourceDirectory,
    [Parameter(Mandatory, ParameterSetName = 'Update')]
    [ValidatePattern('^[a-z0-9][a-z0-9.-]{0,63}$')][string]$UiRevision,
    [Parameter(ParameterSetName = 'Update')]
    [ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedBundleSha256,
    [Parameter(Mandatory, ParameterSetName = 'Rollback')]
    [ValidatePattern('^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')]
    [string]$RollbackTransaction,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../windows/installer/package-common.ps1')
. (Join-Path $PSScriptRoot '../windows/client-bundle.ps1')

function Get-DesignHash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Get-DesignManifestHash($Records) {
    # Sort normalized byte records ordinally: Sort-Object uses culture/runtime
    # collation, which differs between Windows PowerShell and modern .NET.
    [string[]]$lines = @($Records | ForEach-Object {
        $_.path.Replace('\', '/').ToLowerInvariant() + ':' + $_.sha256.ToLowerInvariant()
    })
    [Array]::Sort($lines, [StringComparer]::Ordinal)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}
function Assert-DesignAncestors([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    if ($current.StartsWith('\\') -or $current.Length -lt 3) { throw 'Local filesystem paths are required.' }
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse-point ancestor rejected.' }
        $current = [IO.Path]::GetDirectoryName($current.TrimEnd('\'))
    }
}
function Read-DesignJson([string]$Path) {
    if ((Get-Item -LiteralPath $Path).Length -gt 10MB) { throw 'Design metadata exceeds the size limit.' }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}
function Write-DesignFile([string]$Path, [byte[]]$Bytes) {
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
        [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    Set-ProtectedPackageACL $Path
}
function Set-DesignState([string]$Source, [string]$Destination) {
    # Same-directory replacement preserves the fixed path and existing ACL.
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($Destination)) ('design-state-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Write-DesignFile $temporary ([IO.File]::ReadAllBytes($Source))
        [IO.File]::Replace($temporary, $Destination, [NullString]::Value)
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary }
    }
}
function Write-DesignJournal([string]$Path, $Journal, [string]$Phase) {
    $Journal.phase = $Phase
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Journal | ConvertTo-Json -Depth 12))
    if (Test-Path -LiteralPath $Path) {
        $temporary = Join-Path ([IO.Path]::GetDirectoryName($Path)) ('journal-' + [guid]::NewGuid().ToString('N') + '.tmp')
        Write-DesignFile $temporary $bytes
        [IO.File]::Replace($temporary, $Path, [NullString]::Value)
    } else { Write-DesignFile $Path $bytes }
}
function Assert-DesignOtherTrees($State, $Roots) {
    foreach ($tree in @('service', 'control')) {
        Assert-ProtectedPackage $Roots[$tree]
        $ignore = @(); if ($tree -eq 'control') { $ignore = @('install-state.json') }
        Assert-TreeManifest $Roots[$tree] $State.trees.$tree $ignore
    }
}
function Read-DesignInstallation($Roots, [string]$StatePath) {
    foreach ($root in $Roots.Values) { Assert-DesignAncestors $root; Assert-ProtectedPackage $root }
    $state = Read-DesignJson $StatePath
    if ($state.format -ne 1 -or $state.version -cne '0.1.0' -or $state.build -ne 18 -or
        $state.ownerSid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$' -or $state.networkTesting -isnot [bool]) {
        throw 'Only the managed ExVPN 0.1.0+18 installation is supported.'
    }
    Assert-TreeManifest $Roots.ui $state.trees.ui
    Assert-DesignOtherTrees $state $Roots
    $state
}
function Get-DesignServiceSnapshot($State, $Roots) {
    $service = Get-CimInstance Win32_Service -Filter "Name='ExVPNService'"
    $expected = '"' + (Join-Path $Roots.service 'exvpn-service.exe') + '" -owner-sid ' +
        $State.ownerSid + ' -client "' + (Join-Path $Roots.ui 'exvpn.exe') + '"'
    if ($State.networkTesting) { $expected += ' -network-testing' }
    if (!$service -or $service.StartName -cne 'LocalSystem' -or $service.PathName -cne $expected -or
        $service.State -cne 'Running' -or $service.ProcessId -le 0) {
        throw 'The expected installed service must be running; it will not be reconfigured or started.'
    }
    [ordered]@{ pid = $service.ProcessId; command = $service.PathName; startName = $service.StartName; state = $service.State } | ConvertTo-Json -Compress
}
function Enter-DesignUiLock([string]$OwnerSid) {
    $security = [Security.AccessControl.MutexSecurity]::new()
    $security.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($OwnerSid, 'S-1-5-18', 'S-1-5-32-544')) {
        $security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid), [Security.AccessControl.MutexRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow))
    }
    $created = $false
    $mutex = [Threading.Mutex]::new($false, "Global\ExVPN.UI.v1.$OwnerSid", [ref]$created, $security)
    try {
        $acl = $mutex.GetAccessControl()
        $trusted = @($OwnerSid, 'S-1-5-18', 'S-1-5-32-544')
        if (!$acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { throw 'Untrusted UI mutex owner/ACL.' }
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($rule.IsInherited -or $rule.IdentityReference.Value -notin $trusted -or
                $rule.AccessControlType -ne 'Allow' -or $rule.MutexRights -ne [Security.AccessControl.MutexRights]::FullControl) { throw 'Untrusted UI mutex permission.' }
        }
        $acquired = $false
        try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (!$acquired) { throw 'Exit ExVPN normally in every session before applying the design.' }
        $mutex
    } catch { $mutex.Dispose(); throw }
}
function Get-DesignSourcePlan([string]$Source, $Current, $Roots) {
    Assert-DesignAncestors $Source
    $sourceRoot = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\')
    $files = @(Get-ExVpnBundleFiles $sourceRoot)
    if (($files | Measure-Object Length -Sum).Sum -gt 1GB) { throw 'Design bundle exceeds 1 GiB.' }
    $records = @(Get-TreeManifest $sourceRoot)
    Assert-TreeManifest $sourceRoot $records
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $sourceRoot 'exvpn.exe')).ProductVersion
    if ($version -cne '0.1.0+18') { throw 'The built design must have ProductVersion 0.1.0+18.' }
    foreach ($required in @('flutter_windows.dll', 'data\icudtl.dat', 'data\app.so')) {
        if (@($records | Where-Object path -IEQ $required).Count -ne 1) { throw 'Incomplete release UI bundle.' }
    }
    # This operation changes presentation, not the Flutter engine/CRT ABI.
    foreach ($fixed in @('flutter_windows.dll', 'data\icudtl.dat', 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        $old = @($Current.trees.ui | Where-Object path -IEQ $fixed)
        $new = @($records | Where-Object path -IEQ $fixed)
        if ($old.Count -ne 1 -or ($new.Count -and ($new.Count -ne 1 -or $new[0].sha256 -cne $old[0].sha256))) { throw 'Design replacement must preserve the installed engine and CRT.' }
    }
    [pscustomobject]@{ root = $sourceRoot; records = $records; sha256 = (Get-DesignManifestHash $records) }
}
function Invoke-DesignUiSwap([string]$Installed, [string]$Replacement, [string]$Retained,
    [string]$StatePath, [string]$PreviousState, [string]$NextState, $PreviousRecords, $NextRecords,
    [scriptblock]$RecordPhase, [scriptblock]$AssertOtherState) {
    Assert-ProtectedPackage $Installed; Assert-TreeManifest $Installed $PreviousRecords
    Assert-ProtectedPackage $Replacement; Assert-TreeManifest $Replacement $NextRecords
    if (Test-Path -LiteralPath $Retained) { throw 'Retained UI path already exists.' }
    if ((Get-DesignHash $StatePath) -cne (Get-DesignHash $PreviousState)) { throw 'Installed state changed before UI replacement.' }
    & $AssertOtherState
    $oldMoved = $false; $newMoved = $false; $stateMoved = $false
    try {
        & $RecordPhase 'before_retain'
        [IO.Directory]::Move($Installed, $Retained); $oldMoved = $true
        & $RecordPhase 'before_promote'
        [IO.Directory]::Move($Replacement, $Installed); $newMoved = $true
        & $RecordPhase 'before_state'
        Set-DesignState $NextState $StatePath; $stateMoved = $true
        & $RecordPhase 'after_state'
        Assert-ProtectedPackage $Installed; Assert-TreeManifest $Installed $NextRecords
        & $AssertOtherState
        & $RecordPhase 'completed'
    } catch {
        $failure = $_
        try {
            if ($newMoved) { Assert-TreeManifest $Installed $NextRecords; [IO.Directory]::Move($Installed, $Replacement) }
            if ($oldMoved) { [IO.Directory]::Move($Retained, $Installed) }
            if ($stateMoved) { Set-DesignState $PreviousState $StatePath }
            Assert-TreeManifest $Installed $PreviousRecords
            if ((Get-DesignHash $StatePath) -cne (Get-DesignHash $PreviousState)) { throw 'Previous state was not restored.' }
            & $AssertOtherState
            & $RecordPhase 'restored_after_failure'
        } catch { throw "UI update recovery is INCOMPLETE: $($_.Exception.Message) Initial failure: $($failure.Exception.Message) Preserve the protected design transaction; do not run package maintenance. Service and per-user storage were not changed." }
        throw "UI update was refused or restored to the previous UI/state: $($failure.Exception.Message)"
    }
}

if (![Environment]::Is64BitProcess -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw '64-bit Windows is required.' }
if (!$CheckOnly) {
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) { throw 'Apply using 64-bit Windows PowerShell 5.1.' }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Apply requires an elevated Windows PowerShell.' }
    if ($PSCmdlet.ParameterSetName -eq 'Update' -and !$ExpectedBundleSha256) { throw 'Run -CheckOnly first and pass its sourceBundleSha256 as -ExpectedBundleSha256.' }
}
$programFiles = Get-ExVpnProgramFiles
$roots = @{ ui = (Join-Path $programFiles 'ExVPN'); service = (Join-Path $programFiles 'ExVPN Service'); control = (Join-Path $programFiles 'ExVPN Installer') }
$statePath = Join-Path $roots.control 'install-state.json'
$transactions = Join-Path $programFiles 'ExVPN Design Updates'
$machineLock = $null; $uiLock = $null
try {
    if (!$CheckOnly) { $machineLock = Enter-MachineMaintenanceLock }
    $current = Read-DesignInstallation $roots $statePath
    if (!$CheckOnly) { $uiLock = Enter-DesignUiLock $current.ownerSid }
    $initialService = Get-DesignServiceSnapshot $current $roots
    $assertOther = {
        Assert-DesignOtherTrees $current $roots
        if ((Get-DesignServiceSnapshot $current $roots) -cne $initialService) { throw 'Service identity/process changed during UI replacement.' }
    }
    if (Test-Path -LiteralPath $transactions) {
        Assert-DesignAncestors $transactions; Assert-ProtectedPackage $transactions
        foreach ($directory in Get-ChildItem -LiteralPath $transactions -Directory -Force) {
            $existing = Read-DesignJson (Join-Path $directory.FullName 'journal.json')
            if ($existing.phase -notin @('completed', 'restored_after_failure', 'rolled_back')) { throw 'An unfinished design transaction requires inspection before another update.' }
        }
    }
    if ($PSCmdlet.ParameterSetName -eq 'Rollback') {
        $transaction = Join-Path $transactions $RollbackTransaction
        Assert-DesignAncestors $transaction; Assert-ProtectedPackage $transaction
        $journalPath = Join-Path $transaction 'journal.json'
        $journal = Read-DesignJson $journalPath
        $previousState = Join-Path $transaction 'previous-state.json'
        $nextState = Join-Path $transaction 'next-state.json'
        if ($journal.id -cne $RollbackTransaction -or $journal.phase -cne 'completed' -or
            (Get-DesignHash $statePath) -cne $journal.nextStateSha256 -or
            (Get-DesignHash $previousState) -cne $journal.previousStateSha256 -or
            (Get-DesignHash $nextState) -cne $journal.nextStateSha256) { throw 'Rollback requires the unchanged latest design revision and verified previous state.' }
        $previous = Read-DesignJson $previousState
        $oldUi = Join-Path $transaction 'previous-ui'
        Assert-TreeManifest $oldUi $previous.trees.ui
        if ($CheckOnly) { [pscustomobject]@{ status = 'checked'; action = 'rollback'; transaction = $RollbackTransaction; version = '0.1.0+18' }; return }
        $phaseWriter = {
            param($phase)
            if ($phase -eq 'completed') { $phase = 'rolled_back' }
            elseif ($phase -eq 'restored_after_failure') { $phase = 'completed' }
            else { $phase = 'rollback_' + $phase }
            Write-DesignJournal $journalPath $journal $phase
        }
        Invoke-DesignUiSwap $roots.ui $oldUi (Join-Path $transaction 'reverted-ui') $statePath $nextState $previousState $current.trees.ui $previous.trees.ui $phaseWriter $assertOther
        [pscustomobject]@{ status = 'rolled_back'; transaction = $RollbackTransaction; version = '0.1.0+18' }
        return
    }
    $plan = Get-DesignSourcePlan $SourceDirectory $current $roots
    foreach ($root in @($roots.Values) + @($transactions)) {
        if ($plan.root -ieq $root -or $plan.root.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Source must be outside installed/protected maintenance roots.' }
    }
    if ($ExpectedBundleSha256 -and $plan.sha256 -cne $ExpectedBundleSha256) { throw 'Design source changed since review.' }
    if ($CheckOnly) {
        [pscustomobject]@{ status = 'checked'; action = 'update'; version = '0.1.0+18'; uiRevision = $UiRevision; sourceBundleSha256 = $plan.sha256; sourceFiles = $plan.records.Count; serviceUnchanged = $true }
        return
    }
    if (!(Test-Path -LiteralPath $transactions)) { New-Item -ItemType Directory -Path $transactions | Out-Null; Set-ProtectedPackageACL $transactions -Directory }
    $id = [guid]::NewGuid().ToString('D')
    $transaction = Join-Path $transactions $id
    New-Item -ItemType Directory -Path $transaction | Out-Null; Set-ProtectedPackageACL $transaction -Directory
    $previousState = Join-Path $transaction 'previous-state.json'
    Write-DesignFile $previousState ([IO.File]::ReadAllBytes($statePath))
    $stage = Join-Path $transaction 'next-ui'
    Copy-OwnedTree $plan.root $stage $plan.records
    foreach ($runtime in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        $target = Join-Path $stage $runtime
        if (!(Test-Path -LiteralPath $target)) { [IO.File]::Copy((Join-Path $roots.ui $runtime), $target, $false); Set-ProtectedPackageACL $target }
    }
    Assert-TreeManifest $plan.root $plan.records
    $next = [IO.File]::ReadAllText($previousState) | ConvertFrom-Json
    $next.trees.ui = @(Get-TreeManifest $stage)
    $revision = [pscustomobject]@{ id = $UiRevision; createdUtc = [DateTime]::UtcNow.ToString('o'); sourceBundleSha256 = $plan.sha256; transaction = $id }
    $next | Add-Member -NotePropertyName uiRevision -NotePropertyValue $revision -Force
    $nextState = Join-Path $transaction 'next-state.json'
    Write-DesignFile $nextState ([Text.UTF8Encoding]::new($false).GetBytes(($next | ConvertTo-Json -Depth 12)))
    $journal = [pscustomobject]@{ format = 1; id = $id; revision = $UiRevision; phase = 'prepared'; previousStateSha256 = (Get-DesignHash $previousState); nextStateSha256 = (Get-DesignHash $nextState) }
    $journalPath = Join-Path $transaction 'journal.json'
    Write-DesignJournal $journalPath $journal 'prepared'
    $phaseWriter = { param($phase) Write-DesignJournal $journalPath $journal $phase }
    Invoke-DesignUiSwap $roots.ui $stage (Join-Path $transaction 'previous-ui') $statePath $previousState $nextState $current.trees.ui $next.trees.ui $phaseWriter $assertOther
    [pscustomobject]@{ status = 'updated'; version = '0.1.0+18'; uiRevision = $UiRevision; transaction = $id; sourceBundleSha256 = $plan.sha256; serviceUnchanged = $true }
} finally {
    if ($uiLock) { $uiLock.ReleaseMutex(); $uiLock.Dispose() }
    if ($machineLock) { $machineLock.ReleaseMutex(); $machineLock.Dispose() }
}
