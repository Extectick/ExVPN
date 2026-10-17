# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'android-lifecycle-tools.ps1')
$checks=0
function Assert-QaReject([scriptblock]$Action) {
    $rejected=$false
    try { $null=& $Action } catch { $rejected=$true }
    if (!$rejected) { throw 'qa_negative_fixture_was_accepted' }
    $script:checks++
}
$base="INSTRUMENTATION_RESULT: durationMs=1`nINSTRUMENTATION_RESULT: uid=10001`nINSTRUMENTATION_RESULT: vpnTransport=true`n"
$good=$base+"INSTRUMENTATION_RESULT: success=true`nINSTRUMENTATION_RESULT: httpStatus=204`nINSTRUMENTATION_CODE: -1`n"
$parsed=ConvertFrom-AndroidLifecycleProbe $good
if (!$parsed.success -or !$parsed.vpnTransport -or $parsed.uid -ne 10001 -or $parsed.httpStatus -ne 204) { throw 'qa_success_fixture_failed' }
$checks++
$failed=ConvertFrom-AndroidLifecycleProbe ($base+"INSTRUMENTATION_RESULT: error=deadline`nINSTRUMENTATION_CODE: -1`n")
if ($failed.success -or $failed.error -cne 'deadline') { throw 'qa_failed_request_was_success' }
$checks++
Assert-QaReject { ConvertFrom-AndroidLifecycleProbe ($good+"INSTRUMENTATION_RESULT: uid=10002`n") }
Assert-QaReject { ConvertFrom-AndroidLifecycleProbe ($good+"INSTRUMENTATION_RESULT: error=network`n") }
Assert-QaReject { ConvertFrom-AndroidLifecycleProbe ($good.Replace('success=true','success=True')) }
Assert-QaReject { ConvertFrom-AndroidLifecycleProbe ($good.Replace('uid=10001','uid=-1')) }
Assert-QaReject { ConvertFrom-AndroidLifecycleProbe ($good.Replace('INSTRUMENTATION_CODE: -1','INSTRUMENTATION_CODE: 0')) }
Assert-QaReject { ConvertFrom-AndroidLifecycleProbe ($base+"INSTRUMENTATION_CODE: -1`n") }
Assert-QaReject { ConvertFrom-AndroidLifecycleProbe ($good+"INSTRUMENTATION_RESULT: bodySha256=not-a-digest`n") }
Assert-QaReject { ConvertFrom-AndroidLifecycleProbe ($good+"INSTRUMENTATION_RESULT: endpoint=synthetic.invalid`n") }
$unknownCounter=ConvertFrom-AndroidLifecycleProbe ($good+"INSTRUMENTATION_RESULT: uidTxBytes=-1`n")
if ($unknownCounter.uidTxBytes -ne -1) { throw 'qa_unknown_counter_was_fabricated' }
$checks++
Assert-QaReject { ConvertFrom-AndroidLifecycleProbe ($good+"INSTRUMENTATION_RESULT: durationMs=-1`n") }
$nonceReply=$base+"INSTRUMENTATION_RESULT: success=false`nINSTRUMENTATION_RESULT: dnsQueryAttempted=true`nINSTRUMENTATION_RESULT: dnsQuerySha256=$('a'*64)`nINSTRUMENTATION_RESULT: dnsOutcome=no_answer`nINSTRUMENTATION_CODE: -1`n"
$nonceResult=ConvertFrom-AndroidLifecycleProbe $nonceReply
if ($nonceResult.success -or !$nonceResult.dnsQueryAttempted -or $nonceResult.dnsOutcome -cne 'no_answer') { throw 'qa_dns_no_answer_was_success' }
$checks++
Assert-QaReject { ConvertFrom-AndroidLifecycleProbe ($nonceReply.Replace('no_answer','example.invalid')) }
Assert-QaReject { ConvertFrom-AndroidLifecycleProbe ($nonceReply+"INSTRUMENTATION_RESULT: nonce=0123456789abcdef0123456789abcdef`n") }

