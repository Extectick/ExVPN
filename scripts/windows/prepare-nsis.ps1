[CmdletBinding()]
param([switch]$Offline)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$pin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'nsis.lock.json') -Raw | ConvertFrom-Json
$archive = Join-Path $repository ".cache/nsis-$($pin.version).zip"
$tool = Join-Path $repository ".tools/nsis-$($pin.version)"
if (!(Test-Path -LiteralPath $archive)) {
    if ($Offline) { throw 'Pinned NSIS archive is missing in offline mode.' }
    New-Item -ItemType Directory -Force -Path (Split-Path $archive) | Out-Null
    Invoke-WebRequest -Uri $pin.url -OutFile $archive -TimeoutSec 120
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pin.sha256) { throw 'NSIS archive checksum mismatch.' }
if (!(Test-Path -LiteralPath (Join-Path $tool 'makensis.exe'))) { Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $repository '.tools') }
if ((Get-FileHash -LiteralPath (Join-Path $tool 'makensis.exe') -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pin.compilerSha256) { throw 'NSIS compiler checksum mismatch.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    foreach ($entry in $zip.Entries) {
        if (!$entry.Name) { continue }
        $target = [IO.Path]::GetFullPath((Join-Path (Join-Path $repository '.tools') $entry.FullName))
        if (!$target.StartsWith($tool + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'NSIS archive escaped the pinned tool directory.' }
        $stream = $entry.Open(); $sha = [Security.Cryptography.SHA256]::Create()
        try { $expected = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant() } finally { $stream.Dispose(); $sha.Dispose() }
        if (!(Test-Path -LiteralPath $target -PathType Leaf) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'Expanded NSIS SDK differs from its pinned archive.' }
    }
} finally { $zip.Dispose() }
Write-Host "NSIS $($pin.version) verified. No system installation performed."
