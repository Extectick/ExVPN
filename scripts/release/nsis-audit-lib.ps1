#requires -Version 7.0
# Inspection only: never execute the supplied installer or uninstaller.
Set-StrictMode -Version Latest

function Invoke-AuditExtractor([string]$Executable, [string[]]$Arguments, [int]$MaximumBytes = 8MB, [int]$TimeoutSeconds = 45) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $bytes = [IO.MemoryStream]::new()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $started = $false
    try {
        if (!$process.Start()) { throw 'archive_inspector_start_failed' }
        $started = $true
        # Drain diagnostics without retaining unbounded or untrusted text.
        $stderr = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
        $buffer = [byte[]]::new(65536)
        while ($true) {
            $remaining = $TimeoutSeconds * 1000 - [int]$timer.ElapsedMilliseconds
            if ($remaining -le 0) { throw 'archive_inspector_timeout' }
            $read = $process.StandardOutput.BaseStream.ReadAsync($buffer, 0, $buffer.Length)
            if (!$read.Wait($remaining)) { throw 'archive_inspector_timeout' }
            $count = $read.GetAwaiter().GetResult()
            if (!$count) { break }
            if ($bytes.Length + $count -gt $MaximumBytes) { throw 'archive_inspector_output_limit' }
            $bytes.Write($buffer, 0, $count)
        }
        $remaining = $TimeoutSeconds * 1000 - [int]$timer.ElapsedMilliseconds
        if ($remaining -le 0 -or !$process.WaitForExit($remaining)) { throw 'archive_inspector_timeout' }
        $remaining = $TimeoutSeconds * 1000 - [int]$timer.ElapsedMilliseconds
        if ($remaining -le 0 -or !$stderr.Wait($remaining)) { throw 'archive_inspector_timeout' }
        if ($process.ExitCode -ne 0) { throw 'archive_inspector_failed' }
        return ,$bytes.ToArray()
    } finally {
        if ($started -and !$process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
        $process.Dispose()
        $bytes.Dispose()
    }
}

function Get-AuditArchiveInspector([string]$Repository) {
    $pin = Get-Content (Join-Path $PSScriptRoot 'archive-inspector.lock.json') -Raw | ConvertFrom-Json
    $root = Join-Path $Repository ".tools/7zip-$($pin.version)"
    $files = Get-AuditTreeFiles $root
    if ($files.Count -ne $pin.files.Count) { throw 'archive_inspector_file_set_mismatch' }
    foreach ($file in $pin.files) {
        if (!$files.ContainsKey($file.name) -or $files[$file.name].sha256 -cne $file.sha256) { throw 'archive_inspector_pin_mismatch' }
    }
    [pscustomobject]@{ executable = (Join-Path $root '7z.exe'); version = $pin.version; files = $pin.files }
}

