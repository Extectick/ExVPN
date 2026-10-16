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
[ordered]@{status='PASS'; checks=$checks; adbInvoked=$false; networkChanged=$false} | ConvertTo-Json -Compress
