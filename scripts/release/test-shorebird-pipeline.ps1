# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Synthetic guard regressions only: no SDK, actual keys, cloud, VPN or builds.
param([switch]$AndroidBuildDiagnosticsOnly,[switch]$SdkCacheFallbackOnly,[switch]$LockedPubPreparationOnly,[switch]$PatchTargetOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'shorebird-pipeline-lib.ps1')
. (Join-Path $PSScriptRoot 'shorebird-preview-lib.ps1')
. (Join-Path $PSScriptRoot 'artifact-audit-lib.ps1')
. (Join-Path $PSScriptRoot 'flutter-runtime-inputs.ps1')
$script:checks=0
function Assert-Test([bool]$Condition,[string]$Name) {
    $script:checks++
    if (!$Condition) { throw "shorebird_test_failed_$Name" }
}
function Assert-Refuses([scriptblock]$Action,[string]$Name) {
    $threw=$false
    try { & $Action | Out-Null } catch { $threw=$true }
    Assert-Test $threw $Name
}
function Copy-Fixture($Value) { $Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable }

$cacheWorkflow=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../../.github/workflows/shorebird.yml'))
$targetCache=[regex]::Match($cacheWorkflow,'(?s)      - name: Cache exact Shorebird checkout and SDK \(verified after restore\)(?<step>.*?)      - name: Restore exact Windows SDK for first Android patch cache')
$windowsFallback=[regex]::Match($cacheWorkflow,'(?s)      - name: Restore exact Windows SDK for first Android patch cache(?<step>.*?)      - name: Prepare pinned ordinary tools and Android inputs')
Assert-Test ($targetCache.Success -and $targetCache.Groups['step'].Value.Contains('id: target-sdk') -and $targetCache.Groups['step'].Value.Contains('uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9') -and $targetCache.Groups['step'].Value.Contains('${{ matrix.target }}-${{ hashFiles(''scripts/bootstrap/shorebird.lock.json'') }}')) 'primary_target_cache_keeps_normal_save_and_exact_pin_key'
$fallback=$windowsFallback.Groups['step'].Value
Assert-Test ($windowsFallback.Success -and $fallback.Contains("if: inputs.operation == 'patch' && matrix.target == 'Android' && steps.target-sdk.outputs.cache-hit != 'true'") -and $fallback.Contains('uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9') -and $fallback.Contains('path: .tools/shorebird-1.6.129') -and $fallback.Contains('-Windows-${{ hashFiles(''scripts/bootstrap/shorebird.lock.json'') }}') -and !$fallback.Contains('restore-keys:') -and !$fallback.Contains('cache/save@')) 'android_patch_miss_uses_only_exact_windows_restore_without_save'
Assert-Test ($windowsFallback.Index -gt $targetCache.Index -and $windowsFallback.Index -lt $cacheWorkflow.IndexOf('name: Prepare pinned ordinary tools') -and $cacheWorkflow.Contains('run: ./scripts/release/prepare-shorebird.ps1 -Target $env:EXVPN_TARGET')) 'cache_fallback_precedes_unchanged_pinned_preparation'
if($SdkCacheFallbackOnly) {
    Write-Host "Shorebird SDK cache fallback: $script:checks focused checks PASS; no SDK or builds."
    $global:LASTEXITCODE=0
    return
}

$lockedPubStep=[regex]::Match($cacheWorkflow,'(?s)      - name: Resolve locked app dependencies for patch or recovery from a cold cache\r?\n(?<step>.*?)      - name: Require clean source after SDK before native builds')
$lockedBody=$lockedPubStep.Groups['step'].Value
Assert-Test ($lockedPubStep.Success -and $lockedBody.Contains("if: inputs.operation == 'patch' || inputs.operation == 'recover_base'") -and $cacheWorkflow.IndexOf('name: Prepare exact Shorebird CLI and Flutter') -lt $lockedPubStep.Index -and $lockedPubStep.Index -lt $cacheWorkflow.IndexOf('name: Require clean source after SDK before native builds')) 'patch_and_recovery_locked_resolve_after_sdk_before_clean_gate'
Assert-Test ($lockedBody.Contains('Get-ReleaseFlutterRuntime -Repository $repository -Target $env:EXVPN_TARGET -FlutterRuntime shorebird -FlutterBuildMode release') -and $lockedBody.Contains('$flutter=Join-Path $runtime.SdkRoot ''bin/flutter.bat''') -and $lockedBody.Contains('$env:PUB_CACHE=Join-Path $repository ''.tools/cache/pub''') -and $lockedBody.Contains('& $flutter pub get --enforce-lockfile') -and !$lockedBody.Contains('--offline')) 'cold_patch_resolves_exact_lock_online_using_prepared_sdk_and_main_pub_cache'
$lockedRun=[regex]::Match($lockedBody,'(?s)        run: \|\r?\n(?<run>.*)').Groups['run'].Value
$lockedRun=($lockedRun -split '\r?\n'|ForEach-Object {if($_.StartsWith('          ')){$_.Substring(10)}else{$_}})-join "`n"
$lockedTokens=$null;$lockedErrors=$null
$null=[Management.Automation.Language.Parser]::ParseInput($lockedRun,[ref]$lockedTokens,[ref]$lockedErrors)
$patchWrapper=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'shorebird-patch.ps1'))
Assert-Test (!$lockedErrors.Count -and $lockedRun.Contains('finally { Pop-Location }') -and $patchWrapper.Contains('pub get --offline --enforce-lockfile')) 'locked_prepare_parses_restores_location_and_keeps_wrapper_offline_guard'
if($LockedPubPreparationOnly) {
    Write-Host "Shorebird locked pub preparation: $script:checks focused cache/pub checks PASS; no SDK or builds."
    $global:LASTEXITCODE=0
    return
}

$patchTargetInput=[regex]::Match($cacheWorkflow,'(?s)      patch_target:\r?\n(?<input>.*?)      android_patch_number:').Groups['input'].Value
Assert-Test ($patchTargetInput.Contains('type: choice') -and $patchTargetInput.Contains('options: [Both, Android, Windows]') -and $patchTargetInput.Contains('default: Both')) 'patch_target_explicit_choices_default_both'
$matrixSelector=[regex]::Match($cacheWorkflow,'      matrix:\r?\n        target: (?<selector>[^\r\n]+)').Groups['selector'].Value
Assert-Test ($matrixSelector.Contains('inputs.operation == ''patch'' && inputs.patch_target == ''Android'' && ''["Android"]''') -and $matrixSelector.Contains('inputs.operation == ''patch'' && inputs.patch_target == ''Windows'' && ''["Windows"]''') -and $matrixSelector.Contains('inputs.operation == ''diagnose'' && ''["Windows"]''') -and $matrixSelector.EndsWith('''["Android","Windows"]'') }}')) 'only_patch_can_select_one_platform_base_recovery_and_diagnose_preserved'
Assert-Test ($cacheWorkflow.Contains('EXVPN_PATCH_TARGET: ${{ inputs.patch_target }}') -and $cacheWorkflow.Contains('if ($env:EXVPN_OPERATION -ceq ''patch'' -and $env:EXVPN_PATCH_TARGET -cnotin @(''Both'',''Android'',''Windows'')) { throw ''shorebird_patch_target_invalid'' }')) 'unknown_patch_target_refused_before_preparation_or_cloud'
if($PatchTargetOnly) {
    Write-Host "Shorebird patch platform selection: $script:checks focused cache/pub/target checks PASS; no SDK or builds."
    $global:LASTEXITCODE=0
    return
}

$diagnosticRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$diagnosticFixture=Join-Path $diagnosticRoot ('.private/shorebird-diagnostic-tests/'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($diagnosticFixture)
foreach($target in @('Android','Windows')){
    foreach($ci in @($true,$false)){
        $forward=@(Get-ShorebirdBaseForwardingArguments $target $ci)
        Assert-Test ($forward[0] -ceq '--' -and $forward[1] -ceq $(if($target -ceq 'Android'){'--pub'}else{'--no-pub'})) 'base_forwarded_pub_mode_unchanged'
        Assert-Test (($forward -ccontains '--verbose') -eq ($target -ceq 'Android' -and $ci)) 'only_ci_android_forwards_verbose_after_separator'
    }
}
function New-SyntheticDiagnosticZip([string]$Path,[string[]]$Names,[int]$Attributes=0){
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew)
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
    try{foreach($name in $Names){$entry=$zip.CreateEntry($name);$entry.ExternalAttributes=$Attributes;$out=$entry.Open();try{$out.Write([byte[]]@(7,8,9),0,3)}finally{$out.Dispose()}}}
    finally{$zip.Dispose();$stream.Dispose()}
}
$diagnosticZip=Join-Path $diagnosticFixture 'symbols.aab'
$nativeEntry='base/lib/arm64-v8a/libflutter.so'
$symbolEntry='BUNDLE-METADATA/com.android.tools.build.debugsymbols/arm64-v8a/libflutter.so.sym'
New-SyntheticDiagnosticZip $diagnosticZip @($nativeEntry,$symbolEntry,'base/res/Aa.xml','base/res/aa.xml','base/assets/private-should-not-export.txt')
$inventory=Get-ShorebirdAndroidAabInventory $diagnosticZip
Assert-Test ($inventory.status -ceq 'inspected' -and $inventory.entries.Count -eq 18) 'aab_inventory_fixed_eighteen_paths_accept_android_case_variants'
$actual=@($inventory.entries|Where-Object present)
Assert-Test ($actual.Count -eq 2 -and $actual[0].path -ceq $nativeEntry -and $actual[1].path -ceq $symbolEntry -and $actual[0].size -eq 3 -and $actual[0].sha256 -cmatch '^[a-f0-9]{64}$') 'aab_inventory_hashes_actual_native_and_symbol_bytes'
Assert-Test (!(($inventory|ConvertTo-Json -Depth 6 -Compress).Contains('private-should-not-export'))) 'aab_inventory_never_exports_other_archive_paths'
Assert-Test ((Get-ShorebirdAndroidAabInventory $diagnosticZip ([datetime]::UtcNow.AddDays(1))).status -ceq 'stale') 'aab_inventory_refuses_stale_output'
Assert-Test ((Get-ShorebirdAndroidAabInventory (Join-Path $diagnosticFixture 'missing.aab')).status -ceq 'missing') 'aab_inventory_reports_missing_without_claims'
foreach($names in @(@('duplicate.bin','duplicate.bin'),@('../escape.bin'),@('base/lib/arm64-v8a/libflutter.so','base/lib/arm64-v8a/libflutter.so/child'))){
    $bad=Join-Path $diagnosticFixture ([guid]::NewGuid().ToString('N')+'.aab');New-SyntheticDiagnosticZip $bad $names
    $rejected=Get-ShorebirdAndroidAabInventory $bad
    Assert-Test ($rejected.status -ceq 'invalid_archive' -and $rejected.entries.Count -eq 0 -and $null -eq $rejected.sha256) 'aab_diagnostic_rejects_duplicate_traversal_file_directory_collision'
}
$linkZip=Join-Path $diagnosticFixture 'link.aab';New-SyntheticDiagnosticZip $linkZip @($nativeEntry) (0xa000 -shl 16)
Assert-Test ((Get-ShorebirdAndroidAabInventory $linkZip).status -ceq 'invalid_archive') 'aab_diagnostic_rejects_zip_symlink'
$large=Join-Path $diagnosticFixture 'oversized.aab';$stream=[IO.File]::Open($large,[IO.FileMode]::CreateNew);try{$stream.SetLength(1GB+1)}finally{$stream.Dispose()}
Assert-Test ((Get-ShorebirdAndroidAabInventory $large).status -ceq 'size_limit') 'aab_diagnostic_checks_size_before_zip_parse'
Remove-Item -LiteralPath $large
$sectionText="Section Headers:`n  [ 1] .debug_info PROGBITS 0 0`n  [27] .symtab SYMTAB 0 0`nprivate-should-not-export"
$elf=ConvertFrom-ShorebirdElfSections $sectionText
Assert-Test ($elf.debugInfoPresent -and $elf.symbolTablePresent -and $elf.Count -eq 2) 'elf_diagnostic_only_exports_section_presence'
Assert-Test (!(ConvertFrom-ShorebirdElfSections "Section Headers:`n  [ 1] .text PROGBITS 0 0").debugInfoPresent) 'elf_diagnostic_reports_stripped_engine'
Assert-Refuses {ConvertFrom-ShorebirdElfSections 'tool failed .debug_info'} 'elf_diagnostic_does_not_infer_sections_from_error_text'
$sdk=Join-Path $diagnosticFixture 'sdk';$latest=Join-Path $sdk 'cmdline-tools/latest/bin';$versioned=Join-Path $sdk 'cmdline-tools/19.0/bin'
[void][IO.Directory]::CreateDirectory($latest);[void][IO.Directory]::CreateDirectory($versioned)
[IO.File]::WriteAllText((Join-Path $latest 'apkanalyzer.bat'),'synthetic latest, never executed')
[IO.File]::WriteAllText((Join-Path $versioned 'apkanalyzer.bat'),'synthetic versioned, never executed')
$tools=Get-ShorebirdAndroidToolStatus $sdk
Assert-Test ($tools.analyzerPath -ceq 'cmdline-tools/latest/bin/apkanalyzer.bat' -and $tools.analyzerSha256 -cmatch '^[a-f0-9]{64}$' -and $tools.flutterJavaSelection -ceq 'not_observed') 'tool_status_prefers_latest_without_claiming_flutter_java'
Remove-Item -LiteralPath (Join-Path $latest 'apkanalyzer.bat')
Assert-Test ((Get-ShorebirdAndroidToolStatus $sdk).analyzerPath -ceq 'cmdline-tools/19.0/bin/apkanalyzer.bat') 'tool_status_versioned_fallback_matches_flutter_order'
$diagnosticOutput=Write-ShorebirdAndroidFailureDiagnostic $diagnosticFixture (Join-Path $diagnosticFixture 'missing-flutter') $sdk $diagnosticFixture ([datetime]::MinValue) 9876
$exported=Get-Content -LiteralPath $diagnosticOutput -Raw|ConvertFrom-Json -AsHashtable
Assert-Test ($exported.aab.status -ceq 'missing' -and $exported.engineJars.Count -eq 2 -and $exported.engineJars[0].elfStatus -ceq 'unavailable' -and $exported.rawLogsExported -eq $false) 'missing_failure_inputs_remain_unknown_and_safe_diagnostic_is_retained'
Assert-Test (!([IO.File]::ReadAllText($diagnosticOutput).Contains($diagnosticFixture))) 'public_failure_diagnostic_excludes_absolute_paths'
Assert-Test ($exported.preBuildPathLength -eq 9876 -and $exported.tools.processPathLength -eq $env:PATH.Length) 'diagnostic_records_only_before_and_after_path_lengths'
$diagRelease=Get-Content -LiteralPath (Join-Path $diagnosticRoot 'scripts/release/shorebird-release.ps1') -Raw
Assert-Test ($diagRelease.Contains('Get-ShorebirdBaseForwardingArguments $Target ($env:GITHUB_ACTIONS -ceq ''true'')') -and $diagRelease.Contains('try{$null=Write-ShorebirdAndroidFailureDiagnostic')) 'actual_wrapper_uses_ci_forwarding_and_best_effort_failure_diagnostic'
foreach($wrapper in @('shorebird-release.ps1','shorebird-patch.ps1')){
    $wrapperPath=Join-Path $diagnosticRoot ('scripts/release/'+$wrapper)
    $wrapperText=Get-Content -LiteralPath $wrapperPath -Raw
    $wrapperTokens=$null;$wrapperErrors=$null
    $wrapperAst=[Management.Automation.Language.Parser]::ParseFile($wrapperPath,[ref]$wrapperTokens,[ref]$wrapperErrors)
    $ciGate=@($wrapperAst.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq '$Target -ceq ''Android'' -and $env:GITHUB_ACTIONS -ceq ''true''' -and $node.Clauses[0].Item2.Extent.Text.Contains('Initialize-ShorebirdAndroidToolEnvironment')},$true))
    Assert-Test (!$wrapperErrors.Count -and $ciGate.Count -eq 1 -and $wrapperText.Contains("'shorebird-android-environment.ps1'") -and $wrapperText.Contains("'APPDATA'") -and $wrapperText.IndexOf('Initialize-ShorebirdAndroidToolEnvironment') -lt $wrapperText.IndexOf('pub get --offline')) 'both_wrappers_initialize_same_ci_android_environment_before_pub_and_restore_appdata'
}
if($AndroidBuildDiagnosticsOnly){
    Write-Host "Shorebird Android build diagnostics: $script:checks focused checks PASS; no SDK, keys, cloud or builds."
    $global:LASTEXITCODE=0
    return
}

