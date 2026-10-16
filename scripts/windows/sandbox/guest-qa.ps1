# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
[CmdletBinding()]
param([switch]$ConfirmDisposableGuest)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$inputRoot = 'C:\ExVPN-Package'
$outputRoot = 'C:\ExVPN-QA'
if (!$ConfirmDisposableGuest -or $env:USERNAME -cne 'WDAGUtilityAccount' -or
    [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -ine $inputRoot) { throw 'This runner is restricted to the explicitly prepared disposable Windows Sandbox.' }
$bundle = Get-Content -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Raw | ConvertFrom-Json
if ($bundle.format -ne 1 -or $env:COMPUTERNAME -ieq $bundle.forbiddenHost -or
    !(Test-Path -LiteralPath $outputRoot -PathType Container)) { throw 'Sandbox isolation preflight failed.' }
foreach ($record in $bundle.files) {
    if ($record.file -notmatch '^[A-Za-z0-9_.-]+$' -or $record.sha256 -notmatch '^[a-f0-9]{64}$' -or
        (Get-FileHash -LiteralPath (Join-Path $inputRoot $record.file) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $record.sha256) { throw 'Sandbox input checksum mismatch.' }
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (![Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Ordinary guest UAC only. This branch is unreachable on the workstation:
    # exact guest account, paths and forbidden host are checked first.
    $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File C:\ExVPN-Package\guest-qa.ps1 -ConfirmDisposableGuest' -Verb RunAs -WindowStyle Hidden -PassThru -Wait
    exit $process.ExitCode
}
if (![Environment]::Is64BitProcess) { throw 'Sandbox QA requires 64-bit Windows PowerShell.' }
$reportPath = Join-Path $outputRoot 'result.json'
if (Test-Path -LiteralPath $reportPath) { throw 'Output already contains a result. Prepare a fresh sandbox bundle for each run.' }
$steps = [Collections.Generic.List[object]]::new()
$report = [ordered]@{ format=1; status='running'; startedUtc=[DateTime]::UtcNow.ToString('o'); installerSha256=$bundle.installerSha256; networkTesting=$false; uiTested=$false; tunnelTested=$false; upgradeTested=$false; steps=$steps }
function Save-Report { $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8 }
function Pass([string]$Name) { $steps.Add([ordered]@{name=$Name;result='passed'}); Save-Report }
function Wait-OwnedProcess($Process) {
    if (!$Process.WaitForExit(180000)) { throw 'Package process timed out. Guest retained for inspection; no forced termination or network reset.' }
    $Process.Refresh()
    if ($Process.ExitCode -ne 0) { throw 'Package process reported failure. Protected staging remains in the guest.' }
}
$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$uiRoot = Join-Path $programFiles 'ExVPN'
$serviceRoot = Join-Path $programFiles 'ExVPN Service'
$controlRoot = Join-Path $programFiles 'ExVPN Installer'
$statePath = Join-Path $controlRoot 'install-state.json'
$registrationPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ExVPN'
function Get-NetworkFingerprint {
    # Read-only and credential-free snapshots. Compare route/DNS values in memory;
    # write only digests, never addresses or arbitrary system logs, to host output.
    $routes = @(Get-NetRoute | Select-Object InterfaceIndex,DestinationPrefix,NextHop,RouteMetric,Protocol,PolicyStore | Sort-Object InterfaceIndex,DestinationPrefix,NextHop)
    $dns = @(Get-DnsClientServerAddress | Select-Object InterfaceIndex,AddressFamily,ServerAddresses | Sort-Object InterfaceIndex,AddressFamily)
    $bytes = [Text.Encoding]::UTF8.GetBytes(([ordered]@{routes=$routes;dns=$dns} | ConvertTo-Json -Depth 6 -Compress))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Assert-ServiceRunning {
    $service = Get-CimInstance Win32_Service -Filter "Name='ExVPNService'"
    $expected = '"' + (Join-Path $serviceRoot 'exvpn-service.exe') + '" -owner-sid ' + $identity.User.Value + ' -client "' + (Join-Path $uiRoot 'exvpn.exe') + '"'
    if (!$service -or $service.State -ne 'Running' -or $service.StartName -ne 'LocalSystem' -or $service.PathName -cne $expected) { throw 'Installed SCM identity/configuration is incorrect.' }
}
function Invoke-Maintenance([string]$Mode) {
    $uninstaller = Join-Path $controlRoot 'Uninstall.exe'
    $args = '/S'; if ($Mode) { $args += ' /' + $Mode + '=1' }
    # _?= runs this exact installed uninstaller synchronously rather than letting
    # the NSIS initial copy exit before its maintenance child has finished.
    # Run a verified copy in guest Temp so cleanup can remove the installed EXE.
    $temporary = Join-Path $env:TEMP ('ExVPN-QA-Uninstall-' + [Guid]::NewGuid().ToString('N') + '.exe')
    Copy-Item -LiteralPath $uninstaller -Destination $temporary
    if ((Get-FileHash -LiteralPath $temporary).Hash -ne (Get-FileHash -LiteralPath $uninstaller).Hash) { throw 'Maintenance copy mismatch.' }
    $process = Start-Process -FilePath $temporary -ArgumentList ($args + ' _?=' + $controlRoot) -PassThru -WindowStyle Hidden
    Wait-OwnedProcess $process
    Remove-Item -LiteralPath $temporary
}
try {
    Save-Report
    foreach ($path in @($uiRoot,$serviceRoot,$controlRoot)) { if (Test-Path -LiteralPath $path) { throw 'Guest already has an ExVPN installation.' } }
    if ((Get-Service ExVPNService -ErrorAction SilentlyContinue) -or (Test-Path $registrationPath)) { throw 'Guest is not clean.' }
    $beforeNetwork = Get-NetworkFingerprint
    Pass 'disposable_guest_and_input_hashes'
    $installer = Join-Path $inputRoot $bundle.installerFile
    Wait-OwnedProcess (Start-Process -FilePath $installer -ArgumentList ('/S /OWNER_SID=' + $identity.User.Value) -PassThru -WindowStyle Hidden)
    Assert-ServiceRunning
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($state.networkTesting -or $state.ownerSid -cne $identity.User.Value) { throw 'Unexpected network testing or IPC ownership.' }
    . (Join-Path $controlRoot 'package-common.ps1')
    foreach ($pair in @(@('ui',$uiRoot),@('service',$serviceRoot),@('control',$controlRoot))) {
        Assert-ProtectedPackage $pair[1]
        $ignore = @(); if ($pair[0] -eq 'control') { $ignore = @('install-state.json') }
        Assert-TreeManifest $pair[1] $state.trees.($pair[0]) $ignore
    }
    Pass 'install_service_and_protected_manifests'
    $serviceAcl = & "$env:SystemRoot\System32\sc.exe" sdshow ExVPNService
    if ($LASTEXITCODE -ne 0) { throw 'Service ACL readback failed.' }
    Assert-ServiceControlAcl ($serviceAcl -join '')
    Pass 'service_control_acl'
    Invoke-Maintenance 'RECOVER'
    if ((Get-Service ExVPNService).Status -ne 'Stopped' -or (Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue)) { throw 'Recovery did not leave the owned service stopped with no tunnel.' }
    Pass 'explicit_recovery_stops_service'
    Start-Service ExVPNService
    (Get-Service ExVPNService).WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(20))
    Assert-ServiceRunning
    Pass 'restart_after_recovery'
    Invoke-Maintenance ''
    foreach ($path in @($uiRoot,$serviceRoot,$controlRoot)) { if (Test-Path -LiteralPath $path) { throw 'Owned installation files remain after uninstall.' } }
    if ((Get-Service ExVPNService -ErrorAction SilentlyContinue) -or (Test-Path $registrationPath) -or (Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue)) { throw 'Owned service/registration/tunnel remains after uninstall.' }
    Pass 'uninstall_owned_resources'
    $afterNetwork = Get-NetworkFingerprint
    $report.networkBeforeSha256=$beforeNetwork; $report.networkAfterSha256=$afterNetwork
    if ($beforeNetwork -cne $afterNetwork) { throw 'Guest routes/DNS changed; inspect the disposable guest before acceptance.' }
    Pass 'guest_routes_dns_unchanged'
    $report.status='passed'
    $report.skipped=@('interactive_UI_and_named_pipe','VPN_TUN_WFP_and_crash_matrix','upgrade_failed_upgrade_and_rollback_require_version_pair','Windows_reboot_sleep_and_Windows10')
} catch {
    $report.status='failed'; $report.errorType=$_.Exception.GetType().FullName
    $report.error=$_.Exception.Message
    # No raw service logs, private profile data or host paths are collected.
} finally { $report.finishedUtc=[DateTime]::UtcNow.ToString('o'); Save-Report }
if ($report.status -ne 'passed') { exit 1 }
exit 0
