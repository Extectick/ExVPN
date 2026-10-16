#requires -Version 7.0
[CmdletBinding()]
param([string]$OutputDirectory = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'android-notice-inputs.ps1')
if (!$OutputDirectory) { $OutputDirectory = Join-Path $repository ('artifacts/android-package-inputs/inputs-' + [Guid]::NewGuid().ToString('N')) }
$output = [IO.Path]::GetFullPath($OutputDirectory)
$allowed = [IO.Path]::GetFullPath((Join-Path $repository 'artifacts/android-package-inputs')) + [IO.Path]::DirectorySeparatorChar
if (!$output.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $output)) { throw 'Choose a new directory under artifacts/android-package-inputs. Existing inputs are preserved.' }
$parent = [IO.Path]::GetDirectoryName($output)
while (!(Test-Path -LiteralPath $parent)) { $parent = [IO.Path]::GetDirectoryName($parent) }
Assert-AuditNoLinks $parent
New-Item -ItemType Directory -Path $output | Out-Null
$binaries = @()
foreach ($abi in @('arm64-v8a', 'x86_64')) {
    $source = Join-Path $repository ".tools/artifacts/android-jni/$abi/libexvpn.so"
    Assert-AuditNoLinks $source
    $destination = Join-Path $output "jniLibs/$abi/libexvpn.so"
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination
    $binaries += $destination
}
$bundle = Join-Path $output 'assets/exvpn_notices'
$previousProxy = $env:GOPROXY
$previousSumDb = $env:GOSUMDB
try {
    # Offline collection uses existing pinned caches. Archive/native checksums
    # remain mandatory; a cache miss is an explicit failure, not a download.
    $env:GOPROXY = 'off'
    $env:GOSUMDB = 'off'
    & (Join-Path $PSScriptRoot 'collect-notices.ps1') -Target Android -NativeBinaries $binaries -OutputDirectory $bundle
    if (!$?) { throw 'Android notice collection failed.' }
} finally {
    $env:GOPROXY = $previousProxy
    $env:GOSUMDB = $previousSumDb
}
$state = Get-AndroidNoticeSnapshotState $repository $output
Assert-AndroidNoticeNativeInfo $repository $output
Write-AuditJson (Join-Path $output 'seal.json') $state
Assert-AndroidNoticeSeal $repository $output
[pscustomobject]@{
    InputDirectory = $output
    AppVersion = $state.appVersion
    SealSha256 = Get-AuditSha256 (Join-Path $output 'seal.json')
    AssetFiles = $state.assetFiles.Count
    NativeBinaries = $state.nativeFiles.Count
}
