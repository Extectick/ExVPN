# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$SandboxId,[Parameter(Mandatory)][string]$BundleDirectory,[string]$PrivateProfileDirectory='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$bundle=[IO.Path]::GetFullPath($BundleDirectory)
if (!$bundle.StartsWith((Join-Path $repository 'artifacts/windows/'),[StringComparison]::OrdinalIgnoreCase)) {throw 'owned_bundle_required'}
$inputRoot=Join-Path $bundle 'input'
$outputRoot=Join-Path $bundle 'output'
$marker=Get-Content (Join-Path $inputRoot 'sandbox-bundle.json') -Raw | ConvertFrom-Json
$runGuid=[guid]::Empty
if(![guid]::TryParseExact($marker.runId,'D',[ref]$runGuid) -or $runGuid -eq [guid]::Empty){throw 'canonical_run_id_required'}
if ($marker.forbiddenHost -ine $env:COMPUTERNAME -or !$marker.controllerHarness -or $marker.installedServiceIpcTested -or @((Get-ChildItem $outputRoot -Force)).Count) {throw 'fresh_controller_bundle_required'}
. (Join-Path $repository 'scripts/windows/installer/package-common.ps1')
. (Join-Path $PSScriptRoot 'windows-pcap-dns-audit.ps1')
$captureMapping=& (Join-Path $PSScriptRoot 'ensure-windows-lifecycle-mapping.ps1') -SandboxId $SandboxId
Assert-TreeManifest $inputRoot @($marker.files | ForEach-Object {[pscustomobject]@{path=$_.file;sha256=$_.sha256}}) @('sandbox-bundle.json','command.txt')
$wsb=Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps/wsb.exe'
$remote=$PrivateProfileDirectory -ne ''
if($remote){
    $PrivateProfileDirectory=[IO.Path]::GetFullPath($PrivateProfileDirectory)
    if(!$PrivateProfileDirectory.StartsWith((Join-Path $repository '.private/'),[StringComparison]::OrdinalIgnoreCase) -or !(Test-Path (Join-Path $PrivateProfileDirectory 'profile.json'))){throw 'private_profile_directory_required'}
    $null=& $wsb share --id $SandboxId.ToString() --host-path $PrivateProfileDirectory --sandbox-path C:\ExVPN-Automatic-Private --raw
    if($LASTEXITCODE -ne 0){throw 'private_profile_mapping_failed'}
}
$inventory=& $wsb list --raw | ConvertFrom-Json
if (@($inventory.WindowsSandboxEnvironments | Where-Object Id -EQ $SandboxId.ToString()).Count -ne 1) {throw 'live_sandbox_required'}
foreach($mapping in @(@{host=$inputRoot;guest='C:\ExVPN-Package';write=$false},@{host=$inputRoot;guest='C:\ExVPN-System-QA';write=$false},@{host=$outputRoot;guest='C:\ExVPN-QA';write=$true})) {
    $arguments=@('share','--id',$SandboxId.ToString(),'--host-path',$mapping.host,'--sandbox-path',$mapping.guest,'--raw')
    if($mapping.write){$arguments+='--allow-write'}
    $null=& $wsb @arguments
    if($LASTEXITCODE -ne 0){throw 'isolated_mapping_failed'}
}
function Guest([string]$Body,[string]$RunAs='System') {
    $preamble=@'
$ErrorActionPreference='Stop'
$m=Get-Content C:\ExVPN-Package\sandbox-bundle.json -Raw | ConvertFrom-Json
if($env:COMPUTERNAME -ieq $m.forbiddenHost -or $m.runId -cne '__RUN__'){throw 'disposable_guest_required'}
'@
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($preamble.Replace('__RUN__',$marker.runId)+"`n"+$Body))
    $raw=& $wsb exec --id $SandboxId.ToString() --run-as $RunAs --command ('powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand '+$encoded) --raw
    if($LASTEXITCODE -ne 0 -or ($raw | ConvertFrom-Json).ExitCode -ne 0){throw 'guest_action_failed'}
}
function Read-Native {
    $path=Join-Path $outputRoot 'native-network.json'
    if(!(Test-Path $path)){return $null}
    if((Get-Item $path).Length -gt 65536){throw 'oversize_native_report'}
    $value=Get-Content $path -Raw | ConvertFrom-Json
    if($value.runId -cne $marker.runId -or !$value.controllerHarness -or $value.installedServiceIpcTested){throw 'foreign_native_report'}
    if($value.phase -ceq 'failed'){throw ('native_failed_'+$value.code)}
    return $value
}
function Wait-Connected([string]$Profile) {
    $deadline=[DateTime]::UtcNow.AddSeconds(100)
    do {
        $sample=Read-Native
        if($sample -and $sample.phase -ceq 'running' -and $sample.status.state -ceq 'connected' -and $sample.status.activeProfileId -ceq $Profile){
            if(!$sample.guardArmed -or $sample.guardReadFailed -or !$sample.status.automaticSelection){throw 'connected_guard_or_supervisor_missing'}
            return $sample
        }
        Start-Sleep -Milliseconds 200
    }while([DateTime]::UtcNow -lt $deadline)
    throw 'automatic_connection_deadline'
}
function Control([string]$Command) {[IO.File]::WriteAllText((Join-Path $inputRoot 'command.txt'),$Command)}
function Capture([ValidateSet('start','stop')][string]$Action,[ValidateSet('calibration','protected')][string]$Phase) {
    $body=@'
$route=Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' | Where-Object InterfaceAlias -NE 'ExVPN-Tunnel' | Sort-Object RouteMetric | Select-Object -First 1
$components=@((& pktmon.exe list --json | ConvertFrom-Json).Components | Where-Object {$_.DriverName -ieq 'netvsc.sys' -and @($_.Properties | Where-Object {$_.Name -ceq 'ifIndex' -and [int]$_.Value -eq $route.InterfaceIndex}).Count} | Select-Object -ExpandProperty Id -Unique)
if($components.Count -ne 1){throw 'physical_capture_component_required'}
$path='C:\ExVPN-Lifecycle-QA-Results\'+$m.runId+'-__PHASE__'
if('__ACTION__' -ceq 'start'){
 & pktmon.exe filter add ExVPNAutomaticDns -p 53 | Out-Null
 if($LASTEXITCODE -ne 0){throw 'dns_capture_filter_failed'}
 & pktmon.exe start --capture --comp $components[0] --pkt-size 128 --file-size 16 --file-name ($path+'.etl') | Out-Null
 if($LASTEXITCODE -ne 0){throw 'dns_capture_start_failed'}
}else{
 & pktmon.exe stop | Out-Null
 if($LASTEXITCODE -ne 0){throw 'dns_capture_stop_failed'}
 & pktmon.exe etl2pcap ($path+'.etl') --out ($path+'.pcapng') | Out-Null
 if($LASTEXITCODE -ne 0){throw 'dns_capture_export_failed'}
 & pktmon.exe filter remove ExVPNAutomaticDns | Out-Null
 if($LASTEXITCODE -ne 0){throw 'dns_capture_filter_cleanup_failed'}
}
'@
    Guest ($body.Replace('__ACTION__',$Action).Replace('__PHASE__',$Phase))
    if($Action -ceq 'stop'){return Get-PhysicalDnsPacketCounts (Join-Path $captureMapping.root ($marker.runId+'-'+$Phase+'.pcapng'))}
}
function Probes([ValidateSet('primary','backup','outage')][string]$Phase) {
    $script=@'
Clear-DnsClientCache
$results=@()
foreach($name in @('protected-probe.exe','excluded-probe.exe')) {
 foreach($mode in @('numeric','health','dns-tun','numeric6')) {
  $out=& ('C:\Program Files\ExVPN System QA\'+$name) -mode $mode
  if($LASTEXITCODE -ne 0){throw 'probe_process_failed'}
  $results+=@([ordered]@{executable=$name;result=($out | ConvertFrom-Json)})
 }
}
[ordered]@{runId=$m.runId;phase='__PHASE__';dnsCacheCleared=$true;probes=$results} | ConvertTo-Json -Depth 7 | Set-Content C:\ExVPN-QA\automatic-probes-__PHASE__.json -Encoding UTF8
'@
    # Clear cache needs SYSTEM; independent probe processes retain own App-ID.
    Guest ($script.Replace('__PHASE__',$Phase))
    $report=Get-Content (Join-Path $outputRoot ('automatic-probes-'+$Phase+'.json')) -Raw | ConvertFrom-Json
    if($report.runId -cne $marker.runId){throw 'foreign_probe_report'}
    foreach($probe in $report.probes){
        $expected=($Phase -cne 'outage' -or $probe.executable -ceq 'excluded-probe.exe')
        if($probe.result.mode -ceq 'numeric6'){
            $expected=($remote -and $Phase -cne 'outage' -and $probe.executable -ceq 'protected-probe.exe')
        }
        if($probe.result.mode -ceq 'dns-tun' -and $Phase -ceq 'outage'){continue}
        if([bool]$probe.result.success -ne $expected){throw ('probe_expectation_failed_'+$Phase+'_'+$probe.executable+'_'+$probe.result.mode)}
    }
    return $report
}
$report=[ordered]@{format=1;runId=$marker.runId;computerUse=$false;hostNetworkChanged=$false;controllerHarness=$true;installedServiceIpcTested=$false;uiPresent=$false;distinctRemoteEgressTested=$false;remoteRelay=$remote;twoIndependentVpsFailuresTested=$false;ipv6EgressTested=$false;dnsLeakCaptureTested=$false;phases=@();passed=$false;cleanupPassed=$false}
$report.bundleManifestSha256=(Get-FileHash -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Algorithm SHA256).Hash.ToLowerInvariant()
if($remote){$report.privateProfileSha256=(Get-FileHash -LiteralPath (Join-Path $PrivateProfileDirectory 'profile.json') -Algorithm SHA256).Hash.ToLowerInvariant()}
$prepared=$false
$captureActive=$false
$capturePhase='calibration'
try {
    Guest '& C:\ExVPN-System-QA\guest-system-qa.ps1 -ConfirmDisposableGuest -Action Prepare'
    $prepared=$true
    Capture 'start' 'calibration'
    $captureActive=$true
    Guest "try { Resolve-DnsName www.gstatic.com -Server 1.1.1.1 -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Out-Null } catch {}"
    $calibration=Capture 'stop' 'calibration'
    $captureActive=$false
    if($calibration.dnsPackets -lt 1){throw 'physical_dns_capture_calibration_failed'}
    $report.dnsCaptureCalibration=$calibration
    Control ''
    $startScript=@'
. C:\ExVPN-System-QA\package-common.ps1
Assert-ProtectedPackage 'C:\Program Files\ExVPN System QA'
if((Get-Process qa-system -ErrorAction SilentlyContinue) -or (Get-NetAdapter ExVPN-Tunnel -ErrorAction SilentlyContinue)){throw 'clean_guest_required'}
$route=Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1
if(!$route){throw 'physical_route_required'}
Start-Process -FilePath 'C:\Program Files\ExVPN System QA\qa-system.exe' -ArgumentList ('-confirm-disposable-guest -automatic-failover __REMOTE__ -interface-index '+$route.InterfaceIndex) -WorkingDirectory 'C:\Program Files\ExVPN System QA' -WindowStyle Hidden -RedirectStandardOutput C:\ExVPN-QA\automatic-stdout.txt -RedirectStandardError C:\ExVPN-QA\automatic-stderr.txt
'@
    Guest ($startScript.Replace('__REMOTE__',$(if($remote){'-remote-relay'}else{''})))
    $primaryConnected=Wait-Connected 'qa-primary'
    $report.phases+=$primaryConnected
    $report.guardTestStartSequence=$primaryConnected.sequence
    $capturePhase='protected'
    Capture 'start' 'protected'
    $captureActive=$true
    $report.phases+=Probes 'primary'
    Control 'stop-primary'
    $report.phases+=Wait-Connected 'qa-backup'
    $report.phases+=Probes 'backup'
    Control 'stop-all'
    $deadline=[DateTime]::UtcNow.AddSeconds(65)
    do {
        $sample=Read-Native
        if($sample -and $sample.status.state -in @('blocked','reconnecting') -and $sample.primaryStopped -and $sample.backupStopped){break}
        Start-Sleep -Milliseconds 200
    }while([DateTime]::UtcNow -lt $deadline)
    if(!$sample -or $sample.status.state -notin @('blocked','reconnecting') -or !$sample.guardArmed){throw 'all_servers_outage_not_guarded'}
    $report.phases+=$sample
    $report.phases+=Probes 'outage'
    $capture=Capture 'stop' 'protected'
    $captureActive=$false
    $report.dnsPhysicalCapture=$capture
    if($capture.dnsPackets -ne 0){throw 'physical_dns_leak_observed'}
    $report.dnsLeakCaptureTested=$true
    $samples=@(Get-Content (Join-Path $outputRoot 'automatic-samples.jsonl') | ForEach-Object {$_ | ConvertFrom-Json} | Where-Object {$_.sequence -ge $primaryConnected.sequence})
    if(@($samples | Where-Object {$_.guardReadFailed -or !$_.guardArmed}).Count){throw 'guard_continuity_failed'}
    $report.sampleCount=$samples.Count
    $report.guardSampleContinuityPassed=$true
    $report.ipv6EgressTested=$remote
    $report.adapterContinuityPassed=(@($samples | Where-Object {!$_.adapterPresent}).Count -eq 0)
    $report.passed=$true
} catch {
    $report.error=$_.Exception.Message
} finally {
    if($captureActive){try{$null=Capture 'stop' $capturePhase}catch{$report.captureCleanupError=$_.Exception.Message}}
    if($prepared){
        try {
            Control 'disconnect'
            $deadline=[DateTime]::UtcNow.AddSeconds(35)
            do {$sample=Read-Native;if($sample -and $sample.phase -ceq 'disconnected'){break};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $deadline)
            if(!$sample -or $sample.phase -cne 'disconnected' -or $sample.guardArmed -or $sample.guardReadFailed -or $sample.adapterPresent){throw 'native_disconnect_failed'}
            Guest '& C:\ExVPN-System-QA\guest-system-qa.ps1 -ConfirmDisposableGuest -Action Inspect -RoutingMode exclude'
            $before=Get-Content (Join-Path $outputRoot 'prepared.json') -Raw | ConvertFrom-Json
            $after=Get-Content (Join-Path $outputRoot 'inspection-exclude.json') -Raw | ConvertFrom-Json
            if($after.harnessRunning -or $after.adapterPresent -or $after.servicePresent -or $after.networkSha256 -cne $before.networkBeforeSha256){throw 'network_baseline_not_restored'}
            $report.cleanupPassed=$true
        } catch {$report.cleanupError=$_.Exception.Message}
    }
    $report | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $outputRoot 'automatic-coordinator.json') -Encoding utf8NoBOM
}
if(!$report.passed -or !$report.cleanupPassed){throw 'automatic_failover_qa_incomplete'}
$report
