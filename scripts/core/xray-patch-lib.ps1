# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Shared ZIP/h1 validators remain identical to those used by the artifact audit.
. (Join-Path $PSScriptRoot '../release/artifact-audit-lib.ps1')

function Assert-XrayFields($Object, [string[]]$Fields) {
    if ($Object -isnot [Collections.IDictionary] -or $Object.Count -ne $Fields.Count) { throw 'xray_patch_invalid_lock_fields' }
    foreach ($field in $Fields) { if (!$Object.Contains($field)) { throw 'xray_patch_invalid_lock_fields' } }
}

function Assert-XrayJsonUnique($Element) {
    if ($Element.ValueKind -ne [Text.Json.JsonValueKind]::Object) { return }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($property in $Element.EnumerateObject()) {
        if (!$seen.Add($property.Name)) { throw 'xray_patch_duplicate_lock_field' }
        Assert-XrayJsonUnique $property.Value
    }
}

function Get-XrayPatchLock([string]$Path) {
    Assert-AuditNoLinks $Path
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt 64KB) { throw 'xray_patch_lock_too_large' }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $lock = $text | ConvertFrom-Json -AsHashtable
    $document=[Text.Json.JsonDocument]::Parse($text)
    try {
        Assert-XrayJsonUnique $document.RootElement
        if ($document.RootElement.GetProperty('schemaVersion').GetInt32() -ne 1) { throw 'xray_patch_unsupported_lock' }
        # PowerShell converts ISO timestamps into DateTime by default. Retain
        # the literal JSON string, including its exact UTC syntax, on PS 7.0+.
        $lock.patched.time=$document.RootElement.GetProperty('patched').GetProperty('time').GetString()
    } finally { $document.Dispose() }
    Assert-XrayFields $lock @('schemaVersion','module','upstream','patch','patched')
    Assert-XrayFields $lock.upstream @('version','commit','zipSha256','sum','goModSum')
    Assert-XrayFields $lock.patch @('path','sha256')
    Assert-XrayFields $lock.patched @('version','time','sum','goModSum')
    if ($lock.schemaVersion -ne 1 -or $lock.module -cne 'github.com/xtls/xray-core') { throw 'xray_patch_unsupported_lock' }
    if ($lock.upstream.version -cnotmatch '^v1\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$' -or
        $lock.upstream.commit -cnotmatch '^[a-f0-9]{40}$' -or
        $lock.patched.version -cnotmatch '^v1\.[0-9]+\.[0-9]+-exvpn\.[1-9][0-9]*$' -or
        $lock.patched.time -cnotmatch '^20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z$') {
        throw 'xray_patch_invalid_identity'
    }
    [void][DateTimeOffset]::ParseExact($lock.patched.time, 'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    foreach ($hash in @($lock.upstream.zipSha256,$lock.patch.sha256)) {
        if ($hash -isnot [string] -or $hash -cnotmatch '^[a-f0-9]{64}$') { throw 'xray_patch_unfinalized_hash' }
    }
    foreach ($sum in @($lock.upstream.sum,$lock.upstream.goModSum,$lock.patched.sum,$lock.patched.goModSum)) {
        if ($sum -isnot [string] -or $sum -cnotmatch '^h1:[A-Za-z0-9+/]{43}=$') { throw 'xray_patch_unfinalized_sum' }
    }
    # Keep the checked-in patch beside its lock; no caller-controlled traversal.
    if ($lock.patch.path -cne 'xray-lifecycle.patch') { throw 'xray_patch_invalid_patch_path' }
    [ordered]@{ Value=$lock; Sha256=Get-AuditSha256 $Path }
}

