# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
<#
.SYNOPSIS
Builds the signed 0.1.0+18 Android demo with the pinned ordinary Flutter SDK.
.DESCRIPTION
Requires prebuilt JNI, prepared Android/Flutter caches and the four
EXVPN_ANDROID signing environment variables. Does not create keys, install an
app, publish a release, enable synthetic profiles or claim stable acceptance.
Tool diagnostics and the raw Maven graph remain under .private. Only the seven
allowlisted deliverables are promoted to artifacts/demo/android after checks.
#>
[CmdletBinding()]
param([string]$AndroidSdkPath = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'android-notice-inputs.ps1')
. (Join-Path $PSScriptRoot 'demo-release-lib.ps1')
. (Join-Path $PSScriptRoot 'demo-android-lib.ps1')

$environment = @{}
foreach ($name in @('PATH','GOTOOLCHAIN','GOPATH','GOCACHE','GOPROXY','GOSUMDB','GONOSUMDB','GOWORK',
    'PUB_CACHE','GRADLE_USER_HOME','CI','FLUTTER_SUPPRESS_ANALYTICS','DART_SUPPRESS_ANALYTICS',
    'ANDROID_HOME','ANDROID_SDK_ROOT','JAVA_HOME','FLUTTER_STORAGE_BASE_URL','PUB_HOSTED_URL',
    'EXVPN_ANDROID_PACKAGE_INPUTS','EXVPN_FLUTTER_RUNTIME','EXVPN_FLUTTER_BUILD_MODE','EXVPN_DEMO_MAVEN_GRAPH')) {
    $environment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$phase = 'preflight'
$privateRun = $null
$hook = $null
$hookHash = $null
$hookOwned = $false
try {
    if (!$IsWindows) { throw 'demo_android_windows_runner_required' }
    $sourceInputs = @(Get-DemoAndroidSourceInputs $repository)
    $sourceCommit = (& git -C $repository rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceCommit -cnotmatch '^[a-f0-9]{40}$') { throw 'demo_android_source_commit_missing' }
    $app = Join-Path $repository 'apps/exvpn'
    $version = Get-NoticeAppVersion ([IO.File]::ReadAllText((Join-Path $app 'pubspec.yaml'))) ([IO.File]::ReadAllText((Join-Path $app 'lib/build_identity.dart')))
    Assert-DemoAndroidVersion $version
    $signing = Get-DemoAndroidSigningInput
    $certificate = Join-Path $repository 'config/signing/android-release-cert.pem'
    $expectedSigner = Get-DemoAndroidCertificateSha256 $certificate -Pem
    $output = Join-Path $repository 'artifacts/demo/android'
    if (Test-Path -LiteralPath $output) { throw 'demo_android_output_exists' }

    $privateParent = Join-Path $repository '.private/demo-android-builds'
    $ancestor = $privateParent
    while (!(Test-Path -LiteralPath $ancestor)) { $ancestor = [IO.Path]::GetDirectoryName($ancestor) }
    Assert-AuditNoLinks $ancestor
    $privateRun = Join-Path $privateParent ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $privateRun | Out-Null
    $stage = Join-Path $privateRun 'public'
    New-Item -ItemType Directory -Path $stage | Out-Null

    $phase = 'toolchain'
    $sdk = Get-ReleaseAndroidSdkPath $AndroidSdkPath
    . (Join-Path $repository 'scripts/bootstrap/enter-environment.ps1') -AndroidSdkPath $sdk 6> (Join-Path $privateRun 'environment.log')
    $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.googleapis.com'
    $env:PUB_HOSTED_URL = 'https://pub.dev'
    $env:EXVPN_FLUTTER_RUNTIME = 'ordinary'
    $env:EXVPN_FLUTTER_BUILD_MODE = 'release'
    foreach ($relative in @('platforms/android-36/android.jar','build-tools/36.0.0/aapt2.exe',
        'build-tools/36.0.0/lib/apksigner.jar','ndk/27.1.12297006/source.properties','ndk/28.2.13676358/source.properties')) {
        if (!(Test-Path -LiteralPath (Join-Path $sdk $relative) -PathType Leaf)) { throw 'demo_android_sdk_input_missing' }
    }
    if (!$env:JAVA_HOME) { throw 'demo_android_jdk_missing' }
    $java = Join-Path $env:JAVA_HOME 'bin/java.exe'
    $keytool = Join-Path $env:JAVA_HOME 'bin/keytool.exe'
    foreach ($tool in @($java,$keytool)) { Assert-AuditNoLinks $tool }
    foreach ($abi in @('arm64-v8a','x86_64')) {
        Assert-AuditNoLinks (Join-Path $repository ".tools/artifacts/android-jni/$abi/libexvpn.so")
    }
    $runtime = Get-ReleaseFlutterRuntime -Repository $repository -Target Android -FlutterRuntime ordinary -FlutterBuildMode release
    $flutter = Join-Path $runtime.SdkRoot 'bin/flutter.bat'

    $phase = 'signing_preflight'
    $exportedCertificate = Join-Path $privateRun 'signer.der'
    # Password stays in the child's environment, never its command line/output.
    $null = Invoke-AuditTool $keytool @('-exportcert','-alias',$signing.Alias,'-keystore',$signing.Path,
        '-storepass:env','EXVPN_ANDROID_STORE_PASSWORD','-file',$exportedCertificate)
    if ((Get-DemoAndroidCertificateSha256 $exportedCertificate) -cne $expectedSigner) { throw 'demo_android_keystore_signer_mismatch' }

    Push-Location $app
    try {
        $phase = 'pub'
        & $flutter pub get --offline --enforce-lockfile *> (Join-Path $privateRun 'pub.log')
        if ($LASTEXITCODE -ne 0) { throw 'demo_android_pub_failed' }
        $phase = 'notice_snapshot'
        $inputs = & (Join-Path $PSScriptRoot 'prepare-android-notices.ps1') -FlutterRuntime ordinary -FlutterBuildMode release 6> (Join-Path $privateRun 'notices.log')
        if (!$inputs.InputDirectory -or $inputs.AppVersion -cne $version -or
            $inputs.SealSha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'demo_android_notice_snapshot_invalid' }
        $env:EXVPN_ANDROID_PACKAGE_INPUTS = $inputs.InputDirectory

        $phase = 'maven_observer'
        $rawGraph = Join-Path $privateRun 'android-maven-inputs.json'
        $env:EXVPN_DEMO_MAVEN_GRAPH = $rawGraph
        $hookDirectory = Join-Path $env:GRADLE_USER_HOME 'init.d'
        if (!(Test-Path -LiteralPath $hookDirectory)) { New-Item -ItemType Directory -Path $hookDirectory -Force | Out-Null }
        Assert-AuditNoLinks $hookDirectory
        $hook = Join-Path $hookDirectory 'exvpn-demo-maven-notices.gradle'
        if (Test-Path -LiteralPath $hook) { throw 'demo_android_maven_hook_exists' }
        $hookSource = Join-Path $PSScriptRoot 'prepare-demo-maven-notices.init.gradle'
        $hookHash = Get-AuditSha256 $hookSource
        # CreateNew prevents a competing run's observer from being overwritten.
        $hookStream = [IO.File]::Open($hook, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $hookOwned = $true
        try { $bytes = [IO.File]::ReadAllBytes($hookSource); $hookStream.Write($bytes, 0, $bytes.Length) }
        finally { $hookStream.Dispose() }

        $phase = 'apk'
        try {
            # --pub regenerates the release plugin registrant; --no-pub can
            # retain the dev integration_test registrant after ordinary pub get.
            $arguments = Get-DemoAndroidBuildArguments
            & $flutter @arguments *> (Join-Path $privateRun 'flutter-build.log')
            if ($LASTEXITCODE -ne 0) { throw 'demo_android_flutter_build_failed' }
        } finally {
            Remove-DemoAndroidOwnedHook $hook $hookHash
            $hookOwned = $false
            Remove-Item -LiteralPath 'Env:\EXVPN_DEMO_MAVEN_GRAPH' -ErrorAction SilentlyContinue
        }
        if (!(Test-Path -LiteralPath $rawGraph -PathType Leaf)) { throw 'demo_android_maven_graph_missing' }

        $phase = 'jvm'
        Push-Location (Join-Path $app 'android')
        try {
            $jvmStarted = [datetime]::UtcNow
            # Gradle's task-specific --rerun refreshes tests, not all prerequisites.
            & './gradlew.bat' ':app:testReleaseUnitTest' '--rerun' '--no-daemon' *> (Join-Path $privateRun 'jvm.log')
            if ($LASTEXITCODE -ne 0) { throw 'demo_android_jvm_failed' }
        } finally { Pop-Location }
        $jvm = Get-DemoAndroidJvmSummary (Join-Path $app 'build/app/test-results/testReleaseUnitTest') $jvmStarted
    } finally { Pop-Location }

    $phase = 'package_verification'
    & (Join-Path $PSScriptRoot 'verify-android-notices.ps1') -InputDirectory $inputs.InputDirectory -ExpectedVersion $version -FlutterRuntime ordinary -FlutterBuildMode release *> (Join-Path $privateRun 'verify-inputs.log')
    if (!$?) { throw 'demo_android_notice_snapshot_changed' }
    $builtApk = Join-Path $app 'build/app/outputs/flutter-apk/app-release.apk'
    Assert-AuditNoLinks $builtApk
    $builtHash = Get-AuditSha256 $builtApk
    $packagedRuntime = Assert-AndroidPackagedNotices $repository $inputs.InputDirectory $builtApk -FlutterRuntime ordinary -FlutterBuildMode release -PassThruRuntime -AndroidSdkPath $sdk
    if (!$packagedRuntime.engineBytesBound) { throw 'demo_android_flutter_engine_not_bound' }
    $signatureText = Invoke-AuditTool $java @('-jar',(Join-Path $sdk 'build-tools/36.0.0/lib/apksigner.jar'), 'verify','--verbose','--print-certs',$builtApk)
    $signature = ConvertFrom-DemoAndroidSignature $signatureText $expectedSigner
    $badging = Invoke-AuditTool (Join-Path $sdk 'build-tools/36.0.0/aapt2.exe') @('dump','badging',$builtApk)
    $identity = ConvertFrom-DemoAndroidIdentity $badging
    if ((Get-AuditSha256 $builtApk) -cne $builtHash) { throw 'demo_android_apk_changed' }
    $destination = Join-Path $stage 'ExVPN-0.1.0-demo-android.apk'
    Copy-Item -LiteralPath $builtApk -Destination $destination
    if ((Get-AuditSha256 $destination) -cne $builtHash) { throw 'demo_android_apk_copy_mismatch' }

    $phase = 'notice_archive'
    $noticeDirectory = Join-Path $inputs.InputDirectory 'assets/exvpn_notices'
    $noticeFiles = Get-AuditTreeFiles $noticeDirectory
    $noticesZip = Join-Path $stage 'android-notices.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($noticeDirectory, $noticesZip)
    $zippedNotices = Get-AuditZipFiles $noticesZip
    if ($zippedNotices.Count -ne $noticeFiles.Count) { throw 'demo_android_notice_zip_mismatch' }
    foreach ($name in $noticeFiles.Keys) {
        if (!$zippedNotices.ContainsKey($name) -or $zippedNotices[$name].sha256 -cne $noticeFiles[$name].sha256 -or
            $zippedNotices[$name].size -ne $noticeFiles[$name].size) { throw 'demo_android_notice_zip_mismatch' }
    }
    $phase = 'maven_notices'
    & (Join-Path $PSScriptRoot 'prepare-demo-maven-notices.ps1') -ResolvedGraph $rawGraph -ArtifactPath $destination -OutputDirectory $stage *> (Join-Path $privateRun 'maven-notices.log')
    if (!$?) { throw 'demo_android_maven_notices_failed' }
    $maven = Get-Content -LiteralPath (Join-Path $stage 'android-maven-notices.json') -Raw | ConvertFrom-Json
    if ($maven.status -cne 'PASS' -or $maven.appVersion -cne $version -or $maven.apkSha256 -cne $builtHash -or
        $maven.archiveSha256 -cne (Get-AuditSha256 (Join-Path $stage 'android-maven-notices.zip'))) { throw 'demo_android_maven_notices_binding_failed' }

    $phase = 'audit'
    Export-DemoAudit -Target Android -ArtifactPath $destination -OutputDirectory $stage -ExpectedSignerSha256 $expectedSigner -AndroidSdkPath $sdk *> (Join-Path $privateRun 'audit.log')
    $phase = 'final_inputs'
    $runtimeAfter = Get-ReleaseFlutterRuntime -Repository $repository -Target Android -FlutterRuntime ordinary -FlutterBuildMode release
    Assert-ReleaseFlutterRuntimeEvidence $runtimeAfter.Evidence $runtime.Evidence
    Assert-DemoAndroidSourceUnchanged $sourceInputs @(Get-DemoAndroidSourceInputs $repository)
    $commitAfter = (& git -C $repository rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $commitAfter -cne $sourceCommit -or (Get-AuditSha256 $destination) -cne $builtHash) { throw 'demo_android_final_inputs_changed' }
    [ordered]@{
        schema=1;version=$version;sourceCommit=$sourceCommit;runtime='ordinary';syntheticProfiles=$false
        artifact=(Get-DemoAssetRecord $destination);stableReady=$false;dartOtaAvailable=$false
        networkTestingOptInRequired=$true;signature=$signature;android=$identity;jvm=$jvm
        sourceInputs=[ordered]@{files=$sourceInputs.Count;sha256=(Get-AuditTextHash ($sourceInputs | ConvertTo-Json -Depth 5 -Compress));unchanged=$true}
        packageInputsSealSha256=$inputs.SealSha256;flutterRuntime=$packagedRuntime
        notices=(Get-DemoAssetRecord $noticesZip)
        mavenNotices=(Get-DemoAssetRecord (Join-Path $stage 'android-maven-notices.zip'))
        sbom=(Get-DemoAssetRecord (Join-Path $stage 'android-sbom.cdx.json'));sbomComplete=$false
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $stage 'android-build.json') -Encoding utf8
    Assert-DemoAndroidPublicFiles $stage

    $phase = 'promote'
    # Both absolute endpoints are fixed children of this workspace. No existing
    # output or unrelated directory is deleted or replaced on a repeated run.
    $allowedPrivate = [IO.Path]::GetFullPath($privateParent) + [IO.Path]::DirectorySeparatorChar
    $demoRoot = [IO.Path]::GetFullPath((Join-Path $repository 'artifacts/demo'))
    if (![IO.Path]::GetFullPath($stage).StartsWith($allowedPrivate, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($output)) -cne $demoRoot -or (Test-Path -LiteralPath $output)) { throw 'demo_android_promotion_path_invalid' }
    $ancestor = $demoRoot
    while (!(Test-Path -LiteralPath $ancestor)) { $ancestor = [IO.Path]::GetDirectoryName($ancestor) }
    Assert-AuditNoLinks $ancestor
    New-Item -ItemType Directory -Path $demoRoot -Force | Out-Null
    Move-Item -LiteralPath $stage -Destination $output
    Write-Host "Android demo release staged: version=$version; sha256=$builtHash; JVM tests=$($jvm.tests); stableReady=false."
} catch {
    if ($privateRun -and (Test-Path -LiteralPath $privateRun -PathType Container)) {
        [IO.File]::WriteAllText((Join-Path $privateRun 'failure.log'), ($_ | Out-String))
    }
    # Never echo a child tool's diagnostics, signing arguments, environment or paths.
    $diagnostic = Get-DemoAndroidFailureDiagnostic $_ $repository
    throw "demo_android_failed phase=$phase code=$($diagnostic.code) exception=$($diagnostic.exceptionType) locations=$($diagnostic.locations -join ','); private diagnostics retained, not uploaded"
} finally {
    try {
        if ($hookOwned) {
            try { Remove-DemoAndroidOwnedHook $hook $hookHash }
            catch { throw 'demo_android_maven_hook_cleanup_failed' }
        }
    }
    finally { Restore-DemoAndroidEnvironment $environment }
}
