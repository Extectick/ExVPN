# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
param([Parameter(Mandatory)][ValidateSet('Setup','Refresh','Restore')][string]$Action,[switch]$ConfirmDisposableGuest)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$inputRoot = 'C:\ExVPN-App-QA'
$outputRoot = 'C:\ExVPN-App-QA-Results'
$qaRoot = 'C:\Program Files\ExVPN UI QA'
$stateFile = 'C:\Program Files\ExVPN UI QA Control\state.json'
$serviceExe = 'C:\Program Files\ExVPN Service\exvpn-service.exe'
$uiExe = 'C:\Program Files\ExVPN\exvpn.exe'
if (!$ConfirmDisposableGuest -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18' -or [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -ine $inputRoot) { throw 'Disposable System runner required.' }
$marker = Get-Content -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Raw | ConvertFrom-Json
if ($marker.PSObject.Properties['transportCycles'] -and $marker.transportCycles -ne 0) {
    if (($marker.transportCycles -isnot [int] -and $marker.transportCycles -isnot [long]) -or $marker.transportCycles -lt 3 -or $marker.transportCycles -gt 20) { throw 'Invalid transport cycle count.' }
    $parsedRun = [guid]::Empty
    if (![guid]::TryParseExact($marker.runId,'D',[ref]$parsedRun) -or $parsedRun -eq [guid]::Empty) { throw 'Invalid lifecycle run ID.' }
    $outputRoot = Join-Path 'C:\ExVPN-Lifecycle-QA-Results' $marker.runId
}
if (!$marker.forbiddenHost -or $env:COMPUTERNAME -ieq $marker.forbiddenHost -or !(Test-Path -LiteralPath $outputRoot -PathType Container)) { throw 'Guest isolation failed.' }
# Verify this helper before importing it, then verify the whole read-only bundle.
$common = @($marker.files | Where-Object path -CEQ 'package-common.ps1')
if ($common.Count -ne 1 -or $common[0].sha256 -cne (Get-FileHash -LiteralPath (Join-Path $inputRoot 'package-common.ps1')).Hash.ToLowerInvariant()) { throw 'Helper checksum mismatch.' }
. (Join-Path $inputRoot 'package-common.ps1')
Assert-TreeManifest $inputRoot $marker.files @('sandbox-bundle.json')

function Stop-Maintenance {
    $service = Get-Service ExVPNService
    if ($service.Status -eq 'Running') {
        & "$env:SystemRoot\System32\sc.exe" control ExVPNService 128 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Maintenance disconnect refused.' }
        $service.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(45))
    } elseif ($service.Status -ne 'Stopped') { throw 'Service is transitioning.' }
    $service = Get-CimInstance Win32_Service -Filter "Name='ExVPNService'"
    if ($service.ExitCode -ne 0 -or $service.ServiceSpecificExitCode -ne 0 -or (Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue)) { throw 'Maintenance cleanup failed.' }
}

