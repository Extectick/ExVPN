# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$SandboxId,[Parameter(Mandatory)][string]$BundleDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$bundle = [IO.Path]::GetFullPath($BundleDirectory).TrimEnd('\')
$prefix = [IO.Path]::GetFullPath((Join-Path $repository 'artifacts/windows')).TrimEnd('\') + '\'
if (!$bundle.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Local routing QA artifact directory required.' }
$inputRoot = Join-Path $bundle 'input'
$outputRoot = Join-Path $bundle 'output'
$marker = Get-Content -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Raw | ConvertFrom-Json
$runId = [guid]::Empty
if ($marker.format -ne 1 -or $marker.forbiddenHost -ine $env:COMPUTERNAME -or !$marker.controllerHarness -or $marker.installedServiceIpcTested -or
    ($marker.routingModes -join ',') -cne 'disabled,exclude,include' -or ![guid]::TryParseExact($marker.runId,'D',[ref]$runId) -or $runId -eq [guid]::Empty) { throw 'Owned three-mode controller bundle required.' }
if (@(Get-ChildItem -LiteralPath $outputRoot -Force).Count) { throw 'Use a fresh output directory for every matrix.' }
. (Join-Path $PSScriptRoot 'installer/package-common.ps1')
Assert-TreeManifest $inputRoot @($marker.files | ForEach-Object { [pscustomobject]@{path=$_.file;sha256=$_.sha256} }) @('sandbox-bundle.json','command.txt')
. (Join-Path $repository 'scripts/qa/routing-modes-evidence.ps1')
$wsb = Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps/wsb.exe'
$inventory = & $wsb list --raw | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or @($inventory.WindowsSandboxEnvironments | Where-Object Id -EQ $SandboxId.ToString()).Count -ne 1) { throw 'Requested live Sandbox is unavailable.' }
function Invoke-Guest([string]$Action,[string]$Mode='disabled',[string]$Phase='baseline') {
    $runAs = if ($Action -ceq 'Probe') { 'ExistingLogin' } else { 'System' }
    $command = 'powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ExVPN-System-QA\guest-system-qa.ps1 -ConfirmDisposableGuest -Action '+$Action+' -RoutingMode '+$Mode+' -Phase '+$Phase
    $raw = & $wsb exec --id $SandboxId.ToString() --run-as $runAs --command $command --raw
    if ($LASTEXITCODE -ne 0 -or ($raw | ConvertFrom-Json).ExitCode -ne 0) { throw 'Guest routing action failed; inspect sanitized evidence.' }
}
function Read-Report([string]$Name) {
    $path = Join-Path $outputRoot $Name
    if (!(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -gt 65536) { throw 'Bounded guest report required.' }
    $value = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($value.runId -cne $marker.runId) { throw 'Stale/foreign guest report.' }
    $value
}
function Wait-Native([string]$Mode,[string]$Phase,[bool]$FixtureStopped=$false) {
    $deadline = [DateTime]::UtcNow.AddSeconds(65)
    do {
        $path = Join-Path $outputRoot 'native-network.json'
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $native = Read-Report 'native-network.json'
            if ($native.routingMode -cne $Mode -or !$native.controllerHarness -or $native.installedServiceIpcTested) { throw 'Native harness identity mismatch.' }
            if ($native.phase -ceq 'failed') { throw 'Native harness reported a fixed-code failure.' }
            if ($native.phase -ceq $Phase) {
                if ($Phase -ceq 'disconnected') {
                    if ($native.guardReadFailed -or $native.guardArmed -or $native.adapterPresent) { throw 'Owned native cleanup failed.' }
                    return
                }
                if ($native.guardReadFailed -or !$native.guardArmed) { throw 'Persistent guest guard missing.' }
                if ($native.fixtureStopped -eq $FixtureStopped -and ($FixtureStopped -or $native.status.state -ceq 'connected')) { return }
            }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Native routing phase timed out.'
}
function Set-Control([ValidateSet('','stop-fixture','disconnect')][string]$Command) {
    [IO.File]::WriteAllText((Join-Path $inputRoot 'command.txt'),$Command)
}
function Test-Phase([string]$Mode,[string]$Phase) {
    Invoke-Guest 'Probe' $Mode $Phase
    $evidence = Read-Report ('probes-'+$Mode+'-'+$Phase+'.json')
    Assert-RoutingModeEvidence $evidence $Mode $Phase $marker.runId
}
function Assert-Cleanup([string]$Mode) {
    Invoke-Guest 'Inspect' $Mode
    $inspection = Read-Report ('inspection-'+$Mode+'.json')
    $guard = Read-Report 'guard-inspection.json'
    $before = Read-Report 'prepared.json'
    if ($inspection.harnessRunning -or $inspection.adapterPresent -or $inspection.servicePresent -or $guard.readFailed -or $guard.guardArmed -or $inspection.networkSha256 -cne $before.networkBeforeSha256) { throw 'Guest route/DNS/guard baseline was not restored.' }
}
$report = [ordered]@{runId=$marker.runId;startedUtc=[DateTime]::UtcNow.ToString('o');computerUse=$false;hostNetworkChanged=$false;controllerHarness=$true;installedServiceIpcTested=$false;distinctRemoteEgressTested=$false;ipv6Tested=$false;crashPersistenceTested=$false;passed=$false;cleanupPassed=$false;phases=@()}
$prepared = $false; $active = $false; $currentMode = 'disabled'
try {
    Invoke-Guest 'Prepare'
    $prepared = $true
    foreach ($mode in @('disabled','exclude','include')) {
        $currentMode = $mode
        Set-Control ''
        $report.phases += Test-Phase $mode 'baseline'
        $active = $true
        Invoke-Guest 'Start' $mode
        Wait-Native $mode 'running'
        Invoke-Guest 'ClearDns' $mode
        $report.phases += Test-Phase $mode 'connected-cold'
        Set-Control 'stop-fixture'
        Wait-Native $mode 'running' $true
        Invoke-Guest 'ClearDns' $mode
        $report.phases += Test-Phase $mode 'outage-cold'
        Set-Control 'disconnect'
        Wait-Native $mode 'disconnected'
        Assert-Cleanup $mode
        $active = $false
        $report.phases += Test-Phase $mode 'disconnected'
    }
    $report.passed = $true
} catch {
    $report.error = 'routing_matrix_failed'
    Write-Warning 'Routing matrix failed; sanitized reports are retained.'
} finally {
    $cleanupErrors = @()
    if ($prepared) {
        if ($active) {
            try { Set-Control 'disconnect'; Wait-Native $currentMode 'disconnected' } catch { $cleanupErrors += 'disconnect_failed' }
        }
        # Do not kill a live tunnel or erase a persistent guard to force PASS.
        # Recovery is only attempted after the owned harness has exited.
        try { Assert-Cleanup $currentMode } catch { $cleanupErrors += 'baseline_verification_failed' }
        $report.cleanupPassed = $cleanupErrors.Count -eq 0
    }
    $report.cleanupErrors = $cleanupErrors
    $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $outputRoot 'routing-modes-coordinator.json') -Encoding utf8NoBOM
}
if (!$report.passed -or !$report.cleanupPassed) { throw 'Three-mode routing QA did not pass; retain this guest for inspection.' }
Write-Host 'Three routing modes, cold DNS, fixture outage and guest baseline cleanup passed (controller harness only).'