[xml]$tree='<hierarchy><node package="ru.exvpn.exvpn" text="" content-desc="Подключить VPN" bounds="[2,4][12,24]" /></hierarchy>'
$node=Find-AndroidLifecycleLabel $tree 'Подключить VPN'
if ($node.GetAttribute('bounds') -cne '[2,4][12,24]') { throw 'qa_ui_target_lost_bounds' }
$checks++
Assert-QaReject { Find-AndroidLifecycleLabel $tree 'Missing' }
[xml]$duplicate='<hierarchy><node text="same" /><node content-desc="same" /></hierarchy>'
Assert-QaReject { Find-AndroidLifecycleLabel $duplicate 'same' }
[xml]$other='<hierarchy><node package="another.package" bounds="[2,4][12,24]" /></hierarchy>'
Assert-QaReject { Invoke-AndroidLifecycleTap $other.hierarchy.node 'synthetic' }
[xml]$empty='<hierarchy><node package="ru.exvpn.exvpn" bounds="[2,4][2,4]" /></hierarchy>'
Assert-QaReject { Invoke-AndroidLifecycleTap $empty.hierarchy.node 'synthetic' }
Assert-QaReject { Initialize-AndroidLifecycleQa -Serial 'emulator-5564' -OutputDirectory (Join-Path $PSScriptRoot 'outside-private') }
Assert-QaReject { Initialize-AndroidLifecycleQa -Serial 'physical-device' -OutputDirectory '.private/test' }

# Semantic UI output is a distinct contract, not an HTTPS or service proof.
$uiRun='12345678-1234-1234-1234-123456789abc'
function New-UiReply([string]$Run=$uiRun) {
    @('mechanism=instrumentation_semantics_v1',"runId=$Run",'command=connect','status=completed',
        'beforePhase=disconnected','afterPhase=connected','actionAttempted=true','actionAccepted=true',
        'targetCount=1','nodesVisited=8','durationMs=25') | ForEach-Object { "INSTRUMENTATION_RESULT: $_" } |
        Join-String -Separator "`n" -OutputSuffix "`nINSTRUMENTATION_CODE: -1`n"
}
$uiGood=New-UiReply
$ui=ConvertFrom-AndroidLifecycleVpnUi -Output $uiGood -RunId $uiRun -Command connect
if ($ui.status -cne 'completed' -or !$ui.actionAccepted -or $ui.afterPhase -cne 'connected') { throw 'qa_ui_completion_fixture_failed' }
$checks++
$uiCrlf=ConvertFrom-AndroidLifecycleVpnUi -Output ($uiGood.Replace("`n","`r`n")) -RunId $uiRun -Command connect
if ($uiCrlf.mechanism -cne 'instrumentation_semantics_v1') { throw 'qa_ui_crlf_failed' }
$checks++
$observe=$uiGood.Replace('command=connect','command=observe').Replace('status=completed','status=observed').Replace('beforePhase=disconnected','beforePhase=connected').Replace('actionAttempted=true','actionAttempted=false').Replace('actionAccepted=true','actionAccepted=false')
$observed=ConvertFrom-AndroidLifecycleVpnUi -Output $observe -RunId $uiRun -Command observe
if ($observed.actionAttempted) { throw 'qa_ui_observe_clicked' }; $checks++
foreach ($replacement in @(
    @('status=completed','status=observed'), @('status=completed','status=precondition_failed'),
    @('afterPhase=connected','afterPhase=disconnected'), @('beforePhase=disconnected','beforePhase=connected'),
    @('actionAttempted=true','actionAttempted=false'), @('actionAccepted=true','actionAccepted=false'),
    @('actionAccepted=true','actionAccepted=True'), @('nodesVisited=8','nodesVisited=2049'),
    @('targetCount=1','targetCount=2'), @('durationMs=25','durationMs=-1'),
    @('durationMs=25','durationMs=35001'), @('durationMs=25','durationMs=01'),
    @('mechanism=instrumentation_semantics_v1','mechanism=uiautomator'),
    @('INSTRUMENTATION_CODE: -1','INSTRUMENTATION_CODE: 0'),
    @('status=completed','status=arbitrary'), @('beforePhase=disconnected','beforePhase=private-label'))) {
    Assert-QaReject { ConvertFrom-AndroidLifecycleVpnUi -Output ($uiGood.Replace($replacement[0],$replacement[1])) -RunId $uiRun -Command connect }
}
Assert-QaReject { ConvertFrom-AndroidLifecycleVpnUi -Output ($uiGood+"INSTRUMENTATION_RESULT: status=completed`n") -RunId $uiRun -Command connect }
Assert-QaReject { ConvertFrom-AndroidLifecycleVpnUi -Output ($uiGood+"INSTRUMENTATION_RESULT: nodeText=synthetic-secret`n") -RunId $uiRun -Command connect }
Assert-QaReject { ConvertFrom-AndroidLifecycleVpnUi -Output ($uiGood+"arbitrary output`n") -RunId $uiRun -Command connect }
Assert-QaReject { ConvertFrom-AndroidLifecycleVpnUi -Output ($uiGood+"INSTRUMENTATION_CODE: -1`n") -RunId $uiRun -Command connect }
Assert-QaReject { ConvertFrom-AndroidLifecycleVpnUi -Output $uiGood -RunId '22345678-1234-1234-1234-123456789abc' -Command connect }
Assert-QaReject { ConvertFrom-AndroidLifecycleVpnUi -Output $uiGood -RunId $uiRun -Command disconnect }
Assert-QaReject { ConvertFrom-AndroidLifecycleVpnUi -Output $observe.Replace('actionAttempted=false','actionAttempted=true') -RunId $uiRun -Command observe }
Assert-QaReject { ConvertFrom-AndroidLifecycleVpnUi -Output $uiGood.Replace("INSTRUMENTATION_RESULT: nodesVisited=8`n",'') -RunId $uiRun -Command connect }