function Get-XrayGoModSum([byte[]]$Bytes) {
    $fileHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
    'h1:' + [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$fileHash  go.mod`n")))
}

function Assert-XrayModuleZip([string]$Path, [string]$Module, [string]$Version, [string]$Sum, [string]$GoModSum) {
    $files = Get-AuditZipFiles $Path -GoModule
    $prefix = "$Module@$Version/"
    [long]$total = 0
    foreach ($name in $files.Keys) {
        if (!$name.StartsWith($prefix, [StringComparison]::Ordinal)) { throw 'xray_patch_wrong_zip_prefix' }
        $relative = $name.Substring($prefix.Length)
        if ($relative.Split('/') -contains '.git' -or $relative -ceq '.gitmodules') { throw 'xray_patch_vcs_path_in_zip' }
        $total += $files[$name].size
        if ($files[$name].size -gt 32MB -or $total -gt 256MB -or $files.Count -gt 10000) { throw 'xray_patch_source_size_limit' }
    }
    if ((Get-AuditGoZipSum $Path) -cne $Sum) { throw 'xray_patch_module_sum_mismatch' }
    $mod = Read-AuditZipBytes $Path ($prefix + 'go.mod') 1MB
    if ((Get-XrayGoModSum $mod) -cne $GoModSum) { throw 'xray_patch_go_mod_sum_mismatch' }
    $modText = [Text.UTF8Encoding]::new($false,$true).GetString($mod)
    if ([regex]::Matches($modText, '(?m)^module\s+github\.com/xtls/xray-core\s*$').Count -ne 1 -or
        [regex]::Matches($modText, '(?m)^module\s+').Count -ne 1) { throw 'xray_patch_wrong_module_declaration' }
    ,$files
}

function Assert-XrayPatchText([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt 8MB) { throw 'xray_patch_too_large' }
    $text = [Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    if ($text.Contains([char]0) -or $text.Contains("`r") -or !$text.EndsWith("`n")) { throw 'xray_patch_requires_utf8_lf' }
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $currentPath = ''
    foreach ($line in $text.Split("`n")) {
        if ($line.StartsWith('diff --git ')) {
            $match = [regex]::Match($line, '^diff --git a/([A-Za-z0-9_./-]+) b/([A-Za-z0-9_./-]+)$')
            if (!$match.Success -or $match.Groups[1].Value -cne $match.Groups[2].Value) { throw 'xray_patch_unsupported_diff_path' }
            $currentPath = ConvertTo-AuditPath $match.Groups[1].Value
            if ($currentPath.Split('/') -contains '.git' -or $currentPath -ceq '.gitmodules' -or !$paths.Add($currentPath)) {
                throw 'xray_patch_unsafe_or_duplicate_path'
            }
        } elseif ($line -match '^(---|\+\+\+) ') {
            $side = if ($line.StartsWith('---')) { 'a/' } else { 'b/' }
            $name = $line.Substring(4)
            if (!$currentPath -or ($name -cne '/dev/null' -and $name -cne ($side + $currentPath))) { throw 'xray_patch_header_path_mismatch' }
        } elseif ($line -match '^(new file mode|deleted file mode) ') {
            if ($line -notmatch ' 100644$') { throw 'xray_patch_unsupported_file_mode' }
        } elseif ($line -match '^(old mode|new mode|rename |copy |similarity |dissimilarity |GIT binary patch|Binary files)') {
            throw 'xray_patch_unsupported_operation'
        }
    }
    if (!$paths.Count) { throw 'xray_patch_empty_diff' }
    @($paths | Sort-Object -CaseSensitive -Culture en-US)
}

function Invoke-XrayGit([string]$Directory, [string[]]$Arguments) {
    $git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $git
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    foreach ($name in @('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES','GIT_COMMON_DIR','GIT_CONFIG')) { [void]$start.Environment.Remove($name) }
    $start.Environment['GIT_CONFIG_NOSYSTEM']='1'; $start.Environment['GIT_CONFIG_SYSTEM']='NUL'; $start.Environment['GIT_CONFIG_GLOBAL']='NUL'
    $start.Environment['GIT_CONFIG_COUNT']='0'; $start.Environment['GIT_ATTR_NOSYSTEM']='1'
    $start.Environment['GIT_CEILING_DIRECTORIES']=[IO.Path]::GetDirectoryName($Directory)
    foreach ($argument in (@('-C',$Directory,'-c','core.autocrlf=false','-c','core.safecrlf=false','-c','core.protectNTFS=true','-c','core.longpaths=true') + $Arguments)) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        if (!$process.Start()) { throw 'xray_patch_git_start_failed' }
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(30000)) { $process.Kill($true); throw 'xray_patch_git_timeout' }
        [void]$stdout.GetAwaiter().GetResult(); [void]$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'xray_patch_git_apply_failed' }
    } finally { $process.Dispose() }
}