foreach ($path in @('apps/exvpn/lib/ui_revision.dart','apps/exvpn/lib/src/home_screen.dart','packages/exvpn_updates/lib/src/controller.dart')) {
    Assert-ShorebirdPatchPaths @($path); Assert-Test $true 'owned_dart'
}
foreach ($path in @('native/core/core.go','apps/exvpn/android/app/build.gradle.kts','apps/exvpn/windows/runner/main.cpp',
    'apps/exvpn/assets/picture.png','apps/exvpn/pubspec.yaml','apps/exvpn/pubspec.lock','apps/exvpn/lib/build_identity.dart',
    'packages/exvpn_updates/pubspec.yaml','scripts/bootstrap/shorebird.lock.json','config/signing/shorebird-beta-public.pem',
    'scripts/release/unreviewed-patch-wrapper.ps1','apps/exvpn/lib/Foo.DART','apps/exvpn/lib/../native.dart','apps/exvpn/lib/foo\\bar.dart')) {
    Assert-Refuses { Assert-ShorebirdPatchPaths @('apps/exvpn/lib/ui_revision.dart',$path) } 'non_dart_guard'
}
Assert-Refuses { Assert-ShorebirdPatchPaths @() } 'empty_patch'
Assert-Refuses { Assert-ShorebirdPatchPaths @('docs/change.md') } 'prose_only'
Assert-ShorebirdPatchPaths @('apps/exvpn/lib/ui_revision.dart','apps/exvpn/test/updates_test.dart','docs/releases/example.md')
Assert-Test $true 'test_prose_with_dart'
Assert-ShorebirdPatchPaths @('apps/exvpn/lib/ui_revision.dart','docs/evidence/release-v0.1.7.json')
Assert-Test $true 'noncompiled_json_proof_with_dart'
Assert-Refuses { Assert-ShorebirdPatchPaths @('apps/exvpn/lib/ui_revision.dart','docs/elsewhere/proof.json') } 'only_scoped_json_evidence'
foreach ($path in @('scripts/release/shorebird-rollback.ps1','scripts/release/shorebird-pipeline-lib.ps1','scripts/release/test-shorebird-pipeline.ps1',
    '.github/workflows/shorebird.yml','scripts/release/shorebird-patch.ps1',
    'scripts/release/shorebird-android-environment.ps1','scripts/release/test-shorebird-android-environment.ps1',
    'scripts/release/shorebird-patch-inputs.ps1','scripts/release/test-shorebird-patch-inputs.ps1')) {
    Assert-ShorebirdPatchPaths @('apps/exvpn/lib/ui_revision.dart',$path)
    Assert-Test $true 'noncompiled_rollback_maintenance_with_dart'
    Assert-Refuses { Assert-ShorebirdPatchPaths @($path) } 'maintenance_alone_is_not_patch'
}
foreach ($path in @('scripts/release/shorebird-release.ps1','.github/workflows/shorebird-publish.yml','scripts/release/shorebird-rollback-all.ps1',
    'scripts/release/shorebird-patch-inputs-extra.ps1','scripts/release/SHOREBIRD-PATCH.ps1',
    'scripts/release/flutter-runtime-inputs.ps1','scripts/bootstrap/bootstrap.ps1')) {
    Assert-Refuses { Assert-ShorebirdPatchPaths @('apps/exvpn/lib/ui_revision.dart',$path) } 'unreviewed_tooling_still_refused'
}
$lookup=@(Get-ShorebirdPatchLookupArguments '0.1.8+29' 2)
Assert-Test ($lookup.Count -eq 3) 'lookup_separate_native_arguments'
Assert-Test ($lookup[0] -ceq "--app-id=$((Get-ShorebirdPolicy).appId)" -and $lookup[1] -ceq '--release-version=0.1.8+29' -and $lookup[2] -ceq '--patch-number=2') 'lookup_exact_identity_options'
Assert-Refuses { Get-ShorebirdPatchLookupArguments latest 2 } 'lookup_requires_exact_version'
Assert-Refuses { Get-ShorebirdPatchLookupArguments '0.1.8+29' 0 } 'lookup_requires_positive_patch'

$dry=@(Get-ShorebirdPatchArguments Android '0.1.7+28' 'PUBLIC.pem' 'PRIVATE.pem')
$live=@(Get-ShorebirdPatchArguments Windows '0.1.7+28' 'PUBLIC.pem' 'PRIVATE.pem' -PublishCloud)
Assert-Test ($dry -ccontains '--dry-run') 'default_dry_run'
Assert-Test ($live -cnotcontains '--dry-run') 'explicit_cloud'
Assert-Test ($dry -ccontains '--release-version=0.1.7+28' -and $dry -ccontains '--track=beta') 'exact_base_beta'
Assert-Test ($dry -ccontains '--private-key-path=PRIVATE.pem' -and $dry -ccontains '--public-key-path=PUBLIC.pem') 'signing_required'
Assert-Test (@($dry | Where-Object { $_ -like '--allow-*' }).Count -eq 0) 'diff_bypass_absent'
Assert-Test ([Array]::IndexOf($dry,'--target-platform=android-arm64,android-x64') -gt [Array]::IndexOf($dry,'--')) 'android_abi_forwarded'
Assert-Refuses { Get-ShorebirdPatchArguments Android latest p k } 'latest_refused'

$policy=Get-ShorebirdPolicy
$cloud=@{id=7;app_id=$policy.appId;version='0.1.7+28';flutter_revision=$policy.flutterRevision;platform_statuses=@{android='active';windows='active'}}
Assert-ShorebirdCloudRelease $cloud '0.1.7+28' Android 7
Assert-Test $true 'cloud_base_matches'
foreach ($change in @(@('id',8),@('app_id','other'),@('version','0.1.6+27'),@('flutter_revision',('f'*40)))) {
    $bad=Copy-Fixture $cloud; $bad[$change[0]]=$change[1]
    Assert-Refuses { Assert-ShorebirdCloudRelease $bad '0.1.7+28' Android 7 } 'cloud_base_rejects_drift'
}
$bad=Copy-Fixture $cloud; $bad.platform_statuses.android='draft'
Assert-Refuses { Assert-ShorebirdCloudRelease $bad '0.1.7+28' Android 7 } 'cloud_draft_refused'
$envelope=@{status='success';meta=@{version=$policy.cliVersion;command='release'};data=@{ok=$true}}
Assert-Test (Assert-ShorebirdJson $envelope release).ok 'json_envelope'
foreach ($change in @(@('version','1.6.130'),@('command','patch'))) {
    $bad=Copy-Fixture $envelope;$bad.meta[$change[0]]=$change[1]
    Assert-Refuses { Assert-ShorebirdJson $bad release } 'json_wrong_pin_or_command'
}
$bad=Copy-Fixture $envelope;$bad.status='error'
Assert-Refuses { Assert-ShorebirdJson $bad release } 'json_error_refused'

$base=@{
    schemaVersion=2;action='base';version='0.1.7+28';target='Android';track='beta';appId=$policy.appId
    published=$true;auditAccepted=$true;sourceCommit=('a'*40);releaseId=7;publicKeySha256=('b'*64)
    autoUpdate=$false;patchVerification='strict';packagedRuntime=@{engineBytesBound=$true}
    runtime=@{identity=@{kind='shorebird';target='Android';buildMode='release';flutterRevision=$policy.flutterRevision;engineRevision=$policy.engineRevision;cli=@{revision=$policy.cliRevision}}}
    baseAot=@(@{platform='android';arch='aarch64';sha256=('a'*64);bytes=12},@{platform='android';arch='x86_64';sha256=('b'*64);bytes=15})
}
Assert-ShorebirdBaseReceipt $base '0.1.7+28' Android
Assert-Test $true 'base_receipt'
foreach ($change in @(@('published',$false),@('auditAccepted',$false),@('version','0.1.6+27'),@('target','Windows'),@('track','stable'),@('autoUpdate',$true),@('patchVerification','install_only'))) {
    $bad=Copy-Fixture $base;$bad[$change[0]]=$change[1]
    Assert-Refuses { Assert-ShorebirdBaseReceipt $bad '0.1.7+28' Android } 'base_receipt_guard'
}
$artifacts=@(@{platform='android';arch='aarch64';sha256=('a'*64);bytes=12},@{platform='android';arch='x86_64';sha256=('b'*64);bytes=15})
Assert-ShorebirdPatchArtifacts $artifacts Android;Assert-Test $true 'both_android_abis'
$windowsAot=@(@{platform='windows';arch='x86_64';sha256=('a'*64);bytes=12})
Assert-ShorebirdPatchArtifacts $windowsAot Windows;Assert-Test $true 'single_windows_aot_valid_under_strict_mode'
Assert-Refuses {Assert-ShorebirdPatchArtifacts @() Windows} 'missing_windows_aot_refused'
Assert-Refuses {Assert-ShorebirdPatchArtifacts @($windowsAot[0],$windowsAot[0]) Windows} 'duplicate_windows_aot_refused'
Assert-Refuses { Assert-ShorebirdPatchArtifacts @($artifacts[0]) Android } 'missing_abi'
Assert-Refuses { Assert-ShorebirdPatchArtifacts @($artifacts[0],$artifacts[0]) Android } 'duplicate_abi'
Assert-Refuses { Assert-ShorebirdPatchArtifacts $artifacts Windows } 'wrong_platform'

$audit=@{
    schema=1;target='Android';appVersion='0.1.7+28';expectedAppVersion='0.1.7+28';artifact=@{sha256=('a'*64)}
    flutterRuntime=@{engineBytesBound=$true;identity=@{kind='shorebird';buildMode='release'}}
    noticeEvidence=@{xraySource=@{matched=$true;patch=@{included=$true}}}
    signature=@{verified=$true;trustedSignerMatched=$true;debug=$false};noticeSource='actual-apk-entries'
    findings=@(@{code='dart_flutter_runtime_link_inventory_incomplete'});releaseReady=$false;complete=$false
}
Assert-ShorebirdPreviewAudit $audit Android ('a'*64) '0.1.7+28';Assert-Test $true 'preview_discloses_incomplete_inventory'
foreach ($code in @('notice_text_missing','flutter_runtime_engine_mismatch','android_signer_mismatch')) {
    $bad=Copy-Fixture $audit;$bad.findings=@(@{code=$code})
    Assert-Refuses { Assert-ShorebirdPreviewAudit $bad Android ('a'*64) '0.1.7+28' } 'real_audit_finding_blocked'
}
$bad=Copy-Fixture $audit;$bad.flutterRuntime.identity.kind='ordinary'
Assert-Refuses { Assert-ShorebirdPreviewAudit $bad Android ('a'*64) '0.1.7+28' } 'ordinary_engine_cannot_claim_shorebird'
$bad=Copy-Fixture $audit;$bad.signature.trustedSignerMatched=$false
Assert-Refuses { Assert-ShorebirdPreviewAudit $bad Android ('a'*64) '0.1.7+28' } 'untrusted_apk_signer_refused'

