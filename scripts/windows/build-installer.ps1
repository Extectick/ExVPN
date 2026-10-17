#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$NoticesDirectory = '', [switch]$Offline,
    [string]$UiDirectory = '',
    [string]$RuntimeDirectory = '',
    [string]$DumpbinPath = '',
    [ValidateSet('ordinary','shorebird')][string]$FlutterRuntime = 'ordinary'
)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'installer/package-common.ps1')
& (Join-Path $PSScriptRoot 'prepare-nsis.ps1') -Offline:$Offline
$pin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'nsis.lock.json') -Raw | ConvertFrom-Json
$pubspec = Get-Content -LiteralPath (Join-Path $repository 'apps/exvpn/pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') { throw 'Application SemVer/build is missing.' }
$version, $build = $Matches[1], [int]$Matches[2]
$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
$output = Join-Path $repository "artifacts/windows/package-$version-$build-$stamp"
$payload = Join-Path $output 'payload'
New-Item -ItemType Directory -Path $payload | Out-Null
function Copy-BuildTree([string]$Source,[string]$Destination) {
    New-Item -ItemType Directory -Path $Destination | Out-Null
    foreach ($file in Get-PackageTree $Source | Where-Object { !$_.PSIsContainer }) {
        $relative = $file.FullName.Substring([IO.Path]::GetFullPath($Source).TrimEnd('\').Length + 1)
        $target = Get-OwnedPath $Destination $relative
        New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
    }
}
$ui = if ($UiDirectory) { [IO.Path]::GetFullPath($UiDirectory) } else { Join-Path $repository 'apps/exvpn/build/windows/x64/runner/Release' }
if (!(Test-Path -LiteralPath (Join-Path $ui 'exvpn.exe'))) { throw 'Build Flutter Windows release first.' }
Copy-BuildTree $ui (Join-Path $payload 'ui')
& (Join-Path $PSScriptRoot 'prepare-msvc-runtime.ps1') -UiDirectory (Join-Path $payload 'ui') -RuntimeDirectory $RuntimeDirectory -DumpbinPath $DumpbinPath
New-Item -ItemType Directory -Path (Join-Path $payload 'service'),(Join-Path $payload 'control') | Out-Null
foreach ($name in @('exvpn-service.exe','wintun.dll','Wintun-LICENSE.txt')) { Copy-Item -LiteralPath (Join-Path $repository "artifacts/windows/$name") -Destination (Join-Path $payload "service/$name") }
$wintunPin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'wintun.lock.json') -Raw | ConvertFrom-Json
if ((Get-FileHash -LiteralPath (Join-Path $payload 'service/wintun.dll') -Algorithm SHA256).Hash.ToLowerInvariant() -ne $wintunPin.dllSha256) { throw 'Wintun mismatch.' }
foreach ($name in @('package.ps1','package-common.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot "installer/$name") -Destination (Join-Path $payload "control/$name") }
Copy-Item -LiteralPath (Join-Path $repository 'LICENSE'),(Join-Path $repository 'NOTICE'),(Join-Path $repository 'native/windows/INSTALLER.md') -Destination (Join-Path $payload 'control')
Copy-Item -LiteralPath (Join-Path $repository 'native/windows/licenses/NSIS-3.13.txt') -Destination (Join-Path $payload 'control')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'nsis.lock.json') -Destination (Join-Path $payload 'control')
foreach ($name in @('Microsoft-Visual-Studio-2026-Community.txt','MSVC-REDISTRIBUTION.md')) { Copy-Item -LiteralPath (Join-Path $repository "native/windows/licenses/$name") -Destination (Join-Path $payload 'control') }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'msvc-runtime.lock.json') -Destination (Join-Path $payload 'control')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'installer/runtime-terms.txt') -Destination (Join-Path $payload 'control')
if ($NoticesDirectory) { Copy-BuildTree ([IO.Path]::GetFullPath($NoticesDirectory)) (Join-Path $payload 'control/notices') }
else {
    $previousProxy,$previousSum = $env:GOPROXY,$env:GOSUMDB
    try {
        if ($Offline) { $env:GOPROXY='off'; $env:GOSUMDB='off' }
        & (Join-Path $repository 'scripts/release/collect-notices.ps1') -Target Windows `
            -NativeBinaries (Join-Path $payload 'service/exvpn-service.exe') `
            -WintunLicensePath (Join-Path $payload 'service/Wintun-LICENSE.txt') `
            -FlutterRuntime $FlutterRuntime -FlutterBuildMode release `
            -OutputDirectory (Join-Path $payload 'control/notices')
    } finally { $env:GOPROXY=$previousProxy; $env:GOSUMDB=$previousSum }
}
. (Join-Path $repository 'scripts/release/notice-inputs.ps1')
$noticesInventory = Get-Content -LiteralPath (Join-Path $payload 'control/notices/inventory.json') -Raw | ConvertFrom-Json
$nativeHashes = @{ 'service/exvpn-service.exe' = (Get-FileHash -LiteralPath (Join-Path $payload 'service/exvpn-service.exe') -Algorithm SHA256).Hash.ToLowerInvariant() }
Assert-NoticePackageBinding $noticesInventory "$version+$build" `
    (Get-FileHash -LiteralPath (Join-Path $repository 'apps/exvpn/pubspec.lock') -Algorithm SHA256).Hash.ToLowerInvariant() $nativeHashes
. (Join-Path $repository 'scripts/release/artifact-audit-lib.ps1')
. (Join-Path $repository 'scripts/release/flutter-runtime-inputs.ps1')
$runtime = Get-ReleaseFlutterRuntime -Repository $repository -Target Windows -FlutterRuntime $FlutterRuntime -FlutterBuildMode release
Assert-ReleaseFlutterNotices $noticesInventory $runtime.Evidence
$metadata = [ordered]@{ format=1; version=$version; build=$build; installer=$pin; development=$true; trees=[ordered]@{} }
$metadata.flutterRuntime = Get-ReleasePackagedFlutterEvidence $runtime.Evidence (Get-AuditTreeFiles $payload) -RequireByteMatch
foreach ($tree in @('ui','service','control')) { $metadata.trees[$tree] = @(Get-TreeManifest (Join-Path $payload $tree)) }
$metadata | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath (Join-Path $payload 'package.json') -Encoding utf8
& (Join-Path $PSScriptRoot 'installer/package.ps1') -Action Inspect -PayloadRoot $payload

# Emit a fixed file list. No installer/uninstaller uses recursive deletion or
# accepts a user-selected installation root.
$include = [Collections.Generic.List[string]]::new()
$include.Add('!macro ExtractPayload')
$files = @(Get-PackageTree $payload | Where-Object { !$_.PSIsContainer })
foreach ($file in $files) {
    $relative = $file.FullName.Substring($payload.Length+1)
    if ($relative -match '["$\r\n]') { throw 'NSIS path contains unsupported characters.' }
    $parent = [IO.Path]::GetDirectoryName($relative)
    $include.Add('SetOutPath "$Stage\' + $parent + '"')
    $include.Add('File "' + $file.FullName + '"')
}
$include.Add('!macroend')
$include.Add('!macro ExtractMaintenance')
$include.Add('SetOutPath "$Stage\control"')
foreach ($name in @('package.ps1','package-common.ps1')) { $include.Add('File "' + (Join-Path $payload "control/$name") + '"') }
$include.Add('!macroend')
$include.Add('!macro RemoveStaging')
foreach ($file in $files) { $include.Add('Delete "$Stage\' + $file.FullName.Substring($payload.Length+1) + '"') }
$include.Add('Delete "$Stage\Uninstall.exe"')
foreach ($dir in Get-PackageTree $payload | Where-Object PSIsContainer | Sort-Object { $_.FullName.Length } -Descending) { $include.Add('RMDir "$Stage\' + $dir.FullName.Substring($payload.Length+1) + '"') }
$include.Add('RMDir "$Stage"')
$include.Add('!macroend')
$generated = Join-Path $output 'payload-files.nsh'
$include | Set-Content -LiteralPath $generated -Encoding utf8
$installer = Join-Path $output "ExVPN-$version-$build-windows-x64-development.exe"
$compiler = Join-Path $repository ".tools/nsis-$($pin.version)/makensis.exe"
$previousNsisDirectory = $env:NSISDIR
try {
    $env:NSISDIR = Split-Path $compiler
    # Ignore user/global NSIS configuration; includes/plugins/stubs must come
    # exclusively from the verified pinned SDK. Warnings fail the build.
    & $compiler /NOCONFIG /WX /INPUTCHARSET UTF8 /V3 "/DOUTPUT_FILE=$installer" "/DPRODUCT_VERSION=$version.$build" "/DDISPLAY_VERSION=$version+$build" "/DICON_FILE=$(Join-Path $repository 'apps/exvpn/windows/runner/resources/app_icon.ico')" "/DLICENSE_FILE=$(Join-Path $repository 'LICENSE')" "/DRUNTIME_TERMS_FILE=$(Join-Path $PSScriptRoot 'installer/runtime-terms.txt')" "/DGENERATED_INCLUDE=$generated" (Join-Path $PSScriptRoot 'installer/exvpn.nsi')
    if ($LASTEXITCODE -ne 0) { throw 'NSIS compilation failed; payload retained for review.' }
} finally { $env:NSISDIR = $previousNsisDirectory }
$hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
[ordered]@{ file=[IO.Path]::GetFileName($installer); sha256=$hash; nsis=$pin.version; version=$version; build=$build; signed=$false; systemTested=$false } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'artifact.json') -Encoding utf8
Write-Host "Compiled unsigned controlled-test installer: $installer"