function New-XrayModuleZip([string]$Source, [string]$Path, [string]$Module, [string]$Version) {
    $files = Get-AuditTreeFiles $Source
    # Exclude only the private Git directory created by this builder. Tests and
    # every other source file are preserved; no go list/build-tag filtering.
    $names = [string[]]@($files.Keys | Where-Object { -not $_.StartsWith('.git/', [StringComparison]::Ordinal) })
    [Array]::Sort($names,[StringComparer]::Ordinal)
    $zip = [IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $names) {
            $entry = $zip.CreateEntry("$Module@$Version/$name",[IO.Compression.CompressionLevel]::NoCompression)
            $entry.LastWriteTime = [DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero)
            $entry.ExternalAttributes = 0
            $input = [IO.File]::OpenRead((Join-Path $Source $name)); $output = $entry.Open()
            try { $input.CopyTo($output) } finally { $input.Dispose(); $output.Dispose() }
        }
    } finally { $zip.Dispose() }
}

function Get-XrayProxyProvenance($Lock, [string]$LockSha256, [string]$ZipSha256) {
    [ordered]@{
        schema=1;builderVersion=1;lockSha256=$LockSha256;module=$Lock.module
        upstream=[ordered]@{
            version=$Lock.upstream.version;commit=$Lock.upstream.commit;zipSha256=$Lock.upstream.zipSha256;sum=$Lock.upstream.sum;goModSum=$Lock.upstream.goModSum
            zipUrl="https://proxy.golang.org/$($Lock.module)/@v/$($Lock.upstream.version).zip"
            sourceUrl="https://github.com/XTLS/Xray-core/tree/$($Lock.upstream.commit)"
        }
        patch=[ordered]@{path=$Lock.patch.path;sha256=$Lock.patch.sha256}
        patched=[ordered]@{version=$Lock.patched.version;time=$Lock.patched.time;sum=$Lock.patched.sum;goModSum=$Lock.patched.goModSum;zipSha256=$ZipSha256}
        distribution='Modified Xray source; preserve MPL-2.0 notices and this provenance with the exact corresponding source.'
    }
}

function Get-XrayCanonicalJson($Value) { (($Value | ConvertTo-Json -Depth 20) -replace "`r`n","`n") + "`n" }

function Assert-XrayProxy([string]$Root, $Lock, [string]$LockSha256) {
    Assert-AuditNoLinks $Root
    $base = "$($Lock.module)/@v/$($Lock.patched.version)"
    $zip = Join-Path $Root "$base.zip"
    $files = Get-AuditTreeFiles $Root
    $expected = @("$base.zip","$base.mod","$base.info","$($Lock.module)/@v/list",'provenance.json')
    if ($files.Count -ne $expected.Count) { throw 'xray_patch_unexpected_proxy_file' }
    foreach ($name in $expected) { if (!$files.ContainsKey($name)) { throw 'xray_patch_missing_proxy_file' } }
    [void](Assert-XrayModuleZip $zip $Lock.module $Lock.patched.version $Lock.patched.sum $Lock.patched.goModSum)
    $mod = [IO.File]::ReadAllBytes((Join-Path $Root "$base.mod"))
    if ((Get-XrayGoModSum $mod) -cne $Lock.patched.goModSum) { throw 'xray_patch_proxy_mod_mismatch' }
    $info = Get-XrayCanonicalJson ([ordered]@{Version=$Lock.patched.version;Time=$Lock.patched.time})
    if ([IO.File]::ReadAllText((Join-Path $Root "$base.info")) -cne $info -or
        [IO.File]::ReadAllText((Join-Path $Root "$($Lock.module)/@v/list")) -cne "$($Lock.patched.version)`n") { throw 'xray_patch_proxy_metadata_mismatch' }
    $provenance = Get-XrayProxyProvenance $Lock $LockSha256 (Get-AuditSha256 $zip)
    if ([IO.File]::ReadAllText((Join-Path $Root 'provenance.json')) -cne (Get-XrayCanonicalJson $provenance)) { throw 'xray_patch_provenance_mismatch' }
    [ordered]@{ProxyRoot=$Root;ZipPath=$zip;Version=$Lock.patched.version;Sum=$Lock.patched.sum;GoModSum=$Lock.patched.goModSum;ProvenancePath=(Join-Path $Root 'provenance.json')}
}

