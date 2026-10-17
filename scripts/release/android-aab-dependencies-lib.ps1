# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'artifact-audit-lib.ps1')

function Assert-AabCoordinate($Value, [switch]$AllowEmpty) {
    if ($Value -isnot [string]) { throw 'aab_coordinate_invalid' }
    if ($AllowEmpty -and $Value -ceq '') { return }
    if ($Value -cin @('.','..') -or $Value -cnotmatch '^[A-Za-z0-9_.-]{1,200}$' -or $Value -imatch 'snapshot|^latest\.') {
        throw 'aab_coordinate_invalid'
    }
}

function Get-AabCacheDirectory([string]$CacheRoot, [string]$Relative) {
    $root = [IO.Path]::GetFullPath($CacheRoot).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $folder = [IO.Path]::GetFullPath((Join-Path $root $Relative))
    if (!$folder.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) { throw 'aab_cache_path_outside_root' }
    $folder
}

function Get-AabPinnedTools([string]$CacheRoot, [string]$PinPath) {
    Assert-AuditNoLinks $CacheRoot
    Assert-AuditNoLinks $PinPath
    $pin = Get-Content -LiteralPath $PinPath -Raw | ConvertFrom-Json -AsHashtable
    if ($pin.schema -ne 1 -or $pin.agpVersion -cne '9.1.0' -or @($pin.tools).Count -ne 3 -or
        $pin.schemaSha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'aab_parser_pin_invalid' }
    $files = [Collections.Generic.List[object]]::new()
    foreach ($tool in $pin.tools) {
        foreach ($value in @($tool.group, $tool.name, $tool.version)) { Assert-AabCoordinate $value }
        if ($tool.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'aab_parser_pin_invalid' }
        $folder = Get-AabCacheDirectory $CacheRoot "$($tool.group)/$($tool.name)/$($tool.version)"
        Assert-AuditNoLinks $folder
        $matches = @(Get-ChildItem -LiteralPath $folder -Recurse -File -Filter "$($tool.name)-$($tool.version).jar")
        if ($matches.Count -ne 1) { throw 'aab_parser_missing_or_ambiguous' }
        Assert-AuditNoLinks $matches[0].FullName
        if ((Get-AuditSha256 $matches[0].FullName) -cne $tool.sha256) { throw 'aab_parser_hash_mismatch' }
        $files.Add([ordered]@{name=$matches[0].Name;path=$matches[0].FullName;sha256=$tool.sha256;size=$matches[0].Length})
    }
    $schema = Read-AuditZipBytes $files[0].path $pin.schemaEntry 64KB
    $schemaHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($schema)).ToLowerInvariant()
    if ($schemaHash -cne $pin.schemaSha256) { throw 'aab_schema_hash_mismatch' }
    [ordered]@{pin=$pin;files=$files.ToArray()}
}

function Get-AabEmbeddedDependencies([string]$AabPath, [string]$ExpectedSha256) {
    if ([IO.Path]::GetExtension($AabPath) -cne '.aab' -or $ExpectedSha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'aab_input_identity_invalid' }
    Assert-AuditNoLinks $AabPath
    if ((Get-AuditSha256 $AabPath) -cne $ExpectedSha256) { throw 'aab_hash_mismatch' }
    # Enumerating the archive also rejects duplicate/case-colliding entries,
    # links, unsafe paths and decompression limits before selecting metadata.
    $files = Get-AuditZipFiles $AabPath
    $entry = 'BUNDLE-METADATA/com.android.tools.build.libraries/dependencies.pb'
    $producerEntry = 'BUNDLE-METADATA/com.android.tools.build.gradle/app-metadata.properties'
    if (!$files.ContainsKey($entry) -or !$files.ContainsKey($producerEntry)) { throw 'aab_dependencies_metadata_missing' }
    $bytes = Read-AuditZipBytes $AabPath $entry 1MB
    if (!$bytes.Length) { throw 'aab_dependencies_metadata_empty' }
    $producer = [Text.UTF8Encoding]::new($false,$true).GetString((Read-AuditZipBytes $AabPath $producerEntry 4KB))
    $versions = [regex]::Matches($producer, '(?m)^androidGradlePluginVersion=([^\r\n]+)\r?$')
    if ($versions.Count -ne 1 -or $versions[0].Groups[1].Value -cne '9.1.0') { throw 'aab_producer_not_pinned' }
    if ((Get-AuditSha256 $AabPath) -cne $ExpectedSha256) { throw 'aab_input_changed' }
    [ordered]@{bytes=$bytes;entry=$entry;metadataSha256=$files[$entry].sha256;producerSha256=$files[$producerEntry].sha256}
}

