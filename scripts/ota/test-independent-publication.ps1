# SPDX-License-Identifier: Apache-2.0
#Requires -Version 7.2
# Synthetic read-only policy tests; no builds, network or real signing keys.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repository=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repository 'scripts/release/artifact-audit-lib.ps1')
. (Join-Path $repository 'scripts/release/shorebird-pipeline-lib.ps1')
. (Join-Path $repository 'scripts/release/shorebird-publication-lib.ps1')
$script:checks=0
function Check([bool]$Value,[string]$Name) { if (!$Value) { throw ('independent_publication_fixture_failed_' + $Name) };$script:checks++ }
function Reject([scriptblock]$Action,[string]$Name) { try { & $Action | Out-Null } catch { Check $true $Name; return };throw ('independent_publication_fixture_did_not_reject_' + $Name) }
function Copy-Fixture($Value) { $Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable }
$policy=Get-ShorebirdPolicy
$version='0.1.10+31';$baseCommit='e'*40
$config="app_id: $($policy.appId)`nauto_update: false`npatch_verification: strict`npatch_public_key: QUJD`nbase_url: http://127.0.0.1:57791`n"
Assert-IndependentCompiledPolicy $config QUJD
Check $true 'independent_exact_loopback_policy'
Reject { Assert-ShorebirdCompiledPolicy $config QUJD } 'legacy_does_not_accept_loopback_endpoint'
foreach ($bad in @($config.Replace('57791','57792'),$config.Replace('127.0.0.1','0.0.0.0'),$config.Replace('http://','https://'),$config.Replace('false','true'),$config.Replace('strict','install_only'),$config.Replace('QUJD','AAAA'),($config+"base_url: http://127.0.0.1:57791`n"))) {
    Reject { Assert-IndependentCompiledPolicy $bad QUJD } 'independent_config_drift_rejected'
}
$base=@{
    schemaVersion=2;action='base';delivery='independent';published=$false;releaseId=$null;version=$version;target='Windows';track='beta';appId=$policy.appId
    auditAccepted=$true;sourceCommit=$baseCommit;compiledSourceCommit=$baseCommit;recoveryProof=$null;publicKeySha256=('a'*64);autoUpdate=$false;patchVerification='strict'
    runtime=@{identity=@{kind='shorebird';target='Windows';buildMode='release';flutterRevision=$policy.flutterRevision;engineRevision=$policy.engineRevision;cli=@{revision=$policy.cliRevision}}}
    packagedRuntime=@{engineBytesBound=$true};sourceLockUnchanged=$true;updaterPolicyVerified=$true;stableReady=$false
    baseAot=@(@{platform='windows';arch='x86_64';sha256=('f'*64);bytes=4096})
}
Assert-IndependentBaseReceipt $base $version Windows
Check $true 'independent_base_has_no_cloud_registration'
Reject { Assert-ShorebirdBaseReceipt $base $version Windows } 'legacy_does_not_accept_independent_receipt'
foreach ($change in @(@('delivery','shorebird_cloud'),@('published',$true),@('releaseId',42),@('auditAccepted',$false),@('compiledSourceCommit',('a'*40)),@('sourceLockUnchanged',$false),@('updaterPolicyVerified',$false),@('stableReady',$true))) {
    $bad=Copy-Fixture $base;$bad[$change[0]]=$change[1]
    Reject { Assert-IndependentBaseReceipt $bad $version Windows } 'independent_base_drift_rejected'
}
$bad=Copy-Fixture $base;$bad.packagedRuntime.engineBytesBound=$false
Reject { Assert-IndependentBaseReceipt $bad $version Windows } 'native_engine_binding_required'
$bad=Copy-Fixture $base;$bad.runtime.identity.engineRevision='a'*40
Reject { Assert-IndependentBaseReceipt $bad $version Windows } 'pinned_engine_required'
$receiptHashes=@{Android=('a'*64);Windows=('b'*64)}
$artifactHashes=@{Android=('c'*64);Windows=('d'*64)}
$platforms=@()
foreach ($target in @('Android','Windows')) {
    $platforms+=@{target=$target;artifactSha256=$artifactHashes[$target];patchNumber=1;applyVerified=$true;rollbackVerified=$true;appliedCurrentPatch=1;rollbackCurrentPatch=0;dataPreserved=$true;updaterAvailable=$true;baseUiRevision=2;appliedUiRevision=3;rollbackUiRevision=2;applyCatalogRevision=1;rollbackCatalogRevision=2;applyCatalogSha256=('1'*64);rollbackCatalogSha256=('2'*64);patchDiffSha256=('3'*64);patchAotSha256=('4'*64);signedCatalogVerified=$true;signatureVerified=$true}
}
$proof=@{schemaVersion=1;delivery='independent';version=$version;baseSourceCommit=$baseCommit;compiledSourceCommit=$baseCommit;baseReceipts=$receiptHashes;platforms=$platforms;privateDiagnostic='MUST-NOT-EXPORT'}
$safe=Assert-IndependentRuntimeGate $proof $version $baseCommit $receiptHashes $artifactHashes
Check ($safe.platforms.Count -eq 2 -and ($safe | ConvertTo-Json -Depth 12) -notmatch 'MUST-NOT-EXPORT|patchId') 'safe_proof_has_real_catalog_identity_no_fake_cloud_id'
foreach ($field in @('applyVerified','rollbackVerified','dataPreserved','updaterAvailable','signedCatalogVerified','signatureVerified')) {
    $bad=Copy-Fixture $proof;$bad.platforms[0][$field]=$false
    Reject { Assert-IndependentRuntimeGate $bad $version $baseCommit $receiptHashes $artifactHashes } 'both_real_runtime_cycles_required'
}
foreach ($field in @('applyCatalogSha256','rollbackCatalogSha256','patchDiffSha256','patchAotSha256')) {
    $bad=Copy-Fixture $proof;$bad.platforms[1][$field]='not-a-hash'
    Reject { Assert-IndependentRuntimeGate $bad $version $baseCommit $receiptHashes $artifactHashes } 'cryptographic_identity_required'
}
foreach ($change in @(@('applyCatalogRevision',0),@('rollbackCatalogRevision',1),@('appliedCurrentPatch',0),@('rollbackCurrentPatch',1),@('appliedUiRevision',2),@('rollbackUiRevision',3))) {
    $bad=Copy-Fixture $proof;$bad.platforms[0][$change[0]]=$change[1]
    Reject { Assert-IndependentRuntimeGate $bad $version $baseCommit $receiptHashes $artifactHashes } 'catalog_and_sdk_transition_required'
}
$bad=Copy-Fixture $proof;$bad.platforms=@($bad.platforms[0])
Reject { Assert-IndependentRuntimeGate $bad $version $baseCommit $receiptHashes $artifactHashes } 'both_platforms_required'
$bad=Copy-Fixture $proof;$bad.platforms[1]=$bad.platforms[0]
Reject { Assert-IndependentRuntimeGate $bad $version $baseCommit $receiptHashes $artifactHashes } 'duplicate_platform_rejected'
$bad=Copy-Fixture $proof;$bad.baseReceipts.Android='9'*64
Reject { Assert-IndependentRuntimeGate $bad $version $baseCommit $receiptHashes $artifactHashes } 'base_receipt_bound'
$bad=Copy-Fixture $proof;$bad.platforms[0].artifactSha256='9'*64
Reject { Assert-IndependentRuntimeGate $bad $version $baseCommit $receiptHashes $artifactHashes } 'actual_package_bound'
$workflow=[IO.File]::ReadAllText((Join-Path $repository '.github/workflows/independent-ota.yml'))
Check ($workflow -notmatch 'secrets\.SHOREBIRD_TOKEN|shorebird\s+(release|patch|login)|PublishCloud') 'workflow_no_cloud_account'
Check ($workflow.Contains('scripts/ota/build-ui-patch.ps1') -and $workflow.Contains('scripts/ota/build-base.ps1') -and $workflow.Contains('scripts/ota/publish-base.ps1')) 'workflow_has_three_explicit_lanes'
Check ($workflow.Contains("if: inputs.operation == 'base' && matrix.target == 'Android'") -and $workflow.Contains("if: inputs.operation == 'base' && matrix.target == 'Windows'")) 'native_builds_only_new_base'
Check ($workflow.Contains('cancel-in-progress: false') -and $workflow.Contains('persist-credentials: false')) 'publication_serialization_and_credential_scope'
foreach ($match in [regex]::Matches($workflow,'(?m)^\s+- uses: ([^\s]+)')) { Check ($match.Groups[1].Value -cmatch '@[a-f0-9]{40}$') 'actions_pinned' }
foreach ($match in [regex]::Matches($workflow,'(?m)^\s+uses: ([^\s]+)')) { Check ($match.Groups[1].Value -cmatch '@[a-f0-9]{40}$') 'actions_pinned' }
foreach ($match in [regex]::Matches($workflow,'(?m)^        run: \|\r?\n((?:          [^\r\n]*\r?\n)+)')) {
    $code=($match.Groups[1].Value -split '\r?\n' | ForEach-Object { if ($_.Length -ge 10) {$_.Substring(10)} else {$_} }) -join "`n"
    $tokens=$null;$errors=$null
    $null=[Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$errors)
    Check (@($errors).Count -eq 0) 'workflow_powershell_syntax'
}
foreach ($path in @('scripts/release/publish-shorebird-preview.ps1','scripts/release/shorebird-publication-lib.ps1','scripts/ota/publish-base.ps1')) {
    $tokens=$null;$errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repository $path),[ref]$tokens,[ref]$errors)
    Check (@($errors).Count -eq 0) 'publisher_syntax'
}
[ordered]@{schemaVersion=1;checks=$script:checks;passed=$true;scope='independent publication and CI contract fixtures; no network, builds, secrets or release writes'} | ConvertTo-Json -Compress
