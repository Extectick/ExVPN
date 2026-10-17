# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
param([Parameter(Mandatory)][ValidateSet('Setup','Reopen','Cleanup')][string]$Action,[switch]$ConfirmDisposableGuest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$inputRoot='C:\ExVPN-App-QA'
$qaRoot='C:\Program Files\ExVPN UI QA'
$controlRoot='C:\Program Files\ExVPN UI QA Control'
$stateFile=Join-Path $controlRoot 'state.json'
$serviceExe='C:\Program Files\ExVPN Service\exvpn-service.exe'
if (!$ConfirmDisposableGuest -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne 'S-1-5-18' -or
    [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -ine $inputRoot) { throw 'subscription_disposable_system_required' }
$marker=Get-Content -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Raw | ConvertFrom-Json
if (!$marker.forbiddenHost -or $marker.forbiddenHost -ieq $env:COMPUTERNAME) { throw 'subscription_host_forbidden' }
foreach($name in @('package-common.ps1','windows-subscriptions-lib.ps1')) {
    $record=@($marker.files | Where-Object path -CEQ $name)
    if ($record.Count -ne 1 -or $record[0].sha256 -cne (Get-FileHash -LiteralPath (Join-Path $inputRoot $name)).Hash.ToLowerInvariant()) { throw 'subscription_helper_hash_mismatch' }
}
. (Join-Path $inputRoot 'package-common.ps1')
. (Join-Path $inputRoot 'windows-subscriptions-lib.ps1')
$paths=Get-SubscriptionQaPaths $marker
Assert-TreeManifest $inputRoot $marker.files @('sandbox-bundle.json')
foreach($path in @($qaRoot,$controlRoot,$paths.data,$paths.backup)) { Assert-SubscriptionNoLinks $path }
if (!(Test-Path -LiteralPath $paths.output -PathType Container)) { throw 'subscription_private_output_required' }
$installed=Get-Content -LiteralPath 'C:\Program Files\ExVPN Installer\install-state.json' -Raw | ConvertFrom-Json
Assert-ProtectedPackage 'C:\Program Files\ExVPN Installer'
Assert-ProtectedPackage 'C:\Program Files\ExVPN Service'
Assert-TreeManifest 'C:\Program Files\ExVPN Service' $installed.trees.service
if ($installed.build -ne $marker.build -or $installed.ownerSid -cnotmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw 'subscription_install_identity_invalid' }
$original='"'+$serviceExe+'" -owner-sid '+$installed.ownerSid+' -client "C:\Program Files\ExVPN\exvpn.exe" -network-testing'
function Read-SubscriptionBaseline {
    $service=Get-CimInstance Win32_Service -Filter "Name='ExVPNService'"
    if (!$service -or $service.PathName -cne $original -or $service.StartName -cne 'LocalSystem' -or $service.State -cne 'Running') { throw 'subscription_production_binding_required' }
    $process=Get-Process -Id $service.ProcessId -ErrorAction Stop
    if ($process.Path -ine $serviceExe) { throw 'subscription_service_process_mismatch' }
    $guard=& (Join-Path $inputRoot 'ui\qa-guard.exe') | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $guard.readFailed -or $guard.guardArmed -or (Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue)) { throw 'subscription_disconnected_baseline_required' }
    $routes=@(Get-NetRoute | Select-Object InterfaceIndex,DestinationPrefix,NextHop,RouteMetric,Protocol,PolicyStore | Sort-Object InterfaceIndex,DestinationPrefix,NextHop,RouteMetric,Protocol,PolicyStore)
    $dns=@(Get-DnsClientServerAddress | Select-Object InterfaceIndex,AddressFamily,ServerAddresses | Sort-Object InterfaceIndex,AddressFamily)
    $bytes=[Text.Encoding]::UTF8.GetBytes(([ordered]@{routes=$routes;dns=$dns}|ConvertTo-Json -Depth 5 -Compress))
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$network=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    [ordered]@{servicePid=[int]$service.ProcessId;serviceStartedFiletime=$process.StartTime.ToUniversalTime().ToFileTimeUtc();serviceSha256=(Get-FileHash -LiteralPath $serviceExe).Hash.ToLowerInvariant();networkSha256=$network;productionBinding=$true;tunnelAbsent=$true;guardArmed=$false}
}
function Assert-SubscriptionBaseline($Expected) {
    $actual=Read-SubscriptionBaseline
    foreach($name in @('servicePid','serviceStartedFiletime','serviceSha256','networkSha256')) {
        if ([string]$actual[$name] -cne [string]$Expected.$name) { throw 'subscription_baseline_changed' }
    }
    $actual
}
function Save-SubscriptionJson([string]$Name,$Value) {
    $target=Join-Path $paths.output $Name
    if (Test-Path -LiteralPath $target) { throw 'subscription_evidence_already_exists' }
    $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $target -Encoding utf8
}
function Assert-NoSubscriptionUiProcess {
    if (Get-Process -Name exvpn -ErrorAction SilentlyContinue) { throw 'subscription_existing_ui_process' }
}
$ownershipPath=Join-Path $paths.backup 'ownership.json'
if ($Action -ceq 'Setup') {
    if ($paths.phase -cne 'edit' -or (Test-Path -LiteralPath $paths.backup) -or (Test-Path -LiteralPath $paths.data)) { throw 'subscription_fresh_edit_required' }
    Assert-NoSubscriptionUiProcess
    $baseline=Read-SubscriptionBaseline
    $hadPrevious=Test-Path -LiteralPath $qaRoot
    if ($hadPrevious -ne (Test-Path -LiteralPath $controlRoot)) { throw 'subscription_incomplete_previous_qa_tree' }
    $previousUi=@();$previousControl=@()
    if ($hadPrevious) {
        Assert-ProtectedPackage $qaRoot; Assert-ProtectedPackage $controlRoot
        $old=Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        if ($old.ownerSid -cne $installed.ownerSid -or $old.original -cne $original -or $old.build -gt $marker.build) { throw 'subscription_previous_qa_not_owned' }
        Assert-TreeManifest $qaRoot $old.files
        $previousUi=@(Get-TreeManifest $qaRoot);$previousControl=@(Get-TreeManifest $controlRoot)
    }
    $backupParent=Split-Path $paths.backup
    if (!(Test-Path -LiteralPath $backupParent)) { New-Item -ItemType Directory -Path $backupParent | Out-Null; Set-ProtectedPackageACL $backupParent -Directory }
    Assert-ProtectedPackage $backupParent
    New-Item -ItemType Directory -Path $paths.backup | Out-Null; Set-ProtectedPackageACL $paths.backup -Directory
    [ordered]@{runId=$marker.runId;ownerSid=$installed.ownerSid;build=$marker.build;baseline=$baseline;hadPrevious=[bool]$hadPrevious;previousUi=$previousUi;previousControl=$previousControl;files=@(Get-TreeManifest (Join-Path $inputRoot 'ui'))} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ownershipPath -Encoding utf8
    Set-ProtectedPackageACL $ownershipPath
    # Both fixed source roots are verified QA trees. Destinations are children
    # of this new canonical run-ID backup; no production directory is moved.
    if ($hadPrevious) {
        Move-Item -LiteralPath $qaRoot -Destination (Get-OwnedPath $paths.backup 'ui')
        Move-Item -LiteralPath $controlRoot -Destination (Get-OwnedPath $paths.backup 'control')
    }
    Copy-OwnedTree (Join-Path $inputRoot 'ui') $qaRoot @(Get-TreeManifest (Join-Path $inputRoot 'ui'))
    New-Item -ItemType Directory -Path $controlRoot | Out-Null; Set-ProtectedPackageACL $controlRoot -Directory
    [ordered]@{subscriptionUi=$true;runId=$marker.runId;ownerSid=$installed.ownerSid;build=$marker.build;original=$original;serviceSha256=$baseline.serviceSha256;files=@(Get-TreeManifest $qaRoot)} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $stateFile -Encoding utf8
    Set-ProtectedPackageACL $stateFile
    $dataParent=Split-Path $paths.data
    if (!(Test-Path -LiteralPath $dataParent)) { New-Item -ItemType Directory -Path $dataParent | Out-Null; Set-ProtectedPackageACL $dataParent -Directory }
    Assert-ProtectedPackage $dataParent
    New-Item -ItemType Directory -Path $paths.data | Out-Null
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;0x1301bf;;;'+$installed.ownerSid+')')
    Set-Acl -LiteralPath $paths.data -AclObject $acl
    [void](Assert-SubscriptionBaseline ([pscustomobject]$baseline))
    Save-SubscriptionJson 'subscriptions-setup.json' ([ordered]@{runId=$marker.runId;passed=$true;temporaryClientBinding=$false;networkChanged=$false;storagePathOverride=$true;baseline=$baseline})
    return
}
Assert-ProtectedPackage $paths.backup
$ownership=Get-Content -LiteralPath $ownershipPath -Raw | ConvertFrom-Json
if ($ownership.runId -cne $marker.runId -or $ownership.ownerSid -cne $installed.ownerSid -or $ownership.build -ne $marker.build) { throw 'subscription_run_ownership_invalid' }
if ($Action -ceq 'Reopen') {
    if ($paths.phase -cne 'reopen') { throw 'subscription_reopen_phase_required' }
    Assert-NoSubscriptionUiProcess
    Assert-ProtectedPackage $qaRoot; Assert-ProtectedPackage $controlRoot
    Assert-TreeManifest $qaRoot $ownership.files
    $editMarker=$marker.PSObject.Copy();$editMarker.subscriptionPhase='edit'
    $edit=Get-Content -LiteralPath (Join-Path $paths.output 'subscriptions-edit.json') -Raw | ConvertFrom-Json
    Assert-SubscriptionReport $edit $editMarker (Get-FileHash -LiteralPath (Join-Path $qaRoot 'exvpn.exe')).Hash.ToLowerInvariant()
    [void](Assert-SubscriptionBaseline $ownership.baseline)
    Save-SubscriptionJson 'subscriptions-reopen-ready.json' ([ordered]@{runId=$marker.runId;passed=$true;previousProcessExited=$true;networkChanged=$false})
    return
}
# A failed test may leave its own GUI running. Never stop another PID by name.
foreach($phase in @('edit','reopen')) {
    $launchPath=Join-Path $paths.output ('subscriptions-'+$phase+'-launch-report.json')
    if (!(Test-Path -LiteralPath $launchPath)) { continue }
    $launch=Get-Content -LiteralPath $launchPath -Raw | ConvertFrom-Json
    if ($launch.runId -cne $marker.runId -or $launch.subscriptionPhase -cne $phase) { throw 'subscription_launch_ownership_invalid' }
    $process=Get-Process -Id $launch.processId -ErrorAction SilentlyContinue
    if ($process) {
        if ($process.Path -ine (Join-Path $qaRoot 'exvpn.exe') -or $process.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $launch.processStartFiletime) { throw 'subscription_ui_process_identity_changed' }
        $cimProcess=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id)
        if (!$cimProcess) { throw 'subscription_ui_process_identity_changed' }
        $processOwner=Invoke-CimMethod -InputObject $cimProcess -MethodName GetOwnerSid
        if ($processOwner.ReturnValue -ne 0 -or $processOwner.Sid -cne $installed.ownerSid) { throw 'subscription_ui_process_owner_changed' }
        Assert-TreeManifest $qaRoot $ownership.files
        Stop-Process -Id $process.Id -Force
        if (!$process.WaitForExit(10000)) { throw 'subscription_ui_stop_deadline' }
    }
}
Assert-NoSubscriptionUiProcess
$after=Assert-SubscriptionBaseline $ownership.baseline
if (Test-Path -LiteralPath $paths.data) {
    Assert-SubscriptionNoLinks $paths.data
    $dataFiles=@(Get-TreeManifest $paths.data)
    Remove-OwnedTree $paths.data $dataFiles
}
if (Test-Path -LiteralPath $qaRoot) { Assert-ProtectedPackage $qaRoot; Remove-OwnedTree $qaRoot $ownership.files }
if (Test-Path -LiteralPath $controlRoot) {
    Assert-ProtectedPackage $controlRoot
    $state=Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    if (!$state.subscriptionUi -or $state.runId -cne $marker.runId -or $state.ownerSid -cne $installed.ownerSid) { throw 'subscription_control_ownership_changed' }
    Remove-OwnedTree $controlRoot @(Get-TreeManifest $controlRoot)
}
if ($ownership.hadPrevious) {
    Assert-TreeManifest (Get-OwnedPath $paths.backup 'ui') $ownership.previousUi
    Assert-TreeManifest (Get-OwnedPath $paths.backup 'control') $ownership.previousControl
    Move-Item -LiteralPath (Get-OwnedPath $paths.backup 'ui') -Destination $qaRoot
    Move-Item -LiteralPath (Get-OwnedPath $paths.backup 'control') -Destination $controlRoot
}
Save-SubscriptionJson 'subscriptions-cleanup.json' ([ordered]@{runId=$marker.runId;passed=$true;qaDataRemoved=(!(Test-Path -LiteralPath $paths.data));previousQaRestored=[bool]$ownership.hadPrevious;serviceProcessUnchanged=$true;serviceBindingUnchanged=$true;networkUnchanged=$true;tunnelAbsent=$true;guardArmed=$false;baseline=$after})