# Exercise actual Git comparisons, not mocked diff names. Keep the small owned
# fixture for diagnosis; no recursive cleanup or mutations of the real repo.
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$reviewedFull=Get-Content -LiteralPath (Join-Path $root 'docs/evidence/shorebird29-accepted-patch-full.json') -Raw|ConvertFrom-Json -AsHashtable
Assert-Test ((Assert-ShorebirdReviewedPatchFull $reviewedFull) -ceq '0d9fdf2236aeeb27085120341526827229e42b45') 'reviewed_full_matches_real_accepted_source_counts_and_fingerprint'
foreach($change in @(@('schemaVersion',2),@('testedSourceCommit',('a'*40)),@('mode','Changed'),@('result','failed'),
    @('appTests',373),@('appTests','374'),@('passedLanes',11),@('passedLanes','12'),@('sourceUnchanged',$false),
    @('sourceUnchanged','true'),@('sourceFingerprintBefore',('b'*64)),@('sourceFingerprintAfter',('b'*64)))) {
    $bad=Copy-Fixture $reviewedFull;$bad[$change[0]]=$change[1]
    Assert-Refuses { Assert-ShorebirdReviewedPatchFull $bad } 'fixed_full_evidence_cannot_be_replaced_or_weakened'
}
$bad=Copy-Fixture $reviewedFull;$bad.sourceFingerprintBefore='b'*64;$bad.sourceFingerprintAfter='b'*64
Assert-Refuses { Assert-ShorebirdReviewedPatchFull $bad } 'equal_but_unreviewed_full_fingerprints_refused'
Assert-Test (@(Get-ShorebirdPatchDartValidationLanes @()).Count -eq 0) 'no_new_dart_inputs_has_no_new_dart_lanes'
Assert-Test ((@(Get-ShorebirdPatchDartValidationLanes @('apps/exvpn/lib/src/home_screen.dart')) -join ',') -ceq 'app') 'future_app_change_runs_app_without_native_lanes'
Assert-Test ((@(Get-ShorebirdPatchDartValidationLanes @('packages/exvpn_domain/lib/src/profile.dart')) -join ',') -ceq 'domain,state,app') 'future_domain_change_runs_pure_dart_dependency_closure'
Assert-Test ((@(Get-ShorebirdPatchDartValidationLanes @('packages/exvpn_client_state/test/state_test.dart','packages/exvpn_updates/lib/src/controller.dart')) -join ',') -ceq 'state,updates,app') 'future_state_and_updates_changes_keep_both_package_lanes_and_app'
foreach($path in @('native/core/config.go','apps/exvpn/assets/icon.png','packages/exvpn_domain/pubspec.yaml',
    'apps/exvpn/lib/../native.dart','docs/change.md','.github/workflows/shorebird.yml')) {
    Assert-Refuses { Get-ShorebirdPatchDartValidationLanes @($path) } 'dart_validation_selector_never_silently_ignores_other_scopes'
}
$planFixture=Join-Path $root ('.private/shorebird-validation-plan-tests/'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $planFixture 'docs/evidence'))
$planEvidence=Join-Path $planFixture 'docs/evidence/shorebird29-accepted-patch-full.json'
$reviewedFull|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $planEvidence -Encoding utf8NoBOM
function Invoke-SyntheticPatchValidationPlan([string[]]$Changes=@(),[bool]$RejectSource=$false,[bool]$RejectAncestor=$false) {
    $script:validationPlanGuardCalls=0;$script:validationPlanGitCalls=[Collections.Generic.List[object]]::new()
    function Assert-ShorebirdPatchSource([string]$Repository,[string]$BaseCommit) {
        $script:validationPlanGuardCalls++
        if($RejectSource){throw 'synthetic_native_source_refused'}
        @{sourceCommit=('c'*40);baseCommit=$BaseCommit}
    }
    function Invoke-ShorebirdGit([string]$Repository,[string[]]$Arguments) {
        $script:validationPlanGitCalls.Add($Arguments)
        if($Arguments[0] -ceq 'merge-base') { if($RejectAncestor){throw 'synthetic_reviewed_commit_not_ancestor'};return '' }
        if($Arguments[0] -ceq 'diff'){return ($Changes -join "`n")}
        throw 'unexpected_synthetic_git_operation'
    }
    Get-ShorebirdPatchValidationPlan $planFixture ('a'*40)
}
$plan=Invoke-SyntheticPatchValidationPlan
Assert-Test ($plan.reusedReviewedFull -and $plan.lanes.Count -eq 0 -and $script:validationPlanGuardCalls -eq 1) 'maintenance_reuses_only_after_source_guard_and_fixed_proof'
$scopes=@('apps/exvpn/lib','apps/exvpn/test','packages/exvpn_domain/lib','packages/exvpn_domain/test',
    'packages/exvpn_client_state/lib','packages/exvpn_client_state/test','packages/exvpn_updates/lib','packages/exvpn_updates/test')
$diffArgs=$script:validationPlanGitCalls[1]
Assert-Test ($script:validationPlanGitCalls.Count -eq 2 -and $diffArgs[0] -ceq 'diff' -and $diffArgs[3] -ceq ('0d9fdf2236aeeb27085120341526827229e42b45..'+('c'*40)) -and ($diffArgs[5..12] -join ',') -ceq ($scopes -join ',')) 'reuse_compares_every_app_and_owned_package_lib_test_tree'
$plan=Invoke-SyntheticPatchValidationPlan @('apps/exvpn/test/widget_test.dart')
Assert-Test (!$plan.reusedReviewedFull -and ($plan.lanes -join ',') -ceq 'app') 'new_test_input_cannot_reuse_old_full'
$plan=Invoke-SyntheticPatchValidationPlan @('packages/exvpn_domain/lib/src/profile.dart')
Assert-Test (!$plan.reusedReviewedFull -and ($plan.lanes -join ',') -ceq 'domain,state,app' -and !$plan.nativeLanesSelected) 'new_package_input_requires_dart_consumers_not_native_full'
Assert-Refuses { Invoke-SyntheticPatchValidationPlan @() $true } 'source_guard_failure_blocks_reuse'
Assert-Test ($script:validationPlanGitCalls.Count -eq 0) 'forbidden_source_stops_before_reviewed_tree_comparison'
Assert-Refuses { Invoke-SyntheticPatchValidationPlan @() $false $true } 'unrelated_reviewed_commit_refused'
$bad=Copy-Fixture $reviewedFull;$bad.appTests=0;$bad|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $planEvidence -Encoding utf8NoBOM
Assert-Refuses { Invoke-SyntheticPatchValidationPlan } 'invalid_on_disk_full_proof_cannot_reuse_or_skip_validation'
$fixture=Join-Path $root ('.private/shorebird-pipeline-tests/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $fixture 'apps/exvpn/lib') -Force | Out-Null
$null=Invoke-ShorebirdGit $fixture @('init','--quiet')
$null=Invoke-ShorebirdGit $fixture @('config','user.name','Synthetic QA')
$null=Invoke-ShorebirdGit $fixture @('config','user.email','qa@example.invalid')
[IO.File]::WriteAllText((Join-Path $fixture '.gitignore'),"artifacts/`n")
[IO.File]::WriteAllText((Join-Path $fixture 'apps/exvpn/lib/ui_revision.dart'),'const revision = 0;')
$null=Invoke-ShorebirdGit $fixture @('add','--all');$null=Invoke-ShorebirdGit $fixture @('-c','commit.gpgsign=false','commit','--quiet','-m','synthetic base')
$baseSha=Get-ShorebirdSourceCommit $fixture
[IO.File]::WriteAllText((Join-Path $fixture 'apps/exvpn/lib/ui_revision.dart'),'const revision = 1;')
Assert-Refuses { Assert-ShorebirdPatchSource $fixture $baseSha } 'dirty_source_refused'
$null=Invoke-ShorebirdGit $fixture @('add','--all');$null=Invoke-ShorebirdGit $fixture @('-c','commit.gpgsign=false','commit','--quiet','-m','synthetic Dart patch')
$source=Assert-ShorebirdPatchSource $fixture $baseSha
Assert-Test ($source.baseCommit -ceq $baseSha -and $source.paths.Count -eq 1 -and $source.onlyDartProductionChanges) 'real_git_dart_patch'
$proofDirectory=Join-Path $fixture 'docs/evidence'
New-Item -ItemType Directory -Path $proofDirectory -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $proofDirectory 'release-v0.1.7.json'),'{"sanitized":true}')
$null=Invoke-ShorebirdGit $fixture @('add','--all');$null=Invoke-ShorebirdGit $fixture @('-c','commit.gpgsign=false','commit','--quiet','-m','synthetic noncompiled proof')
$source=Assert-ShorebirdPatchSource $fixture $baseSha
Assert-Test ($source.paths.Count -eq 2 -and $source.onlyDartProductionChanges) 'real_git_json_proof_allowed'
$oversized=Join-Path $proofDirectory 'oversized.json'
[IO.File]::WriteAllText($oversized,(' ' * (1MB+1)))
$null=Invoke-ShorebirdGit $fixture @('add','--all');$null=Invoke-ShorebirdGit $fixture @('-c','commit.gpgsign=false','commit','--quiet','-m','synthetic oversized proof')
Assert-Refuses { Assert-ShorebirdPatchSource $fixture $baseSha } 'oversized_proof_refused'
Remove-Item -LiteralPath $oversized
$null=Invoke-ShorebirdGit $fixture @('add','--all');$null=Invoke-ShorebirdGit $fixture @('-c','commit.gpgsign=false','commit','--quiet','-m','remove synthetic oversized proof')
$null=Invoke-ShorebirdGit $fixture @('update-index','--chmod=+x','apps/exvpn/lib/ui_revision.dart')
$null=Invoke-ShorebirdGit $fixture @('-c','commit.gpgsign=false','commit','--quiet','-m','synthetic executable-mode refusal')
Assert-Refuses { Assert-ShorebirdPatchSource $fixture $baseSha } 'executable_mode_refused'
$null=Invoke-ShorebirdGit $fixture @('update-index','--chmod=-x','apps/exvpn/lib/ui_revision.dart')
$null=Invoke-ShorebirdGit $fixture @('-c','commit.gpgsign=false','commit','--quiet','-m','restore synthetic regular mode')
[IO.File]::WriteAllText((Join-Path $fixture 'apps/exvpn/pubspec.yaml'),'version: 0.1.8+29')
$null=Invoke-ShorebirdGit $fixture @('add','--all');$null=Invoke-ShorebirdGit $fixture @('-c','commit.gpgsign=false','commit','--quiet','-m','synthetic forbidden dependency change')
Assert-Refuses { Assert-ShorebirdPatchSource $fixture $baseSha } 'real_git_dependency_change_refused'

