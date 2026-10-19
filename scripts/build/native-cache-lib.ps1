# SPDX-License-Identifier: Apache-2.0
# Finished native outputs are an optimization, never a trust or release gate.
#requires -Version 7.0
Set-StrictMode -Version Latest

function Get-NativeCacheGoTools([string]$GoPath, [switch]$Cgo) {
    $root = Split-Path (Split-Path ([IO.Path]::GetFullPath($GoPath)))
    $paths = @($GoPath)
    foreach ($name in @('compile.exe','link.exe','asm.exe')) { $paths += Join-Path $root ('pkg/tool/windows_amd64/' + $name) }
    if ($Cgo) { $paths += Join-Path $root 'pkg/tool/windows_amd64/cgo.exe' }
    return $paths
}

function Assert-NativeCacheNoLinks([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'native_cache_link' }
            if (!$item.PSIsContainer -and $IsWindows) {
                if (!('ExvpnNativeCacheIdentity' -as [type])) {
                    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class ExvpnNativeCacheIdentity {
  [StructLayout(LayoutKind.Sequential)] private struct Info {
    public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh,
      WriteLow, WriteHigh, Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
  }
  [DllImport("kernel32.dll", SetLastError=true)]
  private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
  public static bool SingleLink(SafeFileHandle handle) {
    Info info; return GetFileInformationByHandle(handle, out info) && info.Links == 1;
  }
}
'@
                }
                $stream = [IO.File]::Open($cursor, 'Open', 'Read', 'Read')
                try { if (![ExvpnNativeCacheIdentity]::SingleLink($stream.SafeFileHandle)) { throw 'native_cache_hardlink' } }
                finally { $stream.Dispose() }
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -ceq $cursor) { break }; $cursor = $parent
    }
}

function Get-NativeCacheFileRecord([string]$Path, [string]$Name, [switch]$AllowEmpty) {
    Assert-NativeCacheNoLinks $Path
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or $item.Length -lt 0 -or (!$AllowEmpty -and $item.Length -eq 0)) { throw 'native_cache_invalid_file' }
    [ordered]@{ file=$Name; bytes=$item.Length; sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
}

