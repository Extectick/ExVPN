# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Inspect','Install','Uninstall','Recover','Rollback')][string]$Action,
    [string]$PayloadRoot,
    [string]$OwnerSid = 'AUTO',
    [switch]$EnableNetworkTesting,
    [switch]$RequireDisconnected
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'package-common.ps1')
if ($RequireDisconnected -and $Action -ne 'Install') { throw 'The automatic update gate is only valid for Install.' }

function Read-PackageJson([string]$Path) {
    if ((Get-Item -LiteralPath $Path).Length -gt 10MB) { throw 'Package metadata is too large.' }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}
function Read-Payload([string]$Root) {
    $metadata = Read-PackageJson (Join-Path $Root 'package.json')
    if ($metadata.format -ne 1 -or $metadata.version -notmatch '^\d+\.\d+\.\d+$' -or $metadata.build -lt 1 -or $metadata.build -gt 2147483647) { throw 'Invalid package version.' }
    foreach ($tree in @('ui','service','control')) { Assert-TreeManifest (Join-Path $Root $tree) $metadata.trees.$tree }
    if (!(Test-Path -LiteralPath (Join-Path $Root 'ui/exvpn.exe')) -or !(Test-Path -LiteralPath (Join-Path $Root 'service/exvpn-service.exe'))) { throw 'Package binaries missing.' }
    $metadata
}

function Resolve-PackageNetworkTesting($Current, [bool]$WasExplicit, [bool]$Requested) {
    if ($Current -and $Current.networkTesting -isnot [bool]) { throw 'Installed network-testing state must be a boolean.' }
    if ($WasExplicit) { return $Requested }
    if ($Current) { return $Current.networkTesting }
    return $false
}

function Get-PackageMaintenanceControl([bool]$RequireIdle) {
    if ($RequireIdle) { return 129 }
    return 128
}