# A real dirty Git fixture must still fail, while a public receipt diagnoses
# tracked/untracked/deleted paths without exporting local/private material.
$sourceFixture=Join-Path $root ('.private/shorebird-source-tests/'+[guid]::NewGuid().ToString('N'))
$sourceFiles=Join-Path $sourceFixture 'apps/exvpn/lib'
New-Item -ItemType Directory -Path $sourceFiles -Force | Out-Null
$null=Invoke-ShorebirdGit $sourceFixture @('init','--quiet')
$null=Invoke-ShorebirdGit $sourceFixture @('config','user.name','Synthetic QA')
$null=Invoke-ShorebirdGit $sourceFixture @('config','user.email','qa@example.invalid')
[IO.File]::WriteAllText((Join-Path $sourceFixture '.gitignore'),"artifacts/`n")
[IO.File]::WriteAllText((Join-Path $sourceFiles 'keep.dart'),'synthetic base')
[IO.File]::WriteAllText((Join-Path $sourceFiles 'deleted.dart'),'synthetic deleted base')
$null=Invoke-ShorebirdGit $sourceFixture @('add','--all')
$null=Invoke-ShorebirdGit $sourceFixture @('-c','commit.gpgsign=false','commit','--quiet','-m','synthetic clean source')
$sourceHead=Get-ShorebirdSourceCommit $sourceFixture
[IO.File]::WriteAllText((Join-Path $sourceFiles 'keep.dart'),'synthetic modified source')
Remove-Item -LiteralPath (Join-Path $sourceFiles 'deleted.dart')
[IO.File]::WriteAllText((Join-Path $sourceFiles 'generated.dart'),'synthetic generated source')
[IO.File]::WriteAllText((Join-Path $sourceFixture 'LOCAL-PRIVATE-INPUT.txt'),'SYNTHETIC-PRIVATE-CONTENTS')
Assert-Refuses { Get-ShorebirdSourceCommit $sourceFixture -Phase after_checks } 'dirty_source_still_fatal_with_receipt'
$sourceReceiptPath=@(Get-ChildItem -LiteralPath (Join-Path $sourceFixture 'artifacts/shorebird-source') -File -Filter '*.json')[0].FullName
$sourceText=[IO.File]::ReadAllText($sourceReceiptPath)
$sourceReceipt=$sourceText | ConvertFrom-Json -AsHashtable
Assert-Test ($sourceReceipt.sourceCommit -ceq $sourceHead -and $sourceReceipt.phase -ceq 'after_checks' -and !$sourceReceipt.clean -and !$sourceReceipt.distributionApproved -and !$sourceReceipt.rawDiagnosticsIncluded) 'dirty_receipt_source_and_checkpoint_bound'
$modified=@($sourceReceipt.entries | Where-Object path -CEQ 'apps/exvpn/lib/keep.dart')
$deleted=@($sourceReceipt.entries | Where-Object path -CEQ 'apps/exvpn/lib/deleted.dart')
$generated=@($sourceReceipt.entries | Where-Object path -CEQ 'apps/exvpn/lib/generated.dart')
Assert-Test ($modified.Count -eq 1 -and $modified[0].status -ceq ' M' -and $modified[0].sha256 -ceq (Get-AuditSha256 (Join-Path $sourceFiles 'keep.dart'))) 'dirty_tracked_file_actual_hash'
Assert-Test ($generated.Count -eq 1 -and $generated[0].status -ceq '??' -and $generated[0].sha256 -ceq (Get-AuditSha256 (Join-Path $sourceFiles 'generated.dart'))) 'dirty_untracked_public_file_actual_hash'
Assert-Test ($deleted.Count -eq 1 -and $deleted[0].hashState -ceq 'missing' -and $null -eq $deleted[0].sha256) 'deleted_source_diagnosed_without_read'
Assert-Test ($sourceReceipt.omittedCount -ge 1 -and !$sourceText.Contains('LOCAL-PRIVATE-INPUT') -and !$sourceText.Contains('SYNTHETIC-PRIVATE-CONTENTS') -and !$sourceText.Contains($sourceFixture) -and !$sourceText.Contains('synthetic modified source')) 'dirty_receipt_does_not_export_private_paths_or_contents'
foreach ($unsafe in @('../apps/exvpn/lib/x.dart','apps/exvpn/lib/../x.dart','.private/profile.json','config/secrets/user.json','apps/exvpn/.dart_tool/package_config.json',"apps/exvpn/lib/line`nbreak.dart",'C:/outside.dart')) {
    Assert-Test (!(Test-ShorebirdPublicSourcePath $unsafe)) 'source_diagnosis_rejects_unsafe_or_private_path'
}
$largePath=Join-Path $sourceFiles 'large.dart'
$largeStream=[IO.File]::Open($largePath,[IO.FileMode]::CreateNew)
try { $largeStream.SetLength(17MB) } finally { $largeStream.Dispose() }
$largeReceipt=Write-ShorebirdSourceReceipt $sourceFixture $sourceHead after_sdk ("?? apps/exvpn/lib/large.dart"+[char]0)
$record=Get-Content -LiteralPath $largeReceipt -Raw | ConvertFrom-Json -AsHashtable
Assert-Test ($record.entries[0].hashState -ceq 'size_budget' -and $null -eq $record.entries[0].sha256) 'dirty_hash_read_is_size_bounded'
$manyStatus=((1..80 | ForEach-Object {"?? apps/exvpn/lib/file$_.dart"+[char]0}) -join '')
$manyReceipt=Write-ShorebirdSourceReceipt $sourceFixture $sourceHead after_sdk $manyStatus
$record=Get-Content -LiteralPath $manyReceipt -Raw | ConvertFrom-Json -AsHashtable
Assert-Test ($record.entries.Count -eq 64 -and $record.omittedCount -eq 16 -and $record.truncated -and (Get-Item -LiteralPath $manyReceipt).Length -lt 32KB) 'dirty_receipt_count_and_output_bounded'
$renameReceipt=Write-ShorebirdSourceReceipt $sourceFixture $sourceHead after_sdk ("R  apps/exvpn/lib/moved.dart"+[char]0+"apps/exvpn/lib/original.dart"+[char]0+"?? apps/exvpn/lib/generated.dart"+[char]0)
$record=Get-Content -LiteralPath $renameReceipt -Raw | ConvertFrom-Json -AsHashtable
Assert-Test ($record.observedCount -eq 2 -and $record.entries.Count -eq 2 -and $record.entries[0].path -ceq 'apps/exvpn/lib/moved.dart') 'nul_rename_origin_not_misparsed_as_status'

$bytesPath=Join-Path $fixture 'base.bin'
[IO.File]::WriteAllBytes($bytesPath,[byte[]]@(1,2,3,4))
$receiptPath=Join-Path $fixture 'base.json'
$files=@{files=@(@{path='base.bin';sha256=(Get-FileHash -LiteralPath $bytesPath).Hash.ToLowerInvariant()})}
Assert-ShorebirdReceiptFiles $receiptPath $files;Assert-Test $true 'base_file_bytes_match'
[IO.File]::WriteAllBytes($bytesPath,[byte[]]@(1,2,3,5))
Assert-Refuses { Assert-ShorebirdReceiptFiles $receiptPath $files } 'base_file_tampering_refused'
$files.files[0].path='../base.bin'
Assert-Refuses { Assert-ShorebirdReceiptFiles $receiptPath $files } 'base_file_traversal_refused'

function New-SyntheticAotZip([string]$Path,[string]$Prefix,[byte]$LastByte,[string[]]$ExtraNames=@()) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew)
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($abi in @('arm64-v8a','x86_64')) {
            $entry=$zip.CreateEntry("${Prefix}lib/$abi/libapp.so")
            $output=$entry.Open()
            try { $output.Write([byte[]]@(1,2,3,$LastByte),0,4) } finally { $output.Dispose() }
        }
        foreach($name in $ExtraNames){[void]$zip.CreateEntry($name)}
    } finally { $zip.Dispose();$stream.Dispose() }
}
$apk=Join-Path $fixture 'base.apk';$aab=Join-Path $fixture 'base.aab';$wrong=Join-Path $fixture 'wrong.aab'
New-SyntheticAotZip $apk '' 4;New-SyntheticAotZip $aab 'base/' 4;New-SyntheticAotZip $wrong 'base/' 5
$aot=@(Assert-ShorebirdAndroidAotBinding $apk $aab)
Assert-Test ($aot.Count -eq 2 -and $aot[0].sha256 -ceq $aot[1].sha256) 'apk_aab_actual_aot_bytes_bound'
Assert-Refuses { Assert-ShorebirdAndroidAotBinding $apk $wrong } 'apk_aab_different_aot_refused'
$caseApk=Join-Path $fixture 'case-res.apk';$caseAab=Join-Path $fixture 'case-res.aab'
New-SyntheticAotZip $caseApk '' 4 @('res/Aa.xml','res/aa.xml')
New-SyntheticAotZip $caseAab 'base/' 4 @('base/res/Aa.xml','base/res/aa.xml')
$caseAot=@(Assert-ShorebirdAndroidAotBinding $caseApk $caseAab)
Assert-Test (($caseAot | ConvertTo-Json -Compress) -ceq ($aot | ConvertTo-Json -Compress)) 'android_case_sensitive_resources_do_not_change_aot_binding'
foreach($badNames in @(@('lib/arm64-v8a/libapp.so'),@('../unsafe'),@('res','res/item'))){
    $badZip=Join-Path $fixture ('bad-aot-'+[guid]::NewGuid().ToString('N')+'.apk')
    New-SyntheticAotZip $badZip '' 4 $badNames
    Assert-Refuses {Get-ShorebirdAndroidAot $badZip -Apk} 'aot_android_zip_still_refuses_duplicate_traversal_and_file_directory_collision'
}

# Reproduce the pinned entrypoint's --system query without running Shorebird.
# The process overlay must preserve real settings, produce strict JSON, and
# restore the caller's environment even when malformed stdout is rejected.
$systemConfig=Join-Path $fixture 'synthetic-system.config'
[IO.File]::WriteAllText($systemConfig,"[core]`n`tlongpaths = false`n[exvpnqa]`n`tretained = yes`n")
$systemHash=Get-AuditSha256 $systemConfig
$oldSystem=$env:GIT_CONFIG_SYSTEM
$oldStorage=$env:FLUTTER_STORAGE_BASE_URL
try {
    $env:GIT_CONFIG_SYSTEM=$systemConfig
    $fake=Join-Path $fixture 'fake-cli.ps1'
    $fakeSource=@'
if ((& git config --system core.longpaths) -cne 'true') { Write-Output 'Git longpaths warning' }
Write-Output '{"status":"success","meta":{"version":"1.6.129","command":"version"},"data":{"ok":true}}'
$global:LASTEXITCODE=0
'@
    [IO.File]::WriteAllText($fake,$fakeSource)
    $json=Invoke-ShorebirdJson $fake @('--version') version $fixture 'strict-json'
    Assert-Test $json.ok 'system_warning_avoided_without_parser_relaxation'
    Assert-Test ($env:GIT_CONFIG_SYSTEM -ceq $systemConfig -and (Get-AuditSha256 $systemConfig) -ceq $systemHash) 'system_config_and_environment_preserved'
    $overlay=New-ShorebirdGitOverlay $fixture
    $env:GIT_CONFIG_SYSTEM=$overlay
    Assert-Test ((& git config --system core.longpaths) -ceq 'true' -and (& git config --includes --get exvpnqa.retained) -ceq 'yes') 'overlay_preserves_system_includes'
    $env:GIT_CONFIG_SYSTEM=$systemConfig
    [IO.File]::WriteAllText($fake,"Write-Output 'unexpected prefix'`n" + $fakeSource)
    Assert-Refuses { Invoke-ShorebirdJson $fake @('--version') version $fixture 'bad-json' } 'json_prefix_still_refused'
    Assert-Test ($env:GIT_CONFIG_SYSTEM -ceq $systemConfig) 'overlay_restored_after_json_failure'
    $coldMarker=Join-Path $fixture 'cold-bootstrap-complete'
    $cold=Join-Path $fixture 'cold-cli.ps1'
    $coldSource=@'
$marker=Join-Path $PSScriptRoot 'cold-bootstrap-complete'
if (!(Test-Path -LiteralPath $marker)) {
    Write-Output 'Rebuilding shorebird...'
    Write-Output 'Compiling shorebird...'
    [IO.File]::WriteAllText($marker,'synthetic cached CLI')
}
Remove-Item Env:\FLUTTER_STORAGE_BASE_URL -ErrorAction SilentlyContinue
Write-Output '{"status":"success","meta":{"version":"1.6.129","command":"version"},"data":{"ok":true}}'
$global:LASTEXITCODE=0
'@
    [IO.File]::WriteAllText($cold,$coldSource)
    $env:FLUTTER_STORAGE_BASE_URL='https://synthetic-storage.invalid'
    $bootstrapOutput=@(Initialize-ShorebirdCliCache $cold $fixture)
    Assert-Test ($bootstrapOutput.Count -eq 0 -and (Test-Path -LiteralPath $coldMarker)) 'cold_bootstrap_has_no_success_stream_output'
    $bootstrapLog=[IO.File]::ReadAllText((Join-Path $fixture 'bootstrap-private.log'))
    Assert-Test ($bootstrapLog.Contains('Rebuilding shorebird...') -and $bootstrapLog.Contains('Compiling shorebird...')) 'cold_chatter_private_only'
    Assert-Test ($env:FLUTTER_STORAGE_BASE_URL -ceq 'https://synthetic-storage.invalid') 'cold_bootstrap_restores_process_storage'
    $warm=Invoke-ShorebirdJson $cold @('--version') version $fixture 'warm-after-bootstrap'
    Assert-Test ($warm.ok -and $env:GIT_CONFIG_SYSTEM -ceq $systemConfig) 'post_bootstrap_json_stays_strict'
} finally { $env:GIT_CONFIG_SYSTEM=$oldSystem;$env:FLUTTER_STORAGE_BASE_URL=$oldStorage }

# Execute the real precache invocation against a tiny synthetic executable,
# never a SDK. Check argv and environment on both target paths, including failure.
$fakeFlutter=Join-Path $fixture 'fake-flutter.ps1'
[IO.File]::WriteAllText($fakeFlutter,@'
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'precache-arguments.json'),(@{argv=@($args);storage=$env:FLUTTER_STORAGE_BASE_URL} | ConvertTo-Json))
$global:LASTEXITCODE=$(if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'fail-precache')) {64} else {0})
'@)
function Invoke-SyntheticPrecache([string]$Target) {
    function Get-ShorebirdPinnedFlutter([string]$Repository) { $fakeFlutter }
    Invoke-ShorebirdFlutterPrecache $fixture $Target $fixture
}
$oldStorage=$env:FLUTTER_STORAGE_BASE_URL
try {
    $env:FLUTTER_STORAGE_BASE_URL='https://caller-storage.invalid'
    foreach ($target in @('Android','Windows')) {
        $output=@(Invoke-SyntheticPrecache $target)
        $arguments=Get-Content -LiteralPath (Join-Path $fixture 'precache-arguments.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-Test ($arguments.argv.Count -eq 2 -and $arguments.argv[0] -ceq 'precache' -and $arguments.argv[1] -ceq ('--'+$target.ToLowerInvariant())) 'precache_calls_flutter_directly_for_target'
        Assert-Test ($arguments.storage -ceq 'https://download.shorebird.dev' -and $env:FLUTTER_STORAGE_BASE_URL -ceq 'https://caller-storage.invalid' -and $output.Count -eq 0) 'precache_pinned_storage_and_silent_result'
    }
    [IO.File]::WriteAllText((Join-Path $fixture 'fail-precache'),'synthetic failure')
    Assert-Refuses { Invoke-SyntheticPrecache Windows } 'precache_nonzero_exit_refused'
    Assert-Test ($env:FLUTTER_STORAGE_BASE_URL -ceq 'https://caller-storage.invalid') 'precache_failure_restores_storage'
    Remove-Item -LiteralPath (Join-Path $fixture 'fail-precache')
} finally { $env:FLUTTER_STORAGE_BASE_URL=$oldStorage }

$syntheticSdk=Join-Path $fixture ".tools/shorebird-$($policy.cliVersion)/bin/cache/flutter/$($policy.flutterRevision)"
New-Item -ItemType Directory -Path (Join-Path $syntheticSdk 'bin/internal') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $syntheticSdk 'bin/flutter.bat'),'synthetic fixture, never executed')
[IO.File]::WriteAllText((Join-Path $syntheticSdk 'bin/internal/engine.version'),$policy.engineRevision)
function Get-SyntheticPinnedFlutter([bool]$RejectCheckout=$false) {
    function Assert-ReleaseRuntimeCheckout([string]$Root,[string]$Revision) {
        if ($RejectCheckout -or $Root -cne $syntheticSdk -or $Revision -cne $policy.flutterRevision) { throw 'flutter_runtime_checkout_mismatch' }
    }
    function Invoke-ReleaseRuntimeGit([string]$Root,[string[]]$Arguments) { $policy.engineRevision }
    Get-ShorebirdPinnedFlutter $fixture
}
Assert-Test ((Get-SyntheticPinnedFlutter) -ceq (Join-Path $syntheticSdk 'bin/flutter.bat')) 'precache_selects_only_exact_pinned_sdk'
Assert-Refuses { Get-SyntheticPinnedFlutter $true } 'precache_checkout_identity_required'
[IO.File]::WriteAllText((Join-Path $syntheticSdk 'bin/internal/engine.version'),('f'*40))
Assert-Refuses { Get-SyntheticPinnedFlutter } 'precache_engine_drift_refused_before_execution'

