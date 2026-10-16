# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$SandboxId,[Parameter(Mandatory)][string]$BundleDirectory)
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$bundle=[IO.Path]::GetFullPath($BundleDirectory).TrimEnd('\')
$prefix=[IO.Path]::GetFullPath((Join-Path $repository 'artifacts/windows')).TrimEnd('\')+'\'
if (!$bundle.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Local QA artifact directory required.' }
$inputRoot=Join-Path $bundle 'input'
$outputRoot=Join-Path $bundle 'output'
$marker=Get-Content -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Raw | ConvertFrom-Json
if (!$marker.networkRecovery -or !$marker.providerMatrix -or $marker.faults -or !$marker.unelevated -or $marker.forbiddenHost -ine $env:COMPUTERNAME -or $marker.runId -notmatch '^[a-f0-9-]{36}$') { throw 'Owned network-recovery provider bundle required.' }
. (Join-Path $PSScriptRoot 'installer/package-common.ps1')
Assert-TreeManifest $inputRoot $marker.files @('sandbox-bundle.json')
$wsb=Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps/wsb.exe'
$inventory=& $wsb list --raw | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or @($inventory.WindowsSandboxEnvironments | Where-Object Id -EQ $SandboxId.ToString()).Count -ne 1) { throw 'Requested live Sandbox is unavailable.' }
function Guest-Command([string]$Script,[string]$Arguments='') {
    'powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ExVPN-App-QA\'+$Script+' -ConfirmDisposableGuest '+$Arguments
}
function Invoke-Guest([string]$Script,[string]$Arguments='') {
    $raw=& $wsb exec --id $SandboxId.ToString() --run-as System --command (Guest-Command $Script $Arguments) --raw
    if ($LASTEXITCODE -ne 0 -or ($raw | ConvertFrom-Json).ExitCode -ne 0) { throw 'Guest action failed; inspect the sanitized reports.' }
}
$report=[ordered]@{runId=$marker.runId;startedUtc=[DateTime]::UtcNow.ToString('o');computerUse=$false;actions=@();passed=$false;cleanupPassed=$false}
$owned=$false; $baseline=$false; $networkOwned=$false; $launcher=$null
try {
    $owned=$true
    Invoke-Guest 'guest-app-qa.ps1' '-Action Refresh'
    Invoke-Guest 'guest-app-faults.ps1' '-Action Prepare'
    $baseline=$true
    Invoke-Guest 'guest-app-network.ps1' '-Action Prepare'
    $networkOwned=$true
    $psi=[Diagnostics.ProcessStartInfo]::new($wsb)
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    foreach ($argument in @('exec','--id',$SandboxId.ToString(),'--run-as','ExistingLogin','--command',(Guest-Command 'guest-app-launch.ps1'),'--raw')) { $psi.ArgumentList.Add($argument) }
    $launcher=[Diagnostics.Process]::Start($psi)
    $stdout=$launcher.StandardOutput.ReadToEndAsync()
    $stderr=$launcher.StandardError.ReadToEndAsync()
    $step=1
    $actions=@('network-down','network-up')
    $deadline=[DateTime]::UtcNow.AddMinutes(8)
    while (!$launcher.HasExited) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Network QA deadline expired.' }
        $requestPath=Join-Path $outputRoot 'fault-request.json'
        if ($step -le $actions.Count -and (Test-Path -LiteralPath $requestPath)) {
            if ((Get-Item -LiteralPath $requestPath).Length -gt 4096) { throw 'Oversized fault request.' }
            $request=Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json
            if ($request.runId -ceq $marker.runId -and $request.step -eq $step) {
                if ($request.action -cne $actions[$step-1]) { throw 'Unexpected fault action.' }
                $action=if ($step -eq 1) { 'Down' } else { 'Up' }
                Invoke-Guest 'guest-app-network.ps1' ('-Action '+$action)
                $report.actions+=@([ordered]@{step=$step;action=$actions[$step-1];utc=[DateTime]::UtcNow.ToString('o')})
                $temporary=Join-Path $outputRoot 'fault-ack.tmp'
                [ordered]@{runId=$marker.runId;step=$step;ok=$true} | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding utf8
                [IO.File]::Move($temporary,(Join-Path $outputRoot 'fault-ack.json'),$true)
                $step++
            }
        }
        Start-Sleep -Milliseconds 300
    }
    $native=$stdout.GetAwaiter().GetResult() | ConvertFrom-Json
    $null=$stderr.GetAwaiter().GetResult()
    if ($launcher.ExitCode -ne 0 -or $native.ExitCode -ne 0) { throw 'Flutter integration process failed.' }
    $flutter=Get-Content -LiteralPath (Join-Path $outputRoot 'flutter-report.json') -Raw | ConvertFrom-Json
    $watchdogActed=$false
    $watchdogReport=Join-Path $outputRoot 'network-Watchdog.json'
    if (Test-Path -LiteralPath $watchdogReport) {
        if ((Get-Item -LiteralPath $watchdogReport).Length -gt 4096) { throw 'Oversized watchdog report.' }
        $watchdog=Get-Content -LiteralPath $watchdogReport -Raw | ConvertFrom-Json
        # Previous failed runs remain evidence; only this session's watchdog
        # can invalidate automatic recovery observed by the current UI run.
        $watchdogActed=$watchdog.runId -ceq $marker.runId
    }
    if ($flutter.runId -cne $marker.runId -or !$flutter.frameworkPassed -or !$flutter.allProtocolsPassed -or !$flutter.networkRecoveryPassed -or !$flutter.distinctEgressTested -or !$flutter.ordinaryUserTokenTested -or !$flutter.cleanupDisconnected -or $step -ne 3 -or $watchdogActed) { throw 'Required network recovery checks did not pass.' }
    $report.passed=$true
} catch {
    $report.error='network_recovery_qa_failed'
    Write-Warning $_.Exception.Message
} finally {
    if ($owned) {
        $cleanupErrors=@()
        # A failed adapter recovery must not skip the independent attempt to
        # restore the original service binding and remove this owned tunnel.
        if ($networkOwned) {
            try { Invoke-Guest 'guest-app-network.ps1' '-Action Recover' }
            catch { $cleanupErrors+=@('adapter_recovery_failed') }
        }
        try { Invoke-Guest 'guest-app-qa.ps1' '-Action Restore' }
        catch { $cleanupErrors+=@('service_restore_failed') }
        if ($baseline) {
            try { Invoke-Guest 'guest-app-faults.ps1' '-Action Finish' }
            catch { $cleanupErrors+=@('network_baseline_failed') }
        }
        if ($networkOwned) {
            try { Invoke-Guest 'guest-app-network.ps1' '-Action Finish' }
            catch { $cleanupErrors+=@('adapter_cleanup_failed') }
        }
        $report.cleanupPassed=$cleanupErrors.Count -eq 0
        if ($cleanupErrors.Count) { $report.cleanupErrors=$cleanupErrors }
    }
    $report.finishedUtc=[DateTime]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $outputRoot 'network-coordinator.json') -Encoding utf8
    if ($launcher) { $launcher.Dispose() }
}
if (!$report.passed -or !$report.cleanupPassed) { throw 'Network recovery QA failed; reports are retained.' }
Write-Host 'Guest adapter loss, guarded recovery and cleanup passed without Computer Use.'