function ConvertFrom-AuditNsisListing([string]$Text, [switch]$Uninstaller) {
    if ($Text.Length -gt 8MB -or ([regex]::Matches($Text, '(?m)^Type = Nsis\r?$')).Count -ne 1) { throw 'unsupported_nsis_archive' }
    $parts = [regex]::Split($Text, '(?m)^----------\r?$')
    if ($parts.Count -ne 2) { throw 'invalid_nsis_listing' }
    $records = New-AuditFileMap
    [long]$total = 0
    foreach ($block in [regex]::Split($parts[1].Trim(), '\r?\n\r?\n')) {
        $fields = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        foreach ($line in $block -split '\r?\n') {
            if ($line -notmatch '^([^=]+) = (.*)$' -or !$fields.TryAdd($Matches[1], $Matches[2])) { throw 'invalid_nsis_listing' }
        }
        if (!$fields.ContainsKey('Path') -or !$fields.ContainsKey('Size') -or !$fields.ContainsKey('Attributes')) { throw 'invalid_nsis_listing' }
        foreach ($field in $fields.Keys) {
            if ($field -cnotin @('Path','Size','Packed Size','Modified','Attributes','Method','Solid','Offset')) { throw 'unsupported_nsis_entry' }
        }
        if ($fields['Attributes']) { throw 'unsupported_nsis_entry' }
        $path = ConvertTo-AuditPath $fields['Path']
        $size = [long]0
        $known = $fields['Size'] -cmatch '^(0|[1-9][0-9]{0,10})$'
        if ($fields['Size'] -and !$known) { throw 'invalid_nsis_entry_size' }
        if ($known) { $size = [long]$fields['Size'] }
        if ($size -gt 1GB) { throw 'archive_size_limit' }
        $total += $(if ($known) { $size } else { 16MB })
        if ($total -gt 4GB) { throw 'archive_size_limit' }
        if ($records.ContainsKey($path)) { throw 'duplicate_archive_path' }
        $records.Add($path, [ordered]@{ path=$path; size=$size; sizeKnown=$known })
        if ($records.Count -gt 30000) { throw 'too_many_archive_entries' }
    }
    $anchor = if ($Uninstaller) { 'control/package.ps1' } else { 'package.json' }
    $roots = @($records.Keys | Where-Object { $_ -cmatch ('^\$_[0-9]{1,3}_/' + [regex]::Escape($anchor) + '$') })
    if ($roots.Count -ne 1) { throw 'nsis_payload_root_ambiguous' }
    $prefix = $roots[0].Substring(0, $roots[0].Length - $anchor.Length)
    $allowedPlugins = if ($Uninstaller) { @('System.dll','nsExec.dll') } else { @('modern-wizard.bmp','nsDialogs.dll','System.dll','nsExec.dll') }
    foreach ($record in $records.Values) {
        $path = $record.path
        if ($path.StartsWith($prefix, [StringComparison]::Ordinal)) {
            $relative = $path.Substring($prefix.Length)
            if ($Uninstaller -and $relative -cnotin @('control/package.ps1','control/package-common.ps1')) { throw 'unexpected_nsis_payload_entry' }
            if (!$Uninstaller -and $relative -cne 'package.json' -and $relative -cne 'Uninstall.exe' -and $relative -cnotmatch '^(ui|service|control)/') { throw 'unexpected_nsis_payload_entry' }
            if (!$record.sizeKnown -and ($Uninstaller -or $relative -cne 'Uninstall.exe')) { throw 'nsis_payload_size_unknown' }
        } elseif ($path.StartsWith('$PLUGINSDIR/', [StringComparison]::Ordinal)) {
            if ($path.Substring(12) -cnotin $allowedPlugins) { throw 'unexpected_nsis_plugin' }
        } else { throw 'unexpected_nsis_archive_entry' }
        $parent = $path
        while ($parent.Contains('/')) {
            $parent = $parent.Substring(0, $parent.LastIndexOf('/'))
            if ($records.ContainsKey($parent)) { throw 'archive_path_collision' }
        }
    }
    foreach ($plugin in $allowedPlugins) { if (!$records.ContainsKey('$PLUGINSDIR/' + $plugin)) { throw 'nsis_plugin_missing' } }
    if (!$Uninstaller -and !$records.ContainsKey($prefix + 'Uninstall.exe')) { throw 'nsis_uninstaller_missing' }
    if ($Uninstaller -and !$records.ContainsKey($prefix + 'control/package-common.ps1')) { throw 'nsis_maintenance_file_missing' }
    [pscustomobject]@{ entries=$records; prefix=$prefix; totalBound=$total }
}