# Run the actual prepare try/catch/finally with synthetic dependencies. This
# proves a failed substep survives runner loss as a safe receipt, and that
# neither environment restoration nor a failed preparation claims success.
$prepareErrors=$null;$prepareTokens=$null
$prepareAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/release/prepare-shorebird.ps1'),[ref]$prepareTokens,[ref]$prepareErrors)
$prepareTry=@($prepareAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
Assert-Test (!$prepareErrors.Count -and $prepareTry.Count -eq 1) 'actual_prepare_control_flow_found'
$prepareBody=[scriptblock]::Create($prepareTry[0].Extent.Text)
$pinDirectory=Join-Path $fixture 'scripts/bootstrap'
New-Item -ItemType Directory -Path $pinDirectory -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'scripts/bootstrap/shorebird.lock.json') -Destination (Join-Path $pinDirectory 'shorebird.lock.json')
function Invoke-SyntheticPrepare([string]$Failure='') {
    $repository=$fixture;$Target='Windows';$phase='source_identity';$privateRun=$null;$prepareReceipt='';$sourceCommit=''
    $saved=@{}
    foreach ($name in @('PUB_CACHE','FLUTTER_STORAGE_BASE_URL','CI','FLUTTER_SUPPRESS_ANALYTICS','DART_SUPPRESS_ANALYTICS')) { $saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
    function Invoke-ShorebirdGit([string]$Repository,[string[]]$Arguments) { 'a'*40 }
    function New-ShorebirdPrivateDirectory([string]$Repository,[string]$Kind) {
        $directory=Join-Path $fixture ('private-prepare-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $directory | Out-Null
        $directory
    }
    function Assert-ReleaseRuntimeCheckout([string]$Root,[string]$Revision) { }
    function Get-AuditSha256([string]$Path) {
        if ($Path.EndsWith('shorebird.ps1')) { $pin.cli.powershellEntrypointSha256 } else { $pin.cli.pubspecLockSha256 }
    }
    function Initialize-ShorebirdCliCache([string]$Cli,[string]$PrivateDirectory) { }
    function Get-ShorebirdCli([string]$Repository) { 'synthetic CLI, never executed' }
    function Invoke-ShorebirdJson {
        @{shorebird_version=$policy.cliVersion;flutter_revision=$policy.flutterRevision;engine_revision=$policy.engineRevision}
    }
    function Invoke-ShorebirdFlutterPrecache {
        if ($Failure -ceq 'precache') { throw 'shorebird_precache_failed' }
    }
    function Get-ReleaseFlutterRuntime {
        if ($Failure -ceq 'runtime') { throw 'SYNTHETIC-PRIVATE-DIAGNOSTIC https://secret.invalid/private' }
        @{Identity=@{flutterRevision=$policy.flutterRevision}}
    }
    $failureMessage=''
    try { . $prepareBody } catch { $failureMessage=$_.Exception.Message }
    [pscustomobject]@{message=$failureMessage;receipt=$prepareReceipt}
}
$oldStorage=$env:FLUTTER_STORAGE_BASE_URL
try {
    $env:FLUTTER_STORAGE_BASE_URL='https://caller-storage.invalid'
    $failedPrepare=Invoke-SyntheticPrepare precache
    $record=Get-Content -LiteralPath $failedPrepare.receipt -Raw | ConvertFrom-Json -AsHashtable
    Assert-Test ($record.status -ceq 'failed' -and $record.phase -ceq 'flutter_precache' -and $record.errorCode -ceq 'shorebird_precache_failed' -and $failedPrepare.message.Contains('phase=flutter_precache')) 'actual_precache_failure_exports_exact_safe_phase'
    Assert-Test (!$record.cloudRegistrationAttempted -and !$record.nativeBuildStarted -and !$record.distributionApproved -and $env:FLUTTER_STORAGE_BASE_URL -ceq 'https://caller-storage.invalid') 'failed_prepare_keeps_env_and_no_publish_claim'
    $failedPrepare=Invoke-SyntheticPrepare runtime
    $text=[IO.File]::ReadAllText($failedPrepare.receipt)
    $record=$text | ConvertFrom-Json -AsHashtable
    Assert-Test ($record.phase -ceq 'runtime_validation' -and $record.errorCode -ceq 'shorebird_prepare_operation_failed' -and !$text.Contains('SYNTHETIC-PRIVATE') -and !$text.Contains('secret.invalid') -and !$text.Contains($fixture) -and !$failedPrepare.message.Contains('secret.invalid')) 'actual_unknown_error_diagnostics_never_exported'
    $readyPrepare=Invoke-SyntheticPrepare
    $record=Get-Content -LiteralPath $readyPrepare.receipt -Raw | ConvertFrom-Json -AsHashtable
    Assert-Test (!$readyPrepare.message -and $record.status -ceq 'ready' -and $record.phase -ceq 'complete' -and $null -eq $record.errorCode) 'actual_prepare_success_receipt_after_all_gates'
} finally { $env:FLUTTER_STORAGE_BASE_URL=$oldStorage }
Assert-Refuses { Write-ShorebirdPrepareReceipt -Repository $fixture -Target Windows -Status failed -Path (Join-Path $fixture 'outside.json') } 'prepare_receipt_cannot_escape_owned_directory'

$recovery=Write-ShorebirdRecovery -Repository $fixture -Action base -Version '0.1.7+28' -Target Android -SourceCommit ('a'*40) -Status attempting -CloudOutcome unknown -Phase shorebird_release
$record=Get-Content -LiteralPath $recovery -Raw | ConvertFrom-Json -AsHashtable
Assert-Test ($record.cloudOutcome -ceq 'unknown' -and $null -eq $record.releaseId -and $record.requiresCloudReadbackBeforeRetry -and !$record.distributionApproved) 'interrupted_cloud_attempt_not_claimed_unpublished'
$null=Write-ShorebirdRecovery -Repository $fixture -Action base -Version '0.1.7+28' -Target Android -SourceCommit ('a'*40) -Status failed -CloudOutcome registered -ReleaseId 7 -Phase package_audit -Path $recovery
$record=Get-Content -LiteralPath $recovery -Raw | ConvertFrom-Json -AsHashtable
Assert-Test ($record.status -ceq 'failed' -and $record.releaseId -eq 7 -and $record.cloudOutcome -ceq 'registered' -and !$record.distributionApproved) 'post_upload_base_failure_recovery_keeps_id'
$patchRecovery=Write-ShorebirdRecovery -Repository $fixture -Action patch -Version '0.1.7+28' -Target Windows -SourceCommit ('b'*40) -BaseSourceCommit ('a'*40) -Status failed -CloudOutcome registered -ReleaseId 7 -PatchId 22 -PatchNumber 2 -Phase final_inputs
$record=Get-Content -LiteralPath $patchRecovery -Raw | ConvertFrom-Json -AsHashtable
Assert-Test ($record.patchId -eq 22 -and $record.patchNumber -eq 2 -and $record.releaseId -eq 7 -and $record.baseSourceCommit -ceq ('a'*40) -and !$record.distributionApproved) 'post_upload_patch_failure_recovery_keeps_all_ids'
Assert-Refuses { Write-ShorebirdRecovery -Repository $fixture -Action patch -Version '0.1.7+28' -Target Windows -SourceCommit ('b'*40) -Status failed -CloudOutcome registered -ReleaseId 7 } 'registered_patch_without_ids_refused'
$null=Write-ShorebirdRecovery -Repository $fixture -Action base -Version '0.1.7+28' -Target Android -SourceCommit ('a'*40) -Status failed -CloudOutcome unknown -Phase 'PRIVATE-EXCEPTION-NEVER-EXPORT' -Path $recovery
$text=[IO.File]::ReadAllText($recovery)
Assert-Test (!$text.Contains('PRIVATE-EXCEPTION-NEVER-EXPORT') -and !$text.Contains($fixture) -and !$text.Contains('private.log')) 'recovery_exports_fixed_fields_only'
Assert-Refuses { Write-ShorebirdRecovery -Repository $fixture -Action base -Version '0.1.7+28' -Target Android -SourceCommit ('a'*40) -Status failed -CloudOutcome unknown -Path (Join-Path $fixture 'outside.json') } 'recovery_path_escape_refused'

# A single reviewed cloud recovery, never a caller-selected release or URL.
$fixedRecovery=Get-ShorebirdWindowsRecoveryPolicy
Assert-Test ($fixedRecovery.version -ceq '0.1.8+29' -and $fixedRecovery.releaseId -eq 908884 -and $fixedRecovery.artifactId -eq 4043762 -and $fixedRecovery.bytes -eq 30552700 -and $fixedRecovery.files -eq 283) 'recovery_fixed_cloud_identity'
foreach($path in @('apps/exvpn/lib/ui_revision.dart','native/core/core.go','apps/exvpn/assets/a.png','apps/exvpn/pubspec.yaml','apps/exvpn/pubspec.lock','scripts/bootstrap/shorebird.lock.json','config/signing/shorebird-beta-public.pem','scripts/release/unreviewed-patch-wrapper.ps1','docs/elsewhere/proof.json','docs/../apps/exvpn/lib/main.dart')){
    Assert-Refuses {Assert-ShorebirdRecoveryPaths @($path)} 'recovery_rejects_compiled_or_unreviewed_change'
}
Assert-ShorebirdRecoveryPaths @('scripts/release/shorebird-recovery-lib.ps1','.github/workflows/shorebird.yml','docs/SHOREBIRD.md','docs/evidence/recovery.json',
    'scripts/release/flutter-runtime-inputs.ps1','scripts/release/shorebird-patch.ps1',
    'scripts/release/shorebird-android-environment.ps1','scripts/release/test-shorebird-android-environment.ps1')
Assert-Test $true 'recovery_exact_packaging_and_proof_paths'
$attrsBefore=Get-ShorebirdRecoveryBlob $root $fixedRecovery.compiledSourceCommit '.gitattributes'
$crateBefore=Get-ShorebirdRecoveryBlob $root $fixedRecovery.compiledSourceCommit 'scripts/release/shorebird-updater-notices-crates.lock.json'
$crateAfter=[IO.File]::ReadAllText((Join-Path $root 'scripts/release/shorebird-updater-notices-crates.lock.json'))
$recoveryRule='scripts/release/shorebird-updater-notices-crates.lock.json -text -whitespace'
$attrsAfter=$attrsBefore.TrimEnd("`r","`n")+"`n"+$recoveryRule+"`n"
Assert-ShorebirdRecoveryAttributes $attrsBefore $attrsAfter
Assert-ShorebirdRecoveryCratePin $crateBefore $crateAfter
Assert-Test $true 'reviewed_raw_crate_bytes_only_no_semantic_change'
foreach($badAttrs in @($attrsAfter+"scripts/bootstrap/shorebird.lock.json -text`n",$attrsBefore,($attrsAfter+$recoveryRule+"`n"),($attrsAfter.Replace(' -text -whitespace',' -text')))){
    Assert-Refuses {Assert-ShorebirdRecoveryAttributes $attrsBefore $badAttrs} 'recovery_attributes_cannot_change_other_rules'
}
Assert-Refuses {Assert-ShorebirdRecoveryCratePin $crateBefore ($crateAfter+' ')} 'recovery_crate_raw_hash_drift_refused'
$badCrate=$crateAfter | ConvertFrom-Json -AsHashtable;$badCrate['schemaVersion']=999
Assert-Refuses {Assert-ShorebirdRecoveryCratePin $crateBefore ($badCrate | ConvertTo-Json -Depth 20)} 'recovery_crate_changed_value_or_hash_refused'

$noticeInventoryPath='scripts/release/licenses/shorebird-runtime-4b936a0c03e13389ddfb1ac48823f187964975c2/inventory.json'
$noticePinPath='scripts/release/shorebird-runtime-notices.lock.json'
$noticeBefore=Get-ShorebirdRecoveryBlob $root $fixedRecovery.compiledSourceCommit $noticeInventoryPath
$noticePinBefore=Get-ShorebirdRecoveryBlob $root $fixedRecovery.compiledSourceCommit $noticePinPath
$noticeAfter=[IO.File]::ReadAllText((Join-Path $root $noticeInventoryPath))
$noticePinAfter=[IO.File]::ReadAllText((Join-Path $root $noticePinPath))
Assert-ShorebirdRecoveryNoticeMetadata $noticeBefore $noticeAfter $noticePinBefore $noticePinAfter
Assert-Test $true 'recovery_only_own_git_metadata_removed_all_upstream_records_preserved'
foreach($field in @('engineRevision','sourceCratePinSha256')){
    $bad=Copy-Fixture ($noticeAfter | ConvertFrom-Json -AsHashtable);$bad[$field]='changed'
    Assert-Refuses {Assert-ShorebirdRecoveryNoticeMetadata $noticeBefore ($bad | ConvertTo-Json -Depth 60) $noticePinBefore $noticePinAfter} 'recovery_notice_dependency_pins_cannot_change'
}
$bad=Copy-Fixture ($noticeAfter | ConvertFrom-Json -AsHashtable);$bad.files[0].sha256='a'*64
Assert-Refuses {Assert-ShorebirdRecoveryNoticeMetadata $noticeBefore ($bad | ConvertTo-Json -Depth 60) $noticePinBefore $noticePinAfter} 'recovery_upstream_license_bytes_cannot_change'
$bad=Copy-Fixture ($noticeAfter | ConvertFrom-Json -AsHashtable);$bad.files=@($bad.files | Select-Object -Skip 1)
Assert-Refuses {Assert-ShorebirdRecoveryNoticeMetadata $noticeBefore ($bad | ConvertTo-Json -Depth 60) $noticePinBefore $noticePinAfter} 'recovery_upstream_license_cannot_be_removed'
$bad=Copy-Fixture ($noticeAfter | ConvertFrom-Json -AsHashtable);$bad.claims.stableReleaseReady=$true
Assert-Refuses {Assert-ShorebirdRecoveryNoticeMetadata $noticeBefore ($bad | ConvertTo-Json -Depth 60) $noticePinBefore $noticePinAfter} 'recovery_notice_scope_cannot_be_upgraded'
foreach($field in @('inventorySha256','inventorySize','engineRevision')){
    $bad=Copy-Fixture ($noticePinAfter | ConvertFrom-Json -AsHashtable);$bad[$field]=if($field -ceq 'inventorySize'){1}else{'changed'}
    Assert-Refuses {Assert-ShorebirdRecoveryNoticeMetadata $noticeBefore $noticeAfter $noticePinBefore ($bad | ConvertTo-Json -Depth 20)} 'recovery_notice_pin_must_bind_exact_bytes_and_same_sdk'
}

# Execute the actual Git equivalence gate against an owned tiny repository.
# Only the compiled commit is replaced in this test's function scope.
$recoveryRepo=Join-Path $fixture 'recovery-source'
New-Item -ItemType Directory -Path (Join-Path $recoveryRepo 'scripts/release') -Force | Out-Null
$null=Invoke-ShorebirdGit $recoveryRepo @('init','--quiet')
$null=Invoke-ShorebirdGit $recoveryRepo @('config','user.name','Synthetic QA')
$null=Invoke-ShorebirdGit $recoveryRepo @('config','user.email','qa@example.invalid')
$null=Invoke-ShorebirdGit $recoveryRepo @('config','core.autocrlf','false')
[IO.File]::WriteAllText((Join-Path $recoveryRepo '.gitignore'),"artifacts/`n")
[IO.File]::WriteAllText((Join-Path $recoveryRepo '.gitattributes'),$attrsBefore)
[IO.File]::WriteAllText((Join-Path $recoveryRepo 'scripts/release/shorebird-updater-notices-crates.lock.json'),$crateBefore)
$null=Invoke-ShorebirdGit $recoveryRepo @('add','--all');$null=Invoke-ShorebirdGit $recoveryRepo @('-c','commit.gpgsign=false','commit','--quiet','-m','synthetic compiled source')
$recoveryBase=Get-ShorebirdSourceCommit $recoveryRepo
[IO.File]::WriteAllText((Join-Path $recoveryRepo '.gitattributes'),$attrsAfter)
[IO.File]::WriteAllText((Join-Path $recoveryRepo 'scripts/release/shorebird-updater-notices-crates.lock.json'),$crateAfter)
New-Item -ItemType Directory -Path (Join-Path $recoveryRepo 'docs/evidence') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $recoveryRepo 'docs/evidence/recovery.json'),'{"sanitized":true}')
$null=Invoke-ShorebirdGit $recoveryRepo @('add','--all');$null=Invoke-ShorebirdGit $recoveryRepo @('-c','commit.gpgsign=false','commit','--quiet','-m','synthetic byte-preserving packaging fix')
function Invoke-SyntheticRecoverySource {
    function Get-ShorebirdWindowsRecoveryPolicy { $value=Copy-Fixture $fixedRecovery;$value.compiledSourceCommit=$recoveryBase;$value }
    Assert-ShorebirdRecoverySource $recoveryRepo
}
$equivalence=Invoke-SyntheticRecoverySource
Assert-Test ($equivalence.compiledSourceCommit -ceq $recoveryBase -and $equivalence.sourceCommit -cne $recoveryBase -and $equivalence.onlyPackagingChanges -and $equivalence.paths.Count -eq 3) 'real_git_recovery_equivalence_keeps_both_commits'
New-Item -ItemType Directory -Path (Join-Path $recoveryRepo 'native/core') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $recoveryRepo 'native/core/core.go'),'package synthetic')
$null=Invoke-ShorebirdGit $recoveryRepo @('add','--all');$null=Invoke-ShorebirdGit $recoveryRepo @('-c','commit.gpgsign=false','commit','--quiet','-m','synthetic forbidden native change')
Assert-Refuses {Invoke-SyntheticRecoverySource} 'real_git_recovery_native_change_refused'

