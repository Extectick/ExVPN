# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
param([Parameter(Mandatory)][ValidateSet('Prepare','Crash','Restart','Finish')][string]$Action,[switch]$ConfirmDisposableGuest)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$inputRoot='C:\ExVPN-App-QA'
$outputRoot='C:\ExVPN-App-QA-Results'
$serviceExe='C:\Program Files\ExVPN Service\exvpn-service.exe'
if (!$ConfirmDisposableGuest -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18' -or [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -ine $inputRoot) { throw 'Disposable System runner required.' }
$marker=Get-Content -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Raw | ConvertFrom-Json
if (!$marker.forbiddenHost -or $env:COMPUTERNAME -ieq $marker.forbiddenHost -or !$marker.faults -or $marker.runId -notmatch '^[a-f0-9-]{36}$') { throw 'Fault-enabled guest marker required.' }
trap {
    if (Test-Path -LiteralPath $outputRoot -PathType Container) {
        [ordered]@{action=$Action;error=$_.Exception.Message} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputRoot 'fault-control-error.json') -Encoding utf8
    }
    exit 1
}
$common=@($marker.files | Where-Object path -CEQ 'package-common.ps1')
if ($common.Count -ne 1 -or $common[0].sha256 -cne (Get-FileHash -LiteralPath (Join-Path $inputRoot 'package-common.ps1')).Hash.ToLowerInvariant()) { throw 'Helper checksum mismatch.' }
. (Join-Path $inputRoot 'package-common.ps1')
Assert-TreeManifest $inputRoot $marker.files @('sandbox-bundle.json')
Assert-ProtectedPackage 'C:\Program Files\ExVPN UI QA Control'
$state=Get-Content -LiteralPath 'C:\Program Files\ExVPN UI QA Control\state.json' -Raw | ConvertFrom-Json
$service=Get-CimInstance Win32_Service -Filter "Name='ExVPNService'"
if (!$service -or $service.StartName -ne 'LocalSystem' -or ($service.PathName -cne $state.original -and $service.PathName -cne $state.qaCommand) -or (Get-FileHash -LiteralPath $serviceExe).Hash.ToLowerInvariant() -cne $state.serviceSha256) { throw 'Owned service identity differs.' }
function Read-Guard {
    $json=& (Join-Path $inputRoot 'ui\qa-guard.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Read-only guard inspection failed.' }
    $result=$json | ConvertFrom-Json
    if ($result.readFailed) { throw 'Guard inspection unavailable.' }
    [bool]$result.guardArmed
}
function Network-Fingerprint {
    $routes=@(Get-NetRoute | Select-Object InterfaceIndex,DestinationPrefix,NextHop,RouteMetric,Protocol,PolicyStore | Sort-Object InterfaceIndex,DestinationPrefix,NextHop,RouteMetric,Protocol,PolicyStore)
    $dns=@(Get-DnsClientServerAddress | Select-Object InterfaceIndex,AddressFamily,ServerAddresses | Sort-Object InterfaceIndex,AddressFamily)
    $json=[ordered]@{routes=$routes;dns=$dns} | ConvertTo-Json -Depth 5 -Compress
    $sha=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
$report=[ordered]@{runId=$marker.runId;utc=[DateTime]::UtcNow.ToString('o');action=$Action}
switch ($Action) {
    'Prepare' {
        if ((Read-Guard) -or (Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue) -or $service.State -ne 'Running') { throw 'Guest must start idle and unguarded.' }
        foreach ($process in Get-Process -Name exvpn -ErrorAction SilentlyContinue) {
            if ($process.Path -ine 'C:\Program Files\ExVPN\exvpn.exe') { throw 'Another QA UI is active.' }
            Stop-Process -Id $process.Id -Force
            if (!$process.WaitForExit(10000)) { throw 'Desktop UI did not stop.' }
        }
        $report.networkSha256=Network-Fingerprint
        $report.guardArmed=$false
    }
    'Crash' {
        if ($service.PathName -cne $state.qaCommand -or $service.State -ne 'Running' -or !(Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue) -or !(Read-Guard)) { throw 'An active owned QA tunnel is required before crash.' }
        $process=Get-Process -Id $service.ProcessId -ErrorAction Stop
        if ($process.Path -ine $serviceExe) { throw 'SCM PID does not match the owned executable.' }
        Stop-Process -Id $process.Id -Force
        if (!$process.WaitForExit(10000)) { throw 'SCM process did not terminate.' }
        (Get-Service ExVPNService).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(10))
        $report.scmProcessTerminated=$true
        $report.guardArmed=Read-Guard
        if (!$report.guardArmed) { throw 'Crash lost the owned persistent latch.' }
    }
    'Restart' {
        if ($service.State -eq 'Stopped') { Start-Service ExVPNService }
        (Get-Service ExVPNService).WaitForStatus('Running',[TimeSpan]::FromSeconds(20))
        $report.serviceRunning=$true
        $report.guardArmed=Read-Guard
    }
    'Finish' {
        $baseline=Get-Content -LiteralPath (Join-Path $outputRoot 'fault-Prepare.json') -Raw | ConvertFrom-Json
        if ($baseline.runId -cne $marker.runId) { throw 'Baseline belongs to another run.' }
        $report.guardArmed=Read-Guard
        $report.tunnelAbsent=!(Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue)
        $report.networkSha256=Network-Fingerprint
        $report.networkRestored=$report.networkSha256 -ceq $baseline.networkSha256
        $report.productionBindingRestored=$service.PathName -ceq $state.original
        $report.serviceRunning=$service.State -eq 'Running'
        if ($report.guardArmed -or !$report.tunnelAbsent -or !$report.networkRestored -or !$report.productionBindingRestored -or !$report.serviceRunning) { throw 'Guest cleanup mismatch; inspect before further tests.' }
    }
}
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $outputRoot ('fault-'+$Action+'.json')) -Encoding utf8
