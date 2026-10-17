# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$Offline,
    [string]$ArchivePath = '',
    [string]$OutputDirectory = '',
    [string]$DumpbinPath = ''
)
$ErrorActionPreference = 'Stop'

function Assert-CiMsvcNoLinks([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    if ($current -notmatch '^[A-Za-z]:[\\/]') { throw 'msvc_ci_local_path_required' }
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'msvc_ci_reparse_path' }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Assert-CiMsvcArchive([string]$Path, $SourcePin) {
    Assert-CiMsvcNoLinks $Path
    if (!(Test-Path -LiteralPath $Path -PathType Leaf) -or
        (Get-Item -LiteralPath $Path).Length -ne $SourcePin.bytes -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $SourcePin.sha256) { throw 'msvc_ci_archive_mismatch' }
}

function Save-CiMsvcArchive([string]$Path, $SourcePin, [bool]$Offline) {
    Assert-CiMsvcNoLinks $Path
    if (!(Test-Path -LiteralPath $Path)) {
        if ($Offline) { throw 'msvc_ci_archive_missing_offline' }
        New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
        Assert-CiMsvcNoLinks (Split-Path $Path)
        # No redirect to another origin, installation, global cache or environment changes.
        $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.partial'
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $client = [Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(60)
        $cancel = [Threading.CancellationTokenSource]::new(60000)
        $response = $null; $inputStream = $null; $outputStream = $null
        try {
            $response = $client.GetAsync([uri]$SourcePin.url, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token).GetAwaiter().GetResult()
            if ([int]$response.StatusCode -ne 200) { throw 'msvc_ci_download_status' }
            if ($null -ne $response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -ne $SourcePin.bytes) { throw 'msvc_ci_download_size' }
            $inputStream = $response.Content.ReadAsStreamAsync($cancel.Token).GetAwaiter().GetResult()
            $outputStream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $buffer = [byte[]]::new(65536); [long]$total = 0
            while (($read = $inputStream.ReadAsync($buffer, 0, $buffer.Length, $cancel.Token).GetAwaiter().GetResult()) -gt 0) {
                $total += $read
                if ($total -gt $SourcePin.bytes) { throw 'msvc_ci_download_size' }
                $outputStream.Write($buffer, 0, $read)
            }
            if ($total -ne $SourcePin.bytes) { throw 'msvc_ci_download_size' }
        } finally {
            if ($outputStream) { $outputStream.Dispose() }
            if ($inputStream) { $inputStream.Dispose() }
            if ($response) { $response.Dispose() }
            $cancel.Dispose(); $client.Dispose(); $handler.Dispose()
        }
        Assert-CiMsvcArchive $temporary $SourcePin
        [IO.File]::Move($temporary, $Path)
    }
    # A cache hit or previously expanded directory is never sufficient proof.
    Assert-CiMsvcArchive $Path $SourcePin
}

function Expand-CiMsvcArchive([string]$Archive, [string]$Destination, $Pin, [string]$EntryPrefix) {
    Assert-CiMsvcNoLinks $Destination
    if (Test-Path -LiteralPath $Destination) { throw 'msvc_ci_output_exists' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $entries = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        [long]$total = 0
        if ($zip.Entries.Count -gt 256) { throw 'msvc_ci_archive_entry_count' }
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if (!$name -or $name -match '[\\:\x00-\x1f]' -or $name.StartsWith('/') -or
                @($name.Split('/') | Where-Object { $_ -in @('.', '..') }).Count -gt 0 -or
                $entries.ContainsKey($name)) { throw 'msvc_ci_archive_path_or_duplicate' }
            if ($entry.Length -gt 16MB) { throw 'msvc_ci_archive_size' }
            $total += $entry.Length
            if ($total -gt 32MB) { throw 'msvc_ci_archive_size' }
            $entries.Add($name, $entry)
        }
        foreach ($record in $Pin.files) {
            if ($record.file -cnotmatch '^(msvcp140|vcruntime140|vcruntime140_1)\.dll$') { throw 'msvc_ci_runtime_filename' }
            $expected = $EntryPrefix + $record.file
            if (!$entries.ContainsKey($expected) -or $entries[$expected].FullName -cne $expected -or $entries[$expected].Length -eq 0) { throw 'msvc_ci_runtime_entry_missing' }
        }
        New-Item -ItemType Directory -Path $Destination | Out-Null
        foreach ($record in $Pin.files) {
            # Only these exact release entries become files. Debug and other VSIX contents are not extracted.
            $entry = $entries[$EntryPrefix + $record.file]
            $target = Join-Path $Destination $record.file
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target)
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $record.sha256) { throw 'msvc_ci_extracted_hash_mismatch' }
        }
    } finally { $zip.Dispose() }
}