function Get-AabMavenBindings($Decoded, [string]$CacheRoot, [string]$MetadataSha256) {
    if ($Decoded -isnot [Collections.IDictionary] -or $Decoded.schema -ne 1 -or
        $MetadataSha256 -cnotmatch '^[a-f0-9]{64}$' -or $Decoded.metadataSha256 -cne $MetadataSha256 -or
        @($Decoded.libraries).Count -lt 1 -or @($Decoded.libraries).Count -gt 3000) { throw 'aab_decoded_identity_invalid' }
    Assert-AuditNoLinks $CacheRoot
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $bound = [Collections.Generic.List[object]]::new()
    $unbound = [Collections.Generic.List[object]]::new()
    $inputs = [Collections.Generic.List[object]]::new()
    $expectedIndex = 0
    foreach ($library in $Decoded.libraries) {
        foreach ($value in @($library.group,$library.name,$library.version)) { Assert-AabCoordinate $value }
        foreach ($value in @($library.packaging,$library.classifier)) { Assert-AabCoordinate $value -AllowEmpty }
        $gav = "$($library.group):$($library.name):$($library.version)"
        if (!$seen.Add($gav) -or ($library.index -isnot [int] -and $library.index -isnot [long]) -or
            $library.index -ne $expectedIndex) { throw 'aab_duplicate_or_invalid_library' }
        $expectedIndex++
        if ($null -eq $library.sha256) {
            $unbound.Add([ordered]@{coordinate=$gav;reason='producer_reported_no_file_digest'})
            continue
        }
        if ($library.sha256 -isnot [string] -or $library.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'aab_digest_invalid' }
        if ($library.packaging -cnotin @('','aar','jar')) { throw 'aab_binary_packaging_unsupported' }
        $folder = Get-AabCacheDirectory $CacheRoot "$($library.group)/$($library.name)/$($library.version)"
        if (!(Test-Path -LiteralPath $folder -PathType Container)) { throw 'aab_binary_not_available' }
        Assert-AuditNoLinks $folder
        $stem = "$($library.name)-$($library.version)"
        if ($library.classifier) { $stem += '-' + $library.classifier }
        $extensions = if ($library.packaging) { @($library.packaging) } else { @('aar','jar') }
        $matches = [Collections.Generic.List[object]]::new()
        foreach ($extension in $extensions) {
            foreach ($file in Get-ChildItem -LiteralPath $folder -Recurse -File -Filter "$stem.$extension") {
                Assert-AuditNoLinks $file.FullName
                if ($file.Length -gt 512MB) { throw 'aab_binary_size_limit' }
                if ((Get-AuditSha256 $file.FullName) -ceq $library.sha256) { $matches.Add($file) }
            }
        }
        if ($matches.Count -ne 1) { throw 'aab_binary_hash_missing_or_ambiguous' }
        $file = $matches[0]
        $bound.Add([ordered]@{coordinate=$gav;file=$file.Name;size=$file.Length;sha256=$library.sha256})
        $inputs.Add([ordered]@{path=$file.FullName;sha256=$library.sha256})
    }
    [ordered]@{bound=$bound.ToArray();unbound=$unbound.ToArray();inputs=$inputs.ToArray()}
}

function Invoke-AabParser([string]$JavaPath, [string[]]$JarPaths, [string]$SourcePath, [string[]]$Arguments) {
    Assert-AuditNoLinks $JavaPath
    Assert-AuditNoLinks $SourcePath
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $JavaPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('--class-path',($JarPaths -join [IO.Path]::PathSeparator),'--source','21',$SourcePath) + $Arguments) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(30000)) { $process.Kill($true); $process.WaitForExit(); throw 'aab_parser_timeout' }
        $text = $stdout.GetAwaiter().GetResult()
        $errors = $stderr.GetAwaiter().GetResult()
        if ($errors -cmatch '^AAB_PROTOBUF_REJECTED:([a-z_]{1,80})\s*$') { throw ('aab_parser_' + $Matches[1]) }
        if ($process.ExitCode -ne 0 -or $text.Length -gt 1024 -or $errors.Length -gt 4096) { throw 'aab_parser_rejected' }
        $text.Trim()
    } finally { $process.Dispose() }
}