if ($Action -eq 'Setup') {
    if (Test-Path -LiteralPath $stateFile) { throw 'Restore the previous QA session before preparing another.' }
    if (Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue) { throw 'Guest must start disconnected.' }
    $before = Get-Content -LiteralPath 'C:\Program Files\ExVPN Installer\install-state.json' -Raw | ConvertFrom-Json
    if ($marker.build -ne $before.build) { throw 'Run guest-app-upgrade as the desktop administrator first.' }
    if (Get-Process -Name exvpn -ErrorAction SilentlyContinue) { throw 'Close the desktop ExVPN process before QA setup.' }
    $installed = Get-Content -LiteralPath 'C:\Program Files\ExVPN Installer\install-state.json' -Raw | ConvertFrom-Json
    if ($installed.build -ne $marker.build -or $installed.ownerSid -cne $before.ownerSid) { throw 'Upgrade identity/version mismatch.' }
    $service = Get-CimInstance Win32_Service -Filter "Name='ExVPNService'"
    $original = '"' + $serviceExe + '" -owner-sid ' + $installed.ownerSid + ' -client "' + $uiExe + '" -network-testing'
    if ($service.PathName -cne $original -or $service.StartName -ne 'LocalSystem') { throw 'Unexpected production service identity.' }
    if (Test-Path -LiteralPath $qaRoot) { throw 'QA application directory already exists.' }
    New-Item -ItemType Directory -Path $qaRoot | Out-Null
    Set-ProtectedPackageACL $qaRoot -Directory
    foreach ($file in Get-PackageTree (Join-Path $inputRoot 'ui') | Where-Object { !$_.PSIsContainer }) {
        $relative = $file.FullName.Substring((Join-Path $inputRoot 'ui').Length + 1)
        $target = Get-OwnedPath $qaRoot $relative
        $parent = Split-Path $target
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        Set-ProtectedPackageACL $parent -Directory
        Copy-Item -LiteralPath $file.FullName -Destination $target
        Set-ProtectedPackageACL $target
    }
    Assert-ProtectedPackage $qaRoot
    $qaCommand = '"' + $serviceExe + '" -owner-sid ' + $installed.ownerSid + ' -client "' + (Join-Path $qaRoot 'exvpn.exe') + '" -network-testing'
    $controlRoot = Split-Path $stateFile
    New-Item -ItemType Directory -Path $controlRoot | Out-Null
    Set-ProtectedPackageACL $controlRoot -Directory
    [ordered]@{original=$original;qaCommand=$qaCommand;ownerSid=$installed.ownerSid;build=$installed.build;serviceSha256=(Get-FileHash -LiteralPath $serviceExe).Hash.ToLowerInvariant();files=@(Get-TreeManifest $qaRoot)} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $stateFile -Encoding utf8
    Set-ProtectedPackageACL $stateFile
    Stop-Maintenance
    $service = Get-CimInstance Win32_Service -Filter "Name='ExVPNService'"
    $changed = Invoke-CimMethod -InputObject $service -MethodName Change -Arguments @{PathName=$qaCommand}
    if ($changed.ReturnValue -ne 0) { throw 'QA client binding failed.' }
    Start-Service ExVPNService
    [ordered]@{installedBuild=$installed.build;realScmService=$true;temporaryClientBinding=$true;hostNetworkChanged=$false} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputRoot 'setup-report.json') -Encoding utf8
} elseif ($Action -eq 'Refresh') {
    Assert-ProtectedPackage (Split-Path $stateFile)
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    $service = Get-CimInstance Win32_Service -Filter "Name='ExVPNService'"
    $installed = Get-Content -LiteralPath 'C:\Program Files\ExVPN Installer\install-state.json' -Raw | ConvertFrom-Json
    if (($service.PathName -cne $state.qaCommand -and $service.PathName -cne $state.original) -or $service.StartName -ne 'LocalSystem' -or $state.build -gt $marker.build -or $installed.build -ne $marker.build -or $installed.ownerSid -cne $state.ownerSid) { throw 'QA service ownership changed.' }
    $serviceHash = (Get-FileHash -LiteralPath $serviceExe).Hash.ToLowerInvariant()
    # A completed ordinary UI upgrade may advance the build. Reuse the QA tree
    # only after Restore. A changed service must match the newly installed,
    # protected manifest; the old QA state alone cannot authorize its adoption.
    if ($state.build -lt $marker.build -and $service.PathName -cne $state.original) { throw 'Restore production binding before upgrading the QA session.' }
    if ($state.build -lt $marker.build) {
        Assert-ProtectedPackage 'C:\Program Files\ExVPN Installer'
        Assert-ProtectedPackage 'C:\Program Files\ExVPN Service'
        Assert-TreeManifest 'C:\Program Files\ExVPN Service' $installed.trees.service
        $record = @($installed.trees.service | Where-Object path -CEQ 'exvpn-service.exe')
        if ($record.Count -ne 1 -or $record[0].sha256 -cne $serviceHash) { throw 'Upgraded service is not confirmed by its installed manifest.' }
    } elseif ($serviceHash -cne $state.serviceSha256) { throw 'QA service binary changed without an owned upgrade.' }
    if ((Get-Process -Name exvpn -ErrorAction SilentlyContinue) -or (Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue)) { throw 'QA must be stopped and disconnected before refresh.' }
    Assert-ProtectedPackage $qaRoot
    Assert-TreeManifest $qaRoot $state.files
    Stop-Maintenance
    # Refresh is limited to the separate, manifest-owned QA tree. Production
    # UI, installer manifests, service binary and owner SID are never replaced.
    foreach ($file in Get-PackageTree (Join-Path $inputRoot 'ui') | Where-Object { !$_.PSIsContainer }) {
        $relative = $file.FullName.Substring((Join-Path $inputRoot 'ui').Length + 1)
        $target = Get-OwnedPath $qaRoot $relative
        $parent = Split-Path $target
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        Set-ProtectedPackageACL $parent -Directory
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        Set-ProtectedPackageACL $target
    }
    $newFiles = @(Get-TreeManifest (Join-Path $inputRoot 'ui'))
    Assert-TreeManifest $qaRoot $newFiles
    $state.files = $newFiles
    $state.build = $installed.build
    $state.serviceSha256 = $serviceHash
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $stateFile -Encoding utf8
    Set-ProtectedPackageACL $stateFile
    $changed = Invoke-CimMethod -InputObject (Get-CimInstance Win32_Service -Filter "Name='ExVPNService'") -MethodName Change -Arguments @{PathName=[string]$state.qaCommand}
    if ($changed.ReturnValue -ne 0) { throw 'Restoring the QA client binding failed.' }
    Start-Service ExVPNService
} else {
    Assert-ProtectedPackage (Split-Path $stateFile)
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    $service = Get-CimInstance Win32_Service -Filter "Name='ExVPNService'"
    # Restore is idempotent for the same protected service/installer identity.
    # A repeated cleanup may restart the production binding to drop cached trust.
    if (($service.PathName -cne $state.qaCommand -and $service.PathName -cne $state.original) -or $service.StartName -ne 'LocalSystem' -or (Get-FileHash -LiteralPath $serviceExe).Hash.ToLowerInvariant() -cne $state.serviceSha256) { throw 'QA service ownership changed; no automatic cleanup.' }
    foreach ($process in Get-Process -Name exvpn -ErrorAction SilentlyContinue) {
        if ($process.Path -ine (Join-Path $qaRoot 'exvpn.exe')) { throw 'An unrelated ExVPN process is running.' }
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit(10000) | Out-Null
    }
    Stop-Maintenance
    $changed = Invoke-CimMethod -InputObject (Get-CimInstance Win32_Service -Filter "Name='ExVPNService'") -MethodName Change -Arguments @{PathName=[string]$state.original}
    if ($changed.ReturnValue -ne 0) { throw 'Restoring the production client binding failed.' }
    Start-Service ExVPNService
    $restored = Get-CimInstance Win32_Service -Filter "Name='ExVPNService'"
    [ordered]@{productionBindingRestored=($restored.PathName -ceq $state.original);serviceRunning=($restored.State -eq 'Running');tunnelAbsent=(!(Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue));installedBuild=$state.build} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputRoot 'restore-report.json') -Encoding utf8
}
