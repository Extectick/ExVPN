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
if (!$marker.providerMatrix -or $marker.faults -or !$marker.unelevated -or $marker.forbiddenHost -ine $env:COMPUTERNAME -or $marker.runId -notmatch '^[a-f0-9-]{36}$') { throw 'An owned provider-only, unelevated QA bundle is required.' }
$wsb=Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps/wsb.exe'
$inventory=& $wsb list --raw | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or @($inventory.WindowsSandboxEnvironments | Where-Object Id -EQ $SandboxId.ToString()).Count -ne 1) { throw 'Requested live Sandbox is unavailable.' }
function Invoke-Guest([string]$Script,[string]$Arguments='', [string]$RunAs='System') {
    $command='powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ExVPN-App-QA\'+$Script+' -ConfirmDisposableGuest '+$Arguments
    $raw=& $wsb exec --id $SandboxId.ToString() --run-as $RunAs --command $command --raw
    if ($LASTEXITCODE -ne 0 -or ($raw | ConvertFrom-Json).ExitCode -ne 0) { throw 'Guest action failed; inspect the sanitized local reports.' }
}
$report=[ordered]@{runId=$marker.runId;startedUtc=[DateTime]::UtcNow.ToString('o');computerUse=$false;passed=$false;cleanupPassed=$false}
$owned=$false; $baseline=$false
try {
    $owned=$true
    Invoke-Guest 'guest-app-qa.ps1' '-Action Refresh'
    Invoke-Guest 'guest-app-faults.ps1' '-Action Prepare'
    $baseline=$true
    Invoke-Guest 'guest-app-launch.ps1' '' 'ExistingLogin'
    $flutter=Get-Content -LiteralPath (Join-Path $outputRoot 'flutter-report.json') -Raw | ConvertFrom-Json
    if ($flutter.runId -cne $marker.runId -or !$flutter.frameworkPassed -or !$flutter.providerMatrix -or !$flutter.allProtocolsPassed -or !$flutter.distinctEgressTested -or !$flutter.ordinaryUserTokenTested -or !$flutter.cleanupDisconnected) { throw 'Selected provider HTTPS/egress tests did not pass.' }
    $report.selectedProfiles=@($flutter.profiles).Count
    $report.passed=$true
} catch {
    $report.error='provider_qa_failed'
    Write-Warning $_.Exception.Message
} finally {
    if ($owned) {
        try {
            Invoke-Guest 'guest-app-qa.ps1' '-Action Restore'
            if ($baseline) { Invoke-Guest 'guest-app-faults.ps1' '-Action Finish' }
            $report.cleanupPassed=$true
        } catch { $report.cleanupError='guest_cleanup_failed'; Write-Warning $_.Exception.Message }
    }
    $report.finishedUtc=[DateTime]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $outputRoot 'provider-coordinator.json') -Encoding utf8
}
if (!$report.passed -or !$report.cleanupPassed) { throw 'Provider QA failed; sanitized results are retained in the bundle output.' }
Write-Host 'Selected provider HTTPS/egress checks and guest cleanup passed without Computer Use.'
