#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Windows', 'Android')][string]$Target = 'Windows',
    [string]$OutputDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repository 'scripts/bootstrap/enter-environment.ps1')
$go = Join-Path $repository '.tools/go/bin/go.exe'
if (!$OutputDirectory) { $OutputDirectory = Join-Path $repository "artifacts/notices/$($Target.ToLowerInvariant())" }
$output = [IO.Path]::GetFullPath($OutputDirectory)
# Never delete an earlier evidence bundle; callers can choose a fresh destination.
if (Test-Path -LiteralPath $output) { throw 'Notices destination already exists. Select a new empty destination.' }
New-Item -ItemType Directory -Path $output | Out-Null
$components = [Collections.Generic.List[object]]::new()
$binaryEvidence = [Collections.Generic.List[object]]::new()

function Hash-Text([string]$Value) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Value))).ToLowerInvariant()
}

function Add-Notice([string]$Name, [string]$Version, [string]$SourceRoot, [string]$Scope, [string]$SourceUrl = '', [string]$ModuleSum = '') {
    $rootPath = [IO.Path]::GetFullPath($SourceRoot)
    $noticeFiles = @([IO.Directory]::EnumerateFiles($rootPath, '*', [IO.SearchOption]::AllDirectories) | Where-Object {
        [IO.Path]::GetFileName($_) -match '^(LICENSE|LICENCE|COPYING|NOTICE|PATENTS|AUTHORS)([._-].*)?$'
    } | Sort-Object)
    if (!$noticeFiles.Count) { throw "No license/notice found for $Name@$Version. Do not distribute this bundle." }
    $folder = (Hash-Text "$Scope/$Name@$Version").Substring(0, 24)
    $files = @()
    foreach ($sourceFile in $noticeFiles) {
        $relative = [IO.Path]::GetRelativePath($rootPath, $sourceFile)
        $destination = Join-Path $output (Join-Path $folder $relative)
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force | Out-Null
        Copy-Item -LiteralPath $sourceFile -Destination $destination
        $files += [ordered]@{ path = "$folder/$($relative.Replace('\', '/'))"; sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    $components.Add([ordered]@{ name = $Name; version = $Version; scope = $Scope; source = $SourceUrl; moduleSum = $ModuleSum; notices = $files })
}

function Add-SingleNotice([string]$Name, [string]$Version, [string]$Path, [string]$SourceUrl = '') {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required notice is missing: $Name" }
    $folder = (Hash-Text "$Name@$Version").Substring(0, 24)
    $destination = Join-Path $output "$folder/NOTICE.txt"
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force | Out-Null
    Copy-Item -LiteralPath $Path -Destination $destination
    $components.Add([ordered]@{ name = $Name; version = $Version; scope = 'runtime-or-asset'; source = $SourceUrl; notices = @([ordered]@{ path = "$folder/NOTICE.txt"; sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() }) })
}

$binaries = if ($Target -eq 'Windows') { @('artifacts/windows/exvpn-service.exe') } else {
    @('.tools/artifacts/android-jni/arm64-v8a/libexvpn.so', '.tools/artifacts/android-jni/x86_64/libexvpn.so')
}
$modules = @{}
foreach ($binary in $binaries) {
    $binaryPath = Join-Path $repository $binary
    if (!(Test-Path -LiteralPath $binaryPath -PathType Leaf)) { throw "Build the native binary first: $binary" }
    $buildInfo = (& $go version -m -json $binaryPath) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect Go binary build information.' }
    $info = $buildInfo | ConvertFrom-Json -AsHashtable
    if (!$info.Deps.Count) { throw 'Go module build information is missing.' }
    $binaryEvidence.Add([ordered]@{ name = $binary; sha256 = (Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash.ToLowerInvariant(); go = $info.GoVersion; modules = $info.Deps })
    foreach ($dependency in $info.Deps) {
        if ($dependency.Path.StartsWith('github.com/Extectick/ExVPN/')) { continue }
        if ($dependency['Replace']) { throw "External replacement requires a source review: $($dependency.Path)" }
        $key = "$($dependency.Path)@$($dependency.Version)"
        if ($modules.ContainsKey($key) -and $modules[$key].Sum -ne $dependency.Sum) { throw 'Different embedded module checksums.' }
        $modules[$key] = $dependency
    }
}

foreach ($key in @($modules.Keys | Sort-Object)) {
    # Downloads only the version embedded in the built binary, checked against
    # its Go checksum. No latest lookup and no source modification.
    $download = ((& $go mod download -json $key) -join "`n") | ConvertFrom-Json -AsHashtable
    if ($LASTEXITCODE -ne 0 -or $download['Error'] -or !$download['Dir']) { throw "Cannot resolve pinned source: $key" }
    $dependency = $modules[$key]
    if (!$dependency.Sum -or $download.Sum -ne $dependency.Sum) { throw "Embedded/source checksum mismatch: $key" }
    $sourceUrl = 'https://proxy.golang.org/' + ($dependency.Path -creplace '[A-Z]', '!$0').ToLowerInvariant() + '/@v/' + $dependency.Version + '.zip'
    Add-Notice $dependency.Path $dependency.Version $download.Dir 'linked-go-module' $sourceUrl $dependency.Sum
    if ($dependency.Path -eq 'github.com/xtls/xray-core') {
        # Include the exact, unmodified covered source with each native bundle.
        $sourceDirectory = Join-Path $output 'sources'
        New-Item -ItemType Directory -Path $sourceDirectory -Force | Out-Null
        Copy-Item -LiteralPath $download.Zip -Destination (Join-Path $sourceDirectory 'xray-core.zip')
    }
}

$lock = Get-Content -LiteralPath (Join-Path $repository 'scripts/bootstrap/toolchain.lock.json') -Raw | ConvertFrom-Json
Add-SingleNotice 'ExVPN' '0.1.0+1' (Join-Path $repository 'LICENSE') 'https://github.com/Extectick/ExVPN'
Add-SingleNotice 'ExVPN copyright' '0.1.0+1' (Join-Path $repository 'NOTICE')
Add-SingleNotice 'Go runtime' $lock.go.version (Join-Path $repository '.tools/go/LICENSE') 'https://go.dev/LICENSE'
Add-SingleNotice 'Flutter framework' $lock.flutter.version (Join-Path $repository '.tools/flutter/LICENSE') 'https://github.com/flutter/flutter'
Add-SingleNotice 'Dart runtime' $lock.flutter.dartVersion (Join-Path $repository '.tools/flutter/bin/cache/dart-sdk/LICENSE') 'https://github.com/dart-lang/sdk'
if ($Target -eq 'Windows') {
    Add-SingleNotice 'Flutter Windows engine' $lock.flutter.revision (Join-Path $repository '.tools/flutter/bin/cache/artifacts/engine/windows-x64/license.windows_flutter.md')
    $wintun = Get-Content -LiteralPath (Join-Path $repository 'scripts/windows/wintun.lock.json') -Raw | ConvertFrom-Json
    Add-SingleNotice 'Wintun prebuilt DLL' $wintun.version (Join-Path $repository 'artifacts/windows/Wintun-LICENSE.txt') $wintun.source
} else {
    foreach ($abi in @('android-arm64', 'android-x64')) {
        Add-SingleNotice "Flutter engine $abi" $lock.flutter.revision (Join-Path $repository ".tools/flutter/bin/cache/artifacts/engine/$abi/license.flutter_jar_zip.md")
    }
}
Add-SingleNotice 'Inter font' 'SHA256:29160a80ff49ddcab2c97711247e08b1fab27a484a329ce8b813d820dc559031' (Join-Path $repository 'apps/exvpn/assets/fonts/OFL.txt')
Add-SingleNotice 'Material Icons' $lock.flutter.version (Join-Path $repository 'apps/exvpn/assets/licenses/MaterialIcons.txt')
Add-SingleNotice 'Cupertino Icons' '1.0.9' (Join-Path $repository 'apps/exvpn/assets/licenses/CupertinoIcons.txt')

# A conservative superset from pub's resolved graph includes development-only
# packages too. Native binary modules above are exact; this is not a full SBOM.
$packageConfig = Get-Content -LiteralPath (Join-Path $repository 'apps/exvpn/.dart_tool/package_config.json') -Raw | ConvertFrom-Json
$configUri = [Uri]::new((Join-Path $repository 'apps/exvpn/.dart_tool/package_config.json'))
foreach ($package in $packageConfig.packages) {
    $packageRoot = [Uri]::new($configUri, $package.rootUri).LocalPath
    if (!$packageRoot.StartsWith((Join-Path $repository '.tools/cache/pub/hosted/'), [StringComparison]::OrdinalIgnoreCase)) { continue }
    $spec = Get-Content -LiteralPath (Join-Path $packageRoot 'pubspec.yaml') -Raw
    $versionMatch = [regex]::Match($spec, '(?m)^version:\s*([^\s#]+)')
    if (!$versionMatch.Success) { throw "Missing resolved package version: $($package.name)" }
    Add-Notice $package.name $versionMatch.Groups[1].Value.Trim("'", '"') $packageRoot 'resolved-dart-package' "https://pub.dev/packages/$($package.name)"
}

Copy-Item -LiteralPath (Join-Path $repository 'apps/exvpn/assets/SOURCES.md') -Destination (Join-Path $output 'ASSET_SOURCES.md')
$manifest = [ordered]@{ schema = 1; target = $Target; nativeBinaries = $binaryEvidence.ToArray(); components = $components.ToArray(); limitations = @('Dart list conservatively includes resolved development packages.', 'Android Gradle/Maven and installer components require their own release inventory.', 'This inventory does not assert release acceptance or code signing.') }
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $output 'inventory.json') -Encoding utf8NoBOM
@'
ExVPN third-party notices

inventory.json maps component names, pinned versions and file hashes to the
included full notices. It also records hashes and embedded module versions of
the inspected native binaries. Dart entries conservatively include development
dependencies. This document is not a complete Gradle/installer SBOM.

The exact unmodified Xray module source is included as sources/xray-core.zip.
Xray is licensed under MPL-2.0; the ExVPN Apache-2.0 license does not replace it.
The signed Wintun DLL uses its own Prebuilt Binaries License, separately from
the MIT Go binding. Full upstream license texts are preserved here.

ExVPN source and build instructions: https://github.com/Extectick/ExVPN
'@ | Set-Content -LiteralPath (Join-Path $output 'README.txt') -Encoding utf8NoBOM
Write-Host "Collected $($components.Count) component notices for $Target at $output."
