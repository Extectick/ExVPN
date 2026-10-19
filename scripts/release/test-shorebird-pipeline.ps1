# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Synthetic guard regressions only: no SDK, actual keys, cloud, VPN or builds.
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

foreach ($path in @('apps/exvpn/lib/ui_revision.dart','apps/exvpn/lib/src/home_screen.dart','packages/exvpn_updates/lib/src/controller.dart')) {
    Assert-ShorebirdPatchPaths @($path); Assert-Test $true 'owned_dart'
}
foreach ($path in @('native/core/core.go','apps/exvpn/android/app/build.gradle.kts','apps/exvpn/windows/runner/main.cpp',
    'apps/exvpn/assets/picture.png','apps/exvpn/pubspec.yaml','apps/exvpn/pubspec.lock','apps/exvpn/lib/build_identity.dart',
    'packages/exvpn_updates/pubspec.yaml','scripts/bootstrap/shorebird.lock.json','config/signing/shorebird-beta-public.pem',
    'scripts/release/shorebird-patch.ps1','apps/exvpn/lib/Foo.DART','apps/exvpn/lib/../native.dart','apps/exvpn/lib/foo\\bar.dart')) {
    Assert-Refuses { Assert-ShorebirdPatchPaths @('apps/exvpn/lib/ui_revision.dart',$path) } 'non_dart_guard'
}
Assert-Refuses { Assert-ShorebirdPatchPaths @() } 'empty_patch'
Assert-Refuses { Assert-ShorebirdPatchPaths @('docs/change.md') } 'prose_only'
Assert-ShorebirdPatchPaths @('apps/exvpn/lib/ui_revision.dart','apps/exvpn/test/updates_test.dart','docs/releases/example.md')
Assert-Test $true 'test_prose_with_dart'
Assert-ShorebirdPatchPaths @('apps/exvpn/lib/ui_revision.dart','docs/evidence/release-v0.1.7.json')
Assert-Test $true 'noncompiled_json_proof_with_dart'
Assert-Refuses { Assert-ShorebirdPatchPaths @('apps/exvpn/lib/ui_revision.dart','docs/elsewhere/proof.json') } 'only_scoped_json_evidence'

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

function New-SyntheticAotZip([string]$Path,[string]$Prefix,[byte]$LastByte) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew)
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($abi in @('arm64-v8a','x86_64')) {
            $entry=$zip.CreateEntry("${Prefix}lib/$abi/libapp.so")
            $output=$entry.Open()
            try { $output.Write([byte[]]@(1,2,3,$LastByte),0,4) } finally { $output.Dispose() }
        }
    } finally { $zip.Dispose();$stream.Dispose() }
}
$apk=Join-Path $fixture 'base.apk';$aab=Join-Path $fixture 'base.aab';$wrong=Join-Path $fixture 'wrong.aab'
New-SyntheticAotZip $apk '' 4;New-SyntheticAotZip $aab 'base/' 4;New-SyntheticAotZip $wrong 'base/' 5
$aot=@(Assert-ShorebirdAndroidAotBinding $apk $aab)
Assert-Test ($aot.Count -eq 2 -and $aot[0].sha256 -ceq $aot[1].sha256) 'apk_aab_actual_aot_bytes_bound'
Assert-Refuses { Assert-ShorebirdAndroidAotBinding $apk $wrong } 'apk_aab_different_aot_refused'

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

# The workflow must retain the new byte-pinned dotfile and preserve ONLY the
# allowlisted recovery directory on failure, never .private build logs.
$workflow=[IO.File]::ReadAllText((Join-Path $root '.github/workflows/shorebird.yml'))
Assert-Test ($workflow -cmatch 'include-hidden-files: true') 'base_artifact_keeps_required_hidden_notice'
Assert-Test ($workflow -cmatch '(?s)name: Preserve sanitized cloud recovery identity even after failure\s+if: always\(\).*?path: artifacts/shorebird-recovery/\*\.json') 'failure_recovery_upload_always_and_allowlisted'
Assert-Test ($workflow -cmatch '(?s)name: Preserve sanitized SDK preparation diagnosis even after failure\s+if: always\(\).*?path: artifacts/shorebird-prepare/\*\.json') 'prepare_diagnosis_upload_always_and_allowlisted'
Assert-Test ($workflow -cmatch '(?s)name: Preserve sanitized source guard diagnosis even after failure\s+if: always\(\).*?path: artifacts/shorebird-source/\*\.json') 'source_diagnosis_upload_always_and_allowlisted'
Assert-Test ($workflow -cmatch 'options: \[base, patch, rollback, diagnose\]' -and $workflow -cmatch 'fromJSON\(inputs.operation == ''diagnose'' && ''\["Windows"\]''') 'diagnose_has_only_windows_matrix_target'
foreach ($step in @('Prepare exact Shorebird CLI and Flutter','Build once and optionally publish signed beta','Upload audited artifacts and sanitized receipts only')) {
    Assert-Test ($workflow -cmatch ('name: '+[regex]::Escape($step)+'\r?\n\s+if: inputs.operation != ''diagnose''')) 'diagnose_skips_sdk_secret_step_and_promotion'
}
Assert-Test ($workflow.IndexOf('name: Require clean source after Checks') -lt $workflow.IndexOf('name: Prepare exact Shorebird CLI and Flutter') -and $workflow.IndexOf('name: Require clean source after SDK before native builds') -lt $workflow.IndexOf('name: Build Android JNI for base only')) 'dirty_source_checked_before_sdk_and_native_builds'

Write-Host "Shorebird pipeline guards: $script:checks checks PASS; no SDK, private signing inputs or cloud operations."
# Expected refusal fixtures leave native exit codes behind. Actions propagates
# LASTEXITCODE after this script; clear it only after every assertion passed.
$global:LASTEXITCODE=0
