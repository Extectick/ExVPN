#requires -Version 7.0
<# Builds two separate-UID QA APKs using only the already installed SDK/JBR.
   No SDK downloads, license acceptance, release signing, or device changes. #>
[CmdletBinding()]
param(
    [string]$AndroidSdkPath = (Join-Path $env:LOCALAPPDATA 'Android/Sdk'),
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$workspacePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $workspacePath 'scripts/bootstrap/enter-environment.ps1') -AndroidSdkPath $AndroidSdkPath
$buildTools = Join-Path $AndroidSdkPath 'build-tools/36.0.0'
$androidJar = Join-Path $AndroidSdkPath 'platforms/android-36/android.jar'
$debugKey = Join-Path $env:USERPROFILE '.android/debug.keystore'
if (-not (Test-Path -LiteralPath $debugKey)) { throw 'An existing Android debug keystore is required. No release key is created.' }
$artifactRoot = [IO.Path]::GetFullPath((Join-Path $workspacePath 'artifacts'))
$outputRoot = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $artifactRoot 'android-network-probe' }
if (!$outputRoot.StartsWith($artifactRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'QA output must stay inside workspace artifacts.' }
$checkPath = $outputRoot
while ($checkPath.Length -ge $artifactRoot.Length) {
    if ((Test-Path -LiteralPath $checkPath) -and ((Get-Item -LiteralPath $checkPath).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'QA output links are not allowed.' }
    $checkPath = [IO.Path]::GetDirectoryName($checkPath)
}
$classesPath = Join-Path $outputRoot 'classes'
$dexPath = Join-Path $outputRoot 'dex'
New-Item -ItemType Directory -Path $outputRoot, $classesPath, $dexPath -Force | Out-Null
function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "QA build step failed: $([IO.Path]::GetFileName($Executable)) ($LASTEXITCODE)" }
}
Invoke-Checked (Join-Path $env:JAVA_HOME 'bin/javac.exe') @('-source','8','-target','8','-classpath',$androidJar,'-d',$classesPath,(Join-Path $PSScriptRoot 'HttpsProbe.java'),(Join-Path $PSScriptRoot 'ProbeActivity.java'),(Join-Path $PSScriptRoot 'TextInputProbe.java'),(Join-Path $PSScriptRoot 'TextInputPayload.java'),(Join-Path $PSScriptRoot 'VpnUiSemantics.java'),(Join-Path $PSScriptRoot 'VpnUiProbe.java'))
$classesJar = Join-Path $outputRoot 'classes.jar'
Invoke-Checked (Join-Path $env:JAVA_HOME 'bin/jar.exe') @('cf',$classesJar,'-C',$classesPath,'.')
Invoke-Checked (Join-Path $buildTools 'd8.bat') @('--min-api','30','--lib',$androidJar,'--output',$dexPath,$classesJar)
foreach ($flavor in @('protected','excluded')) {
    $packageName = if ($flavor -eq 'protected') { 'ru.exvpn.netprobe' } else { 'ru.exvpn.netprobe.excluded' }
    $textInputInstrumentation = if ($flavor -eq 'protected') { '<instrumentation android:name="ru.exvpn.netprobe.TextInputProbe" android:targetPackage="ru.exvpn.netprobe" android:functionalTest="true" />' } else { '' }
    $vpnUiInstrumentation = if ($flavor -eq 'protected') { '<instrumentation android:name="ru.exvpn.netprobe.VpnUiProbe" android:targetPackage="ru.exvpn.netprobe" android:functionalTest="true" />' } else { '' }
    $manifestPath = Join-Path $outputRoot "$flavor-manifest.xml"
    @"
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="$packageName" android:versionCode="1" android:versionName="0.1.0">
  <uses-sdk android:minSdkVersion="30" android:targetSdkVersion="36" />
  <uses-permission android:name="android.permission.INTERNET" />
  <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
  <application android:label="ExVPN QA $flavor" android:debuggable="true" android:allowBackup="false" android:usesCleartextTraffic="false">
    <activity android:name="ru.exvpn.netprobe.ProbeActivity" android:exported="true">
      <intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter>
    </activity>
  </application>
  <instrumentation android:name="ru.exvpn.netprobe.HttpsProbe" android:targetPackage="$packageName" android:functionalTest="true" />
  $textInputInstrumentation
  $vpnUiInstrumentation
</manifest>
"@ | Set-Content -LiteralPath $manifestPath -Encoding utf8
    $unsignedApk = Join-Path $outputRoot "$flavor-unsigned.apk"
    $alignedApk = Join-Path $outputRoot "$flavor-aligned.apk"
    $signedApk = Join-Path $outputRoot "$flavor-debug.apk"
    Invoke-Checked (Join-Path $buildTools 'aapt2.exe') @('link','-o',$unsignedApk,'--manifest',$manifestPath,'-I',$androidJar)
    $archive = [IO.Compression.ZipFile]::Open($unsignedApk, [IO.Compression.ZipArchiveMode]::Update)
    try { [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $dexPath 'classes.dex'), 'classes.dex') | Out-Null }
    finally { $archive.Dispose() }
    Invoke-Checked (Join-Path $buildTools 'zipalign.exe') @('-f','4',$unsignedApk,$alignedApk)
    Invoke-Checked (Join-Path $buildTools 'apksigner.bat') @('sign','--ks',$debugKey,'--ks-key-alias','androiddebugkey','--ks-pass','pass:android','--key-pass','pass:android','--out',$signedApk,$alignedApk)
    Invoke-Checked (Join-Path $buildTools 'apksigner.bat') @('verify',$signedApk)
    [pscustomobject]@{ Package=$packageName; Apk=$signedApk; SHA256=(Get-FileHash -LiteralPath $signedApk -Algorithm SHA256).Hash.ToLowerInvariant() }
}
