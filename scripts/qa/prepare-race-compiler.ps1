# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$pinPath = Join-Path $PSScriptRoot 'race-compiler.lock.json'
$pin = Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json
if ($pin.schemaVersion -ne 1 -or $pin.name -cne 'w64devkit' -or
    $pin.target -cne 'windows-amd64' -or $pin.version -cnotmatch '^\d+\.\d+\.\d+$' -or
    $pin.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
    $pin.url -cne "https://github.com/skeeto/w64devkit/releases/download/v$($pin.version)/w64devkit-x64-$($pin.version).7z.exe") {
    throw 'Invalid pinned race-test compiler.'
}
$toolRoot = Join-Path $repository ".tools/w64devkit-$($pin.version)"
$compiler = Join-Path $toolRoot 'w64devkit/bin/gcc.exe'
$marker = Join-Path $toolRoot 'exvpn-source.sha256'
if (!(Test-Path -LiteralPath $compiler -PathType Leaf)) {
    if ((Test-Path -LiteralPath $toolRoot) -and @(Get-ChildItem -LiteralPath $toolRoot -Force).Count) {
        throw 'Incomplete compiler directory; preserve it and inspect before retrying.'
    }
    $downloadRoot = Join-Path $repository '.tools/downloads'
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
    $archive = Join-Path $downloadRoot "w64devkit-x64-$($pin.version).7z.exe"
    if (!(Test-Path -LiteralPath $archive -PathType Leaf)) {
        $temporary = "$archive.$([Guid]::NewGuid().ToString('N')).download"
        Invoke-WebRequest -Uri $pin.url -OutFile $temporary -TimeoutSec 120
        if ((Get-Item -LiteralPath $temporary).Length -ne $pin.size -or
            (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pin.sha256) {
            throw 'Downloaded compiler archive differs from the committed pin.'
        }
        [IO.File]::Move($temporary, $archive, $false)
    }
    if ((Get-Item -LiteralPath $archive).Length -ne $pin.size -or
        (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pin.sha256) {
        throw 'Cached compiler archive differs from the committed pin.'
    }
    New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
    # Windows' libarchive-based tar reads the verified 7z SFX as an archive;
    # the downloaded executable is never run. No registry or PATH changes.
    $tar = Join-Path $env:SystemRoot 'System32/tar.exe'
    $entries = @(& $tar -tf $archive)
    if ($LASTEXITCODE -ne 0 -or !$entries.Count) { throw 'Cannot list compiler archive.' }
    foreach ($entry in $entries) {
        if ($entry -cnotmatch '^w64devkit/' -or $entry.Contains('\') -or $entry.Contains(':') -or
            $entry -match '(?:^|/)\.\.?(?:/|$)') { throw 'Unsafe compiler archive path.' }
    }
    & $tar -xf $archive -C $toolRoot
    if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $compiler -PathType Leaf)) {
        throw 'Pinned race-test compiler extraction failed.'
    }
    [IO.File]::WriteAllText($marker, $pin.sha256)
}
if (!(Test-Path -LiteralPath $marker -PathType Leaf) -or
    (Get-Content -LiteralPath $marker -Raw).Trim() -cne $pin.sha256) {
    throw 'Compiler source marker does not match the current pin.'
}
$synchronization = (& $compiler --print-file-name libsynchronization.a) -join ''
if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $synchronization -PathType Leaf)) {
    throw 'Compiler does not provide the mingw-w64 synchronization runtime required by Go race tests.'
}
# A path is returned for a caller to use as its process-local CC setting.
$compiler
