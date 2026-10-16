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
function Sample { @{runId=$run;step=1;action='Observe';passed=$true;sameServiceProcess=$true;qaBinding=$true;serviceRunning=$true;tunnelAbsent=$true;guardArmed=$false;networkRestored=$true;selectedServiceEstablishedConnections=0} }
function ConnectedSample { @{runId=$run;step=1;action='Connected';passed=$true;sameServiceProcess=$true;qaBinding=$true;serviceRunning=$true;tunnelAbsent=$false;guardArmed=$true;selectedServiceEstablishedConnections=1} }
function FlutterReport {
    $profiles=@()
    for ($cycle=1; $cycle -le 3; $cycle++) {
        foreach($name in @('VLESS gRPC','VLESS XHTTP','XHTTP REALITY')) {
            $profiles+=@(@{name=$name;cycle=$cycle;passed=$true;explicitDisconnect=$true;connectedObserved=$true;disconnectObserved=$true;trafficCountersIncreased=$true;state='connected';numericHttps=@{success=$true;httpStatus=200};tunDns=@{success=$true};hostnameHttps=@{httpStatus=204}})
        }
    }
    @{runId=$run;transportCycles=3;frameworkPassed=$true;allProtocolsPassed=$true;ordinaryUserTokenTested=$true;cleanupDisconnected=$true;nativeVpnMocked=$false;distinctEgressTested=$false;profiles=$profiles}
}
Assert-TransportRunId $run; Check $true 'canonical nonzero run ID accepted'
foreach($invalid in @('', '../elsewhere', 'C:\\elsewhere', '00000000-0000-0000-0000-000000000000', ($run+'/child'), $run.ToUpperInvariant())) {
    Refuse { Assert-TransportRunId $invalid } 'noncanonical, zero or escaping run ID refused'
}
$expected=[ordered]@{format=1;runId=$run;build=11;cycles=3;bundleManifestSha256=('a'*64);fixtureExecutableSha256=('b'*64);fixtureProcessId=1234;fixtureStartedUtcTicks=[long]638962505792483947;fixtureManifestSha256=('c'*64);subscriptionSha256=('d'*64)}
function Prepared($Reservation=$expected,$Upgrade=$null,[string]$Extra='') {
    $result=Join-Path $directory ([guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($result) | Out-Null
    $Reservation | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $result 'transport-reservation.json') -Encoding utf8NoBOM
    if ($null -ne $Upgrade) { $Upgrade | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $result 'upgrade-report.json') -Encoding utf8NoBOM }
    if ($Extra) { [IO.File]::WriteAllText((Join-Path $result $Extra),'{}') }
    $result
}
$prepared=Prepared; Assert-TransportPreparedResults $prepared $expected; Check $true 'exact prepared reservation can be reused before starting'
Assert-TransportPreparedResults $prepared $expected; Check $true 'second validation preserves prepared reservation'
$upgrade=@{runId=$run;passed=$true;exitCode=0;installedBuild=11;upgradedFromBuild=10}
$prepared=Prepared -Upgrade $upgrade; Assert-TransportPreparedResults $prepared $expected; Check $true 'matching successful upgrade permits starting the reserved run'
foreach($change in @(@{runId=[guid]::NewGuid().ToString()},@{build=12},@{fixtureExecutableSha256=('e'*64)},@{fixtureStartedUtcTicks=638962505792483948L},@{fixtureProcessId='1234'},@{extra='unexpected'})) {
    $reservation=[ordered]@{}; foreach($name in $expected.Keys) { $reservation[$name]=$expected[$name] }; foreach($name in $change.Keys) { $reservation[$name]=$change[$name] }
    $prepared=Prepared -Reservation $reservation
    Refuse { Assert-TransportPreparedResults $prepared $expected } ('changed reservation refused: '+($change.Keys -join ','))
}
foreach($change in @(@{runId=[guid]::NewGuid().ToString()},@{passed=$false},@{passed='true'},@{exitCode=1},@{installedBuild=12},@{upgradedFromBuild=11},@{upgradedFromBuild=0},@{installedBuild='11'})) {
    $changed=$upgrade.Clone(); foreach($name in $change.Keys) { $changed[$name]=$change[$name] }; $prepared=Prepared -Upgrade $changed
    Refuse { Assert-TransportPreparedResults $prepared $expected } ('stale or invalid upgrade refused: '+($change.Keys -join ','))
}
foreach($extra in @('transport-started.json','transport-coordinator.json')) {
    $prepared=Prepared -Extra $extra
    Refuse { Assert-TransportPreparedResults $prepared $expected } 'started or completed run cannot overwrite results'
}
$prepared=Prepared; [IO.File]::WriteAllText((Join-Path $prepared 'transport-reservation.json'),('x'*65537))
Refuse { Assert-TransportPreparedResults $prepared $expected } 'oversized reservation refused'
$marker=Marker; Assert-TransportMarker $marker 'SYNTHETIC'; Check $true 'explicit unelevated lifecycle marker accepted'
foreach($change in @(@{transportCycles=0},@{transportCycles=2},@{transportCycles=21},@{transportCycles='3'},@{unelevated=$false},@{unelevated='true'},@{faults=$true},@{providerMatrix=$true},@{networkRecovery=$true},@{forbiddenHost='OTHER'},@{runId='00000000-0000-0000-0000-000000000000'})) {
    $marker=Marker; foreach($name in $change.Keys) { $marker[$name]=$change[$name] }
    Refuse { Assert-TransportMarker $marker 'SYNTHETIC' } ('invalid mode refused: '+($change.Keys -join ','))
}
Check ($null -eq (Get-TransportRequest $path $run 1 9)) 'missing request has no action'
Request @{runId=$run;step=1;action='observe-disconnect'}
Check ((Get-TransportRequest $path $run 1 9).step -eq 1) 'next observation accepted'
Check ($null -eq (Get-TransportRequest $path $run 2 9)) 'already acknowledged request is ignored'
Refuse { Get-TransportRequest $path $run 1 9 'observe-connected' } 'disconnect phase before connected proof refused'
Request @{runId=$run;step=1;action='observe-connected'}
Check ((Get-TransportRequest $path $run 1 9 'observe-connected').action -ceq 'observe-connected') 'connected checkpoint accepted in the correct phase'
Check ($null -eq (Get-TransportRequest $path $run 1 9 'observe-disconnect')) 'stale connected request ignored while waiting for disconnect'
Check ($null -eq (Get-TransportRequest $path $run 2 9 'observe-connected')) 'prior connected step cannot acknowledge a new cycle'
Request @{runId=$run;step=2;action='observe-connected'}
Refuse { Get-TransportRequest $path $run 1 9 'observe-disconnect' } 'future connected step cannot skip pending disconnect'
$connectedAck=New-TransportAck $run 1 'observe-connected' $true
$disconnectedAck=New-TransportAck $run 1 'observe-disconnect' $true
Check ($connectedAck.runId -ceq $run -and $connectedAck.step -eq 1 -and $connectedAck.action -ceq 'observe-connected' -and $connectedAck.ok -is [bool] -and $connectedAck.ok) 'connected acknowledgement binds run, step and phase'
Check ($disconnectedAck.action -cne $connectedAck.action -and $disconnectedAck.step -eq $connectedAck.step) 'same-step connected acknowledgement differs from disconnect'
foreach($invalid in @(@{step=0;action='observe-connected';passed=$true},@{step=61;action='observe-connected';passed=$true},@{step='1';action='observe-connected';passed=$true},@{step=1;action='restart-service';passed=$true},@{step=1;action='observe-connected';passed='true'})) {
    Refuse { New-TransportAck $run $invalid.step $invalid.action $invalid.passed } 'invalid acknowledgement cannot be created'
}
foreach($request in @(@{runId=[guid]::NewGuid().ToString();step=1;action='observe-disconnect'},@{runId=$run;step=2;action='observe-disconnect'},@{runId=$run;step=0;action='observe-disconnect'},@{runId=$run;step=10;action='observe-disconnect'},@{runId=$run;step='1';action='observe-disconnect'},@{runId=$run;step=1;action='restart-service'},@{runId=$run;step=1;action='observe-disconnect';command='not permitted'})) {
    Request $request
    Refuse { Get-TransportRequest $path $run 1 9 } 'stale, reordered, malformed or arbitrary command refused'
}
[IO.File]::WriteAllText($path,('{"runId":"'+$run+'","step":1,"step":1,"action":"observe-disconnect"}'))
Refuse { Get-TransportRequest $path $run 1 9 } 'duplicate request field refused'
[IO.File]::WriteAllText($path,('x'*4097))
Refuse { Get-TransportRequest $path $run 1 9 } 'oversized request refused'
$sample=Sample; Assert-TransportSample $sample $run 1; Check $true 'complete same-process cleanup observation accepted'
$connected=ConnectedSample; Assert-TransportConnectedSample $connected $run 1; Check $true 'same-service active socket positive control accepted'
foreach($change in @(@{sameServiceProcess=$false},@{qaBinding=$false},@{serviceRunning=$false},@{tunnelAbsent=$true},@{guardArmed=$false},@{selectedServiceEstablishedConnections=0},@{selectedServiceEstablishedConnections='1'},@{action='Observe'},@{step=2},@{runId=[guid]::NewGuid().ToString()})) {
    $connected=ConnectedSample; foreach($name in $change.Keys) { $connected[$name]=$change[$name] }
    Refuse { Assert-TransportConnectedSample $connected $run 1 } ('missing active socket proof refused: '+($change.Keys -join ','))
}
foreach($change in @(@{sameServiceProcess=$false},@{qaBinding=$false},@{serviceRunning=$false},@{tunnelAbsent=$false},@{guardArmed=$true},@{networkRestored=$false},@{selectedServiceEstablishedConnections=1},@{selectedServiceEstablishedConnections='0'},@{passed='true'},@{step=2},@{runId=[guid]::NewGuid().ToString()})) {
    $sample=Sample; foreach($name in $change.Keys) { $sample[$name]=$change[$name] }
    Refuse { Assert-TransportSample $sample $run 1 } ('incomplete cleanup refused: '+($change.Keys -join ','))
}
$flutter=FlutterReport; Assert-TransportFlutter $flutter $run 3; Check $true 'all nine real-probe cycle reports accepted'
foreach($change in @(@{frameworkPassed=$false},@{cleanupDisconnected=$false},@{ordinaryUserTokenTested=$false},@{nativeVpnMocked=$true},@{distinctEgressTested=$true},@{transportCycles='3'})) {
    $flutter=FlutterReport; foreach($name in $change.Keys) { $flutter[$name]=$change[$name] }
    Refuse { Assert-TransportFlutter $flutter $run 3 } ('incomplete framework proof refused: '+($change.Keys -join ','))
}
foreach($change in @(@{name='VLESS TCP'},@{cycle=2},@{connectedObserved=$false},@{disconnectObserved=$false},@{explicitDisconnect=$false},@{trafficCountersIncreased=$false},@{state='disconnected'},@{passed='true'},@{numericHttps=@{success=$true;httpStatus=503}},@{tunDns=@{success=$false}},@{hostnameHttps=@{httpStatus=503}})) {
    $flutter=FlutterReport; foreach($name in $change.Keys) { $flutter.profiles[0][$name]=$change[$name] }
    Refuse { Assert-TransportFlutter $flutter $run 3 } ('missing protocol evidence refused: '+($change.Keys -join ','))
}
# Exercise the actual guest metadata function under both parsers. Only this
# AST function is loaded: the guest guard, network reader and netstat never run.
$tokens=$null; $parseErrors=$null
$observerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'guest-transport-observe.ps1'),[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw 'guest_observer_parse_failed' }
$metadataFunctions=@($observerAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Read-TransportFixtureMetadata'},$false))
if ($metadataFunctions.Count -ne 1) { throw 'guest_metadata_function_missing' }
$metadataRunner=Join-Path $directory 'metadata-fixtures.ps1'
$metadataCode=@'
param([string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
'@ + [Environment]::NewLine + $metadataFunctions[0].Extent.Text + [Environment]::NewLine + @'
$metadataChecks=0
$names=@('VLESS TCP','VLESS REALITY','VLESS Vision','VLESS XHTTP','XHTTP REALITY','VLESS gRPC','VMess','Shadowsocks')
function Records { for($i=0;$i -lt $names.Count;$i++) { [pscustomobject]@{name=$names[$i];port=(30001+$i)} } }
function Write-Data($Records,[string[]]$Links) {
    [IO.Directory]::CreateDirectory($FixtureRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $FixtureRoot 'manifest.json'),(ConvertTo-Json -InputObject $Records -Depth 5))
    if ($null -eq $Links) { $Links=@($Records | ForEach-Object {'vless://synthetic@127.0.0.1:'+$_.port+'#'+[uri]::EscapeDataString($_.name)}) }
    [IO.File]::WriteAllLines((Join-Path $FixtureRoot 'subscription.txt'),$Links)
}
function Assert([bool]$Value) { if(!$Value){throw 'metadata_fixture_failed'}; $script:metadataChecks++ }
function Refuse([scriptblock]$Action) { $refused=$false;try{& $Action | Out-Null}catch{$refused=$true};Assert $refused }
for($step=1;$step -le 3;$step++) {
    Write-Data (Records) $null
    $actual=Read-TransportFixtureMetadata $FixtureRoot $step
    $expectedIndex=@(6,4,5)[$step-1]
    Assert ($actual.ports.Count -eq 8 -and $actual.selectedFixtureIndex -eq $expectedIndex -and $actual.selectedPort -eq (30000+$expectedIndex) -and $actual.address.ToString() -ceq '127.0.0.1')
}
foreach($bad in @('nested','duplicate-port','string-port','unknown-name','duplicate-name','missing-profile')) {
    $records=@(Records)
    switch($bad) {
        'nested' { Write-Data (,($records)) $null }
        'duplicate-port' { $records[5].port=$records[0].port;Write-Data $records $null }
        'string-port' { $records[5].port='30006';Write-Data $records $null }
        'unknown-name' { $records[5].name='unrecognized';Write-Data $records $null }
        'duplicate-name' { $records[5].name=$records[0].name;Write-Data $records $null }
        'missing-profile' { Write-Data $records[0..6] $null }
    }
    Refuse { Read-TransportFixtureMetadata $FixtureRoot 1 }
}
foreach($badLinks in @(
    @('vless://synthetic@invalid.example:30006#VLESS%20gRPC'),
    @('vless://synthetic@127.0.0.1:30006#wrong'),
    @('vless://synthetic@127.0.0.1:30007#VLESS%20gRPC'),
    @('vless://synthetic@127.0.0.1:30006#VLESS%20gRPC','vless://synthetic@127.0.0.1:30006#VLESS%20gRPC')
)) {
    Write-Data (Records) $badLinks
    Refuse { Read-TransportFixtureMetadata $FixtureRoot 1 }
}
Write-Data (Records) $null
Refuse { Read-TransportFixtureMetadata $FixtureRoot 0 }
Refuse { Read-TransportFixtureMetadata $FixtureRoot 61 }
Write-Output ('metadata_checks='+$metadataChecks)
'@
[IO.File]::WriteAllText($metadataRunner,$metadataCode)
$runtimes=@(@{name='PowerShell 7';command=(Get-Process -Id $PID).Path})
if ($IsWindows) { $runtimes+=@(@{name='Windows PowerShell 5.1';command=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe')}) }
foreach($runtime in $runtimes) {
    $result=& $runtime.command -NoProfile -NonInteractive -File $metadataRunner -FixtureRoot (Join-Path $directory ([guid]::NewGuid().ToString('N')))
    if ($LASTEXITCODE -ne 0 -or $result -cnotmatch '^metadata_checks=15$') { throw 'guest_metadata_runtime_fixtures_failed' }
    $count+=15
    Write-Host ($runtime.name+': 15 actual guest metadata checks PASS; no network commands.')
}
Write-Host "Windows transport lifecycle: $count synthetic checks PASS. No Sandbox or networking operations performed."
