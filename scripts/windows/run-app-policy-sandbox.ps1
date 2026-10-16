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
$markerFile=Join-Path $inputRoot 'sandbox-bundle.json'
$marker=Get-Content -LiteralPath $markerFile -Raw | ConvertFrom-Json
if (!$marker.faults -or $marker.policyRecovery -cne 'reset' -or $marker.forbiddenHost -ine $env:COMPUTERNAME -or $marker.runId -notmatch '^[a-f0-9-]{36}$') { throw 'This host must own a fresh policy recovery bundle.' }
$wsb=Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps/wsb.exe'
$inventory=& $wsb list --raw | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or @($inventory.WindowsSandboxEnvironments | Where-Object Id -EQ $SandboxId.ToString()).Count -ne 1) { throw 'Requested live Sandbox is unavailable.' }
function Invoke-Guest([string]$Script,[string]$Arguments='', [string]$RunAs='System') {
    # All script/argument strings below are fixed locally, never guest-supplied.
    $command='powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ExVPN-App-QA\'+$Script+' -ConfirmDisposableGuest '+$Arguments
    $raw=& $wsb exec --id $SandboxId.ToString() --run-as $RunAs --command $command --raw
    if ($LASTEXITCODE -ne 0 -or ($raw | ConvertFrom-Json).ExitCode -ne 0) { throw 'Guest policy action failed; inspect local guest reports.' }
}
function Verify-Ui([string]$Mode) {
    $ui=Get-Content -LiteralPath (Join-Path $outputRoot ('policy-ui-'+$Mode+'.json')) -Raw | ConvertFrom-Json
    if ($ui.runId -cne $marker.runId -or !$ui.frameworkPassed -or !$ui.passed -or !$ui.policyEmpty -or !$ui.errorCleared -or $ui.state -cne 'disconnected') { throw 'Required policy UI assertions did not pass.' }
    $launch=Get-Content -LiteralPath (Join-Path $outputRoot 'launch-report.json') -Raw | ConvertFrom-Json
    [ordered]@{mode=$Mode;passed=$true;administratorToken=$launch.administratorToken}
}
$result=[ordered]@{runId=$marker.runId;startedUtc=[DateTime]::UtcNow.ToString('o');computerUse=$false;passed=$false;cleanupPassed=$false;ui=@()}
$ownedSession=$false
$corruptAttempted=$false
try {
    # Refresh must already have adopted an upgraded protected service manifest.
    Invoke-Guest 'guest-app-faults.ps1' '-Action Prepare'
    $ownedSession=$true
    Invoke-Guest 'guest-app-qa.ps1' '-Action Refresh'
    $corruptAttempted=$true
    Invoke-Guest 'guest-app-policy.ps1' '-Action Corrupt'
    Invoke-Guest 'guest-app-launch.ps1' '' 'ExistingLogin'
    $result.ui+=Verify-Ui 'reset'
    $marker.policyRecovery='reopen'
    $marker | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $markerFile -Encoding utf8NoBOM
    Invoke-Guest 'guest-app-policy.ps1' '-Action Restart'
    Invoke-Guest 'guest-app-launch.ps1' '' 'ExistingLogin'
    $result.ui+=Verify-Ui 'reopen'
    $result.passed=$true
} catch {
    $result.error='automated_policy_run_failed'
    Write-Warning $_.Exception.Message
} finally {
    if ($ownedSession) {
        $cleanupErrors=@()
        if ($corruptAttempted) {
            try { Invoke-Guest 'guest-app-policy.ps1' '-Action Restore' } catch { $cleanupErrors+='policy_restore_failed' }
        }
        try { Invoke-Guest 'guest-app-qa.ps1' '-Action Restore' } catch { $cleanupErrors+='binding_restore_failed' }
        try { Invoke-Guest 'guest-app-faults.ps1' '-Action Finish' } catch { $cleanupErrors+='baseline_verification_failed' }
        $result.cleanupPassed=$cleanupErrors.Count -eq 0
        $result.cleanupErrors=$cleanupErrors
    }
    $result.finishedUtc=[DateTime]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $outputRoot 'policy-coordinator.json') -Encoding utf8NoBOM
}
if (!$result.passed -or !$result.cleanupPassed) { throw 'Policy recovery QA failed; inspect the sanitized coordinator report.' }
