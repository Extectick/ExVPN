#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('All', 'Go', 'Flutter')]
    [string]$Component = 'All'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'This bootstrap currently supports Windows x64 only.'
}

$workspacePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$toolRoot = [IO.Path]::GetFullPath((Join-Path $workspacePath '.tools'))
$downloadRoot = Join-Path $toolRoot 'downloads'
$toolchainLock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'toolchain.lock.json') -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Force -Path $toolRoot, $downloadRoot | Out-Null

function Assert-ToolPath([string]$Path) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($toolRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to operate outside the workspace .tools directory.'
    }
    return $fullPath
}

function Install-PinnedArchive([string]$Name, $Pin) {
    $targetPath = Assert-ToolPath (Join-Path $toolRoot $Pin.folder)
    $archivePath = Assert-ToolPath (Join-Path $downloadRoot $Pin.archive)
    $markerPath = Join-Path $targetPath '.exvpn-toolchain.json'

    if (Test-Path -LiteralPath $targetPath) {
        if (Test-Path -LiteralPath $markerPath) {
            $installed = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            if ($installed.sha256 -ne $Pin.sha256 -or $installed.version -ne $Pin.version) {
                throw "$Name exists with a different pin. Move it aside explicitly before updating."
            }
        } else {
            throw "An unrecognized $Name SDK already exists; it will not be replaced."
        }
        $executablePath = if ($Name -eq 'Go') { Join-Path $targetPath 'bin/go.exe' } else { Join-Path $targetPath 'bin/flutter.bat' }
        if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
            throw "$Name has an install marker but its executable is missing. Inspect the SDK before repairing it."
        }
        Write-Host "$Name $($Pin.version) already installed at $targetPath"
        return
    }

    if (-not (Test-Path -LiteralPath $archivePath)) {
        $partialPath = Assert-ToolPath ($archivePath + '.part')
        Write-Host "Downloading $Name $($Pin.version) from the pinned official URL..."
        & curl.exe --fail --location --retry 2 --connect-timeout 30 --max-time 1800 --silent --show-error --output $partialPath $Pin.url
        if ($LASTEXITCODE -ne 0) { throw "$Name download failed; the installed SDK was not changed." }
        $downloadHash = (Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($downloadHash -ne $Pin.sha256) { throw "$Name download SHA-256 mismatch. The archive will not be executed." }
        Move-Item -LiteralPath $partialPath -Destination $archivePath
    }

    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($archiveHash -ne $Pin.sha256) { throw "$Name cached archive SHA-256 mismatch." }

    $stagingPath = Assert-ToolPath (Join-Path $toolRoot ('staging-' + $Name.ToLowerInvariant() + '-' + [guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $stagingPath | Out-Null
    # Pin verification above is mandatory. ZIP paths are also checked before extraction.
    $zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        foreach ($entry in $zip.Entries) {
            $entryPath = [IO.Path]::GetFullPath((Join-Path $stagingPath $entry.FullName))
            if (-not $entryPath.StartsWith($stagingPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                throw "$Name archive contains an unsafe path."
            }
        }
    } finally { $zip.Dispose() }

    Write-Host "Extracting verified $Name archive..."
    & tar.exe -xf $archivePath -C $stagingPath
    if ($LASTEXITCODE -ne 0) { throw "$Name extraction failed; staging was retained for inspection." }
    $extractedPath = Assert-ToolPath (Join-Path $stagingPath $Pin.folder)
    if (-not (Test-Path -LiteralPath $extractedPath -PathType Container)) { throw "$Name archive layout differs from its pinned layout." }
    # Both resolved paths have been checked to stay inside .tools. Never replace an existing SDK.
    Move-Item -LiteralPath $extractedPath -Destination $targetPath
    $Pin | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $markerPath -Encoding utf8
    Write-Host "Installed $Name $($Pin.version) at $targetPath"
}

if ($Component -in @('All', 'Go')) { Install-PinnedArchive 'Go' $toolchainLock.go }
if ($Component -in @('All', 'Flutter')) { Install-PinnedArchive 'Flutter' $toolchainLock.flutter }
Write-Host 'No machine/user PATH, environment variables, Android SDK, or Java configuration was changed.'
Write-Host 'For this PowerShell process only, run: . ./scripts/bootstrap/enter-environment.ps1'