$recoveryArtifact=@{id=$fixedRecovery.artifactId;release_id=$fixedRecovery.releaseId;platform='windows';arch='win_archive';hash=$fixedRecovery.sha256;size=$fixedRecovery.bytes;url='https://storage.googleapis.com/synthetic/recovery.zip?synthetic-private=never-export'}
Assert-ShorebirdRecoveryArtifact $recoveryArtifact;Assert-Test $true 'recovery_expected_artifact_metadata'
foreach($change in @(@('id',4043763),@('release_id',908885),@('platform','android'),@('arch','x86_64'),@('hash',('f'*64)),@('size',30552701))){
    $bad=Copy-Fixture $recoveryArtifact;$bad[$change[0]]=$change[1]
    Assert-Refuses {Assert-ShorebirdRecoveryArtifact $bad} 'recovery_wrong_cloud_artifact_refused'
}
foreach($uri in @('http://storage.googleapis.com/a','https://other.invalid/a','https://storage.googleapis.com.evil.invalid/a','https://user@storage.googleapis.com/a','https://storage.googleapis.com:444/a','https://storage.googleapis.com/a#fragment','https://storage.googleapis.com/')){
    Assert-Refuses {Assert-ShorebirdRecoveryUri ([uri]$uri)} 'recovery_storage_uri_not_arbitrary'
}
$fakeApi=Join-Path $fixture 'fake-recovery-api.ps1'
$fakeApiSource=@'
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'recovery-api-arguments.json'),(@($args) | ConvertTo-Json))
Write-Output '__BODY__'
$global:LASTEXITCODE=0
'@
$fakeApiSource=$fakeApiSource.Replace('__BODY__',(@{artifacts=@($recoveryArtifact)} | ConvertTo-Json -Depth 5 -Compress))
[IO.File]::WriteAllText($fakeApi,$fakeApiSource)
$oldSystem=$env:GIT_CONFIG_SYSTEM
$selected=Get-ShorebirdRecoveryArtifact $fakeApi $fixture
$apiArguments=Get-Content -LiteralPath (Join-Path $fixture 'recovery-api-arguments.json') -Raw | ConvertFrom-Json
Assert-Test ($selected.id -eq $fixedRecovery.artifactId -and $apiArguments.Count -eq 5 -and $apiArguments[0] -ceq 'api' -and $apiArguments[1] -ceq '--method=GET' -and $apiArguments[2] -ceq "/apps/$($policy.appId)/releases/908884/artifacts" -and $apiArguments[4] -ceq 'platform=windows' -and $apiArguments -cnotcontains '--json') 'recovery_uses_only_fixed_official_get'
Assert-Test ($env:GIT_CONFIG_SYSTEM -ceq $oldSystem) 'recovery_get_restores_git_environment'

function New-SyntheticRecoveryZip([string]$Path,[string[]]$Names,[int]$Attributes=0){
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew)
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
    try {foreach($name in $Names){$entry=$zip.CreateEntry($name);$entry.ExternalAttributes=$Attributes;$output=$entry.Open();try{$output.Write([byte[]]@(1,2,3,4),0,4)}finally{$output.Dispose()}}}
    finally{$zip.Dispose();$stream.Dispose()}
}
$recoveryZip=Join-Path $fixture 'recovery-valid.zip';$recoveryOutput=Join-Path $fixture 'recovery-valid'
New-SyntheticRecoveryZip $recoveryZip @('exvpn.exe','data/app.so')
$recovered=Expand-ShorebirdRecoveryArchive $recoveryZip $recoveryOutput
Assert-Test ($recovered.Count -eq 2 -and $recovered['data/app.so'].sha256 -ceq (Get-AuditSha256 (Join-Path $recoveryOutput 'data/app.so'))) 'recovery_extract_compares_actual_tree_bytes'
Assert-Refuses {Expand-ShorebirdRecoveryArchive $recoveryZip $recoveryOutput} 'recovery_never_reuses_existing_output'
foreach($names in @(@('exvpn.exe','EXVPN.exe'),@('../outside.bin'),@('data','data/app.so'))){
    $zipPath=Join-Path $fixture ([guid]::NewGuid().ToString('N')+'.zip');$destination=$zipPath+'.out'
    New-SyntheticRecoveryZip $zipPath $names
    Assert-Refuses {Expand-ShorebirdRecoveryArchive $zipPath $destination} 'recovery_ambiguous_or_traversal_zip_refused'
    Assert-Test (!(Test-Path -LiteralPath $destination)) 'recovery_rejects_zip_before_any_extraction'
}
foreach($attributes in @([int]0xa0000000,0x400)){
    $zipPath=Join-Path $fixture ([guid]::NewGuid().ToString('N')+'.zip')
    New-SyntheticRecoveryZip $zipPath @('linked.bin') $attributes
    Assert-Refuses {Expand-ShorebirdRecoveryArchive $zipPath ($zipPath+'.out')} 'recovery_link_zip_refused'
}
$proof=@{compiledSourceCommit=$fixedRecovery.compiledSourceCommit;sourceCommit=('c'*40);releaseId=$fixedRecovery.releaseId;artifactId=$fixedRecovery.artifactId;archiveSha256=$fixedRecovery.sha256;archiveBytes=$fixedRecovery.bytes;uiFiles=$fixedRecovery.files;uiTreeSha256=('d'*64);sourceEquivalence=@{compiledSourceCommit=$fixedRecovery.compiledSourceCommit;sourceCommit=('c'*40);onlyPackagingChanges=$true;paths=@('docs/evidence/recovery.json')};uiBuildPerformed=$false;cloudUploadPerformed=$false}
Assert-ShorebirdRecoveryProof $proof ('c'*40);Assert-Test $true 'recovery_proof_explicitly_no_ui_build_or_upload'
foreach($change in @(@('compiledSourceCommit',('a'*40)),@('sourceCommit',('a'*40)),@('releaseId',1),@('artifactId',1),@('archiveSha256',('a'*64)),@('archiveBytes',1),@('uiFiles',1),@('uiBuildPerformed',$true),@('cloudUploadPerformed',$true))){
    $bad=Copy-Fixture $proof;$bad[$change[0]]=$change[1]
    Assert-Refuses {Assert-ShorebirdRecoveryProof $bad ('c'*40)} 'recovery_proof_cannot_claim_different_build'
}
$recoveredBase=Copy-Fixture $base
$recoveredBase.version=$fixedRecovery.version;$recoveredBase.target='Windows';$recoveredBase.releaseId=$fixedRecovery.releaseId;$recoveredBase.sourceCommit='c'*40
$recoveredBase.runtime.identity.target='Windows';$recoveredBase.baseAot=@(@{platform='windows';arch='x86_64';sha256=('a'*64);bytes=12})
$recoveredBase.compiledSourceCommit=$fixedRecovery.compiledSourceCommit;$recoveredBase.recoveryProof=$proof
Assert-ShorebirdBaseReceipt $recoveredBase $fixedRecovery.version Windows;Assert-Test $true 'recovered_base_compatible_with_patch_receipt_consumer'
$bad=Copy-Fixture $recoveredBase;$bad.runtime.identity.engineRevision='f'*40
Assert-Refuses {Assert-ShorebirdBaseReceipt $bad $fixedRecovery.version Windows} 'recovery_does_not_bypass_engine_pin'
$bad=Copy-Fixture $recoveredBase;$bad.recoveryProof=$null
Assert-Refuses {Assert-ShorebirdBaseReceipt $bad $fixedRecovery.version Windows} 'different_compiled_source_needs_proof'
$normal=Copy-Fixture $base;$normal.compiledSourceCommit=$normal.sourceCommit;$normal.recoveryProof=$null
Assert-ShorebirdBaseReceipt $normal '0.1.7+28' Android;Assert-Test $true 'ordinary_base_same_source_still_accepted'
$null=Write-ShorebirdRecovery -Repository $fixture -Action base -Version $fixedRecovery.version -Target Windows -SourceCommit ('c'*40) -Status failed -CloudOutcome registered -ReleaseId 908884 -Phase package_audit -Subphase windows_notice_binding -ErrorCode shorebird_runtime_notices_inventory_invalid -FailureLeaf 'C:\synthetic\shorebird-runtime-notices.ps1' -FailureLine 47 -Path $recovery
$record=Get-Content -LiteralPath $recovery -Raw | ConvertFrom-Json -AsHashtable
Assert-Test ($record.subphase -ceq 'windows_notice_binding' -and $record.errorCode -ceq 'shorebird_runtime_notices_inventory_invalid' -and $record.failureLeaf -ceq 'shorebird-runtime-notices.ps1' -and $record.failureLine -eq 47) 'recovery_failure_has_safe_precise_phase_leaf_line'
$null=Write-ShorebirdRecovery -Repository $fixture -Action base -Version $fixedRecovery.version -Target Windows -SourceCommit ('c'*40) -Status failed -CloudOutcome unknown -Phase 'PRIVATE' -Subphase 'PRIVATE' -ErrorCode 'SECRET https://secret.invalid' -FailureLeaf 'C:\private\secret.ps1' -FailureLine 999999 -Path $recovery
$text=[IO.File]::ReadAllText($recovery);$record=$text | ConvertFrom-Json -AsHashtable
Assert-Test ($record.errorCode -ceq 'shorebird_operation_failed' -and $record.failureLeaf -ceq '' -and $record.failureLine -eq 0 -and !$text.Contains('secret') -and !$text.Contains('PRIVATE')) 'recovery_failure_never_exports_raw_exception'