function Read-XrayGlobClassRune([string]$Pattern, [ref]$Index) {
    if ($Index.Value -ge $Pattern.Length -or $Pattern[$Index.Value] -in @('-',']')) { throw 'xray_patch_invalid_no_proxy_pattern' }
    if ($Pattern[$Index.Value] -eq '\') { $Index.Value++ }
    if ($Index.Value -ge $Pattern.Length) { throw 'xray_patch_invalid_no_proxy_pattern' }
    $value = [char]::ConvertToUtf32($Pattern,$Index.Value)
    $Index.Value += $(if ($value -gt 0xffff) { 2 } else { 1 })
    if ($Index.Value -ge $Pattern.Length) { throw 'xray_patch_invalid_no_proxy_pattern' }
    $value
}

function ConvertTo-XrayGoGlobRegex([string]$Pattern) {
    if ($Pattern.Length -gt 2048) { throw 'xray_patch_no_proxy_pattern_too_long' }
    $regex = [Text.StringBuilder]::new('^')
    for ($index=0; $index -lt $Pattern.Length;) {
        $char=$Pattern[$index]; $index++
        switch ($char) {
            '*' { [void]$regex.Append('[^/]*') }
            '?' { [void]$regex.Append('[^/]') }
            '\' {
                if ($index -ge $Pattern.Length) { throw 'xray_patch_invalid_no_proxy_pattern' }
                [void]$regex.Append([regex]::Escape([string]$Pattern[$index])); $index++
            }
            '[' {
                $negated=$index -lt $Pattern.Length -and $Pattern[$index] -eq '^'
                if ($negated) { $index++ }
                $members=[bool[]]::new(128); $ranges=0
                while ($true) {
                    if ($index -lt $Pattern.Length -and $Pattern[$index] -eq ']' -and $ranges -gt 0) { $index++; break }
                    $low=Read-XrayGlobClassRune $Pattern ([ref]$index); $high=$low
                    if ($Pattern[$index] -eq '-') { $index++; $high=Read-XrayGlobClassRune $Pattern ([ref]$index) }
                    # The target module path is ASCII. Enumerating its possible
                    # characters also handles Unicode/descending Go ranges.
                    for ($value=0; $value -lt 128; $value++) { if ($value -ge $low -and $value -le $high) { $members[$value]=$true } }
                    $ranges++
                }
                $set=[Text.StringBuilder]::new()
                for ($value=0; $value -lt 128; $value++) {
                    if ($members[$value] -ne $negated) { [void]$set.Append(('\x{0:x2}' -f $value)) }
                }
                if ($set.Length) { [void]$regex.Append('[').Append($set).Append(']') } else { [void]$regex.Append('(?!)') }
            }
            default { [void]$regex.Append([regex]::Escape([string]$char)) }
        }
    }
    [void]$regex.Append('$')
    $regex.ToString()
}

function Test-XrayNoProxyConflict([string]$Patterns, [string]$Module = 'github.com/xtls/xray-core') {
    foreach ($pattern in $Patterns.Split(',', [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($pattern -ceq 'none') { continue }
        # Go matches slash-counted module prefixes, not the complete path only.
        $regex = ConvertTo-XrayGoGlobRegex $pattern
        $segments = $pattern.Split('/').Length
        $parts = $Module.Split('/')
        if ($segments -gt $parts.Length) { continue }
        $prefix = ($parts[0..($segments-1)] -join '/')
        if ([regex]::IsMatch($prefix,$regex,[Text.RegularExpressions.RegexOptions]::CultureInvariant,[TimeSpan]::FromMilliseconds(100))) { throw 'xray_patch_no_proxy_conflict' }
    }
}
