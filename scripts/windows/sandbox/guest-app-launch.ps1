# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
param([switch]$ConfirmDisposableGuest)
$ErrorActionPreference = 'Stop'
$inputRoot = 'C:\ExVPN-App-QA'
$outputRoot = 'C:\ExVPN-App-QA-Results'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$marker = Get-Content -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Raw | ConvertFrom-Json
$subscriptionUi=$marker.PSObject.Properties['subscriptionUi'] -and $marker.subscriptionUi
if ($subscriptionUi) {
    $helper=@($marker.files | Where-Object path -CEQ 'windows-subscriptions-lib.ps1')
    if ($helper.Count -ne 1 -or $helper[0].sha256 -cne (Get-FileHash -LiteralPath (Join-Path $inputRoot 'windows-subscriptions-lib.ps1')).Hash.ToLowerInvariant()) { throw 'Subscription validator checksum mismatch.' }
    . (Join-Path $inputRoot 'windows-subscriptions-lib.ps1')
    $paths=Get-SubscriptionQaPaths $marker
    $outputRoot=$paths.output
}
if ($marker.PSObject.Properties['transportCycles'] -and $marker.transportCycles -ne 0) {
    if (($marker.transportCycles -isnot [int] -and $marker.transportCycles -isnot [long]) -or $marker.transportCycles -lt 3 -or $marker.transportCycles -gt 20) { throw 'Invalid transport cycle count.' }
    $parsedRun = [guid]::Empty
    if (![guid]::TryParseExact($marker.runId,'D',[ref]$parsedRun) -or $parsedRun -eq [guid]::Empty) { throw 'Invalid lifecycle run ID.' }
    $outputRoot = Join-Path 'C:\ExVPN-Lifecycle-QA-Results' $marker.runId
}
if (!$ConfirmDisposableGuest -or $identity.User.Value -eq 'S-1-5-18' -or $env:COMPUTERNAME -ieq $marker.forbiddenHost -or [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -ine $inputRoot) { throw 'Disposable interactive user runner required.' }
$common = @($marker.files | Where-Object path -CEQ 'package-common.ps1')
if ($common.Count -ne 1 -or $common[0].sha256 -cne (Get-FileHash -LiteralPath (Join-Path $inputRoot 'package-common.ps1')).Hash.ToLowerInvariant()) { throw 'Helper checksum mismatch.' }
. (Join-Path $inputRoot 'package-common.ps1')
Assert-TreeManifest $inputRoot $marker.files @('sandbox-bundle.json')
Assert-ProtectedPackage 'C:\Program Files\ExVPN UI QA Control'
$state = Get-Content -LiteralPath 'C:\Program Files\ExVPN UI QA Control\state.json' -Raw | ConvertFrom-Json
if ($identity.User.Value -cne $state.ownerSid -or (Get-Process -Name exvpn -ErrorAction SilentlyContinue)) { throw 'QA desktop identity/state mismatch.' }
Assert-ProtectedPackage 'C:\Program Files\ExVPN UI QA'
Assert-TreeManifest 'C:\Program Files\ExVPN UI QA' $state.files
if ($subscriptionUi) {
    foreach ($suffix in @('.json','-launch-report.json','-exit-report.json')) {
        $name='subscriptions-'+$marker.subscriptionPhase+$suffix
        if (Test-Path -LiteralPath (Join-Path $outputRoot $name)) { throw 'Subscription phase already executed.' }
    }
}
$admin = [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($marker.PSObject.Properties['unelevated'] -and $marker.unelevated) {
    # Helper validates the actual suspended UI process token before resuming it.
    # Its report, not the elevated launcher's token, is authoritative for QA.
    $process = Start-Process -FilePath (Join-Path $inputRoot 'qa-desktop.exe') -PassThru -WindowStyle Hidden
    $deadlineMs = if ($subscriptionUi) { 200000 } else { 1220000 } # Allow bounded child cleanup.
} else {
    [ordered]@{runId=$marker.runId;desktopUser=$true;administratorToken=$admin} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputRoot 'launch-report.json') -Encoding utf8
    # Visible application is intentional; test input is synthesized inside Flutter.
    $process = Start-Process -FilePath 'C:\Program Files\ExVPN UI QA\exvpn.exe' -PassThru -WindowStyle Normal
    $deadlineMs = 1200000
}
if (!$process.WaitForExit($deadlineMs)) { Stop-Process -Id $process.Id; throw 'Bounded Flutter test deadline exceeded.' }
$exitName=if ($subscriptionUi) { 'subscriptions-'+$marker.subscriptionPhase+'-exit-report.json' } else { 'exit-report.json' }
if ($subscriptionUi -and (Test-Path -LiteralPath (Join-Path $outputRoot $exitName))) { throw 'Subscription phase already executed.' }
[ordered]@{exitCode=$process.ExitCode} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputRoot $exitName) -Encoding utf8
exit $process.ExitCode
