# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$SandboxId,[Parameter(Mandatory)][string]$HelperExecutable,
      [Parameter(Mandatory)][string]$PrivateNetworkPath,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ServiceSha256)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'teardown-qa-lib.ps1')
. (Join-Path $repository 'scripts/windows/installer/package-common.ps1')
. (Join-Path $repository 'scripts/release/artifact-audit-lib.ps1')
$helper=[IO.Path]::GetFullPath($HelperExecutable)
$private=[IO.Path]::GetFullPath($PrivateNetworkPath)
if(!$helper.StartsWith((Join-Path $repository 'artifacts/qa')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
   !$private.StartsWith((Join-Path $repository '.private')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'teardown_owned_paths_required'}
Assert-AuditNoLinks $helper
Assert-AuditNoLinks $private
$wsb=Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps/wsb.exe'
$inventory=& $wsb list --raw|ConvertFrom-Json
if($LASTEXITCODE -ne 0 -or @($inventory.WindowsSandboxEnvironments|Where-Object Id -EQ $SandboxId.ToString()).Count -ne 1){throw 'teardown_live_sandbox_required'}
$mapping=& (Join-Path $PSScriptRoot 'ensure-windows-lifecycle-mapping.ps1') -SandboxId $SandboxId
$runId=[guid]::NewGuid().ToString('D')
$guestInputRoot=Get-TeardownGuestInputRoot $runId
$resultRoot=Join-Path $mapping.root $runId
[IO.Directory]::CreateDirectory($resultRoot)|Out-Null
$inputRoot=Join-Path (Join-Path $repository '.private/teardown-inputs') $runId
$payloadRoot=Join-Path $inputRoot 'payload'
[IO.Directory]::CreateDirectory($payloadRoot)|Out-Null
Assert-AuditNoLinks $resultRoot
Assert-AuditNoLinks $payloadRoot
$network=Get-Content -LiteralPath $private -Raw|ConvertFrom-Json
$address=$null
if(![Net.IPAddress]::TryParse($network.gateway,[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
   @(Get-NetIPAddress -AddressFamily IPv4|Where-Object IPAddress -EQ $address.ToString()).Count -ne 1){throw 'teardown_exact_local_interface_required'}
$interface=@(Get-NetIPAddress -AddressFamily IPv4|Where-Object IPAddress -EQ $address.ToString())[0]
$adapter=Get-NetAdapter -InterfaceIndex $interface.InterfaceIndex -ErrorAction Stop
if($adapter.InterfaceDescription -notlike 'Hyper-V*'){throw 'teardown_virtual_interface_required'}
$portReservation=[Net.Sockets.TcpListener]::new($address,0);$portReservation.Start()
try{$port=$portReservation.LocalEndpoint.Port}finally{$portReservation.Stop()}
$bytes=[byte[]]::new(32);[Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$marker=[ordered]@{runId=$runId;forbiddenHost=$env:COMPUTERNAME;helperSha256=(Get-FileHash $helper).Hash.ToLowerInvariant();serviceSha256=$ServiceSha256;serviceCommand='"C:\Program Files\ExVPN Service\exvpn-service.exe" -qa-marker';address=($address.ToString()+':'+$port);payloadHex=[Convert]::ToHexString($bytes).ToLowerInvariant();hostResults=$resultRoot}
Copy-Item -LiteralPath $helper -Destination (Join-Path $payloadRoot 'qa-teardown.exe')
foreach($name in @('guest-teardown-qa.ps1','teardown-qa-lib.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $payloadRoot $name)}
Copy-Item -LiteralPath (Join-Path $repository 'scripts/windows/installer/package-common.ps1') -Destination (Join-Path $payloadRoot 'package-common.ps1')
Write-TeardownCheckpoint (Join-Path $payloadRoot 'marker.json') $marker
Write-TeardownCheckpoint (Join-Path $payloadRoot 'bundle.json') ([ordered]@{format=1;runId=$runId;files=@(Get-TreeManifest $payloadRoot)})
$server=Start-Process -FilePath $helper -ArgumentList @('server',('"'+(Join-Path $payloadRoot 'marker.json')+'"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $resultRoot 'server.stdout.log') -RedirectStandardError (Join-Path $resultRoot 'server.stderr.log')
$created=$server.StartTime.ToUniversalTime().ToFileTimeUtc()
$report=[ordered]@{runId=$runId;startedUtc=[DateTime]::UtcNow.ToString('o');helperSha256=$marker.helperSha256;hostNetworkChanged=$false;productionChanged=$false;wireVersion=1;gateStart='host_receives_data_close_intent';gateMs=10000;serverStopped=$false;cleanupPassed=$false;crashInjection=$false;recoveryLimitation='hard_kill_after_arm_before_ownership_checkpoint_remains_fail_closed';cases=@()}
try {
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while(!(Test-Path -LiteralPath (Join-Path $inputRoot 'server/listening.json'))){if($server.HasExited -or [DateTime]::UtcNow -gt $deadline){throw 'teardown_listener_not_ready'};Start-Sleep -Milliseconds 50}
    $null=& $wsb share --id $SandboxId.ToString() --host-path $inputRoot --sandbox-path $guestInputRoot --raw
    if($LASTEXITCODE -ne 0){throw 'teardown_mapping_failed'}
    $command='powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File '+$guestInputRoot+'\payload\guest-teardown-qa.ps1 -Mode Run -RunId '+$runId+' -ConfirmDisposableGuest'
    $cli=& $wsb exec --id $SandboxId.ToString() --run-as System --command $command --raw
    $cli|Set-Content (Join-Path $resultRoot 'guest-cli.json') -Encoding utf8NoBOM
    if($LASTEXITCODE -ne 0 -or ($cli|ConvertFrom-Json).ExitCode -ne 0){throw 'teardown_guest_failed'}
    $cleanup=Get-Content (Join-Path $resultRoot 'cleanup.json') -Raw|ConvertFrom-Json
    $report.cleanupPassed=$cleanup.passed
    foreach($case in @('A','B','C')){
        $client=Get-Content (Join-Path $resultRoot ('client-'+$case+'.json')) -Raw|ConvertFrom-Json
        if($client.runId -cne $runId -or $client.case -cne $case -or $client.wireVersion -ne 1 -or !$client.positiveEstablished -or !$client.peer.positiveEstablished){throw 'teardown_positive_evidence_missing'}
        $report.cases+=@([ordered]@{case=$case;clientPositive=$client.positiveEstablished;serverPositive=$client.peer.positiveEstablished;eof=$client.peer.eof;readEnd=$client.peer.readEnd;passed=$client.peer.passed;elapsedMs=$client.peer.elapsedMs;serverFinalStates=$client.peer.finalStates;guestAfterStates=$client.guestAfterStates;payloadDrained=$client.payloadDrained;readyToCloseStartedNanos=$client.readyToCloseStartedNanos;readyToCloseReturnedNanos=$client.readyToCloseReturnedNanos})
    }
} catch {$report.error='teardown_experiment_failed'} finally {
    $process=Get-Process -Id $server.Id -ErrorAction SilentlyContinue
    if($process){Assert-TeardownProcessIdentity $process $server.Id $created $helper;Stop-Process -Id $server.Id -Force;$process.WaitForExit(5000)|Out-Null}
    $report.serverStopped=!(Get-Process -Id $server.Id -ErrorAction SilentlyContinue)
    $report.finishedUtc=[DateTime]::UtcNow.ToString('o')
    Write-TeardownCheckpoint (Join-Path $resultRoot 'experiment.json') $report
    $report|ConvertTo-Json -Depth 10
    Write-Host ('Private evidence: '+$resultRoot)
}
if(!$report.cleanupPassed -or $report.cases.Count -ne 3 -or !$report.serverStopped){exit 1}