function Assert-CiMsvcRuntime([string]$Directory, $Pin) {
    Assert-CiMsvcNoLinks $Directory
    $files = @(Get-ChildItem -LiteralPath $Directory -Force)
    if ($files.Count -ne 3 -or @($Pin.files).Count -ne 3 -or @($Pin.files.file | Sort-Object -Unique).Count -ne 3) { throw 'msvc_ci_runtime_membership' }
    foreach ($record in $Pin.files) {
        if ($record.file -cnotmatch '^(msvcp140|vcruntime140|vcruntime140_1)\.dll$') { throw 'msvc_ci_runtime_filename' }
        $path = Join-Path $Directory $record.file
        Assert-CiMsvcNoLinks $path
        if (!(Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $record.sha256 -or
            (Get-Item -LiteralPath $path).VersionInfo.FileVersion -cne $Pin.fileVersion) { throw 'msvc_ci_runtime_mismatch' }
        $signature = Get-AuthenticodeSignature -FilePath $path
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') { throw 'msvc_ci_runtime_signature' }
    }
}

function Get-CiMsvcDumpbin([string]$ExplicitPath, $Pin) {
    $path = $ExplicitPath
    if (!$path) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
        $instances = @(& $vswhere -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json | ConvertFrom-Json | Where-Object { !$_.isPrerelease })
        if ($LASTEXITCODE -ne 0) { throw 'msvc_ci_vswhere_failed' }
        $candidates = @(
            foreach ($instance in $instances) {
                $tools = Join-Path $instance.installationPath 'VC/Tools/MSVC'
                if (!(Test-Path -LiteralPath $tools)) { continue }
                foreach ($version in Get-ChildItem -LiteralPath $tools -Directory | Sort-Object Name -Descending) {
                    $candidate = Join-Path $version.FullName 'bin/Hostx64/x64/dumpbin.exe'
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidate }
                }
            }
        )
        if (!$candidates.Count) { throw 'msvc_ci_dumpbin_missing' }
        $path = $candidates[0]
    }
    $path = [IO.Path]::GetFullPath($path)
    Assert-CiMsvcNoLinks $path
    $file = Get-Item -LiteralPath $path
    $signature = Get-AuthenticodeSignature -FilePath $path
    if ($file.Name -ine 'dumpbin.exe' -or $file.VersionInfo.OriginalFilename -ine 'dumpbin.exe' -or
        $signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') { throw 'msvc_ci_dumpbin_identity' }
    return $path
}

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$pin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'msvc-runtime.lock.json') -Raw | ConvertFrom-Json
$sourcePin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'msvc-runtime-ci.lock.json') -Raw | ConvertFrom-Json
$uri = [uri]$sourcePin.url
if ($sourcePin.format -ne 1 -or $sourcePin.runtimeFileVersion -cne $pin.fileVersion -or
    $sourcePin.entryPrefix -cne ('Contents/' + $pin.sourceRelativePath + '/') -or
    $uri.Scheme -cne 'https' -or $uri.Host -cne 'download.visualstudio.microsoft.com' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
    $sourcePin.archiveFile -cnotmatch '^[A-Za-z0-9._-]+\.vsix$' -or
    $sourcePin.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $sourcePin.bytes -le 0 -or $sourcePin.bytes -gt 16MB) { throw 'msvc_ci_source_pin_invalid' }
if (!$ArchivePath) { $ArchivePath = Join-Path $repository ('.tools/downloads/' + $sourcePin.archiveFile) }
if (!$OutputDirectory) { $OutputDirectory = Join-Path $repository ('.tools/msvc-runtime-' + $pin.fileVersion) }
$ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$inspector = Get-CiMsvcDumpbin $DumpbinPath $pin
Save-CiMsvcArchive $ArchivePath $sourcePin ([bool]$Offline)
Assert-CiMsvcNoLinks $OutputDirectory
if (!(Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path (Split-Path $OutputDirectory) -Force | Out-Null
    $staging = $OutputDirectory + '.stage-' + [Guid]::NewGuid().ToString('N')
    Expand-CiMsvcArchive $ArchivePath $staging $pin $sourcePin.entryPrefix
    Assert-CiMsvcRuntime $staging $pin
    # Unique staging is retained on failure. Publication never overwrites another output.
    [IO.Directory]::Move($staging, $OutputDirectory)
}
Assert-CiMsvcRuntime $OutputDirectory $pin
Write-Host "Pinned MSVC runtime $($pin.fileVersion) verified from Microsoft VSIX; no system installation."
[pscustomobject]@{
    RuntimeDirectory = $OutputDirectory
    DumpbinPath = $inspector
    FileVersion = $pin.fileVersion
    ArchiveSha256 = $sourcePin.sha256
    DumpbinSha256 = (Get-FileHash -LiteralPath $inspector -Algorithm SHA256).Hash.ToLowerInvariant()
    DumpbinVersion = (Get-Item -LiteralPath $inspector).VersionInfo.FileVersion
}