$stat='999 (probe with spaces) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 12345 20'
$marker="$uiRun`n999`n12345`n"
if (!(Test-AndroidLifecycleVpnUiOwner $marker $uiRun 999 $stat)) { throw 'qa_ui_owner_positive_failed' }; $checks++
foreach ($bad in @($marker.Replace($uiRun,'22345678-1234-1234-1234-123456789abc'),$marker.Replace('12345','12346'),$marker.Replace('999','998'),($marker+"extra`n"))) {
    if (Test-AndroidLifecycleVpnUiOwner $bad $uiRun 999 $stat) { throw 'qa_ui_owner_negative_failed' }; $checks++
}
if (Test-AndroidLifecycleVpnUiOwner $marker $uiRun 999 $stat.Replace('999 (','998 (')) { throw 'qa_ui_stat_pid_ignored' }; $checks++
foreach ($invalidRun in @('00000000-0000-0000-0000-000000000000','------------------------------------')) {
    if (Test-AndroidLifecycleVpnUiOwner $marker.Replace($uiRun,$invalidRun) $invalidRun 999 $stat) { throw 'qa_ui_invalid_owner_run' }; $checks++
}
if ((Get-AndroidLifecycleQaProcessId "PID NAME`n999 ru.exvpn.netprobe`n1000 ru.exvpn.netprobe.excluded`n") -ne 999) { throw 'qa_ui_pid_parse_failed' }; $checks++
Assert-QaReject { Get-AndroidLifecycleQaProcessId "PID NAME`n999 ru.exvpn.netprobe`n1000 ru.exvpn.netprobe:child`n" }
Assert-QaReject { Get-AndroidLifecycleQaProcessId "PID NAME`n999 ru.exvpn.netprobe:child`n" }
Assert-QaReject { Get-AndroidLifecycleQaProcessId 'unavailable' }

