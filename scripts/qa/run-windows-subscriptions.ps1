# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$SandboxId,[Parameter(Mandatory)][string]$BundleDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'windows-subscriptions-lib.ps1')
. (Join-Path $repository 'scripts/windows/installer/package-common.ps1')
. (Join-Path $repository 'scripts/release/artifact-audit-lib.ps1')
$bundle=[IO.Path]::GetFullPath($BundleDirectory)
$prefix=[IO.Path]::GetFullPath((Join-Path $repository 'artifacts/windows'))+[IO.Path]::DirectorySeparatorChar
if (!$bundle.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'subscription_owned_bundle_required' }
$source=Join-Path $bundle 'input'
Assert-AuditNoLinks $source
$marker=Get-Content -LiteralPath (Join-Path $source 'sandbox-bundle.json') -Raw | ConvertFrom-Json
$paths=Get-SubscriptionQaPaths $marker
if ($paths.phase -cne 'edit' -or $marker.forbiddenHost -cne $env:COMPUTERNAME) { throw 'subscription_fresh_local_bundle_required' }
Assert-TreeManifest $source $marker.files @('sandbox-bundle.json')
$executableHash=(Get-FileHash -LiteralPath (Join-Path $source 'ui/exvpn.exe')).Hash.ToLowerInvariant()
$wsb=Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps/wsb.exe'
$inventory=& $wsb list --raw | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or @($inventory.WindowsSandboxEnvironments | Where-Object Id -EQ $SandboxId.ToString()).Count -ne 1) { throw 'subscription_live_sandbox_required' }
$mapping=& (Join-Path $PSScriptRoot 'ensure-windows-lifecycle-mapping.ps1') -SandboxId $SandboxId
$outputRoot=Join-Path $mapping.root $marker.runId
$inputRoot=Join-Path (Join-Path $repository '.private/windows-subscription-inputs') $marker.runId
if ((Test-Path -LiteralPath $outputRoot) -or (Test-Path -LiteralPath $inputRoot)) { throw 'subscription_run_already_reserved' }
Assert-AuditNoLinks $mapping.root
$parent=Split-Path $inputRoot
[IO.Directory]::CreateDirectory($parent) | Out-Null
Assert-AuditNoLinks $parent
if ($inputRoot.StartsWith(($mapping.root+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)) { throw 'subscription_input_writable_alias_forbidden' }
[IO.Directory]::CreateDirectory($outputRoot) | Out-Null
# A separate, read-only input root allows the controlled phase marker change
# without mutating the immutable build bundle or exposing it through RW output.
Copy-Item -LiteralPath $source -Destination $inputRoot -Recurse
Assert-AuditNoLinks $inputRoot
Assert-TreeManifest $inputRoot $marker.files @('sandbox-bundle.json')
[ordered]@{runId=$marker.runId;build=$marker.build;bundleManifestSha256=(Get-AuditSha256 (Join-Path $source 'sandbox-bundle.json'));uiSha256=$executableHash} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputRoot 'subscriptions-reservation.json') -Encoding utf8NoBOM
$null=& $wsb share --id $SandboxId.ToString() --host-path $inputRoot --sandbox-path C:\ExVPN-App-QA --raw
if ($LASTEXITCODE -ne 0) { throw 'subscription_readonly_mapping_failed' }
$invocation=0
function Invoke-SubscriptionGuest([string]$Script,[string]$Action='', [string]$RunAs='System') {
    if (($Script -cne 'guest-app-subscriptions.ps1' -or $Action -cnotin @('Setup','Reopen','Cleanup') -or $RunAs -cne 'System') -and
        ($Script -cne 'guest-app-launch.ps1' -or $Action -cne '' -or $RunAs -cne 'ExistingLogin')) { throw 'subscription_guest_action_rejected' }
    $command='powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ExVPN-App-QA\'+$Script+' -ConfirmDisposableGuest'
    if ($Action) { $command+=' -Action '+$Action }
    Invoke-SubscriptionCommand $command $RunAs $(if($Script -ceq 'guest-app-launch.ps1'){215000}else{90000})
}
function Invoke-SubscriptionCommand([string]$Command,[string]$RunAs,[int]$Timeout) {
    $script:invocation++
    $start=[Diagnostics.ProcessStartInfo]::new($wsb)
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($argument in @('exec','--id',$SandboxId.ToString(),'--run-as',$RunAs,'--command',$Command,'--raw')) { $start.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try {
        if (!$process.Start()) { throw 'subscription_guest_start_failed' }
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($Timeout)) { $process.Kill($true); throw 'subscription_guest_deadline' }
        $text=$stdout.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $outputRoot "subscriptions-guest-$script:invocation.stdout.log"),$text)
        [IO.File]::WriteAllText((Join-Path $outputRoot "subscriptions-guest-$script:invocation.stderr.log"),$stderr.GetAwaiter().GetResult())
        $reply=$text|ConvertFrom-Json
        if ($process.ExitCode -ne 0 -or $reply.ExitCode -ne 0) { throw 'subscription_guest_action_failed' }
    } finally {$process.Dispose()}
}
function Assert-SubscriptionGuestMarker {
    $hash=Get-AuditSha256 (Join-Path $inputRoot 'sandbox-bundle.json')
    $script="`$ErrorActionPreference='Stop'; if((Get-FileHash -LiteralPath 'C:\ExVPN-App-QA\sandbox-bundle.json' -Algorithm SHA256).Hash.ToLowerInvariant() -cne '$hash'){exit 78}; exit 0"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    Invoke-SubscriptionCommand ('powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand '+$encoded) 'System' 30000
    $hash
}
function Read-SubscriptionPhase {
    $phase=$marker.subscriptionPhase
    $report=Get-Content -LiteralPath (Join-Path $outputRoot "subscriptions-$phase.json") -Raw | ConvertFrom-Json
    Assert-SubscriptionReport $report $marker $executableHash
    $launch=Get-Content -LiteralPath (Join-Path $outputRoot "subscriptions-$phase-launch-report.json") -Raw | ConvertFrom-Json
    $exit=Get-Content -LiteralPath (Join-Path $outputRoot "subscriptions-$phase-exit-report.json") -Raw | ConvertFrom-Json
    if ($launch.runId -cne $marker.runId -or $launch.subscriptionPhase -cne $phase -or $launch.processId -ne $report.processId -or
        !$launch.processTokenVerified -or !$launch.privilegedAccessDenied -or !$launch.sameInstallerOwner -or
        $launch.administratorToken -or $launch.elevated -or !$launch.mediumIntegrity -or $exit.exitCode -ne 0) { throw 'subscription_phase_launch_failed' }
    $report
}
$report=[ordered]@{format=1;runId=$marker.runId;build=$marker.build;uiSha256=$executableHash;startedUtc=[DateTime]::UtcNow.ToString('o');computerUse=$false;hostNetworkChanged=$false;storagePathOverride=$true;passed=$false;cleanupPassed=$false}
$owned=$false
try {
    $report.editMarkerSha256=Assert-SubscriptionGuestMarker
    $owned=$true
    Invoke-SubscriptionGuest 'guest-app-subscriptions.ps1' 'Setup'
    Invoke-SubscriptionGuest 'guest-app-launch.ps1' '' 'ExistingLogin'
    $report.edit=Read-SubscriptionPhase
    $marker.subscriptionPhase='reopen'
    $marker | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Encoding utf8NoBOM
    $report.reopenMarkerSha256=Assert-SubscriptionGuestMarker
    Invoke-SubscriptionGuest 'guest-app-subscriptions.ps1' 'Reopen'
    Invoke-SubscriptionGuest 'guest-app-launch.ps1' '' 'ExistingLogin'
    $report.reopen=Read-SubscriptionPhase
    Assert-SubscriptionColdPair $report.edit $report.reopen
    $report.passed=$true
} catch {
    $report.failureCode='subscription_ui_qa_failed'
    Write-Warning 'Subscription UI QA failed; raw evidence is retained privately.'
} finally {
    if ($owned) {
        try {
            Invoke-SubscriptionGuest 'guest-app-subscriptions.ps1' 'Cleanup'
            $cleanup=Get-Content -LiteralPath (Join-Path $outputRoot 'subscriptions-cleanup.json') -Raw | ConvertFrom-Json
            if ($cleanup.runId -cne $marker.runId -or !$cleanup.passed -or !$cleanup.qaDataRemoved -or !$cleanup.networkUnchanged -or !$cleanup.serviceBindingUnchanged -or !$cleanup.serviceProcessUnchanged) { throw 'subscription_cleanup_incomplete' }
            $report.cleanup=$cleanup;$report.cleanupPassed=$true
        } catch { $report.cleanupFailureCode='subscription_owned_cleanup_failed' }
    }
    $report.finishedUtc=[DateTime]::UtcNow.ToString('o')
    $report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $outputRoot 'subscriptions-coordinator.json') -Encoding utf8NoBOM
}
if (!$report.passed -or !$report.cleanupPassed) { throw 'subscription_qa_failed_inspect_private_reports' }
Write-Host "Two-process subscription UI, DPAPI restore and cleanup passed: $outputRoot"
