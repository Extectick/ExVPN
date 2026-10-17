# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName='Changed')]
param(
    [Parameter(ParameterSetName='Changed')][switch]$Changed,
    [Parameter(ParameterSetName='Changed')][string]$BaseRef = '',
    [Parameter(Mandatory, ParameterSetName='Full')][switch]$Full,
    [switch]$PlanOnly,
    [ValidateRange(1, 8)][int]$MaxParallel = 3,
    [ValidateRange(1, 16)][int]$TestConcurrency = 2,
    [ValidateRange(1, 60)][int]$LaneTimeoutMinutes = 15,
    [switch]$OnlineDependencies
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'fast-validation-plan.ps1')
$started = [DateTimeOffset]::UtcNow
$clock = [Diagnostics.Stopwatch]::StartNew()
$paths = @(if (!$Full) { Get-FastValidationChangedPaths $repository -BaseRef $BaseRef })
$plan = Get-FastValidationPlan -ChangedPaths $paths -Full:$Full
$mode = if ($Full) { 'Full' } else { 'Changed' }
Write-Host "ExVPN $mode behavioral validation: $($plan.lanes -join ', ')"
Write-Host 'Scope: analyze, unit/widget, synthetic loopback and installer fixtures; not build/VPN/security/release acceptance.'
if ($PlanOnly) {
    $plan | ConvertTo-Json -Depth 5
    exit 0
}