if ($Action -eq 'Inspect') {
    $metadata = Read-Payload $PayloadRoot
    Write-Host "Package $($metadata.version)+$($metadata.build) verified without installation."
    return
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (![Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator rights are required for package maintenance.' }
if (![Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell.' }
$programFiles = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)).TrimEnd('\')
if ((Get-Item -LiteralPath $programFiles).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Program Files cannot be redirected.' }
$roots = @{ ui = (Join-Path $programFiles 'ExVPN'); service = (Join-Path $programFiles 'ExVPN Service'); control = (Join-Path $programFiles 'ExVPN Installer') }
$statePath = Join-Path $roots.control 'install-state.json'
$rollbackRoot = Join-Path $programFiles 'ExVPN Rollback'
$registryPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ExVPN'

function Read-InstalledState {
    if (!(Test-Path -LiteralPath $statePath)) { return $null }
    Assert-ProtectedPackage $roots.control
    $state = Read-PackageJson $statePath
    if ($state.format -ne 1 -or $state.ownerSid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$' -or $state.build -lt 1 -or $state.networkTesting -isnot [bool]) { throw 'Invalid installed state.' }
    foreach ($tree in @('ui','service','control')) {
        Assert-ProtectedPackage $roots[$tree]
        if ($tree -eq 'control') { Assert-TreeManifest $roots[$tree] $state.trees.$tree @('install-state.json') }
        else { Assert-TreeManifest $roots[$tree] $state.trees.$tree }
    }
    $state
}

function Assert-OwnerProxyReleased($State) {
    # WinINET belongs to the desktop account. Elevated package maintenance must
    # never overwrite a different user's HKCU or decrypt their proxy snapshot.
    # Require explicit Disconnect by the owning UI before replacing its service.
    $ownerHive = 'Registry::HKEY_USERS\' + $State.ownerSid
    if (!(Test-Path -LiteralPath $ownerHive)) { throw 'Sign in as the ExVPN owner before package maintenance; proxy recovery cannot be checked while the user hive is unloaded.' }
    $leaseKey = Join-Path $ownerHive 'Software\ExVPN\SystemProxy.v1'
    if (Test-Path -LiteralPath $leaseKey) {
        $key = Get-Item -LiteralPath $leaseKey
        if ('Lease' -in $key.GetValueNames()) { throw 'Disconnect PROXY in ExVPN before package maintenance so the previous Windows proxy settings are restored.' }
    }
}

function Get-ExpectedServiceCommand($State) {
    $command = '"' + (Join-Path $roots.service 'exvpn-service.exe') + '" -owner-sid ' + $State.ownerSid + ' -client "' + (Join-Path $roots.ui 'exvpn.exe') + '"'
    if ($State.networkTesting) { $command += ' -network-testing' }; $command
}
function Assert-OwnedService($State) {
    $service = Get-CimInstance Win32_Service -Filter "Name='ExVPNService'"
    if ($service -and ($service.PathName -cne (Get-ExpectedServiceCommand $State) -or $service.StartName -ne 'LocalSystem')) { throw 'Service identity/configuration differs from owned installation.' }
    $service
}
function Request-OwnedServiceStop([int]$Control) {
    & "$env:SystemRoot\System32\sc.exe" control ExVPNService $Control | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Maintenance stop was not accepted; existing protection was retained.' }
}
function Stop-OwnedService($State) {
    $existing = Assert-OwnedService $State
    if ($RequireDisconnected -and (!$existing -or $existing.State -ne 'Running')) {
        throw 'Automatic update requires a running service that can confirm disconnected state. Existing protection was retained.'
    }
    if ($existing -and $existing.State -ne 'Stopped') {
        if ($existing.State -ne 'Running') { throw 'Service is transitioning; retry maintenance later.' }
        $control = Get-PackageMaintenanceControl ([bool]$RequireDisconnected)
        Request-OwnedServiceStop $control
        $service = Get-Service ExVPNService
        $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(40))
        $existing = Assert-OwnedService $State
        if ($existing.ExitCode -ne 0 -or $existing.ServiceSpecificExitCode -ne 0) { throw 'Service maintenance failed; files and protection retained.' }
    }
    if (Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue) { throw 'An adapter remains after service stop. Restore the VM snapshot or complete owned adapter recovery before proceeding.' }
    if (!$RequireDisconnected) {
        & (Join-Path $roots.service 'exvpn-service.exe') recover-guard
        if ($LASTEXITCODE -ne 0) { throw 'Owned guard recovery failed; installation retained.' }
    }
}
function Delete-OwnedService($State) {
    if (Assert-OwnedService $State) {
        & "$env:SystemRoot\System32\sc.exe" delete ExVPNService | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Service deletion failed.' }
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while (Get-Service ExVPNService -ErrorAction SilentlyContinue) { if ([DateTime]::UtcNow -gt $deadline) { throw 'Service deletion is pending; close service handles and retry.' }; Start-Sleep -Milliseconds 100 }
    }
}
function Create-OwnedService($State) {
    New-Service -Name ExVPNService -BinaryPathName (Get-ExpectedServiceCommand $State) -DisplayName 'ExVPN Service' -Description 'ExVPN controlled tunnel service' -StartupType Automatic -DependsOn BFE | Out-Null
    & "$env:SystemRoot\System32\sc.exe" sdset ExVPNService 'D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;CCLCSWLORC;;;IU)' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Service ACL configuration failed.' }
    $serviceAcl = & "$env:SystemRoot\System32\sc.exe" sdshow ExVPNService
    if ($LASTEXITCODE -ne 0) { throw 'Service ACL readback failed.' }
    Assert-ServiceControlAcl ($serviceAcl -join '')
    Start-Service ExVPNService
    (Get-Service ExVPNService).WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(15))
}
function Write-InstalledState($State) {
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
    Set-ProtectedPackageACL $statePath
}
function Register-InstalledPackage($State) {
    New-Item -Path $registryPath -Force | Out-Null
    $values = @{ DisplayName = 'ExVPN (development)'; DisplayVersion = "$($State.version)+$($State.build)"; Publisher = 'ExVPN'; InstallLocation = $roots.ui; DisplayIcon = (Join-Path $roots.ui 'exvpn.exe'); UninstallString = ('"' + (Join-Path $roots.control 'Uninstall.exe') + '"') }
    foreach ($key in $values.Keys) { New-ItemProperty -Path $registryPath -Name $key -Value $values[$key] -PropertyType String -Force | Out-Null }
    foreach ($key in @('NoModify','NoRepair')) { New-ItemProperty -Path $registryPath -Name $key -Value 1 -PropertyType DWord -Force | Out-Null }
    $menu = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonPrograms)) 'ExVPN.lnk'
    $shell = New-Object -ComObject WScript.Shell
    if (Test-Path -LiteralPath $menu) { if ($shell.CreateShortcut($menu).TargetPath -ine (Join-Path $roots.ui 'exvpn.exe')) { throw 'A different ExVPN Start menu shortcut already exists.' } }
    $shortcut = $shell.CreateShortcut($menu); $shortcut.TargetPath = Join-Path $roots.ui 'exvpn.exe'; $shortcut.WorkingDirectory = $roots.ui; $shortcut.IconLocation = $shortcut.TargetPath; $shortcut.Save()
}
function Remove-OwnedRegistration {
    $registration = Get-ItemProperty $registryPath -ErrorAction SilentlyContinue
    if ($registration -and $registration.InstallLocation -ieq $roots.ui) { Remove-Item -LiteralPath $registryPath }
    $menu = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonPrograms)) 'ExVPN.lnk'
    if (Test-Path -LiteralPath $menu) {
        $shell = New-Object -ComObject WScript.Shell
        if ($shell.CreateShortcut($menu).TargetPath -ieq (Join-Path $roots.ui 'exvpn.exe')) { Remove-Item -LiteralPath $menu }
    }
}
function Remove-InstalledTrees($State, [switch]$Partial) {
    # Preflight every tree before deleting any owned file. Absolute roots are
    # fixed Program Files subdirectories; unknown/changed files always abort.
    foreach ($tree in @('ui','service','control')) {
        $ignore = @(); if ($tree -eq 'control') { $ignore = @('install-state.json') }
        Assert-TreeManifest $roots[$tree] $State.trees.$tree $ignore -AllowMissing:$Partial
    }
    Delete-OwnedService $State
    foreach ($tree in @('ui','service','control')) { $ignore = @(); if ($tree -eq 'control') { $ignore = @('install-state.json') }; Remove-OwnedTree $roots[$tree] $State.trees.$tree $ignore }
}
function Backup-InstalledTrees($State) {
    if (!(Test-Path -LiteralPath $rollbackRoot)) { New-Item -ItemType Directory -Path $rollbackRoot | Out-Null; Set-ProtectedPackageACL $rollbackRoot -Directory }
    Assert-ProtectedPackage $rollbackRoot
    $backup = Join-Path $rollbackRoot ([Guid]::NewGuid().ToString('D'))
    New-Item -ItemType Directory -Path $backup | Out-Null; Set-ProtectedPackageACL $backup -Directory
    foreach ($tree in @('ui','service','control')) { Copy-OwnedTree $roots[$tree] (Join-Path $backup $tree) $State.trees.$tree }
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $backup 'previous-state.json') -Encoding UTF8
    Set-ProtectedPackageACL (Join-Path $backup 'previous-state.json')
    $backup
}
function Read-PackageBackup([string]$Backup, [string]$ExpectedOwner) {
    $absolute = Assert-RollbackPath $rollbackRoot $Backup
    Assert-ProtectedPackage $rollbackRoot
    Assert-ProtectedPackage $absolute
    $old = Read-PackageJson (Join-Path $absolute 'previous-state.json')
    if ($old.format -ne 1 -or $old.ownerSid -cne $ExpectedOwner -or $old.version -notmatch '^\d+\.\d+\.\d+$' -or $old.build -lt 1) { throw 'Invalid rollback package identity.' }
    foreach ($tree in @('ui','service','control')) { Assert-TreeManifest (Join-Path $absolute $tree) $old.trees.$tree }
    $old
}
function Restore-PackageBackup([string]$Backup, [string]$ExpectedOwner) {
    $absolute = Assert-RollbackPath $rollbackRoot $Backup
    $old = Read-PackageBackup $absolute $ExpectedOwner
    # Validate ALL survivors before copying anything. Unknown/modified files
    # stop recovery and preserve the protected source for manual inspection.
    foreach ($tree in @('ui','service','control')) {
        $ignore = @(); if ($tree -eq 'control') { $ignore = @('install-state.json') }
        Assert-TreeManifest $roots[$tree] $old.trees.$tree $ignore -AllowMissing
        if (Test-Path -LiteralPath $roots[$tree]) { Assert-ProtectedPackage $roots[$tree] }
    }
    [void](Assert-OwnedService $old)
    foreach ($tree in @('ui','service','control')) {
        $ignore = @(); if ($tree -eq 'control') { $ignore = @('install-state.json') }
        Restore-MissingOwnedTree (Join-Path $absolute $tree) $roots[$tree] $old.trees.$tree $ignore
    }
    Write-InstalledState $old
    $existing = Assert-OwnedService $old
    if (!$existing) { Create-OwnedService $old }
    elseif ($existing.State -eq 'Stopped') {
        Start-Service ExVPNService
        (Get-Service ExVPNService).WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(15))
    } elseif ($existing.State -ne 'Running') { throw 'Service is transitioning; recovery cannot complete.' }
    Register-InstalledPackage $old
}

