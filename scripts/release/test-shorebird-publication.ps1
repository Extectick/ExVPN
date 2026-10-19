# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Synthetic policies only. No SDK/tool bootstrap, cloud, signing or app execution.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'artifact-audit-lib.ps1')
. (Join-Path $PSScriptRoot 'shorebird-pipeline-lib.ps1')
. (Join-Path $PSScriptRoot 'shorebird-publication-lib.ps1')
$script:checks=0
function Assert-Test([bool]$Value,[string]$Name) { $script:checks++;if (!$Value) { throw "shorebird_public_test_failed_$Name" } }
function Assert-Refuses([scriptblock]$Action,[string]$Name) { $refused=$false;try { & $Action | Out-Null } catch {$refused=$true};Assert-Test $refused $Name }
function Copy-Fixture($Value) { $Value | ConvertTo-Json -Depth 15 | ConvertFrom-Json -AsHashtable }
$receipts=@{Android=('a'*64);Windows=('b'*64)};$artifacts=@{Android=('c'*64);Windows=('d'*64)}
$proof=@{schemaVersion=1;version='0.1.7+28';baseSourceCommit=('e'*40);baseReceipts=$receipts;platforms=@(
    @{target='Android';artifactSha256=$artifacts.Android;patchNumber=1;patchId=11;applyVerified=$true;rollbackVerified=$true;appliedCurrentPatch=1;rollbackCurrentPatch=0;dataPreserved=$true;updaterAvailable=$true;baseUiRevision=0;appliedUiRevision=1;rollbackUiRevision=0},
    @{target='Windows';artifactSha256=$artifacts.Windows;patchNumber=2;patchId=12;applyVerified=$true;rollbackVerified=$true;appliedCurrentPatch=2;rollbackCurrentPatch=0;dataPreserved=$true;updaterAvailable=$true;baseUiRevision=0;appliedUiRevision=1;rollbackUiRevision=0})}
$safe=Assert-ShorebirdRuntimeGate $proof '0.1.7+28' ('e'*40) $receipts $artifacts
Assert-Test ($safe.platforms.Count -eq 2 -and $safe.platforms[1].patchNumber -eq 2) 'distinct_patch_numbers_preserved'
foreach ($field in @('applyVerified','rollbackVerified','dataPreserved','updaterAvailable')) {
    $bad=Copy-Fixture $proof;$bad.platforms[0][$field]=$false
    Assert-Refuses { Assert-ShorebirdRuntimeGate $bad '0.1.7+28' ('e'*40) $receipts $artifacts } 'missing_runtime_gate'
}
foreach ($field in @('appliedUiRevision','rollbackUiRevision')) {
    $bad=Copy-Fixture $proof;$bad.platforms[0][$field]=$(if ($field -ceq 'appliedUiRevision') {0} else {1})
    Assert-Refuses { Assert-ShorebirdRuntimeGate $bad '0.1.7+28' ('e'*40) $receipts $artifacts } 'dart_marker_change_and_restore_required'
}
foreach ($field in @('artifactSha256','appliedCurrentPatch','rollbackCurrentPatch','patchId')) {
    $bad=Copy-Fixture $proof;$bad.platforms[1][$field]=$(if ($field -ceq 'artifactSha256') {'f'*64} else {0})
    if ($field -ceq 'rollbackCurrentPatch') { $bad.platforms[1][$field]=2 }
    Assert-Refuses { Assert-ShorebirdRuntimeGate $bad '0.1.7+28' ('e'*40) $receipts $artifacts } 'runtime_identity_or_marker_refused'
}
$bad=Copy-Fixture $proof;$bad.platforms=@($bad.platforms[0])
Assert-Refuses { Assert-ShorebirdRuntimeGate $bad '0.1.7+28' ('e'*40) $receipts $artifacts } 'both_platforms_required'
$bad=Copy-Fixture $proof;$bad.platforms[1]=$bad.platforms[0]
Assert-Refuses { Assert-ShorebirdRuntimeGate $bad '0.1.7+28' ('e'*40) $receipts $artifacts } 'duplicate_target_refused'
$bad=Copy-Fixture $proof;$bad.baseReceipts.Android='f'*64
Assert-Refuses { Assert-ShorebirdRuntimeGate $bad '0.1.7+28' ('e'*40) $receipts $artifacts } 'receipt_hash_refused'
Assert-Refuses { Assert-ShorebirdRuntimeGate $proof '0.1.7+28' ('f'*40) $receipts $artifacts } 'source_sha_refused'
$bad=Copy-Fixture $proof;$bad.privateProfile='PRIVATE-NEVER-EXPORT'
$clean=Assert-ShorebirdRuntimeGate $bad '0.1.7+28' ('e'*40) $receipts $artifacts
Assert-Test (($clean | ConvertTo-Json -Depth 10) -notlike '*PRIVATE-NEVER-EXPORT*') 'unknown_diagnostic_fields_not_exported'

