#requires -Version 7.0
<#
.SYNOPSIS
Builds an ExVPN Android debug APK with the repository-local toolchain.
.DESCRIPTION
Requires the already installed Android SDK packages. Does not accept SDK
licenses, install packages, change host settings, sign a release, or install
the APK onto a device. A successful build does not prove VPN functionality.
.EXAMPLE
./scripts/bootstrap/build-android-debug.ps1
.EXAMPLE
./scripts/bootstrap/build-android-debug.ps1 -Demo -TargetPlatform android-x64
#>
[CmdletBinding()]
param(
    [ValidateSet('android-arm64', 'android-x64')]
    [string[]]$TargetPlatform = @('android-arm64', 'android-x64'),
    [string]$AndroidSdkPath = $(if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android/Sdk' }),
    [switch]$Demo
)

$ErrorActionPreference = 'Stop'
$workspacePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'enter-environment.ps1') -AndroidSdkPath $AndroidSdkPath
$requiredPackages = @(
    'platforms/android-36/android.jar',
    'build-tools/36.0.0/aapt2.exe',
    'ndk/27.1.12297006/source.properties',
    'ndk/28.2.13676358/source.properties'
)
foreach ($package in $requiredPackages) {
    if (-not (Test-Path -LiteralPath (Join-Path $AndroidSdkPath $package) -PathType Leaf)) {
        throw "Required installed Android SDK package is missing: $package. Install it explicitly after reviewing its license."
    }
}
if (-not $env:JAVA_HOME -or -not (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME 'bin/java.exe'))) {
    throw 'Android Studio JBR/JDK is unavailable. Configure the build process JAVA_HOME explicitly.'
}
foreach ($abi in @('arm64-v8a', 'x86_64')) {
    $nativeLibrary = Join-Path $workspacePath ".tools/artifacts/android-jni/$abi/libexvpn.so"
    if (-not (Test-Path -LiteralPath $nativeLibrary -PathType Leaf)) {
        throw "ExVPN JNI is missing for $abi. Run ./native/android/build.ps1 before packaging the app."
    }
}

$flutterPath = Join-Path $workspacePath '.tools/flutter/bin/flutter.bat'
$appPath = Join-Path $workspacePath 'apps/exvpn'
Push-Location $appPath
try {
    & $flutterPath pub get
    if ($LASTEXITCODE -ne 0) { throw "Flutter dependency resolution failed with exit code $LASTEXITCODE." }
    $buildArguments = @('build', 'apk', '--debug', '--no-pub', '--target-platform', ($TargetPlatform -join ','))
    if ($Demo) { $buildArguments += '--dart-define=EXVPN_DEMO=true' }
    & $flutterPath @buildArguments
    if ($LASTEXITCODE -ne 0) { throw "Android debug build failed with exit code $LASTEXITCODE. No SDK license was auto-accepted by this script." }
} finally {
    Pop-Location
}
$apkPath = Join-Path $appPath 'build/app/outputs/flutter-apk/app-debug.apk'
if (-not (Test-Path -LiteralPath $apkPath -PathType Leaf)) { throw 'Build returned success but the debug APK is absent.' }
[pscustomobject]@{
    Artifact = $apkPath
    SHA256 = (Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Bytes = (Get-Item -LiteralPath $apkPath).Length
    Configuration = 'debug; not a signed release'
    Demo = [bool]$Demo
    TargetPlatform = $TargetPlatform
}