# Mock the command boundary: timeout never retries ACTION_CLICK, and a stale or
# unavailable ownership record cannot authorize force-stop of any application.
$script:AndroidLifecycleContext=@{Serial='emulator-9998';Output='unused';Adb='not-executed'}
$script:uiCalls=[Collections.Generic.List[object]]::new()
$script:uiMode='normal'; $script:currentRun=''
function Invoke-AndroidLifecycleAdb {
    param([string[]]$AdbArguments,[string]$Step,[int]$TimeoutSeconds=30)
    $script:uiCalls.Add([pscustomobject]@{Arguments=$AdbArguments;Step=$Step;Timeout=$TimeoutSeconds})
    if ($Step.EndsWith('-processes')) {
        if ($script:uiMode -ceq 'busy') { return "PID NAME`n999 ru.exvpn.netprobe`n" }
        return "PID NAME`n100 system_server`n"
    }
    if ($Step.EndsWith('-instrument')) {
        $index=[Array]::IndexOf($AdbArguments,'runId'); $script:currentRun=$AdbArguments[$index+1]
        if ($script:uiMode -ceq 'normal') { return New-UiReply $script:currentRun }
        throw 'qa_adb_deadline'
    }
    if ($Step.EndsWith('-owner')) {
        if ($script:uiMode -ceq 'missing') { throw 'qa_adb_failed' }
        $run=if ($script:uiMode -ceq 'wrong') { $uiRun } else { $script:currentRun }
        return "$run`n999`n12345`n"
    }
    if ($Step.EndsWith('-owner-pid')) { return "PID NAME`n999 ru.exvpn.netprobe`n" }
    if ($Step.EndsWith('-owner-start')) {
        if ($script:uiMode -ceq 'stale') { return $stat.Replace('12345','54321') }
        return $stat
    }
    if ($Step.EndsWith('-probe-stop')) {
        if ($script:uiMode -ceq 'stop-failed') { throw 'qa_adb_failed' }
        return ''
    }
    if ($Step.EndsWith('-probe-stopped')) { return "PID NAME`n100 system_server`n" }
    throw 'qa_unexpected_mock_command'
}
$normal=Invoke-AndroidLifecycleVpnUi -Command connect -Step synthetic
if ($normal.status -cne 'completed' -or $script:uiCalls.Count -ne 2 -or $script:uiCalls[1].Timeout -ne 35) { throw 'qa_ui_invocation_contract_failed' }; $checks++
foreach ($mode in @('timeout','wrong','stale','missing','stop-failed')) {
    $script:uiMode=$mode; $script:uiCalls.Clear()
    $timed=Invoke-AndroidLifecycleVpnUi -Command connect -Step synthetic
    $expected=if ($mode -ceq 'timeout') { 'stopped_owned_probe' } elseif ($mode -ceq 'stop-failed') { 'cleanup_failed' } else { 'cleanup_refused' }
    if ($timed.status -cne 'host_deadline' -or $timed.timeoutCleanup -cne $expected -or $null -ne $timed.actionAccepted) { throw 'qa_ui_timeout_contract_failed' }; $checks++
    if (@($script:uiCalls | Where-Object { $_.Step.EndsWith('-instrument') }).Count -ne 1) { throw 'qa_ui_action_retried' }; $checks++
    $stops=@($script:uiCalls | Where-Object { $_.Arguments -contains 'force-stop' })
    $stopCount=if ($mode -cin @('timeout','stop-failed')) { 1 } else { 0 }
    if ($stops.Count -ne $stopCount) { throw 'qa_ui_unauthorized_stop' }; $checks++
    foreach ($stop in $stops) {
        if (($stop.Arguments -join ' ') -cne 'shell am force-stop ru.exvpn.netprobe') { throw 'qa_ui_wrong_stop_target' }; $checks++
    }
}
$script:uiMode='busy'; $script:uiCalls.Clear()
Assert-QaReject { Invoke-AndroidLifecycleVpnUi -Command connect -Step synthetic }
if ($script:uiCalls.Count -ne 1) { throw 'qa_ui_busy_process_touched' }; $checks++