# Machine-readable CLI failures export seven fixed fields, never diagnostics.
$cliErrorFixture=Join-Path $fixture 'cli-error-code'
New-Item -ItemType Directory -Path $cliErrorFixture -Force | Out-Null
$cliErrorPath=Join-Path $cliErrorFixture 'failure.json'
$cliEnvelope=@{status='error';meta=@{version=$policy.cliVersion;command='release'};error=@{code='process_exit';message='SYNTHETIC-PRIVATE https://secret.invalid/token';hint='SYNTHETIC-PRIVATE';details='SYNTHETIC-PRIVATE';api_code='SYNTHETIC-PRIVATE'};exitCode=999}
foreach($known in @('process_exit','usage_error','software_error','fetch_failed','precondition_failed','interactive_prompt_required')){
    $cliEnvelope.error.code=$known
    [IO.File]::WriteAllText($cliErrorPath,($cliEnvelope | ConvertTo-Json -Depth 6))
    $failure=Get-ShorebirdCliFailure $cliErrorPath release 70
    $text=$failure | ConvertTo-Json -Depth 3
    Assert-Test ($failure.Count -eq 7 -and $failure.errorCode -ceq $known -and $failure.exitCode -eq 70 -and $failure.cliVersion -ceq $policy.cliVersion -and $failure.command -ceq 'release' -and !$text.Contains('SYNTHETIC-PRIVATE') -and !$text.Contains('secret.invalid')) 'cli_failure_only_known_code_and_actual_exit'
}
foreach($change in @(@('version','1.6.130'),@('command','patch'),@('version',@('1.6.129')),@('command',@('release')))){
    $bad=Copy-Fixture $cliEnvelope;$bad.meta[$change[0]]=$change[1]
    [IO.File]::WriteAllText($cliErrorPath,($bad | ConvertTo-Json -Depth 6))
    Assert-Test ((Get-ShorebirdCliFailure $cliErrorPath release 65).errorCode -ceq 'unknown') 'cli_failure_refuses_wrong_or_mistyped_meta'
}
foreach($change in @(@('status','success'),@('status',@('error')),@('code','unknown_future_error'),@('code','PROCESS_EXIT'),@('code',@('process_exit')))){
    $bad=Copy-Fixture $cliEnvelope
    if($change[0] -ceq 'code'){$bad.error.code=$change[1]}else{$bad.status=$change[1]}
    [IO.File]::WriteAllText($cliErrorPath,($bad | ConvertTo-Json -Depth 6))
    Assert-Test ((Get-ShorebirdCliFailure $cliErrorPath release 65).errorCode -ceq 'unknown') 'cli_failure_refuses_nonerror_or_unknown_code'
}
foreach($text in @('prefix {"status":"error"}','not JSON',(' '*(4MB+1)))){
    [IO.File]::WriteAllText($cliErrorPath,$text)
    Assert-Test ((Get-ShorebirdCliFailure $cliErrorPath release 65).errorCode -ceq 'unknown') 'cli_failure_json_remains_strict_and_bounded'
}
Assert-Test ((Get-ShorebirdCliFailure (Join-Path $cliErrorFixture 'missing.json') release 65).errorCode -ceq 'unknown') 'cli_failure_missing_output_safe'
$failure=Get-ShorebirdCliFailure $cliErrorPath 'PRIVATE-UNEXPECTED-COMMAND' -1073741819
Assert-Test ($failure.command -ceq 'other' -and $failure.errorCode -ceq 'unknown' -and $failure.exitCode -eq -1073741819 -and !($failure | ConvertTo-Json).Contains('PRIVATE')) 'cli_failure_preserves_numeric_exit_no_arbitrary_command'
Assert-Refuses {Get-ShorebirdCliFailure $cliErrorPath release 0} 'cli_failure_zero_exit_cannot_claim_failure'

$stderrPath=Join-Path $cliErrorFixture 'failure.log'
foreach($case in @(@('No space left on device','disk_space_marker'),@('java.lang.OutOfMemoryError','jvm_memory_marker'),@('Compilation error. See log for more details','compiler_error_marker'),@('Gradle build daemon disappeared unexpectedly','gradle_daemon_marker'),@('SYNTHETIC-PRIVATE https://secret.invalid','unknown'))){
    [IO.File]::WriteAllText($stderrPath,$case[0])
    $markers=Get-ShorebirdStderrMarkers $stderrPath
    Assert-Test ($markers.stderrMarker -ceq $case[1] -and $markers.stageMarker -ceq 'unknown' -and !($markers | ConvertTo-Json).Contains('PRIVATE')) 'stderr_marker_fixed_enum_only'
}
foreach($case in @(@('Building Android app bundle with Flutter 3.47.7','aab'),@('Building APK','apk'),@('Failed to build AAB.','aab'),@('Failed to build APK.','apk'))){
    [IO.File]::WriteAllText($stderrPath,$case[0])
    Assert-Test ((Get-ShorebirdStderrMarkers $stderrPath).stageMarker -ceq $case[1]) 'stderr_stage_exact_pinned_marker'
}
[IO.File]::WriteAllText($stderrPath,"Building Android app bundle with Flutter`nBuilding APK")
Assert-Test ((Get-ShorebirdStderrMarkers $stderrPath).stageMarker -ceq 'apk') 'stderr_stage_uses_last_observed_stage'
[IO.File]::WriteAllText($stderrPath,('No space left on device Building Android app bundle with Flutter'+('x'*300KB)+"`njava.lang.OutOfMemoryError Building APK"))
$markers=Get-ShorebirdStderrMarkers $stderrPath
Assert-Test ($markers.stderrMarker -ceq 'jvm_memory_marker' -and $markers.stageMarker -ceq 'apk') 'stderr_seeks_bounded_tail_ignoring_old_prefix'
[IO.File]::WriteAllText($stderrPath,('No space left on device Building APK'+('x'*300KB)))
$markers=Get-ShorebirdStderrMarkers $stderrPath
Assert-Test ($markers.stderrMarker -ceq 'unknown' -and $markers.stageMarker -ceq 'unknown') 'stderr_does_not_scan_unbounded_prefix'

# Exercise the real invocation's nonzero path with a tiny fake CLI. The safe
# sidecar uses the existing always-upload directory; private output stays put.
$fakeErrorCli=Join-Path $cliErrorFixture 'fake-error-cli.ps1'
$cliEnvelope.error.code='process_exit'
$fakeErrorSource=@'
Write-Output '__ERROR_JSON__'
$global:LASTEXITCODE=70
'@
[IO.File]::WriteAllText($fakeErrorCli,$fakeErrorSource.Replace('__ERROR_JSON__',($cliEnvelope | ConvertTo-Json -Depth 6 -Compress)))
$sidecarDirectory=Join-Path $fixture 'artifacts/shorebird-recovery'
$before=@(Get-ChildItem -LiteralPath $sidecarDirectory -File -Filter 'cli-error-*.json' -ErrorAction SilentlyContinue)
$oldSystem=$env:GIT_CONFIG_SYSTEM
Assert-Refuses {Invoke-ShorebirdJson $fakeErrorCli @('release','android') release $cliErrorFixture 'actual-error'} 'actual_cli_nonzero_still_refuses_release'
$after=@(Get-ChildItem -LiteralPath $sidecarDirectory -File -Filter 'cli-error-*.json')
Assert-Test ($after.Count -eq $before.Count+1 -and $env:GIT_CONFIG_SYSTEM -ceq $oldSystem) 'actual_cli_error_saved_once_and_env_restored'
$latest=@($after | Where-Object FullName -CNotIn @($before | ForEach-Object FullName))
$text=[IO.File]::ReadAllText($latest[0].FullName);$safe=$text | ConvertFrom-Json -AsHashtable
Assert-Test ($safe.Count -eq 7 -and $safe.errorCode -ceq 'process_exit' -and $safe.exitCode -eq 70 -and $safe.command -ceq 'release' -and $safe.stderrMarker -ceq 'unknown' -and $safe.stageMarker -ceq 'unknown' -and !$text.Contains('SYNTHETIC-PRIVATE') -and !$text.Contains('secret.invalid') -and !$text.Contains($fixture)) 'actual_cli_sidecar_never_exports_private_fields'

