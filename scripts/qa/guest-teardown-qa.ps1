# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Run','Watchdog')][string]$Mode,
      [Parameter(Mandatory)][string]$RunId,[switch]$ConfirmDisposableGuest)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'teardown-qa-lib.ps1')
Assert-TeardownRunId $RunId
$inputRoot=Join-Path (Get-TeardownGuestInputRoot $RunId) 'payload'
$controlRoot=Join-Path 'C:\Program Files\ExVPN Teardown QA' $RunId
$outputRoot=Join-Path 'C:\ExVPN-Lifecycle-QA-Results' $RunId
$expectedRoot=if($Mode -ceq 'Run'){$inputRoot}else{$controlRoot}
$marker=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'marker.json') -Raw|ConvertFrom-Json
if (!$ConfirmDisposableGuest -or $marker.runId -cne $RunId) { throw 'teardown_confirmation_required' }
Assert-TeardownGuestContext $env:COMPUTERNAME $marker.forbiddenHost ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) $PSScriptRoot $expectedRoot
$bundle=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'bundle.json') -Raw|ConvertFrom-Json
$common=@($bundle.files | Where-Object path -CEQ 'package-common.ps1')
if ($common.Count -ne 1 -or $common[0].sha256 -cne (Get-FileHash (Join-Path $PSScriptRoot 'package-common.ps1')).Hash.ToLowerInvariant()) { throw 'teardown_helper_hash_mismatch' }
. (Join-Path $PSScriptRoot 'package-common.ps1')
$serviceExe='C:\Program Files\ExVPN Service\exvpn-service.exe'
$helper=Join-Path $controlRoot 'qa-teardown.exe'
function Inspect-Guard {
    $text=& $helper inspect 2> (Join-Path $controlRoot 'inspect.stderr.log')
    if($LASTEXITCODE -ne 0){throw 'teardown_guard_read_failed'}
    $value=$text|ConvertFrom-Json
    if($value.armed -isnot [bool]){throw 'teardown_guard_read_failed'}
    $value.armed
}
function Assert-ServiceIdentity($Baseline) {
    Assert-ProtectedPackage 'C:\Program Files\ExVPN Service'
    if((Get-FileHash $serviceExe).Hash.ToLowerInvariant() -cne $marker.serviceSha256){throw 'teardown_service_hash_changed'}
    $service=Get-CimInstance Win32_Service -Filter "Name='ExVPNService'"
    if(!$service -or $service.PathName -cne $Baseline.serviceCommand -or $service.StartName -cne 'LocalSystem'){throw 'teardown_service_changed'}
    $service
}
if($Mode -ceq 'Run') {
    Assert-TreeManifest $inputRoot $bundle.files @('bundle.json')
    if((Get-FileHash (Join-Path $inputRoot 'qa-teardown.exe')).Hash.ToLowerInvariant() -cne $marker.helperSha256 -or
        !(Test-Path -LiteralPath $outputRoot -PathType Container) -or (Test-Path -LiteralPath $controlRoot)) {throw 'teardown_owned_paths_required'}
    Assert-ProtectedPackage 'C:\Program Files\ExVPN UI QA Control'
    $installedControl=Get-Content 'C:\Program Files\ExVPN UI QA Control\state.json' -Raw|ConvertFrom-Json
    $service=Get-CimInstance Win32_Service -Filter "Name='ExVPNService'"
    if($service.State -cne 'Running' -or $service.PathName -cne $installedControl.original -or $service.StartName -cne 'LocalSystem' -or
        $installedControl.serviceSha256 -cne $marker.serviceSha256 -or (Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue) -or
        (Get-Process -Name exvpn -ErrorAction SilentlyContinue)){throw 'teardown_clean_idle_service_required'}
    $fixtureAddress=($marker.address -split ':')[0]
    if(@(Get-NetRoute -DestinationPrefix '0.0.0.0/0'|Where-Object NextHop -EQ $fixtureAddress).Count -ne 1){throw 'teardown_guest_gateway_mismatch'}
    if(!(Test-Path -LiteralPath (Split-Path $controlRoot))){New-Item -ItemType Directory -Path (Split-Path $controlRoot)|Out-Null;Set-ProtectedPackageACL (Split-Path $controlRoot) -Directory}
    Assert-ProtectedPackage (Split-Path $controlRoot)
    Copy-OwnedTree $inputRoot $controlRoot $bundle.files
    Copy-Item -LiteralPath (Join-Path $inputRoot 'bundle.json') -Destination (Join-Path $controlRoot 'bundle.json')
    Set-ProtectedPackageACL (Join-Path $controlRoot 'bundle.json')
    $effective=$marker.PSObject.Copy();$effective.serviceCommand=$service.PathName
    Write-TeardownCheckpoint (Join-Path $controlRoot 'config.json') $effective
    Assert-ProtectedPackage $controlRoot
    $preflight=& $helper preflight 2> (Join-Path $controlRoot 'preflight.stderr.log')
    if($LASTEXITCODE -ne 0 -or !($preflight|ConvertFrom-Json).luidAbsent){throw 'teardown_luid_preflight_failed'}
    if(Inspect-Guard){throw 'teardown_guard_initially_armed'}
    $parent=Get-Process -Id $PID
    $baseline=[ordered]@{runId=$RunId;serviceCommand=$service.PathName;serviceRunning=$true;guardArmed=$false;tunnelAbsent=$true;networkSha256=(Get-TeardownNetworkHash);parentPid=$PID;parentCreated=$parent.StartTime.ToUniversalTime().ToFileTimeUtc();parentPath=$parent.Path;helperSha256=$marker.helperSha256}
    Write-TeardownCheckpoint (Join-Path $controlRoot 'baseline.json') $baseline
    Copy-Item -LiteralPath (Join-Path $controlRoot 'baseline.json') -Destination (Join-Path $outputRoot 'baseline.json')
    $watchdog=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $controlRoot 'guest-teardown-qa.ps1')+'"'),'-Mode','Watchdog','-RunId',$RunId,'-ConfirmDisposableGuest') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $controlRoot 'watchdog.stdout.log') -RedirectStandardError (Join-Path $controlRoot 'watchdog.stderr.log')
    $readyDeadline=[DateTime]::UtcNow.AddSeconds(8)
    while(!(Test-Path -LiteralPath (Join-Path $controlRoot 'watchdog-ready.json'))){if($watchdog.HasExited -or [DateTime]::UtcNow -gt $readyDeadline){throw 'teardown_watchdog_not_ready'};Start-Sleep -Milliseconds 50}
    try {
        [void](Assert-ServiceIdentity $baseline)
        Stop-Service ExVPNService
        (Get-Service ExVPNService).WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(20))
        if(Inspect-Guard){throw 'teardown_guard_changed_before_client'}
        $client=Start-Process -FilePath $helper -ArgumentList 'client' -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $controlRoot 'client.stdout.log') -RedirectStandardError (Join-Path $controlRoot 'client.stderr.log')
        $identity=[ordered]@{pid=$client.Id;created=$client.StartTime.ToUniversalTime().ToFileTimeUtc()}
        Write-TeardownCheckpoint (Join-Path $controlRoot 'authorized.json') $identity
        $deadline=[DateTime]::UtcNow.AddSeconds(100)
        while(!(Test-Path -LiteralPath (Join-Path $outputRoot 'cleanup.json'))){if([DateTime]::UtcNow -gt $deadline){throw 'teardown_watchdog_deadline'};Start-Sleep -Milliseconds 100}
        $cleanup=Get-Content (Join-Path $outputRoot 'cleanup.json') -Raw|ConvertFrom-Json
        if(!$cleanup.passed){throw 'teardown_cleanup_failed'}
    } finally {
        # The independent watchdog owns process/guard/SCM recovery, even if this
        # launcher exits. It never shares cleanup ownership with this branch.
        Write-TeardownCheckpoint (Join-Path $controlRoot 'launcher-finished.json') ([ordered]@{runId=$RunId})
    }
    exit 0
}

