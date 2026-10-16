#requires -Version 7.0
# Dot-source this file; changes apply only to the calling PowerShell process.
[CmdletBinding()]
param(
    [string]$AndroidSdkPath = $(if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android/Sdk' }),
    [string]$JavaPath = $(if ($env:JAVA_HOME) { $env:JAVA_HOME } else { 'C:/Program Files/Android/Android Studio/jbr' })
)

$workspacePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$localToolRoot = Join-Path $workspacePath '.tools'
$localCacheRoot = Join-Path $localToolRoot 'cache'
New-Item -ItemType Directory -Force -Path $localCacheRoot | Out-Null
$toolBins = @((Join-Path $localToolRoot 'flutter/bin'), (Join-Path $localToolRoot 'go/bin'))
foreach ($toolBin in $toolBins) {
    if (-not (Test-Path -LiteralPath $toolBin -PathType Container)) { throw "Missing local SDK: $toolBin. Run bootstrap.ps1 first." }
}
$env:PATH = ($toolBins + @($env:PATH)) -join [IO.Path]::PathSeparator
$env:GOTOOLCHAIN = 'local'
$env:GOPATH = Join-Path $localCacheRoot 'go'
$env:GOCACHE = Join-Path $localCacheRoot 'go-build'
$env:PUB_CACHE = Join-Path $localCacheRoot 'pub'
$env:GRADLE_USER_HOME = Join-Path $localCacheRoot 'gradle'
$env:CI = 'true'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:DART_SUPPRESS_ANALYTICS = 'true'
if (Test-Path -LiteralPath $AndroidSdkPath -PathType Container) {
    $env:ANDROID_HOME = [IO.Path]::GetFullPath($AndroidSdkPath)
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
}
if (Test-Path -LiteralPath (Join-Path $JavaPath 'bin/java.exe') -PathType Leaf) {
    $env:JAVA_HOME = [IO.Path]::GetFullPath($JavaPath)
    $env:PATH = (Join-Path $env:JAVA_HOME 'bin') + [IO.Path]::PathSeparator + $env:PATH
}
Write-Host 'ExVPN SDK paths and caches are active in this process only.'