# Synthetic recipient only: no production private key enters tests or CI.
function Open-SyntheticDiagnostic($Envelope,$Recipient) {
    $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Recipient.ExportSubjectPublicKeyInfo())).ToLowerInvariant()
    if($Envelope.schemaVersion -ne 1 -or $Envelope.algorithm -cne 'RSA-OAEP-SHA256+A256GCM' -or $Envelope.publicKeySha256 -cne $sha){throw 'synthetic_envelope_identity_rejected'}
    $key=$Recipient.Decrypt([Convert]::FromBase64String($Envelope.wrappedKeyBase64),[Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
    $plain=$null;$aes=$null
    try {
        $cipher=[Convert]::FromBase64String($Envelope.ciphertextBase64);$plain=[byte[]]::new($cipher.Length)
        $aad=[Text.Encoding]::UTF8.GetBytes(('ExVPN/ci-private-diagnostics/v1'+[char]0+$Envelope.algorithm+[char]0+$sha))
        $aes=[Security.Cryptography.AesGcm]::new($key,16)
        $aes.Decrypt([Convert]::FromBase64String($Envelope.nonceBase64),$cipher,[Convert]::FromBase64String($Envelope.tagBase64),$plain,$aad)
        [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json -AsHashtable
    } finally {
        if($aes){$aes.Dispose()};[Security.Cryptography.CryptographicOperations]::ZeroMemory($key)
        if($null -ne $plain){[Security.Cryptography.CryptographicOperations]::ZeroMemory($plain)}
    }
}
$oldDiagnosticKey=$env:EXVPN_CI_DIAGNOSTICS_PUBLIC_KEY_BASE64
$diagnosticRsa=[Security.Cryptography.RSA]::Create(3072);$wrongDiagnosticRsa=[Security.Cryptography.RSA]::Create(3072)
$diagnosticStdout=Join-Path $cliErrorFixture 'encrypted-input.json'
$diagnosticStderr=[IO.Path]::ChangeExtension($diagnosticStdout,'.log')
try {
    $stdoutBytes=[Text.Encoding]::UTF8.GetBytes(('OMITTED-STDOUT-PREFIX'+('s'*90KB)+'SYNTHETIC-PRIVATE-STDOUT https://secret.invalid'))
    $stderrBytes=[Text.Encoding]::UTF8.GetBytes(('OMITTED-STDERR-PREFIX'+('e'*300KB)+'SYNTHETIC-PRIVATE-STDERR https://secret.invalid'))
    [IO.File]::WriteAllBytes($diagnosticStdout,$stdoutBytes);[IO.File]::WriteAllBytes($diagnosticStderr,$stderrBytes)
    $env:EXVPN_CI_DIAGNOSTICS_PUBLIC_KEY_BASE64=[Convert]::ToBase64String($diagnosticRsa.ExportSubjectPublicKeyInfo())
    $encrypted=Write-ShorebirdEncryptedDiagnostic $fixture $diagnosticStdout
    Assert-Test ($encrypted -and [IO.Path]::GetDirectoryName($encrypted) -ceq $sidecarDirectory -and [IO.Path]::GetFileName($encrypted) -cmatch '^cli-private-[a-f0-9]{32}\.json$') 'encrypted_diagnostic_only_owned_recovery_sidecar'
    $text=[IO.File]::ReadAllText($encrypted);$envelope=$text | ConvertFrom-Json -AsHashtable
    Assert-Test ($envelope.Count -eq 7 -and !$text.Contains('SYNTHETIC-PRIVATE') -and !$text.Contains('secret.invalid') -and !$text.Contains($fixture) -and !$text.Contains('stderrTailBase64')) 'encrypted_envelope_never_contains_plaintext_or_paths'
    Assert-Test ([Convert]::FromBase64String($envelope.nonceBase64).Length -eq 12 -and [Convert]::FromBase64String($envelope.tagBase64).Length -eq 16 -and [Convert]::FromBase64String($envelope.wrappedKeyBase64).Length -eq 384) 'encrypted_diagnostic_fixed_crypto_sizes'
    $opened=Open-SyntheticDiagnostic $envelope $diagnosticRsa
    $actualOut=[Convert]::FromBase64String($opened.stdoutTailBase64);$actualErr=[Convert]::FromBase64String($opened.stderrTailBase64)
    $expectedOut=[byte[]]::new(64KB);[Array]::Copy($stdoutBytes,$stdoutBytes.Length-64KB,$expectedOut,0,64KB)
    $expectedErr=[byte[]]::new(256KB);[Array]::Copy($stderrBytes,$stderrBytes.Length-256KB,$expectedErr,0,256KB)
    Assert-Test ($opened.Count -eq 2 -and $actualOut.Length -eq 64KB -and $actualErr.Length -eq 256KB -and [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($actualOut)) -ceq [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($expectedOut)) -and [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($actualErr)) -ceq [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($expectedErr))) 'encrypted_roundtrip_exact_bounded_tail_bytes'
    Assert-Refuses {Open-SyntheticDiagnostic $envelope $wrongDiagnosticRsa} 'encrypted_diagnostic_wrong_recipient_refused'
    foreach($field in @('ciphertextBase64','tagBase64','nonceBase64','wrappedKeyBase64')){
        $bad=Copy-Fixture $envelope;$bytes=[Convert]::FromBase64String($bad[$field]);$bytes[0]=$bytes[0] -bxor 1;$bad[$field]=[Convert]::ToBase64String($bytes)
        Assert-Refuses {Open-SyntheticDiagnostic $bad $diagnosticRsa} 'encrypted_diagnostic_tamper_refused'
    }
    $before=@(Get-ChildItem -LiteralPath $sidecarDirectory -File -Filter 'cli-private-*.json')
    foreach($invalid in @($null,'not-base64',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('not DER')))){
        $env:EXVPN_CI_DIAGNOSTICS_PUBLIC_KEY_BASE64=$invalid
        Assert-Test ($null -eq (Write-ShorebirdEncryptedDiagnostic $fixture $diagnosticStdout) -and @(Get-ChildItem -LiteralPath $sidecarDirectory -File -Filter 'cli-private-*.json').Count -eq $before.Count) 'missing_or_invalid_diagnostic_key_no_plaintext_fallback'
    }
    $env:EXVPN_CI_DIAGNOSTICS_PUBLIC_KEY_BASE64=[Convert]::ToBase64String($diagnosticRsa.ExportSubjectPublicKeyInfo())
    $message=''
    try{Invoke-ShorebirdJson $fakeErrorCli @('release','android') release $cliErrorFixture 'actual-encrypted-error' | Out-Null}catch{$message=$_.Exception.Message}
    Assert-Test ($message -ceq 'shorebird_cli_failed' -and @(Get-ChildItem -LiteralPath $sidecarDirectory -File -Filter 'cli-private-*.json').Count -eq $before.Count+1) 'actual_cli_failure_retains_safe_error_and_encrypted_export'
    function Invoke-SyntheticEncryptionFailure {
        function Read-ShorebirdPrivateTail {throw 'SYNTHETIC-PRIVATE unexpected failure'}
        Write-ShorebirdEncryptedDiagnostic $fixture $diagnosticStdout
    }
    Assert-Test ($null -eq (Invoke-SyntheticEncryptionFailure)) 'unexpected_encryption_failure_never_masks_cli_or_exports_raw'
} finally {
    $env:EXVPN_CI_DIAGNOSTICS_PUBLIC_KEY_BASE64=$oldDiagnosticKey
    $diagnosticRsa.Dispose();$wrongDiagnosticRsa.Dispose()
}

# The workflow must retain the new byte-pinned dotfile and preserve ONLY the
# allowlisted recovery directory on failure, never .private build logs.
$workflow=[IO.File]::ReadAllText((Join-Path $root '.github/workflows/shorebird.yml'))
$coldRecoveryStep=[regex]::Match($workflow,'(?s)      - name: Resolve locked app dependencies for patch or recovery from a cold cache\r?\n(?<step>.*?)      - name: Require clean source after SDK before native builds')
Assert-Test ($coldRecoveryStep.Success -and $coldRecoveryStep.Groups['step'].Value.Contains("if: inputs.operation == 'patch' || inputs.operation == 'recover_base'") -and $coldRecoveryStep.Groups['step'].Value.Contains('Get-ReleaseFlutterRuntime -Repository $repository -Target $env:EXVPN_TARGET -FlutterRuntime shorebird -FlutterBuildMode release') -and $coldRecoveryStep.Groups['step'].Value.Contains('$flutter=Join-Path $runtime.SdkRoot ''bin/flutter.bat''') -and $coldRecoveryStep.Groups['step'].Value.Contains('$env:PUB_CACHE=Join-Path $repository ''.tools/cache/pub''') -and $coldRecoveryStep.Groups['step'].Value.Contains('& $flutter pub get --enforce-lockfile') -and !$coldRecoveryStep.Groups['step'].Value.Contains('--offline') -and $workflow.IndexOf('name: Prepare exact Shorebird CLI and Flutter') -lt $coldRecoveryStep.Index) 'recovery_cold_cache_locked_pub_uses_prepared_sdk_before_clean_gate'
Assert-Test ($workflow -cmatch 'include-hidden-files: true') 'base_artifact_keeps_required_hidden_notice'
Assert-Test ($workflow -cmatch '(?s)name: Preserve sanitized cloud recovery identity even after failure\s+if: always\(\).*?path: artifacts/shorebird-recovery/\*\.json') 'failure_recovery_upload_always_and_allowlisted'
Assert-Test ($workflow -cmatch '(?s)name: Preserve sanitized SDK preparation diagnosis even after failure\s+if: always\(\).*?path: artifacts/shorebird-prepare/\*\.json') 'prepare_diagnosis_upload_always_and_allowlisted'
Assert-Test ($workflow -cmatch '(?s)name: Preserve sanitized source guard diagnosis even after failure\s+if: always\(\).*?path: artifacts/shorebird-source/\*\.json') 'source_diagnosis_upload_always_and_allowlisted'
Assert-Test ($workflow -cmatch 'options: \[base, patch, rollback, diagnose, diagnose_android, recover_base\]' -and $workflow -cmatch 'fromJSON\(inputs.operation == ''diagnose'' && ''\["Windows"\]''') 'diagnose_has_only_windows_matrix_target'
Assert-Test ($workflow -cmatch "inputs.operation != 'rollback' && inputs.operation != 'diagnose_android'") 'android_diagnose_excluded_from_delivery_matrix'
$androidDiagnosis=[regex]::Match($workflow,'(?ms)^  diagnose-android:\r?\n(?<job>.*?)^  rollback:').Groups['job'].Value
Assert-Test ($androidDiagnosis.Contains("inputs.operation == 'diagnose_android'") -and $androidDiagnosis.Contains('runs-on: windows-2025') -and !$androidDiagnosis.Contains('matrix:')) 'android_diagnose_one_windows_host_no_other_platform_job'
Assert-Test ($androidDiagnosis.Contains('actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9') -and $androidDiagnosis.Contains('exvpn-shorebird-sdk-v1-${{ runner.os }}-${{ runner.arch }}-Windows-${{ hashFiles(''scripts/bootstrap/shorebird.lock.json'') }}') -and !$androidDiagnosis.Contains('restore-keys:') -and !$androidDiagnosis.Contains('actions/cache@') -and !$androidDiagnosis.Contains('actions/cache/save@')) 'android_diagnose_exact_existing_windows_cache_restore_only'
foreach($forbidden in @('bootstrap.ps1','prepare-shorebird.ps1','sdkmanager.bat','shorebird-release.ps1','shorebird-patch.ps1','native/android/build.ps1','secrets.SHOREBIRD_TOKEN','secrets.EXVPN_ANDROID','secrets.EXVPN_SHOREBIRD_PRIVATE')) {
    Assert-Test (!$androidDiagnosis.Contains($forbidden)) 'android_diagnose_no_bootstrap_build_cloud_or_signing_secret'
}
Assert-Test ($androidDiagnosis.IndexOf('if(!$safe.sdkCacheHit)') -lt $androidDiagnosis.IndexOf('$null=Get-ShorebirdCli') -and $androidDiagnosis.IndexOf('if(!$safe.sdkCacheHit)') -lt $androidDiagnosis.IndexOf('$runtime=Get-ReleaseFlutterRuntime')) 'android_diagnose_cache_miss_before_any_sdk_execution'
Assert-Test ($androidDiagnosis.Contains('$sdk=Resolve-ReleaseAndroidSdkDirectory $env:ANDROID_HOME') -and $androidDiagnosis.Contains('-AndroidSdkPath $sdk -PrivateDirectory $private')) 'android_diagnose_uses_production_physical_sdk_resolver'
Assert-Test ($androidDiagnosis.Contains('Get-ReleaseFlutterRuntime -Repository $repository -Target Windows -FlutterRuntime shorebird -FlutterBuildMode release') -and $androidDiagnosis.Contains('$env:JAVA_HOME=$env:JAVA_HOME_21_X64')) 'android_diagnose_validates_restored_pins_and_matches_production_jdk'
Assert-Test ($androidDiagnosis.Contains('Write-ShorebirdEncryptedDiagnostic $repository $pair') -and $androidDiagnosis.Contains('artifacts/shorebird-recovery/*.json') -and $androidDiagnosis.Contains('if: always()') -and !$androidDiagnosis.Contains('path: .private') -and !$androidDiagnosis.Contains('*.log')) 'android_diagnose_early_private_pair_encrypted_and_no_raw_export'
Assert-Test ($androidDiagnosis.Contains('[Environment]::SetEnvironmentVariable($name,$saved[$name],''Process'')') -and $androidDiagnosis.Contains('throw ''shorebird_android_diagnose_failed''')) 'android_diagnose_restores_process_context_and_throws_fixed_error'
$diagnosticRun=[regex]::Match($androidDiagnosis,'(?s)        run: \|\r?\n(?<run>.*?)      - name: Preserve safe receipts').Groups['run'].Value
$diagnosticRun=($diagnosticRun -split '\r?\n'|ForEach-Object {if($_.StartsWith('          ')){$_.Substring(10)}else{$_}})-join "`n"
$diagnosticTokens=$null;$diagnosticErrors=$null
$null=[Management.Automation.Language.Parser]::ParseInput($diagnosticRun,[ref]$diagnosticTokens,[ref]$diagnosticErrors)
Assert-Test (!$diagnosticErrors.Count) 'android_diagnose_actual_inline_powershell_parses'
Assert-Test ($workflow.Contains('name: Test exact patch input byte preservation without builds') -and $workflow.Contains('run: ./scripts/release/test-shorebird-patch-inputs.ps1')) 'patch_checks_scoped_input_preservation_guards'
Assert-Test ($workflow.Contains('$plan=Get-ShorebirdPatchValidationPlan (Get-Location).Path $env:EXVPN_BASE_SHA') -and $workflow.Contains('run-fast-validation-lane.ps1 -Lane $lane -OnlineDependencies') -and !$workflow.Contains('run-fast-validation.ps1 -Changed -BaseRef')) 'patch_uses_reviewed_full_or_explicit_dart_lanes_never_native_full_selection'
Assert-Test ($workflow.IndexOf('name: Guard exact patch source before tool preparation') -lt $workflow.IndexOf('name: Prepare pinned ordinary tools')) 'patch_native_asset_pin_guard_before_bootstrap'
foreach ($step in @('Prepare exact Shorebird CLI and Flutter','Build once and optionally publish signed beta','Upload audited artifacts and sanitized receipts only')) {
    Assert-Test ($workflow -cmatch ('name: '+[regex]::Escape($step)+'\r?\n\s+if: inputs.operation != ''diagnose''')) 'diagnose_skips_sdk_secret_step_and_promotion'
}
Assert-Test ($workflow.IndexOf('name: Require clean source after Checks') -lt $workflow.IndexOf('name: Prepare exact Shorebird CLI and Flutter') -and $workflow.IndexOf('name: Require clean source after SDK before native builds') -lt $workflow.IndexOf('name: Build Android JNI for base only')) 'dirty_source_checked_before_sdk_and_native_builds'
Assert-Test ($workflow.IndexOf('name: Prove recovery changes only packaging') -lt $workflow.IndexOf('name: Prepare pinned ordinary tools') -and $workflow -cmatch 'Analyze and test the reviewed Dart source\r?\n\s+if: inputs.operation != ''recover_base''') 'recovery_equivalence_before_tools_and_no_full_retest'
Assert-Test ($workflow -cmatch 'name: shorebird-\$\{\{ inputs.operation == ''recover_base'' && ''base'' \|\| inputs.operation \}\}-\$\{\{ matrix.target \}\}-\$\{\{ github.sha \}\}') 'recovery_artifact_names_match_existing_consumers'
foreach($target in @('Android','Windows')){
    Assert-Test ($workflow.Contains("if: (inputs.operation == 'base' || inputs.operation == 'recover_base') && matrix.target == '$target'")) 'recovery_builds_required_native_packaging_inputs'
}
$releaseTokens=$null;$releaseErrors=$null
$releaseAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/release/shorebird-release.ps1'),[ref]$releaseTokens,[ref]$releaseErrors)
$recoveryBranch=@($releaseAst.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq '$RecoverWindowsBase' -and $node.Clauses[0].Item2.Extent.Text.Contains('Get-ShorebirdRecoveryArtifact')},$true))
Assert-Test (!$releaseErrors.Count -and $recoveryBranch.Count -eq 1) 'actual_recovery_branch_identified'
$recoveryBody=$recoveryBranch[0].Clauses[0].Item2.Extent.Text
Assert-Test ($recoveryBody.Contains('Receive-ShorebirdRecoveryArchive') -and !$recoveryBody.Contains("'release',") -and !$recoveryBody.Contains('flutter build') -and $releaseAst.Extent.Text.Contains('scripts/windows/build-installer.ps1')) 'recovery_downloads_then_common_packaging_no_ui_build_or_upload'

Write-Host "Shorebird pipeline guards: $script:checks checks PASS; no SDK, private signing inputs or cloud operations."
# Expected refusal fixtures leave native exit codes behind. Actions propagates
# LASTEXITCODE after this script; clear it only after every assertion passed.
$global:LASTEXITCODE=0
