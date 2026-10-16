# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')),
    [string]$FlutterRoot='',
    [switch]$Offline
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'build-impact-android-lib.ps1')
$Repository=[IO.Path]::GetFullPath($Repository)
if (!$FlutterRoot) { $FlutterRoot=Join-Path $Repository '.tools/flutter' }
$FlutterRoot=[IO.Path]::GetFullPath($FlutterRoot)
$app=Join-Path $Repository 'apps/exvpn'
$android=Join-Path $app 'android'
$build=Join-Path $app 'build'
$reports=Join-Path $build 'app/test-results/testDebugUnitTest'

function Assert-NoNativePackage {
    if ($env:EXVPN_ANDROID_PACKAGE_INPUTS -or
        (Test-Path -LiteralPath (Join-Path $Repository '.tools/artifacts/android-jni')) -or
        (Test-Path -LiteralPath (Join-Path $Repository 'artifacts/android-package-inputs'))) {
        throw 'android_jvm_requires_checkout_without_exvpn_package_inputs'
    }
    if (Test-Path -LiteralPath $build) {
        $native=@(Get-ChildItem -LiteralPath $build -File -Recurse | Where-Object { $_.Extension -iin @('.apk','.aab') -or $_.Name -ieq 'libexvpn.so' })
        if ($native.Count) { throw 'android_jvm_native_package_found' }
    }
}
Assert-NoNativePackage
if (Test-Path -LiteralPath $reports) { throw 'android_jvm_requires_fresh_test_reports' }
foreach ($required in @('platforms/android-36/android.jar','build-tools/36.0.0/aapt2.exe','ndk/28.2.13676358/source.properties')) {
    if (!$env:ANDROID_HOME -or !(Test-Path -LiteralPath (Join-Path $env:ANDROID_HOME $required) -PathType Leaf)) { throw 'android_jvm_required_sdk_package_missing' }
}
if (!$env:JAVA_HOME -or !(Test-Path -LiteralPath (Join-Path $env:JAVA_HOME 'bin/java.exe') -PathType Leaf)) { throw 'android_jvm_jdk_missing' }

# Flutter normally materializes these ignored files during `flutter build`.
# Use the same pinned SDK wrapper for standalone JVM tests; never download a
# different wrapper or change tracked Gradle configuration.
foreach ($relative in @('gradlew','gradlew.bat','gradle/wrapper/gradle-wrapper.jar')) {
    $source=Join-Path $FlutterRoot ('bin/cache/artifacts/gradle_wrapper/'+$relative)
    $destination=Join-Path $android $relative
    if (!(Test-Path -LiteralPath $source -PathType Leaf)) { throw 'android_jvm_pinned_gradle_wrapper_missing' }
    if (Test-Path -LiteralPath $destination) {
        if ((Get-FileHash -LiteralPath $source).Hash -cne (Get-FileHash -LiteralPath $destination).Hash) { throw 'android_jvm_gradle_wrapper_mismatch' }
    } else { Copy-Item -LiteralPath $source -Destination $destination }
}
$version=[regex]::Match([IO.File]::ReadAllText((Join-Path $app 'pubspec.yaml')),'(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (!$version.Success) { throw 'android_jvm_app_version_invalid' }
$properties=@()
$properties+='sdk.dir='+$env:ANDROID_HOME.Replace('\','/')
$properties+='flutter.sdk='+$FlutterRoot.Replace('\','/')
$properties+='flutter.buildMode=debug'
$properties+='flutter.versionName='+$version.Groups[1].Value
$properties+='flutter.versionCode='+$version.Groups[2].Value
[IO.File]::WriteAllLines((Join-Path $android 'local.properties'),$properties,[Text.UTF8Encoding]::new($false))
$output=Join-Path $Repository ('artifacts/ci/android-jvm-only/'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($output) | Out-Null
$arguments=@(':app:testDebugUnitTest','-x',':app:verifyExVpnPackageInputs','--no-daemon','--no-build-cache','--console=plain')
if ($Offline) { $arguments+='--offline' }
$watch=[Diagnostics.Stopwatch]::StartNew()
Push-Location $android
try {
    # This is the only exclusion, scoped to this explicit non-packaging
    # invocation. Every ordinary APK build retains mandatory snapshot checks.
    & './gradlew.bat' @arguments '--dry-run' *> (Join-Path $output 'task-graph.log')
    if ($LASTEXITCODE -ne 0) { throw 'android_jvm_task_graph_failed' }
    $graph=Get-AndroidJvmTaskGraph ([IO.File]::ReadAllText((Join-Path $output 'task-graph.log')))
    $graph | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $output 'task-graph.json') -Encoding utf8NoBOM
    & './gradlew.bat' @arguments '--rerun-tasks' *> (Join-Path $output 'junit.log')
    if ($LASTEXITCODE -ne 0) { throw 'android_jvm_tests_failed' }
} finally { Pop-Location; $watch.Stop() }
$junit=Get-AndroidJvmResult $reports
Assert-NoNativePackage
$result=[ordered]@{
    status='PASS';junit=$junit;taskGraphCount=$graph.taskCount
    excludedTask=$graph.excludedTask;elapsedSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,3)
    apkAabExvpnJniCount=0;packageSnapshotAbsent=$true;nativeBuildProof=$false
    observedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding utf8NoBOM
Write-Host "Android JVM checks passed: $($junit.tests) tests; $($graph.taskCount) tasks; $($result.elapsedSeconds) seconds. No APK/AAB or ExVPN JNI was built."
Write-Host "JVM evidence: $output"