function Get-NativeCacheIdentity {
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters,
        [Parameter(Mandatory)][string[]]$Tools)
    if ($Target -cnotmatch '^[a-z0-9_-]{1,64}$') { throw 'native_cache_invalid_target' }
    Assert-NativeCacheNoLinks $Repository
    # Include tracked and nonignored untracked inputs; no app identity is used.
    $paths = (& git -C $Repository -c core.quotepath=false ls-files --cached --others --exclude-standard -- native scripts/core scripts/bootstrap scripts/build scripts/windows/build.ps1)
    if ($LASTEXITCODE -ne 0) { throw 'native_cache_source_inventory_failed' }
    $paths = @($paths | Sort-Object -Unique -CaseSensitive)
    foreach ($required in @('native/core/go.mod','native/android/build.ps1','scripts/windows/build.ps1',
        'scripts/bootstrap/toolchain.lock.json','scripts/build/native-cache-lib.ps1')) {
        if ($required -cnotin $paths) { throw 'native_cache_source_inventory_missing' }
    }
    $records = @()
    foreach ($relative in $paths) {
        if ($relative -match '[\r\n"]' -or $relative.StartsWith('/') -or $relative.Contains('..') -or $relative.Contains('\')) { throw 'native_cache_invalid_source_path' }
        $path = [IO.Path]::GetFullPath((Join-Path $Repository $relative))
        if (!$path.StartsWith([IO.Path]::GetFullPath($Repository).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'native_cache_source_outside_repository' }
        $records += Get-NativeCacheFileRecord $path $relative -AllowEmpty
    }
    $toolRecords = @(); $index = 0
    foreach ($tool in $Tools) { $toolRecords += Get-NativeCacheFileRecord $tool ('tool-' + $index++ ) }
    $sortedParameters = [ordered]@{}
    foreach ($key in @($Parameters.Keys | Sort-Object -CaseSensitive)) { $sortedParameters[$key] = $Parameters[$key] }
    $input = [ordered]@{ schema=1; target=$Target; parameters=$sortedParameters; sources=$records; tools=$toolRecords }
    $json = $input | ConvertTo-Json -Depth 12 -Compress
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
    [pscustomobject]@{ key=$hash; target=$Target; sourceCount=$records.Count }
}

function Assert-NativeCacheNames([string[]]$Names) {
    if (!$Names.Count -or $Names.Count -gt 8 -or @($Names | Select-Object -Unique).Count -ne $Names.Count) { throw 'native_cache_output_names_invalid' }
    foreach ($name in $Names) { if ($name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,90}$' -or $name -ceq 'manifest.json') { throw 'native_cache_output_names_invalid' } }
}

function Restore-NativeCachedOutputs {
    param([string]$CacheRoot, $Identity, [string]$OutputDirectory, [string[]]$Names)
    try {
        Assert-NativeCacheNames $Names
        if (!$Identity -or $Identity.key -cnotmatch '^[a-f0-9]{64}$') { return $false }
        $entry = Join-Path $CacheRoot $Identity.key
        Assert-NativeCacheNoLinks $entry
        $manifestPath = Join-Path $entry 'manifest.json'
        Assert-NativeCacheNoLinks $manifestPath
        if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf) -or (Get-Item -LiteralPath $manifestPath).Length -gt 16KB) { return $false }
        $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json -AsHashtable
        if (@($manifest.Keys).Count -ne 4 -or $manifest.schema -ne 1 -or $manifest.key -cne $Identity.key -or $manifest.target -cne $Identity.target -or @($manifest.outputs).Count -ne $Names.Count) { return $false }
        $actualNames = @(Get-ChildItem -LiteralPath $entry -Force | ForEach-Object Name)
        if ($actualNames.Count -ne $Names.Count + 1 -or @($actualNames | Where-Object { $_ -cnotin ($Names + @('manifest.json')) }).Count) { return $false }
        foreach ($name in $Names) {
            $records = @($manifest.outputs | Where-Object { $_.file -ceq $name })
            if ($records.Count -ne 1 -or @($records[0].Keys).Count -ne 3) { return $false }
            $actual = Get-NativeCacheFileRecord (Join-Path $entry $name) $name
            if ($actual.bytes -ne $records[0].bytes -or $actual.sha256 -cne $records[0].sha256) { return $false }
        }
        Assert-NativeCacheNoLinks $OutputDirectory
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
        foreach ($name in $Names) {
            $destination = Join-Path $OutputDirectory $name
            Assert-NativeCacheNoLinks $destination
            Copy-Item -LiteralPath (Join-Path $entry $name) -Destination $destination -Force
            $actual = Get-NativeCacheFileRecord $destination $name
            $expected = @($manifest.outputs | Where-Object { $_.file -ceq $name })[0]
            if ($actual.bytes -ne $expected.bytes -or $actual.sha256 -cne $expected.sha256) { throw 'native_cache_copy_changed' }
        }
        return $true
    } catch { return $false }
}

function Save-NativeCachedOutputs {
    param([string]$CacheRoot, $Identity, [string]$OutputDirectory, [string[]]$Names)
    if (!$Identity) { return }
    $temporary = $null
    try {
        Assert-NativeCacheNames $Names
        if ($Identity.key -cnotmatch '^[a-f0-9]{64}$') { return }
        Assert-NativeCacheNoLinks $CacheRoot
        New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null
        $entry = Join-Path $CacheRoot $Identity.key
        # Immutable entries: corruption causes a rebuild, never overwrites an untrusted tree.
        if (Test-Path -LiteralPath $entry) { return }
        $temporary = Join-Path $CacheRoot ('pending-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temporary | Out-Null
        $records = @()
        foreach ($name in $Names) {
            $source = Join-Path $OutputDirectory $name
            $record = Get-NativeCacheFileRecord $source $name
            Copy-Item -LiteralPath $source -Destination (Join-Path $temporary $name)
            $copy = Get-NativeCacheFileRecord (Join-Path $temporary $name) $name
            if ($copy.bytes -ne $record.bytes -or $copy.sha256 -cne $record.sha256) { throw 'native_cache_copy_changed' }
            $records += $record
        }
        [ordered]@{ schema=1; key=$Identity.key; target=$Identity.target; outputs=$records } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $temporary 'manifest.json') -Encoding utf8
        Move-Item -LiteralPath $temporary -Destination $entry
        $temporary = $null
    } catch {
        Write-Warning 'Native output cache was not saved; normal build output is retained.'
    } finally {
        if ($temporary -and (Test-Path -LiteralPath $temporary)) {
            # Delete only this invocation's fixed files, never recursively follow a tree.
            try {
                Assert-NativeCacheNoLinks $temporary
                foreach ($name in @($Names) + @('manifest.json')) {
                    $path = Join-Path $temporary $name
                    if (Test-Path -LiteralPath $path) { Assert-NativeCacheNoLinks $path; Remove-Item -LiteralPath $path -Force }
                }
                Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue
            } catch { Write-Warning 'Incomplete cache staging retained for inspection.' }
        }
    }
}
