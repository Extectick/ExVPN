#requires -Version 7.0
# Dot-source this file; changes apply only to the calling PowerShell process.
[CmdletBinding()]
param(
    [string]$AndroidSdkPath = $(if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android/Sdk' }),
    [string]$JavaPath = $(if ($env:JAVA_HOME) { $env:JAVA_HOME } else { 'C:/Program Files/Android/Android Studio/jbr' }),
    [switch]$NativeOnly
)

$workspacePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$localToolRoot = Join-Path $workspacePath '.tools'
$localCacheRoot = Join-Path $localToolRoot 'cache'
New-Item -ItemType Directory -Force -Path $localCacheRoot | Out-Null
$toolBins = @()
if (-not $NativeOnly) { $toolBins += Join-Path $localToolRoot 'flutter/bin' }
$toolBins += Join-Path $localToolRoot 'go/bin'
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
# A modified Xray is still an ordinary checksum-pinned Go module. Its reviewed
# source archive is served by an immutable local file proxy, never go.mod replace.
$xrayPins = @()
foreach ($nativeModule in @('core','android','windows')) {
    $modulePath = Join-Path $workspacePath "native/$nativeModule/go.mod"
    $moduleText = [IO.File]::ReadAllText($modulePath)
    $match = [regex]::Match($moduleText,'(?m)^\s*github\.com/xtls/xray-core\s+(\S+)')
    if ($match.Success) { $xrayPins += $match.Groups[1].Value }
}
if (@($xrayPins | Where-Object { $_ -match '-exvpn\.' }).Count) {
    if ($xrayPins.Count -ne 3 -or @($xrayPins | Select-Object -Unique).Count -ne 1) { throw 'xray_patch_native_pins_disagree' }
    $goPath = Join-Path $localToolRoot 'go/bin/go.exe'
    $goEnvironmentText = (& $goPath env -json GOPROXY GONOPROXY GONOSUMDB GOFLAGS) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'xray_patch_go_environment_unavailable' }
    $goEnvironment = $goEnvironmentText | ConvertFrom-Json -AsHashtable
    # Respect effective GOPRIVATE defaults returned by go env. A matching
    # GONOPROXY would bypass the local reviewed source and must be explicit.
    & {
        param($Root,$Environment)
        . (Join-Path $Root 'scripts/core/xray-patch-lib.ps1')
        Test-XrayNoProxyConflict $Environment.GONOPROXY
        if ($Environment.GOFLAGS -match '(?:^|\s)-(?:overlay|modfile)(?:=|\s)|(?:^|\s)-mod(?:=|\s)vendor(?:\s|$)') { throw 'xray_patch_source_override_not_allowed' }
    } $workspacePath $goEnvironment
    # A nested collector may enter again after `off` became our local-only URI.
    # Preserve that mode rather than reintroducing a public-network fallback.
    $offlineProxy = $goEnvironment.GOPROXY -ceq 'off' -or
        ($goEnvironment.GOPROXY -cmatch '^file:' -and $goEnvironment.GOPROXY -notmatch '[,|]')
    $preparedXray = & (Join-Path $workspacePath 'scripts/core/prepare-xray-patch.ps1') -Offline:$offlineProxy
    if ($preparedXray.Version -cne $xrayPins[0]) { throw 'xray_patch_lock_and_module_disagree' }
    $proxyUri = ([Uri]($preparedXray.ProxyRoot + [IO.Path]::DirectorySeparatorChar)).AbsoluteUri.TrimEnd('/')
    $env:GOPROXY = if ($offlineProxy) { $proxyUri } else { "$proxyUri,https://proxy.golang.org,direct" }
    $sumPatterns = [Collections.Generic.List[string]]::new()
    foreach ($pattern in $goEnvironment.GONOSUMDB.Split(',', [StringSplitOptions]::RemoveEmptyEntries)) {
        if (!$sumPatterns.Contains($pattern)) { $sumPatterns.Add($pattern) }
    }
    if (!$sumPatterns.Contains('github.com/xtls/xray-core')) { $sumPatterns.Add('github.com/xtls/xray-core') }
    $env:GONOSUMDB = $sumPatterns -join ','
    $env:GOWORK = 'off'
}
if (Test-Path -LiteralPath $AndroidSdkPath -PathType Container) {
    $env:ANDROID_HOME = [IO.Path]::GetFullPath($AndroidSdkPath)
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
}
if (Test-Path -LiteralPath (Join-Path $JavaPath 'bin/java.exe') -PathType Leaf) {
    $env:JAVA_HOME = [IO.Path]::GetFullPath($JavaPath)
    $env:PATH = (Join-Path $env:JAVA_HOME 'bin') + [IO.Path]::PathSeparator + $env:PATH
}
Write-Host 'ExVPN SDK paths and caches are active in this process only.'