$distinct=@(Get-ShorebirdRollbackGroups 1 2);$shared=@(Get-ShorebirdRollbackGroups 3 3)
Assert-Test ($distinct.Count -eq 2 -and $distinct[0].targets[0] -ceq 'Android' -and $distinct[1].targets[0] -ceq 'Windows') 'rollback_both_distinct_numbers'
Assert-Test ($shared.Count -eq 1 -and $shared[0].targets.Count -eq 2) 'shared_patch_number_checked_once'
Assert-Refuses { Get-ShorebirdRollbackGroups 0 2 } 'missing_android_patch_refused'
Assert-Refuses { Get-ShorebirdRollbackGroups 1 0 } 'missing_windows_patch_refused'

$config="app_id: $((Get-ShorebirdPolicy).appId)`nauto_update: false`npatch_verification: strict`npatch_public_key: 'QUJD'`n"
Assert-ShorebirdCompiledPolicy $config QUJD;Assert-Test $true 'compiled_signed_policy'
foreach ($bad in @($config.Replace('false','true'),$config.Replace('strict','install_only'),$config.Replace('QUJD','AAAA'),($config+"app_id: duplicate`n"),$config.Replace("'QUJD'","'QUJD"),($config+"base_url: https://example.invalid`n"))) {
    Assert-Refuses { Assert-ShorebirdCompiledPolicy $bad QUJD } 'compiled_policy_refuses_drift'
}
$build=@{schema=1;version='0.1.7+28';sourceCommit=('e'*40);runtime='shorebird';dartOtaAvailable=$true;stableReady=$false;syntheticProfiles=$false;artifact=@{file='base.apk';sha256=('c'*64);bytes=12};baseReceiptSha256=('a'*64);runtimeQaSha256=('b'*64)}
Assert-ShorebirdPublicBuild $build '0.1.7+28' ('e'*40) base.apk ('c'*64) 12;Assert-Test $true 'shorebird_feed_identity'
foreach ($change in @(@('runtime','ordinary'),@('dartOtaAvailable',$false),@('stableReady',$true),@('version','0.1.6+27'))) {
    $bad=Copy-Fixture $build;$bad[$change[0]]=$change[1]
    Assert-Refuses { Assert-ShorebirdPublicBuild $bad '0.1.7+28' ('e'*40) base.apk ('c'*64) 12 } 'feed_selector_no_ordinary_bypass'
}
$map=New-AuditFileMap -CaseSensitive
$map.Add('inventory.json',@{path='inventory.json';sha256=('a'*64);size=2})
$noticeList=@([ordered]@{path='inventory.json';sha256=('a'*64);size=2})
$audit=@{noticeEvidence=@{fileCount=1;inventorySha256=('a'*64);fileSetSha256=(Get-AuditTextHash ($noticeList | ConvertTo-Json -Depth 5 -Compress))}}
Assert-ShorebirdNoticeMap $map $audit;Assert-Test $true 'actual_notice_set_matches_saved_audit'
$map['inventory.json'].sha256='b'*64
Assert-Refuses { Assert-ShorebirdNoticeMap $map $audit } 'notice_bytes_changed_refused'
Write-Host "Shorebird public promotion: $script:checks checks PASS; no SDK or cloud operations."
