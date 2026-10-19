# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Builds exactly once. Default dry-run does not upload. Explicit -PublishCloud
# signs and publishes only after the source/base/CLI checks and upstream diffs.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Android','Windows')][string]$Target,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+\+[1-9]\d*$')][string]$ReleaseVersion,
    [Parameter(Mandatory)][string]$BaseReceipt,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$BaseSourceCommit,
    [string]$AndroidSdkPath = '',
    [switch]$PublishCloud
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'flutter-runtime-inputs.ps1')
. (Join-Path $PSScriptRoot 'notice-inputs.ps1')
. (Join-Path $PSScriptRoot 'shorebird-pipeline-lib.ps1')
. (Join-Path $PSScriptRoot 'demo-android-lib.ps1')
. (Join-Path $PSScriptRoot 'shorebird-android-environment.ps1')
$policy = Get-ShorebirdPolicy
$basePath = [IO.Path]::GetFullPath($BaseReceipt)
Assert-AuditNoLinks $basePath
if ((Get-Item -LiteralPath $basePath).Length -gt 4MB) { throw 'shorebird_base_receipt_oversized' }
$base = Get-Content -LiteralPath $basePath -Raw | ConvertFrom-Json -AsHashtable
Assert-ShorebirdBaseReceipt $base $ReleaseVersion $Target
if ($base.sourceCommit -cne $BaseSourceCommit) { throw 'shorebird_base_source_mismatch' }
Assert-ShorebirdReceiptFiles $basePath $base
$source = Assert-ShorebirdPatchSource $repository $base.sourceCommit
$public = Get-ShorebirdPublicKey $repository
if ($base.publicKeySha256 -cne $public.sha256) { throw 'shorebird_base_public_key_changed' }
$app = Join-Path $repository 'apps/exvpn'
$version = Get-NoticeAppVersion ([IO.File]::ReadAllText((Join-Path $app 'pubspec.yaml'))) ([IO.File]::ReadAllText((Join-Path $app 'lib/build_identity.dart')))
if ($version -cne $ReleaseVersion) { throw 'shorebird_patch_version_changed' }
$runtime = Get-ReleaseFlutterRuntime -Repository $repository -Target $Target -FlutterRuntime shorebird -FlutterBuildMode release
Assert-ReleaseFlutterRuntimeEvidence $runtime.Evidence $base.runtime
$cli = Get-ShorebirdCli $repository
$privateRun = New-ShorebirdPrivateDirectory $repository 'patch'
$output = Join-Path $repository ('artifacts/shorebird/patch-' + $ReleaseVersion + '-' + $Target.ToLowerInvariant() + '-' + [Guid]::NewGuid().ToString('N'))
$environment = @{}
foreach ($name in @('PATH','APPDATA','PUB_CACHE','GRADLE_USER_HOME','CI','FLUTTER_STORAGE_BASE_URL','ANDROID_HOME','ANDROID_SDK_ROOT',
    'FLUTTER_SUPPRESS_ANALYTICS','DART_SUPPRESS_ANALYTICS','EXVPN_FLUTTER_RUNTIME','EXVPN_FLUTTER_BUILD_MODE','EXVPN_ANDROID_PACKAGE_INPUTS',
    'EXVPN_ANDROID_KEYSTORE','EXVPN_ANDROID_KEY_ALIAS','EXVPN_ANDROID_STORE_PASSWORD','EXVPN_ANDROID_KEY_PASSWORD','EXVPN_SHOREBIRD_PRIVATE_KEY_BASE64')) {
    $environment[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
}
$keyPath = $null; $passwordBytes = $null; $phase = 'base_lookup'
$recoveryPath = $null; $cloudPatchVerified = $false
Push-Location $app
try {
    $env:CI = 'true'; $env:FLUTTER_SUPPRESS_ANALYTICS = 'true'; $env:DART_SUPPRESS_ANALYTICS = 'true'
    $env:PUB_CACHE = Join-Path $repository '.tools/cache/pub'
    $env:GRADLE_USER_HOME = Join-Path $repository '.tools/cache/gradle'
    $env:FLUTTER_STORAGE_BASE_URL = 'https://download.shorebird.dev'
    $env:PATH = (Join-Path $runtime.SdkRoot 'bin') + [IO.Path]::PathSeparator + $environment.PATH
    $env:EXVPN_FLUTTER_RUNTIME = 'shorebird'; $env:EXVPN_FLUTTER_BUILD_MODE = 'release'
    if ($Target -ceq 'Android') {
        $sdk = Get-ReleaseAndroidSdkPath $AndroidSdkPath
        $env:ANDROID_HOME = $sdk; $env:ANDROID_SDK_ROOT = $sdk
    }
    if ($Target -ceq 'Android' -and $env:GITHUB_ACTIONS -ceq 'true') {
        $null = Initialize-ShorebirdAndroidToolEnvironment -Repository $repository -FlutterSdkRoot $runtime.SdkRoot -AndroidSdkPath $sdk -PrivateDirectory $privateRun
    }
    # A fresh Windows runner has no package_config yet. Resolve the exact lock
    # before upstream --no-pub builds (its cleanup pub get is too late).
    $phase = 'pub'
    & (Join-Path $runtime.SdkRoot 'bin/flutter.bat') pub get --offline --enforce-lockfile *> (Join-Path $privateRun 'pub.log')
    if ($LASTEXITCODE -ne 0) { throw 'shorebird_patch_locked_pub_failed' }
    if ((Get-ShorebirdSourceCommit $repository) -cne $source.sourceCommit) { throw 'shorebird_patch_pub_changed_source' }
    $phase = 'base_lookup'
    if ($Target -ceq 'Android') {
        if (!$env:EXVPN_ANDROID_KEYSTORE -and !$env:EXVPN_ANDROID_STORE_PASSWORD -and !$env:EXVPN_ANDROID_KEY_PASSWORD -and !$env:EXVPN_ANDROID_KEY_ALIAS) {
            $signingRoot = Join-Path $repository '.private/signing/android'
            Assert-AuditNoLinks $signingRoot
            $passwordBytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes((Join-Path $signingRoot 'store-password.dpapi')),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
            $env:EXVPN_ANDROID_KEYSTORE = Join-Path $signingRoot 'release.p12'; $env:EXVPN_ANDROID_KEY_ALIAS = 'exvpn'
            $env:EXVPN_ANDROID_STORE_PASSWORD = [Text.Encoding]::UTF8.GetString($passwordBytes)
            $env:EXVPN_ANDROID_KEY_PASSWORD = $env:EXVPN_ANDROID_STORE_PASSWORD
        }
        $null = Get-DemoAndroidSigningInput
        # Reuse exact base assets/JNI; collecting notices again could change an
        # embedded timestamp and would not be a Dart-only patch.
        $sealedSource = Join-Path ([IO.Path]::GetDirectoryName($basePath)) 'patch-inputs'
        $inputsParent = Join-Path $repository 'artifacts/android-package-inputs'
        New-Item -ItemType Directory -Path $inputsParent -Force | Out-Null
        Assert-AuditNoLinks $inputsParent
        $env:EXVPN_ANDROID_PACKAGE_INPUTS = Join-Path $inputsParent ('patch-' + [Guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $sealedSource -Destination $env:EXVPN_ANDROID_PACKAGE_INPUTS -Recurse
        foreach ($abi in @('arm64-v8a','x86_64')) {
            $cached = Join-Path $repository ".tools/artifacts/android-jni/$abi/libexvpn.so"
            $sealed = Join-Path $sealedSource "jniLibs/$abi/libexvpn.so"
            if (!(Test-Path -LiteralPath $cached)) {
                $parent = [IO.Path]::GetDirectoryName($cached)
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
                Assert-AuditNoLinks $parent
                Copy-Item -LiteralPath $sealed -Destination $cached
            }
            Assert-AuditNoLinks $cached
            if ((Get-AuditSha256 $cached) -cne (Get-AuditSha256 $sealed)) { throw 'shorebird_patch_cached_jni_mismatch' }
        }
        & (Join-Path $PSScriptRoot 'verify-android-notices.ps1') -InputDirectory $env:EXVPN_ANDROID_PACKAGE_INPUTS -ExpectedVersion $version -FlutterRuntime shorebird -FlutterBuildMode release *> (Join-Path $privateRun 'inputs.log')
        if (!$?) { throw 'shorebird_patch_base_inputs_invalid' }
    }
    $cloud = Invoke-ShorebirdJson $cli @('releases','info',"--app-id=$($policy.appId)","--release-version=$version") 'releases info' $privateRun 'base'
    Assert-ShorebirdCloudRelease $cloud.release $version $Target $base.releaseId
    $phase = 'signing'
    $keyPath = Export-ShorebirdPrivateKey $repository $privateRun
    $env:EXVPN_SHOREBIRD_PRIVATE_KEY_BASE64 = $null
    $phase = 'patch'
    $arguments = Get-ShorebirdPatchArguments $Target $version $public.path $keyPath -PublishCloud:$PublishCloud
    if ($PublishCloud) {
        $recoveryPath=Write-ShorebirdRecovery -Repository $repository -Action patch -Version $version -Target $Target -SourceCommit $source.sourceCommit -BaseSourceCommit $base.sourceCommit -ReleaseId $base.releaseId -Status attempting -CloudOutcome unknown -Phase $phase
    }
    $result = Invoke-ShorebirdJson $cli $arguments 'patch' $privateRun 'patch'
    $patchNumber = $null; $patchId = $null; $artifacts = @()
    if ($PublishCloud) {
        if ($result.app_id -cne $policy.appId -or $result.track -cne 'beta' -or @($result.patches).Count -ne 1) { throw 'shorebird_patch_response_invalid' }
        $patch = $result.patches[0]
        if ($patch.release_id -ne $base.releaseId -or $patch.release_version -cne $version -or
            $patch.platform -cne $Target.ToLowerInvariant() -or $patch.patch_number -le 0 -or $patch.patch_id -le 0) { throw 'shorebird_patch_response_invalid' }
        $patchNumber = $patch.patch_number; $patchId = $patch.patch_id
        $cloudPatchVerified = $true
        $null=Write-ShorebirdRecovery -Repository $repository -Action patch -Version $version -Target $Target -SourceCommit $source.sourceCommit -BaseSourceCommit $base.sourceCommit -ReleaseId $base.releaseId -PatchId $patchId -PatchNumber $patchNumber -Status cloud_registered -CloudOutcome registered -Phase $phase -Path $recoveryPath
        $info = Invoke-ShorebirdJson $cli @('patches','info',"--app-id=$($policy.appId)","--release-version=$version","--patch-number=$patchNumber") 'patches info' $privateRun 'patch-info'
        if ($info.patch.id -ne $patchId -or $info.patch.number -ne $patchNumber -or $info.patch.channel -cne 'beta' -or $info.patch.is_rolled_back) { throw 'shorebird_patch_readback_failed' }
        $artifacts = @($info.patch.artifacts | Where-Object platform -CEQ $Target.ToLowerInvariant() | ForEach-Object {
            if ($_.patch_id -ne $patchId -or $_.hash -cnotmatch '^[a-f0-9]{64}$' -or $_.size -le 0) { throw 'shorebird_patch_artifact_invalid' }
            [ordered]@{platform=$_.platform;arch=$_.arch;sha256=$_.hash;bytes=$_.size}
        })
        Assert-ShorebirdPatchArtifacts $artifacts $Target
        $localAot = if ($Target -ceq 'Android') {
            @(Get-ShorebirdAndroidAot (Join-Path $app 'build/app/outputs/bundle/release/app-release.aab'))
        } else {
            $aotPath = Join-Path $app 'build/windows/x64/runner/Release/data/app.so'
            @([ordered]@{platform='windows';arch='x86_64';sha256=(Get-AuditSha256 $aotPath);bytes=(Get-Item -LiteralPath $aotPath).Length})
        }
        foreach ($artifact in $artifacts) {
            $local = @($localAot | Where-Object arch -CEQ $artifact.arch)
            if ($local.Count -ne 1 -or $local[0].sha256 -cne $artifact.sha256) { throw 'shorebird_patch_cloud_aot_mismatch' }
        }
    } elseif (!$result.dry_run -or $result.release_id -ne $base.releaseId -or $result.release_version -cne $version) { throw 'shorebird_patch_dry_run_invalid' }
    $phase = 'final_inputs'
    $after = Assert-ShorebirdPatchSource $repository $base.sourceCommit
    if ($after.sourceCommit -cne $source.sourceCommit) { throw 'shorebird_patch_source_changed' }
    Assert-ReleaseFlutterRuntimeEvidence (Get-ReleaseFlutterRuntime -Repository $repository -Target $Target -FlutterRuntime shorebird -FlutterBuildMode release).Evidence $runtime.Evidence
    Assert-ShorebirdReceiptFiles $basePath $base
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    [ordered]@{
        schemaVersion=1;action='patch';version=$version;target=$Target;track='beta';appId=$policy.appId
        published=[bool]$PublishCloud;signed=$true;publicKeySha256=$public.sha256;releaseId=$base.releaseId
        patchNumber=$patchNumber;patchId=$patchId;artifacts=$artifacts
        baseReceiptSha256=Get-AuditSha256 $basePath;source=$source;runtime=$runtime.Identity
        nativeDiffsAllowed=$false;assetDiffsAllowed=$false;deviceApplyVerified=$false
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $output 'patch.json') -Encoding utf8NoBOM
    if ($recoveryPath) {
        $null=Write-ShorebirdRecovery -Repository $repository -Action patch -Version $version -Target $Target -SourceCommit $source.sourceCommit -BaseSourceCommit $base.sourceCommit -ReleaseId $base.releaseId -PatchId $patchId -PatchNumber $patchNumber -Status ready -CloudOutcome registered -Phase $phase -Path $recoveryPath
    }
} catch {
    ($_ | Out-String) | Set-Content -LiteralPath (Join-Path $privateRun 'failure.log') -Encoding utf8NoBOM
    if ($recoveryPath) {
        $null=Write-ShorebirdRecovery -Repository $repository -Action patch -Version $version -Target $Target -SourceCommit $source.sourceCommit -BaseSourceCommit $base.sourceCommit -ReleaseId $base.releaseId -PatchId $(if ($cloudPatchVerified) {$patchId} else {0}) -PatchNumber $(if ($cloudPatchVerified) {$patchNumber} else {0}) -Status failed -CloudOutcome $(if ($cloudPatchVerified) {'registered'} else {'unknown'}) -Phase $phase -Path $recoveryPath
    }
    throw "shorebird_patch_failed phase=$phase; inspect private cloud receipt before retry"
} finally {
    Pop-Location
    try { if ($keyPath) { Remove-Item -LiteralPath $keyPath -Force -ErrorAction Stop } }
    finally {
        if ($passwordBytes) { [Security.Cryptography.CryptographicOperations]::ZeroMemory($passwordBytes) }
        Restore-DemoAndroidEnvironment $environment
    }
}
[pscustomobject]@{OutputDirectory=$output;Published=[bool]$PublishCloud;Version=$version;Target=$Target}