# Independent cleanup process; invoked only from the protected run directory.
Assert-ProtectedPackage $controlRoot
$baseline=Get-Content (Join-Path $controlRoot 'baseline.json') -Raw|ConvertFrom-Json
if($baseline.runId -cne $RunId -or !$baseline.serviceRunning -or $baseline.guardArmed -or !$baseline.tunnelAbsent -or
    (Get-FileHash $helper).Hash.ToLowerInvariant() -cne $baseline.helperSha256){throw 'teardown_baseline_rejected'}
$maintenance=Enter-MachineMaintenanceLock
$result=[ordered]@{runId=$RunId;passed=$false;helperStopped=$false;guardArmed=$true;serviceRunning=$false;tunnelAbsent=$false;networkRestored=$false;watchdogTimedOut=$false}
try {
    Write-TeardownCheckpoint (Join-Path $controlRoot 'watchdog-ready.json') ([ordered]@{runId=$RunId;ready=$true})
    $deadline=[DateTime]::UtcNow.AddSeconds(75)
    $authorized=$null
    while($true) {
        if(Test-Path -LiteralPath (Join-Path $controlRoot 'authorized.json')){$authorized=Get-Content (Join-Path $controlRoot 'authorized.json') -Raw|ConvertFrom-Json}
        $parent=Get-Process -Id $baseline.parentPid -ErrorAction SilentlyContinue
        $parentAlive=$false
        if($parent){try{Assert-TeardownProcessIdentity $parent $baseline.parentPid $baseline.parentCreated $baseline.parentPath;$parentAlive=$true}catch{}}
        if($authorized){$client=Get-Process -Id $authorized.pid -ErrorAction SilentlyContinue;if(!$client){break};Assert-TeardownProcessIdentity $client $authorized.pid $authorized.created $helper}
        if(!$parentAlive -or [DateTime]::UtcNow -gt $deadline){$result.watchdogTimedOut=$true;break}
        Start-Sleep -Milliseconds 100
    }
    if($authorized){
        $client=Get-Process -Id $authorized.pid -ErrorAction SilentlyContinue
        if($client){Assert-TeardownProcessIdentity $client $authorized.pid $authorized.created $helper;Stop-Process -Id $authorized.pid -Force;$client.WaitForExit(5000)|Out-Null}
        if(Get-Process -Id $authorized.pid -ErrorAction SilentlyContinue){throw 'teardown_client_not_stopped'}
    }
    $result.helperStopped=$true
    [void](Assert-ServiceIdentity $baseline)
    if((Get-Service ExVPNService).Status -ne 'Stopped'){(Get-Service ExVPNService).WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(8))}
    if(Inspect-Guard){
        if(!$authorized){throw 'teardown_unowned_guard'}
        & $helper cleanup 1> (Join-Path $controlRoot 'recover.stdout.log') 2> (Join-Path $controlRoot 'recover.stderr.log')
        if($LASTEXITCODE -ne 0){throw 'teardown_owned_recovery_failed'}
    }
    $result.guardArmed=Inspect-Guard
    if($result.guardArmed){throw 'teardown_guard_remains'}
    Start-Service ExVPNService
    (Get-Service ExVPNService).WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(15))
    $restored=Assert-ServiceIdentity $baseline
    $result.serviceRunning=$restored.State -ceq 'Running'
    $result.tunnelAbsent=!(Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue)
    $result.networkSha256=Get-TeardownNetworkHash
    $result.networkRestored=$result.networkSha256 -ceq $baseline.networkSha256
    $result.passed=$result.helperStopped -and !$result.guardArmed -and $result.serviceRunning -and $result.tunnelAbsent -and $result.networkRestored
} catch {$result.error='teardown_watchdog_failed'} finally {
    $maintenance.ReleaseMutex();$maintenance.Dispose()
    foreach($file in Get-ChildItem -LiteralPath $controlRoot -File|Where-Object {$_.Extension -in @('.json','.log')}){
        $destination=Join-Path $outputRoot ('protected-'+$file.Name)
        if(!(Test-Path -LiteralPath $destination)){Copy-Item -LiteralPath $file.FullName -Destination $destination}
    }
    Write-TeardownCheckpoint (Join-Path $outputRoot 'cleanup.json') $result
}
if(!$result.passed){exit 1}