function Expand-AuditNsis([string]$Executable, [string]$Archive, [string]$Output, $Listing) {
    if (Test-Path -LiteralPath $Output) { throw 'nsis_extract_destination_exists' }
    $arguments = @('x', $Archive, "-o$Output", '-y', '-bso0', '-bsp0', '-bse0')
    foreach ($record in $Listing.entries.Values) {
        if (!$record.sizeKnown) { $arguments += '-x!' + $record.path.Replace('/','\') }
    }
    [void](Invoke-AuditExtractor $Executable $arguments 65536 60)
    foreach ($record in $Listing.entries.Values) {
        if ($record.sizeKnown) { continue }
        # NSIS can omit the last entry's size. Stream only that exact entry with
        # a hard byte bound, instead of allowing an unbounded filesystem write.
        $content = Invoke-AuditExtractor $Executable @('x','-so','-bsp0','-bse0',$Archive,$record.path.Replace('/','\')) 16MB 45
        $path = Join-Path $Output $record.path
        if (Test-Path -LiteralPath $path) { throw 'nsis_unknown_entry_already_extracted' }
        $parent = [IO.Path]::GetDirectoryName($path)
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Assert-AuditNoLinks $parent
        [IO.File]::WriteAllBytes($path, $content)
    }
    $files = Get-AuditTreeFiles $Output
    if ($files.Count -ne $Listing.entries.Count) { throw 'nsis_extracted_file_set_mismatch' }
    foreach ($record in $Listing.entries.Values) {
        if (!$files.ContainsKey($record.path) -or ($record.sizeKnown -and $files[$record.path].size -ne $record.size)) { throw 'nsis_extracted_size_mismatch' }
    }
    ,$files
}

function Assert-AuditNsisPayload($Extracted, [string]$Prefix, $Staged, [switch]$Uninstaller) {
    $payload = New-AuditFileMap
    foreach ($file in $Extracted.Values) {
        if (!$file.path.StartsWith($Prefix, [StringComparison]::Ordinal)) { continue }
        $relative = $file.path.Substring($Prefix.Length)
        if (!$Uninstaller -and $relative -ceq 'Uninstall.exe') { continue }
        if (!$Staged.ContainsKey($relative) -or $Staged[$relative].path -cne $relative -or $Staged[$relative].size -ne $file.size -or $Staged[$relative].sha256 -cne $file.sha256) { throw 'nsis_staged_payload_mismatch' }
        $payload.Add($relative, $file)
    }
    $expectedCount = if ($Uninstaller) { 2 } else { $Staged.Count }
    if ($payload.Count -ne $expectedCount) { throw 'nsis_staged_payload_mismatch' }
}

function Get-AuditNsisEvidence([string]$Repository, [string]$Artifact, [string]$Output, $Staged) {
    $tool = Get-AuditArchiveInspector $Repository
    $nsis = Get-Content (Join-Path $Repository 'scripts/windows/nsis.lock.json') -Raw | ConvertFrom-Json
    $nsisArchive = Join-Path $Repository ".cache/nsis-$($nsis.version).zip"
    Assert-AuditNoLinks $nsisArchive
    if ((Get-AuditSha256 $nsisArchive) -cne $nsis.sha256) { throw 'nsis_source_archive_mismatch' }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $listing = ConvertFrom-AuditNsisListing ($utf8.GetString((Invoke-AuditExtractor $tool.executable @('l','-slt','-sccUTF-8','-bse0',$Artifact))))
    $root = Join-Path $Output 'nsis-installer'
    $files = Expand-AuditNsis $tool.executable $Artifact $root $listing
    Assert-AuditNsisPayload $files $listing.prefix $Staged
    $uninstallerPath = $listing.prefix + 'Uninstall.exe'
    $uninstaller = Join-Path $root $uninstallerPath
    $uninstallListing = ConvertFrom-AuditNsisListing ($utf8.GetString((Invoke-AuditExtractor $tool.executable @('l','-slt','-sccUTF-8','-bse0',$uninstaller)))) -Uninstaller
    $uninstallFiles = Expand-AuditNsis $tool.executable $uninstaller (Join-Path $Output 'nsis-uninstaller') $uninstallListing
    Assert-AuditNsisPayload $uninstallFiles $uninstallListing.prefix $Staged -Uninstaller
    $plugins = [Collections.Generic.List[object]]::new()
    foreach ($entry in @(@{kind='installer';files=$files}, @{kind='uninstaller';files=$uninstallFiles})) {
        foreach ($file in $entry.files.Values) {
            if (!$file.path.StartsWith('$PLUGINSDIR/',[StringComparison]::Ordinal)) { continue }
            $name = $file.path.Substring(12)
            # MUI2 embeds its default win.bmp under the renamed archive entry.
            $sourcePath = if ($name -ceq 'modern-wizard.bmp') { "nsis-$($nsis.version)/Contrib/Graphics/Wizard/win.bmp" } else { "nsis-$($nsis.version)/Plugins/x86-unicode/$name" }
            $source = Read-AuditZipBytes $nsisArchive $sourcePath 16MB
            $sourceHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($source)).ToLowerInvariant()
            if ($sourceHash -cne $file.sha256 -or $source.Length -ne $file.size) { throw 'nsis_plugin_pin_mismatch' }
            $plugins.Add([ordered]@{ container=$entry.kind; path=$file.path; size=$file.size; sha256=$file.sha256; pinnedArchiveEntry=$sourcePath })
        }
    }
    [void](Get-AuditArchiveInspector $Repository)
    if ((Get-AuditSha256 $nsisArchive) -cne $nsis.sha256) { throw 'nsis_source_archive_changed' }
    [ordered]@{
        verified=$true; installerExecuted=$false; installerInstructionSemanticsVerified=$false
        toolVersion=$tool.version; tools=$tool.files; payloadFiles=$Staged.Count
        installerEntries=$files.Count; uninstallerEntries=$uninstallFiles.Count
        maintenanceScriptsMatched=2; nsisSourceArchiveSha256=$nsis.sha256
        uninstallerSha256=$files[$uninstallerPath].sha256
        plugins=@($plugins | Sort-Object container,path)
    }
}
