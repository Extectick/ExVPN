# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$SandboxId,
    [Parameter(Mandatory)][string]$BundleDirectory,
    [Parameter(Mandatory)][string]$FixtureDirectory,
    [Parameter(Mandatory)][string]$FixtureExecutable,
    [Parameter(Mandatory)][int]$FixtureProcessId,
    [Parameter(Mandatory)][DateTimeOffset]$FixtureStartedUtc,
    [string]$ResultDirectory=''
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'windows-transport-lifecycle-lib.ps1')
. (Join-Path $repository 'scripts/windows/installer/package-common.ps1')
. (Join-Path $repository 'scripts/release/artifact-audit-lib.ps1')
$bundle=[IO.Path]::GetFullPath($BundleDirectory)
$artifactPrefix=[IO.Path]::GetFullPath((Join-Path $repository 'artifacts/windows'))+[IO.Path]::DirectorySeparatorChar
$privatePrefix=[IO.Path]::GetFullPath((Join-Path $repository '.private'))+[IO.Path]::DirectorySeparatorChar
if (!$bundle.StartsWith($artifactPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'transport_owned_bundle_required' }
$inputRoot=Join-Path $bundle 'input'
Assert-AuditNoLinks $inputRoot
$marker=Get-Content -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Raw | ConvertFrom-Json -AsHashtable
Assert-TransportMarker $marker $env:COMPUTERNAME
Assert-TreeManifest $inputRoot $marker.files @('sandbox-bundle.json')
$fixture=[IO.Path]::GetFullPath($FixtureDirectory)
if (!$fixture.StartsWith($privatePrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'transport_private_fixture_required' }
Assert-AuditNoLinks $fixture
$fixtureExecutable=[IO.Path]::GetFullPath($FixtureExecutable)
if (!$fixtureExecutable.StartsWith($artifactPrefix,[StringComparison]::OrdinalIgnoreCase) -and
    !$fixtureExecutable.StartsWith(([IO.Path]::GetFullPath((Join-Path $repository 'artifacts/qa'))+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase) -and
    !$fixtureExecutable.StartsWith(([IO.Path]::GetFullPath((Join-Path $repository '.tools/artifacts'))+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)) { throw 'transport_owned_fixture_executable_required' }
Assert-AuditNoLinks $fixtureExecutable
$fixtureManifest=Join-Path $fixture 'manifest.json'
if ((Get-Item -LiteralPath $fixtureManifest).Length -gt 1MB -or !(Test-Path -LiteralPath (Join-Path $fixture 'subscription.txt') -PathType Leaf)) { throw 'transport_fixture_invalid' }
$fixtures=Get-Content -LiteralPath $fixtureManifest -Raw | ConvertFrom-Json
$expectedNames=@('VLESS TCP','VLESS REALITY','VLESS Vision','VLESS XHTTP','XHTTP REALITY','VLESS gRPC','VMess','Shadowsocks')
if ($fixtures.Count -ne 8 -or @($fixtures.Name | Sort-Object -Unique).Count -ne 8 -or @($fixtures | Where-Object { $_.Name -cnotin $expectedNames -or $_.Port -lt 1024 -or $_.Port -gt 65535 }).Count) { throw 'transport_fixture_matrix_invalid' }
$fixturePorts=@($fixtures | ForEach-Object { [int]$_.Port })
if (@($fixturePorts | Sort-Object -Unique).Count -ne $fixturePorts.Count) { throw 'transport_fixture_ports_invalid' }
function Assert-OwnedFixture {
    $process=Get-Process -Id $FixtureProcessId -ErrorAction Stop
    if ($process.Path -ine $fixtureExecutable -or $process.StartTime.ToUniversalTime().Ticks -ne $FixtureStartedUtc.UtcTicks) { throw 'transport_fixture_process_changed' }
    $process
}
[void](Assert-OwnedFixture)
function Get-FixturePeerCount {
    [void](Assert-OwnedFixture)
    @(Get-NetTCPConnection -ErrorAction Stop | Where-Object {
        $_.OwningProcess -eq $FixtureProcessId -and $_.LocalPort -in $fixturePorts -and $_.State -notin @('Listen','TimeWait','Closed','Bound')
    }).Count
}
if ((Get-FixturePeerCount) -ne 0) { throw 'transport_fixture_already_in_use' }
if (!$ResultDirectory) { $ResultDirectory=Join-Path $repository ('.private/windows-lifecycle-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)) }
$outputRoot=[IO.Path]::GetFullPath($ResultDirectory)
if (!$outputRoot.StartsWith($privatePrefix,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $outputRoot)) { throw 'transport_new_private_output_required' }
[IO.Directory]::CreateDirectory($outputRoot) | Out-Null
Assert-AuditNoLinks $outputRoot
$wsb=Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps/wsb.exe'
$inventory=& $wsb list --raw | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or @($inventory.WindowsSandboxEnvironments | Where-Object Id -EQ $SandboxId.ToString()).Count -ne 1) { throw 'transport_live_sandbox_required' }
foreach ($mapping in @(
    @{source=$inputRoot;target='C:\ExVPN-App-QA';write=$false},
    @{source=$outputRoot;target='C:\ExVPN-App-QA-Results';write=$true},
    @{source=$fixture;target='C:\ExVPN-App-QA-Private';write=$false}
)) {
    $arguments=@('share','--id',$SandboxId.ToString(),'--host-path',$mapping.source,'--sandbox-path',$mapping.target,'--raw')
    if ($mapping.write) { $arguments+='--allow-write' }
    $null=& $wsb @arguments
    if ($LASTEXITCODE -ne 0) { throw 'transport_mapping_failed' }
}
$invocation=0
function Start-Guest([string]$Script,[string]$Arguments='', [string]$RunAs='System') {
    if ($Script -cnotin @('guest-app-qa.ps1','guest-app-launch.ps1','guest-transport-observe.ps1') -or $Arguments -notmatch '^(?:-Action (?:Refresh|Restore|Baseline|Observe|Finish)(?: -Step [1-6]?[0-9])?)?$') { throw 'transport_guest_action_rejected' }
    $command='powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ExVPN-App-QA\'+$Script+' -ConfirmDisposableGuest '+$Arguments
    $start=[Diagnostics.ProcessStartInfo]::new($wsb)
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    foreach($argument in @('exec','--id',$SandboxId.ToString(),'--run-as',$RunAs,'--command',$command,'--raw')) { $start.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$start
    if (!$process.Start()) { throw 'transport_guest_launch_failed' }
    [ordered]@{process=$process;stdout=$process.StandardOutput.ReadToEndAsync();stderr=$process.StandardError.ReadToEndAsync()}
}
function Complete-Guest($Child,[int]$TimeoutMs=90000) {
    $script:invocation++
    try {
        if (!$Child.process.WaitForExit($TimeoutMs)) { $Child.process.Kill($true); throw 'transport_guest_deadline' }
        $stdout=$Child.stdout.GetAwaiter().GetResult(); $stderr=$Child.stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $outputRoot "guest-$script:invocation.stdout.log"),$stdout)
        [IO.File]::WriteAllText((Join-Path $outputRoot "guest-$script:invocation.stderr.log"),$stderr)
        $value=$stdout | ConvertFrom-Json
        if ($Child.process.ExitCode -ne 0 -or $value.ExitCode -ne 0) { throw 'transport_guest_action_failed' }
    } finally { $Child.process.Dispose() }
}
function Invoke-Guest([string]$Script,[string]$Arguments='') { Complete-Guest (Start-Guest $Script $Arguments) }
function Write-TransportAck([int]$Step,[bool]$Passed) {
    $temp=Join-Path $outputRoot 'transport-ack.tmp'
    [ordered]@{runId=$marker.runId;step=$Step;ok=$Passed} | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding utf8NoBOM
    [IO.File]::Move($temp,(Join-Path $outputRoot 'transport-ack.json'),$true)
}
$report=[ordered]@{
    format=1;runId=$marker.runId;build=$marker.build;cycles=$marker.transportCycles
    startedUtc=[DateTime]::UtcNow.ToString('o');computerUse=$false;hostNetworkChanged=$false
    fixtureExecutableSha256=(Get-AuditSha256 $fixtureExecutable);bundleManifestSha256=(Get-AuditSha256 (Join-Path $inputRoot 'sandbox-bundle.json'))
    internalCacheObjectsObserved=$false;distinctEgressTested=$false;samples=@();passed=$false;cleanupPassed=$false
}
$owned=$false; $baseline=$false; $launcher=$null
try {
    $owned=$true
    Invoke-Guest 'guest-app-qa.ps1' '-Action Refresh'
    Invoke-Guest 'guest-transport-observe.ps1' '-Action Baseline'
    $baseline=$true
    $report.baseline=Get-Content -LiteralPath (Join-Path $outputRoot 'transport-baseline.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($report.baseline.runId -cne $marker.runId -or !$report.baseline.passed) { throw 'transport_baseline_failed' }
    $launcher=Start-Guest 'guest-app-launch.ps1' '' 'ExistingLogin'
    $step=1; $total=3*$marker.transportCycles
    $deadline=[DateTime]::UtcNow.AddMinutes(18)
    while (!$launcher.process.HasExited) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'transport_runtime_deadline' }
        $request=Get-TransportRequest (Join-Path $outputRoot 'transport-request.json') $marker.runId $step $total
        if ($null -ne $request) {
            try {
                Invoke-Guest 'guest-transport-observe.ps1' ('-Action Observe -Step '+$step)
                $sample=Get-Content -LiteralPath (Join-Path $outputRoot "transport-observe-$step.json") -Raw | ConvertFrom-Json -AsHashtable
                Assert-TransportSample $sample $marker.runId $step
                $drain=[Diagnostics.Stopwatch]::StartNew()
                do {
                    $peers=Get-FixturePeerCount
                    if ($peers -eq 0) { break }
                    Start-Sleep -Milliseconds 200
                } while ($drain.Elapsed.TotalSeconds -lt 10)
                $sample.fixturePeerCount=$peers; $sample.fixtureDrainMs=[int]$drain.Elapsed.TotalMilliseconds
                $report.samples+=@($sample)
                if ($peers -ne 0) { throw 'transport_fixture_connections_remain' }
                Write-TransportAck $step $true
                Write-Host "Transport disconnect $step/${total}: same service, clean TUN/WFP/DNS/routes, fixture peers drained."
                $step++
            } catch {
                Write-TransportAck $step $false
                throw
            }
        }
        Start-Sleep -Milliseconds 200
    }
    Complete-Guest $launcher 1000
    $launcher=$null
    $flutter=Get-Content -LiteralPath (Join-Path $outputRoot 'flutter-report.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-TransportFlutter $flutter $marker.runId $marker.transportCycles
    if ($step -ne $total+1 -or $report.samples.Count -ne $total) { throw 'transport_incomplete_disconnect_observations' }
    $report.passed=$true
} catch {
    $report.error='transport_lifecycle_qa_failed'
    Write-Warning 'Transport lifecycle QA failed; private reports are retained.'
} finally {
    $cleanupErrors=@()
    if ($owned) {
        try { Invoke-Guest 'guest-app-qa.ps1' '-Action Restore' } catch { $cleanupErrors+='service_restore_failed' }
        if ($baseline) {
            try {
                Invoke-Guest 'guest-transport-observe.ps1' '-Action Finish'
                $report.finish=Get-Content -LiteralPath (Join-Path $outputRoot 'transport-finish.json') -Raw | ConvertFrom-Json -AsHashtable
                if ($report.finish.runId -cne $marker.runId -or !$report.finish.passed) { throw 'transport_final_observation_failed' }
            } catch { $cleanupErrors+='network_restore_failed' }
        }
    }
    if ($launcher) {
        try { Complete-Guest $launcher 15000 } catch { $report.launcherDidNotCompleteCleanly=$true }
    }
    try {
        $fixtureProcess=Assert-OwnedFixture
        Stop-Process -Id $fixtureProcess.Id -Force
        if (!$fixtureProcess.WaitForExit(10000)) { throw 'fixture_stop_timeout' }
        $report.fixtureStopped=$true
    } catch { $cleanupErrors+='fixture_stop_failed' }
    $report.cleanupPassed=$owned -and $baseline -and $cleanupErrors.Count -eq 0
    if ($cleanupErrors.Count) { $report.cleanupErrors=$cleanupErrors }
    $report.finishedUtc=[DateTime]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outputRoot 'transport-coordinator.json') -Encoding utf8NoBOM
}
if (!$report.passed -or !$report.cleanupPassed) { throw 'transport_lifecycle_failed_inspect_private_reports' }
Write-Host ('Transport lifecycle and cleanup passed. Private results: '+$outputRoot)