function Copy-PackagePayload([string]$Source, $State) {
    foreach ($tree in @('ui','service')) { Copy-OwnedTree (Join-Path $Source $tree) $roots[$tree] $State.trees.$tree }
    $controlRecords = @($State.trees.control | Where-Object { $_.path -ine 'Uninstall.exe' })
    Copy-OwnedTree (Join-Path $Source 'control') $roots.control $controlRecords
    Copy-Item -LiteralPath (Join-Path $Source 'Uninstall.exe') -Destination (Join-Path $roots.control 'Uninstall.exe')
    Set-ProtectedPackageACL (Join-Path $roots.control 'Uninstall.exe')
}

function Invoke-PackageReplacement($Current, $Next, [scriptblock]$WriteReplacement, [switch]$RecordPreviousBackup) {
    $previousBackupPath = $null
    $phase = 'unchanged'
    try {
        if ($Current) {
            Stop-OwnedService $Current
            $previousBackupPath = Backup-InstalledTrees $Current
            if ($RecordPreviousBackup) { $Next.rollbackPath = $previousBackupPath }
            # Record destructive intent BEFORE the first service/file removal.
            $phase = 'removing_previous'
            Remove-InstalledTrees $Current
        }
        $phase = 'writing_replacement'
        & $WriteReplacement $Next
        Write-InstalledState $Next
        foreach ($tree in @('ui','service','control')) {
            $ignore = @(); if ($tree -eq 'control') { $ignore = @('install-state.json') }
            Assert-TreeManifest $roots[$tree] $Next.trees.$tree $ignore
        }
        Create-OwnedService $Next
        Register-InstalledPackage $Next
    } catch {
        if ($phase -eq 'unchanged') {
            throw 'Package replacement failed before file removal. Existing files were retained; the service may be stopped. Inspect the failure before retrying.'
        }
        try {
            if ($phase -eq 'writing_replacement') {
                if (Assert-OwnedService $Next) { Stop-OwnedService $Next }
                # Known replacement files only. A locked, unknown or modified
                # file aborts cleanup; never force-remove it to make rollback pass.
                Remove-InstalledTrees $Next -Partial
                Remove-OwnedRegistration
            }
            if ($previousBackupPath) { Restore-PackageBackup $previousBackupPath $Current.ownerSid }
        } catch {
            $recoverySource = 'Protected installer staging remains available.'
            if ($previousBackupPath) { $recoverySource = "Protected previous package: $previousBackupPath" }
            throw "Package replacement failed; automatic recovery is INCOMPLETE. $recoverySource Preserve remaining files and the VM snapshot; inspect locked/unknown/modified files before reviewed recovery. No processes were force-unlocked and no global firewall/DNS reset was performed."
        }
        if ($previousBackupPath) { throw 'Package replacement failed; the previous package and service were restored from the verified backup.' }
        throw 'Installation failed; partial known installation files and registration were removed. Protected installer staging remains available.'
    }
}

