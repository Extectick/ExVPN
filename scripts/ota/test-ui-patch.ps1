# SPDX-License-Identifier: Apache-2.0
#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'aot-inputs.ps1')
$script:checks = 0
function Check([bool]$Condition,[string]$Name) {
    if (!$Condition) { throw ('fixture_failed_' + $Name) }
    $script:checks++
}
function Reject([scriptblock]$Action,[string]$Code) {
    try { & $Action | Out-Null } catch {
        Check ($_.Exception.Message -ceq $Code) $Code
        return
    }
    throw ('fixture_did_not_reject_' + $Code)
}
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture = Join-Path $root ('artifacts/qa/ota-aot-fixtures-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
& git -C $fixture init --quiet
if ($LASTEXITCODE -ne 0) { throw 'fixture_git_init_failed' }
function FixtureFile([string]$Relative,[string]$Text) {
    $path = Join-Path $fixture $Relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllText($path,$Text,[Text.UTF8Encoding]::new($false))
}
FixtureFile '.gitattributes' "* text=auto eol=lf`n"
FixtureFile 'apps/exvpn/pubspec.yaml' "name: exvpn`nversion: 0.1.10+31`n"
FixtureFile 'apps/exvpn/pubspec.lock' 'locked synthetic packages'
FixtureFile 'apps/exvpn/lib/build_identity.dart' "const appVersion = '0.1.10';`nconst appBuild = 31;"
FixtureFile 'apps/exvpn/lib/main.dart' 'void main() {}'
FixtureFile 'apps/exvpn/lib/ui_revision.dart' 'const appUiRevision = 1;'
FixtureFile 'apps/exvpn/assets/icon.svg' '<svg/>'
FixtureFile 'apps/exvpn/windows/runner/main.cpp' '// synthetic runner'
FixtureFile 'apps/exvpn/android/app/build.gradle.kts' '// synthetic gradle'
FixtureFile 'packages/domain/lib/profile.dart' 'class Profile {}'
FixtureFile 'packages/domain/pubspec.yaml' 'name: domain'
FixtureFile 'native/core/core.go' 'package core'
FixtureFile 'config/ota/policy.json' '{"synthetic":true}'
FixtureFile 'scripts/bootstrap/shorebird.lock.json' '{"pin":"synthetic"}'
FixtureFile 'docs/ignored.md' 'documentation is not compiled'
& git -C $fixture add -- .
if ($LASTEXITCODE -ne 0) { throw 'fixture_git_add_failed' }
$inputs = @(Get-ExvpnOtaProtectedInputs $fixture)
Check ($inputs.Count -eq 11) 'inventory_count'
Check (@($inputs | Where-Object path -eq '.gitattributes').Count -eq 1) 'checkout_policy_is_protected'
Check (@($inputs | Where-Object path -eq 'apps/exvpn/lib/main.dart').Count -eq 0) 'ui_source_is_patchable'
Check (@($inputs | Where-Object path -eq 'apps/exvpn/lib/build_identity.dart').Count -eq 1) 'base_identity_is_protected'
Check (@($inputs | Where-Object path -eq 'config/ota/policy.json').Count -eq 1) 'trusted_policy_is_protected'
$fingerprint = Get-ExvpnOtaInputsFingerprint $inputs
Check ($fingerprint -cmatch '^[a-f0-9]{64}$') 'fingerprint_shape'
Check ((Get-ExvpnOtaFingerprint @($inputs[($inputs.Count-1)..0])) -ceq $fingerprint) 'fingerprint_order_independent'
Check ((Assert-ExvpnOtaProtectedInputs $fixture $inputs) -ceq $fingerprint) 'original_inputs_accepted'
FixtureFile '.gitattributes' "* text=auto eol=crlf`n"
Reject { Assert-ExvpnOtaProtectedInputs $fixture $inputs } 'ota_native_assets_dependencies_changed'
FixtureFile '.gitattributes' "* text=auto eol=lf`n"
FixtureFile 'apps/exvpn/lib/main.dart' 'void main() { print("new UI"); }'
FixtureFile 'packages/domain/lib/profile.dart' 'class Profile { int value = 1; }'
Check ((Assert-ExvpnOtaProtectedInputs $fixture $inputs) -ceq $fingerprint) 'dart_changes_only_accepted'
FixtureFile 'apps/exvpn/assets/icon.svg' '<svg changed="true"/>'
Reject { Assert-ExvpnOtaProtectedInputs $fixture $inputs } 'ota_native_assets_dependencies_changed'
FixtureFile 'apps/exvpn/assets/icon.svg' '<svg/>'
FixtureFile 'native/core/new.go' 'package core'
Reject { Assert-ExvpnOtaProtectedInputs $fixture $inputs } 'ota_native_assets_dependencies_changed'
Remove-Item -LiteralPath (Join-Path $fixture 'native/core/new.go')
FixtureFile 'apps/exvpn/pubspec.lock' 'changed dependency'
Reject { Assert-ExvpnOtaProtectedInputs $fixture $inputs } 'ota_native_assets_dependencies_changed'
FixtureFile 'apps/exvpn/pubspec.lock' 'locked synthetic packages'
FixtureFile '.gitignore' '*.hiddenasset'
FixtureFile 'apps/exvpn/assets/new.hiddenasset' 'ignored assets must not bypass compatibility'
Reject { Assert-ExvpnOtaProtectedInputs $fixture $inputs } 'ota_native_assets_dependencies_changed'
Remove-Item -LiteralPath (Join-Path $fixture 'apps/exvpn/assets/new.hiddenasset')
Assert-ExvpnOtaVersion $fixture '0.1.10+31'
Check $true 'same_semver_build_accepted'
Reject { Assert-ExvpnOtaVersion $fixture '0.1.11+32' } 'ota_base_version_changed'
Reject { Assert-ExvpnOtaVersion $fixture '0.01.10+31' } 'ota_version_invalid'
Reject { Assert-ExvpnOtaProtectedInputs $fixture @() } 'ota_protected_inputs_empty'
Reject { Get-ExvpnOtaInputsFingerprint @($inputs[0],$inputs[0]) } 'ota_input_record_invalid'
Check (!(Test-ExvpnOtaProtectedPath 'apps/exvpn/.dart_tool/flutter_build/generated.dart')) 'generated_cache_ignored'
Check (!(Test-ExvpnOtaProtectedPath 'apps/exvpn/test/widget_test.dart')) 'test_is_not_runtime'
Check (Test-ExvpnOtaProtectedPath 'packages/domain/lib/native_helper.bin') 'non_dart_lib_asset_protected'
$windows = @(Get-ExvpnOtaAotPlan 'Windows')
$android = @(Get-ExvpnOtaAotPlan 'Android')
Check ($windows.Count -eq 1 -and $windows[0].platform -ceq 'windows-x64') 'windows_architecture'
Check ($android.Count -eq 2 -and $android[0].arch -ceq 'aarch64' -and $android[1].arch -ceq 'x86_64') 'both_android_architectures'
Reject { Get-ExvpnOtaAotPlan 'iOS' } 'ota_target_invalid'
$kernelApp = Join-Path $fixture 'kernel-app'
$kernelOutput = Join-Path $fixture 'kernel-output'
$kernelId = 'f993e5352b3657324b7d9b026cea1365'
$kernelDirectory = Join-Path $kernelApp ('.dart_tool/flutter_build/' + $kernelId)
New-Item -ItemType Directory -Path $kernelDirectory,$kernelOutput -Force | Out-Null
$kernelPath = Join-Path $kernelDirectory 'app.dill'
$stampPath = Join-Path $kernelDirectory 'kernel_snapshot_program.stamp'
$markerPath = Join-Path $kernelOutput '.last_build_id'
$recordedPath = Join-Path $kernelDirectory 'recorded_uses.json'
$kernelBytes = [byte[]]::new(4096)
$kernelBytes[0]=0x90; $kernelBytes[1]=0xab; $kernelBytes[2]=0xcd; $kernelBytes[3]=0xef
$kernelBegin = [DateTime]::UtcNow.AddSeconds(-1)
function ResetKernelFixture {
    [IO.File]::WriteAllText($markerPath,$kernelId,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllBytes($kernelPath,$kernelBytes)
    [IO.File]::WriteAllText($recordedPath,'{}',[Text.UTF8Encoding]::new($false))
    # The pinned SDK repeats app.dill in the depfile outputs; duplicates here
    # are legitimate, while two distinct kernel locations are never accepted.
    $stamp = @{inputs=@((Join-Path $kernelApp 'lib/main.dart'));outputs=@($kernelPath,$recordedPath,$kernelPath)}
    [IO.File]::WriteAllText($stampPath,($stamp | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
}
function ReadKernelFixture { Get-ExvpnOtaKernelOutput $kernelApp $kernelOutput $kernelBegin ([DateTime]::UtcNow) }
ResetKernelFixture
Check ((ReadKernelFixture) -ceq $kernelPath) 'official_intermediate_kernel_selected_without_public_outputs'
[IO.File]::WriteAllText((Join-Path $kernelOutput 'outputs.txt'),'',[Text.UTF8Encoding]::new($false))
Check ((ReadKernelFixture) -ceq $kernelPath) 'empty_public_output_list_does_not_hide_kernel'
[IO.File]::WriteAllText($markerPath,('../' + ('a'*29)),[Text.UTF8Encoding]::new($false))
Reject { ReadKernelFixture } 'ota_kernel_build_id_invalid'
ResetKernelFixture
[IO.File]::WriteAllText($markerPath,$kernelId.ToUpperInvariant(),[Text.UTF8Encoding]::new($false))
Reject { ReadKernelFixture } 'ota_kernel_build_id_invalid'
ResetKernelFixture
[IO.File]::WriteAllText($markerPath,('a'*65),[Text.UTF8Encoding]::new($false))
Reject { ReadKernelFixture } 'ota_kernel_build_file_size_invalid'
ResetKernelFixture
Remove-Item -LiteralPath $markerPath
Reject { ReadKernelFixture } 'ota_kernel_build_file_missing'
ResetKernelFixture
[IO.File]::SetLastWriteTimeUtc($markerPath,[DateTime]::UtcNow.AddHours(-1))
Reject { ReadKernelFixture } 'ota_kernel_build_file_stale'
ResetKernelFixture
[IO.File]::SetLastWriteTimeUtc($stampPath,[DateTime]::UtcNow.AddHours(-1))
Reject { ReadKernelFixture } 'ota_kernel_build_file_stale'
ResetKernelFixture
[IO.File]::SetLastWriteTimeUtc($kernelPath,[DateTime]::UtcNow.AddHours(-1))
Reject { ReadKernelFixture } 'ota_kernel_build_file_stale'
ResetKernelFixture
[IO.File]::SetLastWriteTimeUtc($kernelPath,[DateTime]::UtcNow.AddHours(1))
Reject { ReadKernelFixture } 'ota_kernel_build_file_stale'
ResetKernelFixture
[IO.File]::WriteAllText($stampPath,'not json',[Text.UTF8Encoding]::new($false))
Reject { ReadKernelFixture } 'ota_kernel_stamp_invalid'
ResetKernelFixture
[IO.File]::WriteAllText($stampPath,'{"inputs":[],"outputs":"app.dill"}',[Text.UTF8Encoding]::new($false))
Reject { ReadKernelFixture } 'ota_kernel_stamp_invalid'
ResetKernelFixture
$outsideKernel = Join-Path $fixture 'unrelated-app.dill'
$invalidStamp = @{inputs=@();outputs=@($kernelPath,$outsideKernel)} | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText($stampPath,$invalidStamp,[Text.UTF8Encoding]::new($false))
Reject { ReadKernelFixture } 'ota_kernel_stamp_output_invalid'
ResetKernelFixture
$invalidStamp = @{inputs=@();outputs=@('app.dill')} | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText($stampPath,$invalidStamp,[Text.UTF8Encoding]::new($false))
Reject { ReadKernelFixture } 'ota_kernel_stamp_output_invalid'
ResetKernelFixture
$invalidStamp = @{inputs=@();outputs=@($recordedPath)} | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText($stampPath,$invalidStamp,[Text.UTF8Encoding]::new($false))
Reject { ReadKernelFixture } 'ota_kernel_stamp_output_invalid'
ResetKernelFixture
[IO.File]::WriteAllText($kernelPath,'small',[Text.UTF8Encoding]::new($false))
Reject { ReadKernelFixture } 'ota_kernel_build_file_size_invalid'
ResetKernelFixture
$invalidKernel = [byte[]]::new(4096)
[IO.File]::WriteAllBytes($kernelPath,$invalidKernel)
Reject { ReadKernelFixture } 'ota_kernel_header_invalid'
ResetKernelFixture
$parkedKernelDirectory = $kernelDirectory + '-parked'
Move-Item -LiteralPath $kernelDirectory -Destination $parkedKernelDirectory
try {
    $null = New-Item -ItemType Junction -Path $kernelDirectory -Target $parkedKernelDirectory
    Reject { ReadKernelFixture } 'ota_path_link_rejected'
} finally {
    if ((Get-Item -LiteralPath $kernelDirectory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { Remove-Item -LiteralPath $kernelDirectory }
    Move-Item -LiteralPath $parkedKernelDirectory -Destination $kernelDirectory
}
Reject { Get-ExvpnOtaKernelOutput $kernelApp $kernelOutput ([DateTime]::UtcNow.AddHours(1)) $kernelBegin } 'ota_kernel_build_time_invalid'
$elf = [byte[]]::new(4096)
$elf[0]=0x7f; $elf[1]=0x45; $elf[2]=0x4c; $elf[3]=0x46; $elf[4]=2; $elf[5]=1; $elf[18]=62
$elfPath = Join-Path $fixture 'synthetic-aot.so'
[IO.File]::WriteAllBytes($elfPath,$elf)
Assert-ExvpnOtaElf $elfPath 'x86_64'
Check $true 'elf_x64_accepted'
Reject { Assert-ExvpnOtaElf $elfPath 'aarch64' } 'ota_elf_invalid'
$elf[18]=183
[IO.File]::WriteAllBytes($elfPath,$elf)
Assert-ExvpnOtaElf $elfPath 'aarch64'
Check $true 'elf_arm64_accepted'
$elf[0]=0
[IO.File]::WriteAllBytes($elfPath,$elf)
Reject { Assert-ExvpnOtaElf $elfPath 'aarch64' } 'ota_elf_invalid'
$rsa = [Security.Cryptography.RSA]::Create(4096)
$wrong = [Security.Cryptography.RSA]::Create(4096)
try {
    $hash = Get-ExvpnOtaTextSha256 'synthetic full AOT bytes'
    $signature = New-ExvpnOtaHashSignature $hash $rsa
    $decoded = [Convert]::FromBase64String($signature)
    Check ($decoded.Length -eq 512) 'rsa4096_signature_size'
    Check ($rsa.VerifyData([Text.Encoding]::UTF8.GetBytes($hash),$decoded,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)) 'signature_over_ascii_hex_hash'
    Check (!$wrong.VerifyData([Text.Encoding]::UTF8.GetBytes($hash),$decoded,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)) 'wrong_key_rejected'
    Check (!$rsa.VerifyData([Convert]::FromHexString($hash),$decoded,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)) 'raw_hash_not_interchangeable'
    Reject { New-ExvpnOtaHashSignature $hash.ToUpperInvariant() $rsa } 'ota_signing_input_invalid'
} finally { $rsa.Dispose(); $wrong.Dispose() }
$builderPath = Join-Path $PSScriptRoot 'build-ui-patch.ps1'
$tokens = $null; $parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($builderPath,[ref]$tokens,[ref]$parseErrors)
Check (@($parseErrors).Count -eq 0) 'builder_syntax'
$builder = [IO.File]::ReadAllText($builderPath)
Check ($builder -match "'kernel_snapshot_program'" -and $builder -match "'--snapshot_kind=app-aot-elf'" -and $builder -match "'--strip'") 'aot_only_steps'
Check ($builder -notmatch '(?i)api\.shorebird\.dev|shorebird\s+(release|patch|login)|gradlew|cmake|flutter\s+build\s+(apk|windows)') 'no_cloud_or_native_build'
Check ($builder -match 'merge-base --is-ancestor' -and $builder -match 'sources_changed_during_compile') 'frozen_source_guards'
Check ($builder -match 'ota_signing_key_mismatch' -and $builder -match 'ota_signature_public_check_failed') 'signing_guards'
Check ($builder -match 'ota_flutter_package_sdk_mismatch' -and $builder -match 'ota_development_plugin_in_release') 'runtime_sdk_and_registrant_guards'
Check ($builder.Contains('$diffSize -gt 67108864') -and !$builder.Contains('$diffSize -gt 134217728')) 'diff_limit_matches_catalog_64_mib'
Check ($builder.Contains('Get-ExvpnOtaKernelOutput $app $archOutput $kernelStarted') -and !$builder.Contains('--build-outputs=')) 'kernel_selection_uses_official_build_marker'
$releasePath = Join-Path $root 'scripts/release/shorebird-release.ps1'
$releaseErrors=$null; $releaseTokens=$null
$releaseAst=[Management.Automation.Language.Parser]::ParseFile($releasePath,[ref]$releaseTokens,[ref]$releaseErrors)
Check (@($releaseErrors).Count -eq 0) 'release_wrapper_syntax'
$environmentAssignment=@($releaseAst.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -ceq 'environmentNames'},$true))
Check ($environmentAssignment.Count -eq 1 -and @($environmentAssignment[0].Right.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -ceq 'SHOREBIRD_PUBLIC_KEY'},$true)).Count -eq 1) 'public_compile_key_environment_captured'
$publicKeyAssignment=@($releaseAst.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -ceq 'env:SHOREBIRD_PUBLIC_KEY'},$true))
Check ($publicKeyAssignment.Count -eq 1 -and $publicKeyAssignment[0].Right.Extent.Text -ceq '$compiledPublicKey' -and $builder -match 'ExportRSAPublicKey\(\)') 'compile_environment_contains_public_key_only'
$environmentRestore=@($releaseAst.FindAll({param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Condition.Extent.Text -ceq '$savedEnvironment.Keys'},$true))
Check ($environmentRestore.Count -eq 1) 'release_environment_restorer_found'
$publicKeyEnvironmentBefore=[Environment]::GetEnvironmentVariable('SHOREBIRD_PUBLIC_KEY','Process')
$compiledPublicKey='synthetic-public-key'
try {
    [Environment]::SetEnvironmentVariable('SHOREBIRD_PUBLIC_KEY','existing-public-key','Process')
    $savedEnvironment=@{SHOREBIRD_PUBLIC_KEY='existing-public-key'}
    & ([scriptblock]::Create($publicKeyAssignment[0].Extent.Text))
    Check ($env:SHOREBIRD_PUBLIC_KEY -ceq $compiledPublicKey) 'public_compile_key_passed_to_flutter'
    & ([scriptblock]::Create($environmentRestore[0].Extent.Text))
    Check ($env:SHOREBIRD_PUBLIC_KEY -ceq 'existing-public-key') 'prior_public_compile_key_restored'
    $savedEnvironment=@{SHOREBIRD_PUBLIC_KEY=$null}
    try { & ([scriptblock]::Create($publicKeyAssignment[0].Extent.Text)); throw 'synthetic-build-failure' }
    catch { if($_.Exception.Message -cne 'synthetic-build-failure'){throw} }
    finally { & ([scriptblock]::Create($environmentRestore[0].Extent.Text)) }
    Check ($null -eq [Environment]::GetEnvironmentVariable('SHOREBIRD_PUBLIC_KEY','Process')) 'public_compile_key_removed_after_failure'
} finally { [Environment]::SetEnvironmentVariable('SHOREBIRD_PUBLIC_KEY',$publicKeyEnvironmentBefore,'Process') }
$baseErrors=$null; $baseTokens=$null
$null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'build-base.ps1'),[ref]$baseTokens,[ref]$baseErrors)
Check (@($baseErrors).Count -eq 0) 'base_wrapper_syntax'
Reject { & $releasePath -Target Windows -ReleaseVersion '0.1.10+31' -Independent -PublishCloud -IndependentBaseFingerprint ('a'*64) } 'independent_base_cloud_operation_forbidden'
Reject { & $releasePath -Target Windows -ReleaseVersion '0.1.10+31' -Independent -RecoverWindowsBase -IndependentBaseFingerprint ('a'*64) } 'independent_base_cloud_operation_forbidden'
Reject { & $releasePath -Target Windows -ReleaseVersion '0.1.10+31' -Independent } 'independent_base_fingerprint_missing'
Reject { & $releasePath -Target Windows -ReleaseVersion '0.1.10+31' -IndependentBaseFingerprint ('a'*64) } 'independent_base_switch_required'
$readConfig=@($releaseAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Read-ExVpnUpdaterConfig'},$true))
Check ($readConfig.Count -eq 1) 'updater_config_parser_found'
. ([scriptblock]::Create($readConfig[0].Extent.Text))
$Independent=$false
$sourcePolicy="app_id: ea97a683-02e5-4d86-9aa1-779d6b4bc81e`nauto_update: false`npatch_verification: strict`n"
$null=Read-ExVpnUpdaterConfig $sourcePolicy
Check $true 'legacy_source_policy_unchanged'
$publicScalar=[Convert]::ToBase64String([byte[]](1,2,3))
$compiledPolicy=$sourcePolicy+"base_url: http://127.0.0.1:57791`npatch_public_key: $publicScalar`n"
Reject { Read-ExVpnUpdaterConfig $compiledPolicy -Compiled } 'Unexpected or duplicate updater configuration field.'
$Independent=$true
$parsed=Read-ExVpnUpdaterConfig $compiledPolicy -Compiled
Check ($parsed.base_url -ceq 'http://127.0.0.1:57791') 'independent_compiled_endpoint'
Reject { Read-ExVpnUpdaterConfig $compiledPolicy.Replace('57791','57792') -Compiled } 'independent_base_endpoint_mismatch'
Reject { Read-ExVpnUpdaterConfig $compiledPolicy.Replace('127.0.0.1','0.0.0.0') -Compiled } 'independent_base_endpoint_mismatch'
Reject { Read-ExVpnUpdaterConfig ($compiledPolicy+"base_url: http://127.0.0.1:57791`n") -Compiled } 'Unexpected or duplicate updater configuration field.'
$restoreConfig=@($releaseAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Restore-IndependentUpdaterConfig'},$true))
Check ($restoreConfig.Count -eq 1) 'source_config_restorer_found'
. ([scriptblock]::Create($restoreConfig[0].Extent.Text))
function Get-AuditSha256([string]$Path) { Get-ExvpnOtaSha256 $Path }
$app=Join-Path $fixture 'apps/exvpn'
$sourceConfigBytes=[Text.Encoding]::UTF8.GetBytes($sourcePolicy)
$sourceConfigMtime=[DateTime]::UtcNow.AddHours(-1)
$policyPath=Join-Path $app 'shorebird.yaml'
[IO.File]::WriteAllText($policyPath,$compiledPolicy,[Text.UTF8Encoding]::new($false))
$script:independentConfigHash=Get-AuditSha256 $policyPath
$script:independentConfigLeased=$true
Restore-IndependentUpdaterConfig
Check (!$script:independentConfigLeased -and [IO.File]::ReadAllText($policyPath) -ceq $sourcePolicy) 'source_config_bytes_restored'
Check ([IO.File]::GetLastWriteTimeUtc($policyPath) -eq $sourceConfigMtime) 'source_config_mtime_restored'
[IO.File]::WriteAllText($policyPath,'concurrent change',[Text.UTF8Encoding]::new($false))
$script:independentConfigLeased=$true
Reject { Restore-IndependentUpdaterConfig } 'independent_config_lease_modified'
Check ([IO.File]::ReadAllText($policyPath) -ceq 'concurrent change') 'source_config_concurrent_change_preserved'
$script:independentConfigLeased=$false
$releaseText=[IO.File]::ReadAllText($releasePath)
Check ($releaseText -match 'elseif \(\$Independent\)' -and $releaseText -match 'Restore-IndependentUpdaterConfig\s+\} else') 'direct_build_branch_restores_before_audit'
Check ($releaseText.Contains("{'independent'} else {'shorebird_cloud'}")) 'independent_receipt_distinguishable'
[ordered]@{schemaVersion=1;checks=$script:checks;passed=$true;scope='pure fixtures, RSA signing and command contract; no AOT build, cloud call, package installation or runtime acceptance'} | ConvertTo-Json -Compress
