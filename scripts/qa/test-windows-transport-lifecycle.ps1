# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'windows-transport-lifecycle-lib.ps1')
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$directory=Join-Path $repository ('artifacts/qa/windows-transport-fixtures/'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory) | Out-Null
$path=Join-Path $directory 'request.json'
$run='3ad3e97f-8130-4ce8-b382-254532b6f3dc'
$count=0
function Check([bool]$Passed,[string]$Name) { if (!$Passed) { throw "fixture_failed:$Name" }; $script:count++; Write-Host "PASS $Name" }
function Refuse([scriptblock]$Action,[string]$Name) { $refused=$false; try { & $Action | Out-Null } catch { $refused=$true }; Check $refused $Name }
function Request($Value) { $Value | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding utf8NoBOM }
function Marker { @{format=1;forbiddenHost='SYNTHETIC';unelevated=$true;faults=$false;providerMatrix=$false;networkRecovery=$false;transportCycles=3;runId=$run} }
function Sample { @{runId=$run;step=1;action='Observe';passed=$true;sameServiceProcess=$true;qaBinding=$true;serviceRunning=$true;tunnelAbsent=$true;guardArmed=$false;networkRestored=$true} }
function FlutterReport {
    $profiles=@()
    for ($cycle=1; $cycle -le 3; $cycle++) {
        foreach($name in @('VLESS gRPC','VLESS XHTTP','XHTTP REALITY')) {
            $profiles+=@(@{name=$name;cycle=$cycle;passed=$true;explicitDisconnect=$true;disconnectObserved=$true;trafficCountersIncreased=$true;state='connected';numericHttps=@{success=$true;httpStatus=200};tunDns=@{success=$true};hostnameHttps=@{httpStatus=204}})
        }
    }
    @{runId=$run;transportCycles=3;frameworkPassed=$true;allProtocolsPassed=$true;ordinaryUserTokenTested=$true;cleanupDisconnected=$true;nativeVpnMocked=$false;distinctEgressTested=$false;profiles=$profiles}
}
$marker=Marker; Assert-TransportMarker $marker 'SYNTHETIC'; Check $true 'explicit unelevated lifecycle marker accepted'
foreach($change in @(@{transportCycles=0},@{transportCycles=2},@{transportCycles=21},@{transportCycles='3'},@{unelevated=$false},@{unelevated='true'},@{faults=$true},@{providerMatrix=$true},@{networkRecovery=$true},@{forbiddenHost='OTHER'},@{runId='00000000-0000-0000-0000-000000000000'})) {
    $marker=Marker; foreach($name in $change.Keys) { $marker[$name]=$change[$name] }
    Refuse { Assert-TransportMarker $marker 'SYNTHETIC' } ('invalid mode refused: '+($change.Keys -join ','))
}
Check ($null -eq (Get-TransportRequest $path $run 1 9)) 'missing request has no action'
Request @{runId=$run;step=1;action='observe-disconnect'}
Check ((Get-TransportRequest $path $run 1 9).step -eq 1) 'next observation accepted'
Check ($null -eq (Get-TransportRequest $path $run 2 9)) 'already acknowledged request is ignored'
foreach($request in @(@{runId=[guid]::NewGuid().ToString();step=1;action='observe-disconnect'},@{runId=$run;step=2;action='observe-disconnect'},@{runId=$run;step=0;action='observe-disconnect'},@{runId=$run;step=10;action='observe-disconnect'},@{runId=$run;step='1';action='observe-disconnect'},@{runId=$run;step=1;action='restart-service'},@{runId=$run;step=1;action='observe-disconnect';command='not permitted'})) {
    Request $request
    Refuse { Get-TransportRequest $path $run 1 9 } 'stale, reordered, malformed or arbitrary command refused'
}
[IO.File]::WriteAllText($path,('{"runId":"'+$run+'","step":1,"step":1,"action":"observe-disconnect"}'))
Refuse { Get-TransportRequest $path $run 1 9 } 'duplicate request field refused'
[IO.File]::WriteAllText($path,('x'*4097))
Refuse { Get-TransportRequest $path $run 1 9 } 'oversized request refused'
$sample=Sample; Assert-TransportSample $sample $run 1; Check $true 'complete same-process cleanup observation accepted'
foreach($change in @(@{sameServiceProcess=$false},@{qaBinding=$false},@{serviceRunning=$false},@{tunnelAbsent=$false},@{guardArmed=$true},@{networkRestored=$false},@{passed='true'},@{step=2},@{runId=[guid]::NewGuid().ToString()})) {
    $sample=Sample; foreach($name in $change.Keys) { $sample[$name]=$change[$name] }
    Refuse { Assert-TransportSample $sample $run 1 } ('incomplete cleanup refused: '+($change.Keys -join ','))
}
$flutter=FlutterReport; Assert-TransportFlutter $flutter $run 3; Check $true 'all nine real-probe cycle reports accepted'
foreach($change in @(@{frameworkPassed=$false},@{cleanupDisconnected=$false},@{ordinaryUserTokenTested=$false},@{nativeVpnMocked=$true},@{distinctEgressTested=$true},@{transportCycles='3'})) {
    $flutter=FlutterReport; foreach($name in $change.Keys) { $flutter[$name]=$change[$name] }
    Refuse { Assert-TransportFlutter $flutter $run 3 } ('incomplete framework proof refused: '+($change.Keys -join ','))
}
foreach($change in @(@{name='VLESS TCP'},@{cycle=2},@{disconnectObserved=$false},@{explicitDisconnect=$false},@{trafficCountersIncreased=$false},@{state='disconnected'},@{passed='true'},@{numericHttps=@{success=$true;httpStatus=503}},@{tunDns=@{success=$false}},@{hostnameHttps=@{httpStatus=503}})) {
    $flutter=FlutterReport; foreach($name in $change.Keys) { $flutter.profiles[0][$name]=$change[$name] }
    Refuse { Assert-TransportFlutter $flutter $run 3 } ('missing protocol evidence refused: '+($change.Keys -join ','))
}
Write-Host "Windows transport lifecycle: $count synthetic checks PASS. No Sandbox or networking operations performed."