function Invoke-PackageUninstall($Current) {
    $backup = $null
    $removalStarted = $false
    try {
        Stop-OwnedService $Current
        $backup = Backup-InstalledTrees $Current
        # Service deletion and each file removal can fail independently. Keep a
        # verified complete source before entering this destructive phase.
        $removalStarted = $true
        Remove-InstalledTrees $Current
        Remove-OwnedRegistration
    } catch {
        if (!$removalStarted) {
            throw 'Uninstall failed before service/file removal. Existing files were retained; the service may be stopped. Inspect the failure before retrying.'
        }
        try { Restore-PackageBackup $backup $Current.ownerSid }
        catch {
            throw "Uninstall failed; automatic recovery is INCOMPLETE. Protected previous package: $backup Preserve remaining files and inspect locked/unknown/modified files before reviewed recovery. No processes were force-unlocked and no global firewall/DNS reset was performed."
        }
        throw 'Uninstall failed; the previous package and service were restored from the verified backup. Close the conflicting file owner before retrying uninstall.'
    }
}

$maintenanceLock = Enter-MachineMaintenanceLock
try {
$current = Read-InstalledState
if ($current) { Assert-OwnerProxyReleased $current }
if ($Action -eq 'Install') {
    if ($RequireDisconnected -and !$current) { throw 'Automatic update requires an existing managed installation.' }
    $metadata = Read-Payload $PayloadRoot
    Assert-ProtectedPackage $PayloadRoot
    $resolvedOwner = Resolve-PackageOwner $OwnerSid
    if ($current) {
        if ($current.ownerSid -ne $resolvedOwner) { throw 'Upgrade cannot silently change the IPC owner account.' }
        if ($metadata.build -le $current.build) { throw 'Upgrade requires a strictly increasing build number. Use explicit rollback to restore a previous version.' }
    } else {
        foreach ($root in $roots.Values) { if (Test-Path -LiteralPath $root) { throw 'An unmanaged ExVPN installation exists; inspect it before installation.' } }
        if ((Get-Service ExVPNService -ErrorAction SilentlyContinue) -or (Test-Path $registryPath)) { throw 'An unmanaged ExVPN service or product registration exists.' }
    }
} else {
    if (!$current) { throw 'Managed ExVPN installation not found.' }; $resolvedOwner = $current.ownerSid
}

# Hold the same cross-session per-user writer mutex as the native UI throughout
# maintenance. Do not kill applications or launch the UI with an elevated token.
$mutexAcl = [Security.AccessControl.MutexSecurity]::new()
$mutexAcl.SetAccessRuleProtection($true,$false)
foreach ($sid in @($resolvedOwner,'S-1-5-18','S-1-5-32-544')) { $mutexAcl.AddAccessRule([Security.AccessControl.MutexAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),[Security.AccessControl.MutexRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow)) }
$created = $false
$mutex = [Threading.Mutex]::new($false,"Global\ExVPN.UI.v1.$resolvedOwner",[ref]$created,$mutexAcl)
$acquired = $false
try {
    try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (!$acquired) { throw 'Close ExVPN in all sessions before package maintenance.' }
    if ($Action -eq 'Recover') { Stop-OwnedService $current; Write-Host 'Owned ExVPN guard recovered. Service remains stopped; no unrelated network settings were reset.'; return }
    if ($Action -eq 'Uninstall') {
        Invoke-PackageUninstall $current
        Write-Host 'Owned ExVPN installation removed. Encrypted user data and protected rollback snapshots retained.'; return
    }
    if ($Action -eq 'Rollback') {
        if (!$current.rollbackPath) { throw 'No previous package is recorded.' }
        $rollbackSourcePath = $current.rollbackPath
        # Validate restore source before disconnecting or removing current files.
        $old = Read-PackageBackup $rollbackSourcePath $resolvedOwner
        if ($old.build -ge $current.build) { throw 'Rollback source must precede the installed build.' }
        Invoke-PackageReplacement $current $old {
            param($State)
            foreach ($tree in @('ui','service','control')) { Copy-OwnedTree (Join-Path $rollbackSourcePath $tree) $roots[$tree] $State.trees.$tree }
        }
        Write-Host 'Previous package restored; no subscription data or automatic VPN session was restored.'; return
    }
    $networkTesting = Resolve-PackageNetworkTesting $current ($PSBoundParameters.ContainsKey('EnableNetworkTesting')) ([bool]$EnableNetworkTesting)
    $new = [pscustomobject]@{ format = 1; version = $metadata.version; build = $metadata.build; ownerSid = $resolvedOwner; networkTesting = $networkTesting; rollbackPath = $null; trees = $metadata.trees }
    # The NSIS-generated uninstaller is written into protected staging after
    # payload extraction; record its actual hash before any installation change.
    $uninstaller = Join-Path $PayloadRoot 'Uninstall.exe'
    if (!(Test-Path -LiteralPath $uninstaller -PathType Leaf)) { throw 'NSIS uninstaller is missing.' }
    $new.trees.control = @($new.trees.control) + @([pscustomobject]@{path='Uninstall.exe';sha256=(Get-FileHash -LiteralPath $uninstaller -Algorithm SHA256).Hash.ToLowerInvariant()})
    Invoke-PackageReplacement $current $new { param($State) Copy-PackagePayload $PayloadRoot $State } -RecordPreviousBackup
    Write-Host "Installed ExVPN $($new.version)+$($new.build). UI starts from the ordinary desktop; network testing is $($new.networkTesting)."
} finally { if ($acquired) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
} finally { $maintenanceLock.ReleaseMutex(); $maintenanceLock.Dispose() }