# Synthetic ConnectivityService records: no real addresses, package UIDs or dumps.
$physicalRow='  NetworkAgentInfo{ ni{[type: WIFI[], state: CONNECTED/CONNECTED, reason: (unspecified)]} network{100} lp{{InterfaceName: wlan0 LinkAddresses: [] }} nc{[ Transports: WIFI Capabilities: INTERNET&NOT_VPN]} }'
$vpnRow='  NetworkAgentInfo{ ni{[type: VPN[], state: CONNECTED/CONNECTED, reason: agentConnect]} network{101} lp{{InterfaceName: tun0 LinkAddresses: [] }} nc{[ Transports: WIFI|VPN Capabilities: INTERNET OwnerUid: 10042 RequestorUid: -1]} }'
$directDump="Active default network: 100`nCurrent Networks:`n$physicalRow`nStatus for known UIDs:`n"
$vpnDump=$directDump.Replace("`nStatus for known UIDs:","`n$vpnRow`nStatus for known UIDs:")
$direct=ConvertFrom-AndroidLifecycleVpnNetworks -Output $directDump
if (!$direct.activeVpnNetworkAbsent -or $direct.vpnCount -ne 0 -or $direct.vpnInterfaces.Count -ne 0 -or $direct.ownerUidMatched) { throw 'qa_direct_network_fixture_failed' }; $checks++
$network=ConvertFrom-AndroidLifecycleVpnNetworks -Output $vpnDump -ExpectedOwnerUid 10042
if ($network.activeVpnNetworkAbsent -or $network.vpnCount -ne 1 -or !$network.ownerUidMatched -or
    $network.vpnInterfaces.Count -ne 1 -or $network.vpnInterfaces[0] -cne 'tun0') { throw 'qa_vpn_network_fixture_failed' }; $checks++
foreach ($ending in @("`r`n","`r`r`n")) {
    $network=ConvertFrom-AndroidLifecycleVpnNetworks -Output $vpnDump.Replace("`n",$ending) -ExpectedOwnerUid 10042
    if ($network.vpnCount -ne 1) { throw 'qa_network_line_ending_failed' }; $checks++
}
$history=ConvertFrom-AndroidLifecycleVpnNetworks -Output ($directDump+"`nEvent log:`n$vpnRow`n")
if (!$history.activeVpnNetworkAbsent) { throw 'qa_historical_vpn_counted_as_active' }; $checks++
Assert-QaReject { ConvertFrom-AndroidLifecycleVpnNetworks -Output $vpnDump }
Assert-QaReject { ConvertFrom-AndroidLifecycleVpnNetworks -Output $vpnDump -ExpectedOwnerUid 10043 }
Assert-QaReject { ConvertFrom-AndroidLifecycleVpnNetworks -Output $directDump -ExpectedOwnerUid 9999 }
foreach ($badDump in @('', 'request send failed: Permission denied',
    $vpnDump.Replace('Current Networks:','Unknown section:'),
    $vpnDump.Replace('Status for known UIDs:','Unknown end:'),
    ($vpnDump+$vpnDump),
    $vpnDump.Replace('OwnerUid: 10042 ','OwnerUid: 10042 OwnerUid: 10042 '),
    $vpnDump.Replace('OwnerUid: 10042 ',''),
    $vpnDump.Replace('OwnerUid: 10042','OwnerUid: 999999999999'),
    $vpnDump.Replace('Transports: WIFI|VPN','Transports: WIFI'),
    $vpnDump.Replace('type: VPN[]','type: WIFI[]'),
    $vpnDump.Replace('InterfaceName: tun0','InterfaceName: wlan1'),
    $vpnDump.Replace($vpnRow,$vpnRow.Replace('CONNECTED/CONNECTED','CONNECTING/CONNECTING')),
    $vpnDump.Replace($vpnRow,$vpnRow.Substring(0,$vpnRow.Length-2)),
    $vpnDump.Replace($vpnRow,"$vpnRow`n$vpnRow"),
    $vpnDump.Replace($vpnRow,($vpnRow+"`n"+$vpnRow.Replace('network{101}','network{102}').Replace('tun0','tun1'))),
    $directDump.Replace('InterfaceName: wlan0','InterfaceName: tun0'),
    "Current Networks:`nStatus for known UIDs:`n$physicalRow`n")) {
    Assert-QaReject { ConvertFrom-AndroidLifecycleVpnNetworks -Output $badDump -ExpectedOwnerUid 10042 }
}

