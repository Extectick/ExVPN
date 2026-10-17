#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Windows', 'Android')][string]$Target = 'Windows',
    [Parameter(Mandatory)][string[]]$NativeBinaries,
    [string]$WintunLicensePath = '',
    [string]$OutputDirectory = '',
    [ValidateSet('ordinary','shorebird')][string]$FlutterRuntime = 'ordinary',
    [ValidateSet('','debug','release')][string]$FlutterBuildMode = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$collectorEnvironmentNames = @('PATH','GOTOOLCHAIN','GOPATH','GOCACHE','PUB_CACHE','GRADLE_USER_HOME','CI','FLUTTER_SUPPRESS_ANALYTICS','DART_SUPPRESS_ANALYTICS','GOPROXY','GONOSUMDB','GOWORK','ANDROID_HOME','ANDROID_SDK_ROOT','JAVA_HOME')
$collectorEnvironment = @{}
foreach ($name in $collectorEnvironmentNames) { $collectorEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
. (Join-Path $repository 'scripts/bootstrap/enter-environment.ps1')
. (Join-Path $PSScriptRoot 'notice-inputs.ps1')
$go = Join-Path $repository '.tools/go/bin/go.exe'
$lock = Get-Content -LiteralPath (Join-Path $repository 'scripts/bootstrap/toolchain.lock.json') -Raw | ConvertFrom-Json
$runtime = Get-ReleaseFlutterRuntime -Repository $repository -Target $Target -FlutterRuntime $FlutterRuntime -FlutterBuildMode $FlutterBuildMode
. (Join-Path $PSScriptRoot 'shorebird-updater-notices.ps1')
$updaterNotices = Get-ShorebirdUpdaterNotices $repository $runtime
$appVersion = Get-NoticeAppVersion (Get-Content -LiteralPath (Join-Path $repository 'apps/exvpn/pubspec.yaml') -Raw) (Get-Content -LiteralPath (Join-Path $repository 'apps/exvpn/lib/build_identity.dart') -Raw)
$pubLockPath = Join-Path $repository 'apps/exvpn/pubspec.lock'
$packageConfigPath = Join-Path $repository 'apps/exvpn/.dart_tool/package_config.json'
$dartInputs = @(Get-NoticeDartInputs $repository (Get-Content -LiteralPath $pubLockPath -Raw) $packageConfigPath -FlutterSdkRoot $runtime.SdkRoot)
if ($NativeBinaries.Count -ne $(if ($Target -eq 'Windows') { 1 } else { 2 })) { throw 'Supply the exact staged Windows service or both Android ABI libraries.' }
if ($Target -eq 'Windows' -and !(Test-Path -LiteralPath $WintunLicensePath -PathType Leaf)) { throw 'Supply the Wintun license staged with the Windows native payload.' }
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

$modules = @{}
$binaryNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($binaryPathInput in $NativeBinaries) {
    $binaryPath = [IO.Path]::GetFullPath($binaryPathInput)
    if (!(Test-Path -LiteralPath $binaryPath -PathType Leaf)) { throw 'A required staged native binary is missing.' }
    $buildInfo = (& $go version -m -json $binaryPath) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect Go binary build information.' }
    $info = $buildInfo | ConvertFrom-Json -AsHashtable
    if (!$info.Deps.Count) { throw 'Go module build information is missing.' }
    $binary = Get-NoticeBinaryName $Target $info $lock.go.version
    if (!$binaryNames.Add($binary)) { throw 'Duplicate native ABI supplied; one required ABI would be missing.' }
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
    $xrayPatch = $null
    if ($dependency.Path -ceq 'github.com/xtls/xray-core') {
        $xrayPatch = Get-NoticeXrayPatch $repository $dependency.Version $dependency.Sum
        if ($xrayPatch) { $sourceUrl = $xrayPatch.sourceUrl }
    }
    Add-Notice $dependency.Path $dependency.Version $download.Dir 'linked-go-module' $sourceUrl $dependency.Sum
    if ($dependency.Path -eq 'github.com/xtls/xray-core') {
        # Include exactly the covered source linked by this binary. ExVPN's
        # modified prerelease retains the upstream license and patch provenance.
        $sourceDirectory = Join-Path $output 'sources'
        New-Item -ItemType Directory -Path $sourceDirectory -Force | Out-Null
        Copy-Item -LiteralPath $download.Zip -Destination (Join-Path $sourceDirectory 'xray-core.zip')
        if ($xrayPatch) {
            Copy-Item -LiteralPath $xrayPatch.lockPath -Destination (Join-Path $sourceDirectory 'xray-lifecycle.lock.json')
            Copy-Item -LiteralPath $xrayPatch.patchPath -Destination (Join-Path $sourceDirectory 'xray-lifecycle.patch')
            @"
Xray-core contains ExVPN transport-lifecycle modifications.
Upstream commit: $($xrayPatch.upstreamCommit)
Module version: $($xrayPatch.version)
Linked source checksum: $($xrayPatch.moduleSum)
Patch SHA-256: $($xrayPatch.patchSha256)
Covered original and modified files remain under MPL-2.0.
The accompanying xray-core.zip is the complete corresponding module source.
Reconstruction and review instructions: $($xrayPatch.sourceUrl)
"@ | Set-Content -LiteralPath (Join-Path $sourceDirectory 'XRAY-EXVPN-NOTICE.txt') -Encoding utf8NoBOM
        }
    }
}

Add-SingleNotice 'ExVPN' $appVersion (Join-Path $repository 'LICENSE') 'https://github.com/Extectick/ExVPN'
Add-SingleNotice 'ExVPN copyright' $appVersion (Join-Path $repository 'NOTICE')
Add-SingleNotice 'Go runtime' $lock.go.version (Join-Path $repository '.tools/go/LICENSE') 'https://go.dev/LICENSE'
foreach ($notice in $runtime.Evidence.notices) {
    $sourceUrl = if ($notice.name -ceq 'Flutter engine third-party licenses') {
            $repositoryUrl = if ($FlutterRuntime -ceq 'shorebird') { 'https://github.com/shorebirdtech/flutter' } else { 'https://github.com/flutter/flutter' }
            "$repositoryUrl/blob/$($runtime.Identity.flutterRevision)/engine/src/flutter/sky/packages/sky_engine/LICENSE"
        }
        elseif ($notice.name -ceq 'Dart runtime') { 'https://github.com/dart-lang/sdk' }
        elseif ($FlutterRuntime -ceq 'shorebird') { 'https://github.com/shorebirdtech/flutter' }
        else { 'https://github.com/flutter/flutter' }
    Add-SingleNotice $notice.name $notice.version (Join-Path $runtime.SdkRoot $notice.path) $sourceUrl
}
if ($updaterNotices) {
    Add-Notice $updaterNotices.Name $updaterNotices.Version $updaterNotices.SourceRoot 'engine-source-updater' $updaterNotices.SourceUrl
}
if ($Target -eq 'Windows') {
    $wintun = Get-Content -LiteralPath (Join-Path $repository 'scripts/windows/wintun.lock.json') -Raw | ConvertFrom-Json
    Add-SingleNotice 'Wintun prebuilt DLL' $wintun.version $WintunLicensePath $wintun.source
}
Add-SingleNotice 'Inter font' 'SHA256:29160a80ff49ddcab2c97711247e08b1fab27a484a329ce8b813d820dc559031' (Join-Path $repository 'apps/exvpn/assets/fonts/OFL.txt')
Add-SingleNotice 'Material Icons' $lock.flutter.version (Join-Path $repository 'apps/exvpn/assets/licenses/MaterialIcons.txt')
Add-SingleNotice 'Cupertino Icons' '1.0.9' (Join-Path $repository 'apps/exvpn/assets/licenses/CupertinoIcons.txt')

# A conservative superset from pub's resolved graph includes development-only
# packages too. Native binary modules above are exact; this is not a full SBOM.
foreach ($package in $dartInputs) {
    Add-Notice $package.name $package.version $package.root 'resolved-dart-package' "https://pub.dev/packages/$($package.name)"
}

Copy-Item -LiteralPath (Join-Path $repository 'apps/exvpn/assets/SOURCES.md') -Destination (Join-Path $output 'ASSET_SOURCES.md')
$manifest = [ordered]@{
    schema = 1; target = $Target; app = [ordered]@{ version=$appVersion }
    runtime = $runtime.Evidence
    dartLockSha256 = (Get-FileHash -LiteralPath $pubLockPath -Algorithm SHA256).Hash.ToLowerInvariant()
    dartPackageConfigSha256 = (Get-FileHash -LiteralPath $packageConfigPath -Algorithm SHA256).Hash.ToLowerInvariant()
    dartPackages = @($dartInputs | ForEach-Object { [ordered]@{ name=$_.name; version=$_.version; source='hosted'; sha256=$_.archiveSha256 } })
    nativeBinaries = $binaryEvidence.ToArray(); components = $components.ToArray()
    limitations = @('Dart list conservatively includes resolved development packages; it is not a linker inventory.', 'Pub archive checksums are compared with local cache metadata, not a fresh archive/content verification.', 'Android Gradle/Maven and installer components require their own release inventory.', 'This inventory does not assert release acceptance or code signing.')
}
$runtimeAfter = Get-ReleaseFlutterRuntime -Repository $repository -Target $Target -FlutterRuntime $FlutterRuntime -FlutterBuildMode $FlutterBuildMode
Assert-ReleaseFlutterRuntimeEvidence $runtimeAfter.Evidence $runtime.Evidence
Assert-ReleaseFlutterNotices $manifest $runtime.Evidence
$updaterAfter = Get-ShorebirdUpdaterNotices $repository $runtimeAfter
if (((Get-ReleaseRuntimeField $updaterAfter 'Evidence') | ConvertTo-Json -Depth 10 -Compress) -cne ((Get-ReleaseRuntimeField $updaterNotices 'Evidence') | ConvertTo-Json -Depth 10 -Compress)) { throw 'shorebird_updater_inputs_changed' }
if ($updaterNotices) { $manifest.shorebirdUpdater = $updaterNotices.Evidence }
Assert-ShorebirdUpdaterNotices $manifest $updaterNotices $output
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $output 'inventory.json') -Encoding utf8NoBOM
@'
ExVPN third-party notices

inventory.json maps component names, pinned versions and file hashes to the
included full notices. It also records hashes and embedded module versions of
the inspected native binaries. Dart entries conservatively include development
dependencies. This document is not a complete Gradle/installer SBOM.

The exact linked Xray module source is included as sources/xray-core.zip.
For an ExVPN prerelease, sources/ also contains the patch, its pinned metadata,
and XRAY-EXVPN-NOTICE.txt describing the modifications and corresponding source.
Xray is licensed under MPL-2.0; the ExVPN Apache-2.0 license does not replace it.
The signed Wintun DLL uses its own Prebuilt Binaries License, separately from
the MIT Go binding. Full upstream license texts are preserved here.

ExVPN source and build instructions: https://github.com/Extectick/ExVPN
'@ | Set-Content -LiteralPath (Join-Path $output 'README.txt') -Encoding utf8NoBOM
Write-Host "Collected $($components.Count) component notices for $Target at $output."
} finally {
    foreach ($name in $collectorEnvironmentNames) {
        if ($null -eq $collectorEnvironment[$name]) { Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name, $collectorEnvironment[$name], 'Process') }
    }
}