$runDirectory = Join-Path $repository ('artifacts/qa/fast-' + $started.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$summaryPath = Join-Path $runDirectory 'summary.json'
$report = [ordered]@{
    schemaVersion = 1
    mode = $mode
    scope = 'behavioral checks only; excludes builds and real VPN/security/release acceptance'
    startedAt = $started.ToString('o')
    endedAt = $null
    durationSeconds = 0
    status = 'running'
    sourceFingerprintBefore = $null
    sourceFingerprintAfter = $null
    sourceUnchanged = $null
    toolchain = $null
    changedFileCount = $plan.changedFileCount
    selectedLanes = @($plan.lanes)
    executionOrder = @($plan.executionOrder)
    selectionReasons = @($plan.reasons)
    goResultCacheAllowed = !$Full
    maxParallel = $MaxParallel
    testConcurrency = $TestConcurrency
    lanes = @()
    failure = $null
    requiredNextGates = @('Android JNI/APK and JVM tests', 'Windows native/UI build', 'isolated VPN/IPv4/IPv6/DNS/fault acceptance', 'signed release and upgrade acceptance')
}
$active = [Collections.Generic.List[object]]::new()
$completed = [Collections.Generic.List[object]]::new()
$exitCode = 1
try {
    $report.sourceFingerprintBefore = Get-FastValidationSourceFingerprint $repository
    if (!$plan.lanes.Count) {
        $report.status = 'no-code-checks-required'
        $exitCode = 0
    } else {
        . (Join-Path $repository 'scripts/bootstrap/enter-environment.ps1')
        $pin = Get-Content -LiteralPath (Join-Path $repository 'scripts/bootstrap/toolchain.lock.json') -Raw | ConvertFrom-Json
        $go = Join-Path $repository '.tools/go/bin/go.exe'
        $flutter = Join-Path $repository '.tools/flutter/bin/flutter.bat'
        if ((& $go version) -ne "go version go$($pin.go.version) windows/amd64" -or $LASTEXITCODE -ne 0) { throw 'Go SDK pin mismatch.' }
        $flutterVersion = & (Join-Path $repository 'scripts/ci/flutter-version.ps1') -Flutter $flutter
        if ($flutterVersion.frameworkRevision -ne $pin.flutter.revision -or $flutterVersion.dartSdkVersion -notlike "$($pin.flutter.dartVersion)*") {
            throw 'Flutter/Dart SDK pin mismatch.'
        }
        $report.toolchain = @{ go=$pin.go.version; flutter=$flutterVersion.frameworkRevision; dart=$flutterVersion.dartSdkVersion }
        $pubspec = Get-Content -LiteralPath (Join-Path $repository 'apps/exvpn/pubspec.yaml') -Raw
        $identity = Get-Content -LiteralPath (Join-Path $repository 'apps/exvpn/lib/build_identity.dart') -Raw
        $version = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
        if (!$version.Success -or !$identity.Contains("const appVersion = '$($version.Groups[1].Value)';") -or !$identity.Contains("const appBuild = $($version.Groups[2].Value);")) {
            throw 'Displayed app version/build differs from pubspec.yaml.'
        }
        $queue = [Collections.Generic.Queue[string]]::new()
        foreach ($lane in $plan.executionOrder) { $queue.Enqueue($lane) }
        while ($queue.Count -or $active.Count) {
            while ($queue.Count -and $active.Count -lt $MaxParallel) {
                $lane = $queue.Dequeue()
                $start = [Diagnostics.ProcessStartInfo]::new()
                $start.FileName = Join-Path $PSHOME 'pwsh.exe'
                $start.WorkingDirectory = $repository
                $start.UseShellExecute = $false
                $start.CreateNoWindow = $true
                $start.RedirectStandardOutput = $true
                $start.RedirectStandardError = $true
                foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'run-fast-validation-lane.ps1'), '-Lane', $lane, '-TestConcurrency', "$TestConcurrency")) {
                    $start.ArgumentList.Add($argument)
                }
                if ($Full) { $start.ArgumentList.Add('-FreshGoTests') }
                if ($OnlineDependencies) { $start.ArgumentList.Add('-OnlineDependencies') }
                $process = [Diagnostics.Process]::Start($start)
                $active.Add([pscustomobject]@{ lane=$lane; process=$process; stdout=$process.StandardOutput.ReadToEndAsync(); stderr=$process.StandardError.ReadToEndAsync(); clock=[Diagnostics.Stopwatch]::StartNew() })
                Write-Host "[$lane] started"
            }
            foreach ($item in @($active.ToArray())) {
                $timedOut = $item.clock.Elapsed.TotalMinutes -gt $LaneTimeoutMinutes
                if (!$item.process.HasExited -and !$timedOut) { continue }
                if (!$item.process.HasExited) { $item.process.Kill($true) }
                $item.process.WaitForExit()
                $stdout = $item.stdout.GetAwaiter().GetResult()
                $stderr = $item.stderr.GetAwaiter().GetResult()
                [IO.File]::WriteAllText((Join-Path $runDirectory "$($item.lane).log"), $stdout + "`n" + $stderr)
                $status = if ($timedOut) { 'timeout' } elseif ($item.process.ExitCode -eq 0) { 'passed' } else { 'failed' }
                $seconds = [math]::Round($item.clock.Elapsed.TotalSeconds, 2)
                $cachedPackages = if ($item.lane -in @('core', 'android', 'windows')) { [regex]::Matches($stdout, '(?m)^ok\s+\S+\s+\(cached\)').Count } else { 0 }
                $completed.Add([pscustomobject]@{ lane=$item.lane; status=$status; exitCode=$item.process.ExitCode; durationSeconds=$seconds; cachedGoPackages=$cachedPackages; log="$($item.lane).log" })
                Write-Host "[$($item.lane)] $status (${seconds}s)"
                $item.process.Dispose()
                $null = $active.Remove($item)
            }
            if ($active.Count) { Start-Sleep -Milliseconds 200 }
        }
        $report.status = if (@($completed | Where-Object status -ne 'passed').Count) { 'failed' } else { 'passed' }
        $exitCode = if ($report.status -eq 'passed') { 0 } else { 1 }
    }
    $report.sourceFingerprintAfter = Get-FastValidationSourceFingerprint $repository
    $report.sourceUnchanged = $report.sourceFingerprintBefore -eq $report.sourceFingerprintAfter
    if (!$report.sourceUnchanged) {
        $report.status = 'source-changed-during-run'
        $report.failure = 'Source changed while checks ran. Re-run after writers finish; mixed snapshots are not evidence.'
        $exitCode = 1
    }
} catch {
    $report.status = 'failed'
    $report.failure = $_.Exception.Message
    $exitCode = 1
} finally {
    # Only processes launched by this invocation are stopped, including their
    # test children. No installed ExVPN service or unrelated process is touched.
    foreach ($item in $active) {
        if (!$item.process.HasExited) { $item.process.Kill($true); $item.process.WaitForExit() }
        $item.process.Dispose()
    }
    $report.lanes = @($completed | Sort-Object lane)
    $report.endedAt = [DateTimeOffset]::UtcNow.ToString('o')
    $report.durationSeconds = [math]::Round($clock.Elapsed.TotalSeconds, 2)
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    Write-Host "Result: $($report.status), $($report.durationSeconds)s. Report: $summaryPath"
    if ($report.failure) { Write-Host $report.failure }
}
exit $exitCode