# The system dialog is distinct from the application's semantics. Its warning
# resource differs on API30; both supported IDs still require a single message.
$consentXml='<hierarchy><node package="com.android.vpndialogs"><node package="com.android.vpndialogs" resource-id="android:id/alertTitle" text="Connection request"/><node package="com.android.vpndialogs" resource-id="com.android.vpndialogs:id/warning" text="ExVPN requests a VPN connection."/><node package="com.android.vpndialogs" resource-id="android:id/button2" class="android.widget.Button" clickable="true" enabled="true" text="Cancel"/><node package="com.android.vpndialogs" resource-id="android:id/button1" class="android.widget.Button" clickable="true" enabled="true" text="OK" bounds="[20,40][80,100]"/></node></hierarchy>'
foreach ($validXml in @($consentXml,$consentXml.Replace('com.android.vpndialogs:id/warning','android:id/message'),
    $consentXml.Replace('Connection request','Запрос на подключение').Replace('text="OK"','text="ОК"'))) {
    $positive=Find-AndroidLifecycleVpnConsentButton -Tree ([xml]$validXml)
    if ($positive.GetAttribute('resource-id') -cne 'android:id/button1') { throw 'qa_consent_button_fixture_failed' }; $checks++
}
foreach ($badXml in @($consentXml.Replace('ExVPN requests','Other requests'),
    $consentXml.Replace('ExVPN requests','ExVPNOther requests'),
    $consentXml.Replace('com.android.vpndialogs','another.package'),
    $consentXml.Replace('Connection request','Different request'),
    $consentXml.Replace('text="OK"','text="Yes"'),
    $consentXml.Replace('enabled="true" text="OK"','enabled="false" text="OK"'),
    $consentXml.Replace('clickable="true" enabled="true" text="OK"','clickable="false" enabled="true" text="OK"'),
    $consentXml.Replace('class="android.widget.Button"','class="android.view.View"'),
    $consentXml.Replace('bounds="[20,40][80,100]"','bounds="[20,40][20,100]"'),
    $consentXml.Replace('</hierarchy>','<node package="ru.exvpn.exvpn"/></hierarchy>'),
    $consentXml.Replace('</hierarchy>','<node package="com.android.vpndialogs" resource-id="android:id/button1" enabled="false"/></hierarchy>'),
    $consentXml.Replace('</hierarchy>','<node package="com.android.vpndialogs" resource-id="android:id/message" text="ExVPN requests a VPN connection."/></hierarchy>'))) {
    Assert-QaReject { Find-AndroidLifecycleVpnConsentButton -Tree ([xml]$badXml) }
}

$consentReply=$uiGood.Replace('status=completed','status=wrong_window_package').Replace('afterPhase=connected','afterPhase=requesting_permission')
function New-ConsentReceipt {
    $receipt=ConvertFrom-AndroidLifecycleVpnUi -Output $consentReply -RunId $uiRun -Command connect
    $receipt.runId=[guid]::NewGuid().ToString('D'); $receipt.timeoutCleanup='not_needed'
    return $receipt
}
$script:consentMode='normal'
$script:consentCalls=[Collections.Generic.List[object]]::new()
function Invoke-AndroidLifecycleAdb {
    param([string[]]$AdbArguments,[string]$Step,[int]$TimeoutSeconds=30)
    $script:consentCalls.Add([pscustomobject]@{Arguments=$AdbArguments;Step=$Step;Timeout=$TimeoutSeconds})
    $command=$AdbArguments -join ' '
    switch ($command) {
        'shell dumpsys activity services ru.exvpn.exvpn' {
            if ($script:consentMode -ceq 'service-before' -or ($script:consentMode -ceq 'service-immediate' -and $Step.EndsWith('-immediate'))) {
                return "ACTIVITY MANAGER SERVICES (dumpsys activity services)`nServiceRecord{ ru.exvpn.exvpn/.ExVpnService }`n"
            }
            if ($script:consentMode -ceq 'incomplete-service') { return 'ACTIVITY MANAGER SERVICES (dumpsys activity services)' }
            return "ACTIVITY MANAGER SERVICES (dumpsys activity services)`n  (nothing)`n"
        }
        'shell dumpsys connectivity' {
            if ($script:consentMode -cin @('active-vpn','observe-vpn')) { return $vpnDump }
            if ($script:consentMode -ceq 'incomplete-network') { return 'Current Networks:' }
            return $directDump
        }
        'shell dumpsys activity activities' {
            if ($script:consentMode -ceq 'wrong-top' -or ($script:consentMode -ceq 'changed-top' -and $Step.EndsWith('-immediate'))) {
                return "mResumedActivity: ActivityRecord{synthetic other.package/.OtherDialog}`n"
            }
            return "mResumedActivity: ActivityRecord{synthetic com.android.vpndialogs/.ConfirmDialog}`n"
        }
        'exec-out uiautomator dump /dev/tty' {
            $body=if ($script:consentMode -ceq 'wrong-message') { $consentXml.Replace('ExVPN requests','Other requests') } else { $consentXml }
            return '<?xml version="1.0" encoding="UTF-8"?>'+$body
        }
        'shell input tap 50 70' {
            if ($script:consentMode -ceq 'tap-deadline') { throw 'qa_adb_deadline' }
            return ''
        }
        default { throw 'qa_unexpected_consent_mock_command' }
    }
}
$script:consentMode='observe-vpn'
$observedNetwork=Read-AndroidLifecycleVpnNetworks -Step synthetic -ExpectedOwnerUid 10042
if ($observedNetwork.vpnCount -ne 1 -or $script:consentCalls.Count -ne 1 -or $script:consentCalls[0].Timeout -ne 10) { throw 'qa_network_read_contract_failed' }; $checks++
$script:consentMode='normal'; $script:consentCalls.Clear(); $receipt=New-ConsentReceipt
$sent=Invoke-AndroidLifecycleVpnConsent -ConnectResult $receipt -Step synthetic
if ($sent.status -cne 'tap_sent' -or $sent.positiveTapCount -ne 1 -or $sent.vpnConnectionConfirmed -or
    @($script:consentCalls | Where-Object { $_.Arguments -contains 'tap' }).Count -ne 1 -or $script:consentCalls.Count -ne 7 -or
    @($script:consentCalls | Where-Object { $_.Timeout -gt 10 }).Count) { throw 'qa_consent_action_contract_failed' }; $checks++
