# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Inspect','Install','Uninstall','Recover','Rollback')][string]$Action,
    [string]$PayloadRoot,
    [string]$OwnerSid = 'AUTO',
    [switch]$EnableNetworkTesting
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'package-common.ps1')

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
    if ($state.format -ne 1 -or $state.ownerSid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$' -or $state.build -lt 1) { throw 'Invalid installed state.' }
    foreach ($tree in @('ui','service','control')) {
        Assert-ProtectedPackage $roots[$tree]
        if ($tree -eq 'control') { Assert-TreeManifest $roots[$tree] $state.trees.$tree @('install-state.json') }
        else { Assert-TreeManifest $roots[$tree] $state.trees.$tree }
    }
    $state
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
function Stop-OwnedService($State) {
    $existing = Assert-OwnedService $State
    if ($existing -and $existing.State -ne 'Stopped') {
        if ($existing.State -ne 'Running') { throw 'Service is transitioning; retry maintenance later.' }
        & "$env:SystemRoot\System32\sc.exe" control ExVPNService 128 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Explicit maintenance disconnect was not accepted.' }
        $service = Get-Service ExVPNService
        $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(40))
        $existing = Assert-OwnedService $State
        if ($existing.ExitCode -ne 0 -or $existing.ServiceSpecificExitCode -ne 0) { throw 'Service maintenance failed; files and protection retained.' }
    }
    if (Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue) { throw 'An adapter remains after service stop. Restore the VM snapshot or complete owned adapter recovery before proceeding.' }
    & (Join-Path $roots.service 'exvpn-service.exe') recover-guard
    if ($LASTEXITCODE -ne 0) { throw 'Owned guard recovery failed; installation retained.' }
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
    Assert-ProtectedPackage $absolute
    $old = Read-PackageJson (Join-Path $absolute 'previous-state.json')
    if ($old.format -ne 1 -or $old.ownerSid -cne $ExpectedOwner -or $old.version -notmatch '^\d+\.\d+\.\d+$' -or $old.build -lt 1) { throw 'Invalid rollback package identity.' }
    foreach ($tree in @('ui','service','control')) { Assert-TreeManifest (Join-Path $absolute $tree) $old.trees.$tree }
    $old
}
function Restore-PackageBackup([string]$Backup, [string]$ExpectedOwner) {
    $absolute = Assert-RollbackPath $rollbackRoot $Backup
    $old = Read-PackageBackup $absolute $ExpectedOwner
    foreach ($tree in @('ui','service','control')) { Copy-OwnedTree (Join-Path $absolute $tree) $roots[$tree] $old.trees.$tree }
    Write-InstalledState $old; Create-OwnedService $old; Register-InstalledPackage $old
}

$current = Read-InstalledState
if ($Action -eq 'Install') {
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
        Stop-OwnedService $current; Remove-InstalledTrees $current
        Remove-OwnedRegistration
        Write-Host 'Owned ExVPN installation removed. Encrypted user data and protected rollback snapshots retained.'; return
    }
    if ($Action -eq 'Rollback') {
        if (!$current.rollbackPath) { throw 'No previous package is recorded.' }
        $backup = $current.rollbackPath
        # Validate restore source before disconnecting or removing current files.
        $old = Read-PackageBackup $backup $resolvedOwner
        if ($old.build -ge $current.build) { throw 'Rollback source must precede the installed build.' }
        Stop-OwnedService $current; Remove-InstalledTrees $current; Restore-PackageBackup $backup $resolvedOwner
        Write-Host 'Previous package restored; no subscription data or automatic VPN session was restored.'; return
    }
    $backup = $null; $removedPrevious = $false
    $controlRecords = @($metadata.trees.control)
    $new = [pscustomobject]@{ format = 1; version = $metadata.version; build = $metadata.build; ownerSid = $resolvedOwner; networkTesting = [bool]$EnableNetworkTesting; rollbackPath = $null; trees = $metadata.trees }
    # The NSIS-generated uninstaller is written into protected staging after
    # payload extraction; record its actual hash before any installation change.
    $uninstaller = Join-Path $PayloadRoot 'Uninstall.exe'
    if (!(Test-Path -LiteralPath $uninstaller -PathType Leaf)) { throw 'NSIS uninstaller is missing.' }
    $new.trees.control = @($new.trees.control) + @([pscustomobject]@{path='Uninstall.exe';sha256=(Get-FileHash -LiteralPath $uninstaller -Algorithm SHA256).Hash.ToLowerInvariant()})
    try {
        if ($current) { Stop-OwnedService $current; $backup = Backup-InstalledTrees $current; $new.rollbackPath = $backup; Remove-InstalledTrees $current; $removedPrevious = $true }
        foreach ($tree in @('ui','service')) { Copy-OwnedTree (Join-Path $PayloadRoot $tree) $roots[$tree] $new.trees.$tree }
        # Copy control files, then the generated uninstaller, without treating
        # any arbitrary source folder as installable content.
        Copy-OwnedTree (Join-Path $PayloadRoot 'control') $roots.control $controlRecords
        Copy-Item -LiteralPath $uninstaller -Destination (Join-Path $roots.control 'Uninstall.exe'); Set-ProtectedPackageACL (Join-Path $roots.control 'Uninstall.exe')
        Write-InstalledState $new
        Assert-TreeManifest $roots.control $new.trees.control @('install-state.json')
        Create-OwnedService $new
        Register-InstalledPackage $new
        Write-Host "Installed ExVPN $($new.version)+$($new.build). UI starts from the ordinary desktop; network testing is $($new.networkTesting)."
    } catch {
        if (Assert-OwnedService $new) { Stop-OwnedService $new }
        if (!$current -or $removedPrevious) {
            Remove-InstalledTrees $new -Partial
            Remove-OwnedRegistration
            if ($backup) { Restore-PackageBackup $backup $resolvedOwner }
        }
        throw 'Installation failed. The previous package was restored when safe; protected rollback data remains available. Do not reset global firewall/DNS settings.'
    }
} finally { if ($acquired) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