$previousCount=$script:consentCalls.Count
Assert-QaReject { Invoke-AndroidLifecycleVpnConsent -ConnectResult $receipt -Step synthetic }
if ($script:consentCalls.Count -ne $previousCount) { throw 'qa_consent_repeated_device_action' }; $checks++
foreach ($change in @(@('status','accepted_unconfirmed'),@('command','observe'),@('afterPhase','unknown'),
    @('actionAccepted',$false),@('actionAccepted','true'),@('actionAttempted',$false),@('timeoutCleanup','cleanup_refused'),
    @('targetCount',2),@('targetCount','1'),@('targetCount',$true),
    @('runId','00000000-0000-0000-0000-000000000000'))) {
    $badReceipt=New-ConsentReceipt; $badReceipt[$change[0]]=$change[1]; $script:consentCalls.Clear()
    Assert-QaReject { Invoke-AndroidLifecycleVpnConsent -ConnectResult $badReceipt -Step synthetic }
    if ($script:consentCalls.Count) { throw 'qa_invalid_consent_receipt_touched_device' }; $checks++
}
foreach ($mode in @('service-before','incomplete-service','active-vpn','incomplete-network','wrong-top','wrong-message','service-immediate','changed-top','tap-deadline')) {
    $script:consentMode=$mode; $script:consentCalls.Clear(); $receipt=New-ConsentReceipt
    Assert-QaReject { Invoke-AndroidLifecycleVpnConsent -ConnectResult $receipt -Step synthetic }
    $tapCount=if ($mode -ceq 'tap-deadline') { 1 } else { 0 }
    if (@($script:consentCalls | Where-Object { $_.Arguments -contains 'tap' }).Count -ne $tapCount) { throw 'qa_consent_guard_tapped_or_retried' }; $checks++
    if ($mode -cin @('service-before','incomplete-service','active-vpn','incomplete-network','wrong-top') -and
        @($script:consentCalls | Where-Object { $_.Arguments -contains 'uiautomator' }).Count) { throw 'qa_active_or_unconfirmed_vpn_ui_dumped' }; $checks++
    $previousCount=$script:consentCalls.Count
    Assert-QaReject { Invoke-AndroidLifecycleVpnConsent -ConnectResult $receipt -Step synthetic }
    if ($script:consentCalls.Count -ne $previousCount) { throw 'qa_consent_unknown_action_retried' }; $checks++
}
[ordered]@{status='PASS'; checks=$checks; adbInvoked=$false; networkChanged=$false} | ConvertTo-Json -Compress
