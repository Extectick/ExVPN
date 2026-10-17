# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.4
# A bounded source-lock superset collector. No Cargo, resolver or build actions.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'shorebird-updater-notices.ps1')

function Get-UpdaterCrateLimits {
    @{Count=282;ArchiveBytes=32MB;NetworkBytes=1GB;ExpandedBytes=256MB;TotalExpandedBytes=4GB;Entries=16384;NoticeBytes=8MB;TotalNoticeBytes=128MB;Seconds=600}
}

function Get-UpdaterRemainingLimits($Limits,[long]$Expanded,[long]$NoticeBytes) {
    if($Expanded -ge $Limits.TotalExpandedBytes -or $NoticeBytes -ge $Limits.TotalNoticeBytes){throw 'updater_crate_total_output_limit'}
    $remaining=$Limits.Clone()
    $remaining.ExpandedBytes=[Math]::Min([long]$Limits.ExpandedBytes,[long]($Limits.TotalExpandedBytes-$Expanded))
    $remaining.TotalNoticeBytes=[long]$Limits.TotalNoticeBytes-$NoticeBytes
    $remaining
}

function Assert-UpdaterCrateIdentity($Crate) {
    if ($Crate.name -isnot [string] -or $Crate.name -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_-]{0,127}$' -or
        $Crate.version -isnot [string] -or $Crate.version -cnotmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?(?:\+[A-Za-z0-9.-]+)?$' -or
        $Crate.version.Length -gt 128 -or $Crate.sha256 -isnot [string] -or $Crate.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'updater_crate_identity_invalid' }
}

function Get-UpdaterLockCrates([string]$Text) {
    # These are authenticated Cargo.lock files, not arbitrary TOML. Parse only
    # their fixed package identity fields; never evaluate features/build files.
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($block in [regex]::Matches($Text,'(?ms)^\[\[package\]\]\r?\n(.*?)(?=^\[\[package\]\]|\z)')) {
        $fields=@{}
        foreach ($name in @('name','version','source','checksum')) {
            $matches=[regex]::Matches($block.Groups[1].Value,"(?m)^$name = `"([^`"\r\n]+)`"\r?$")
            if ($matches.Count -gt 1) { throw 'updater_crate_lock_invalid' }
            if ($matches.Count) { $fields[$name]=$matches[0].Groups[1].Value }
        }
        if (!$fields.ContainsKey('name') -or !$fields.ContainsKey('version') -or !$seen.Add("$($fields.name)@$($fields.version)")) { throw 'updater_crate_lock_invalid' }
        if (!$fields.ContainsKey('source')) { continue }
        if ($fields.source -cne 'registry+https://github.com/rust-lang/crates.io-index' -or !$fields.ContainsKey('checksum')) { throw 'updater_crate_lock_source_invalid' }
        $row=@{name=$fields.name;version=$fields.version;sha256=$fields.checksum}
        Assert-UpdaterCrateIdentity $row
        $row
    }
    if (!$seen.Count) { throw 'updater_crate_lock_invalid' }
}

function Get-UpdaterCratePins([string]$Repository) {
    $file=Get-ReleaseRuntimeFile $Repository 'scripts/release/shorebird-updater-notices-crates.lock.json'
    if ($file.size -gt 256KB) { throw 'updater_crate_pin_invalid' }
    $pin=Get-Content -LiteralPath (Join-Path $Repository $file.path) -Raw | ConvertFrom-Json -AsHashtable
    $own=Get-Content -LiteralPath (Join-Path $Repository 'scripts/release/shorebird-updater-notices.lock.json') -Raw | ConvertFrom-Json -AsHashtable
    if (($pin.schemaVersion -isnot [int] -and $pin.schemaVersion -isnot [long]) -or $pin.schemaVersion -ne 1 -or $pin.scope -cne 'conservative-source-lock-superset' -or
        $pin.updaterRevision -cne $own.updater.revision -or $pin.rustSourceRevision -cnotmatch '^[a-f0-9]{40}$' -or
        $pin.sources -isnot [Collections.IList] -or $pin.sources.Count -ne 2 -or
        $pin.crates -isnot [Collections.IList] -or !$pin.crates.Count -or $pin.crates.Count -gt (Get-UpdaterCrateLimits).Count) { throw 'updater_crate_pin_invalid' }
    $expectedPaths=@(
        "scripts/release/licenses/shorebird-updater-$($pin.updaterRevision)/Cargo.lock",
        "scripts/release/licenses/shorebird-updater-runtime-$($pin.rustSourceRevision)/Cargo.lock"
    )
    $scopes=@('updater-workspace','rust-library')
    $membership=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    for ($i=0;$i -lt 2;$i++) {
        $source=$pin.sources[$i]
        if ($source.path -cne $expectedPaths[$i] -or $source.scope -cne $scopes[$i]) { throw 'updater_crate_pin_invalid' }
        $sourcePath=Join-Path $Repository $source.path
        Get-ShorebirdUpdaterPinnedFile ([IO.Path]::GetDirectoryName($sourcePath)) 'Cargo.lock' $source | Out-Null
        if ($i -eq 0 -and ($source.sha256 -cne $own.updater.cargoLock.sha256 -or $source.gitBlob -cne $own.updater.cargoLock.gitBlob)) { throw 'updater_crate_source_mismatch' }
        foreach ($crate in @(Get-UpdaterLockCrates ([IO.File]::ReadAllText($sourcePath)))) {
            $id="$($crate.name)@$($crate.version)"
            if ($membership.ContainsKey($id)) {
                if ($membership[$id].sha256 -cne $crate.sha256) { throw 'updater_crate_checksum_conflict' }
                $membership[$id].scopes+=@($source.scope)
            } else { $crate.scopes=@($source.scope);$membership[$id]=$crate }
        }
    }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($crate in $pin.crates) {
        Assert-UpdaterCrateIdentity $crate
        $id="$($crate.name)@$($crate.version)"
        if (!$seen.Add($id) -or !$membership.ContainsKey($id) -or $membership[$id].sha256 -cne $crate.sha256 -or
            $crate.scopes -isnot [Collections.IList] -or ($crate.scopes -join ',') -cne ($membership[$id].scopes -join ',')) { throw 'updater_crate_membership_mismatch' }
    }
    if ($seen.Count -ne $membership.Count) { throw 'updater_crate_membership_mismatch' }
    [pscustomobject]@{Pin=$pin;Sha256=$file.sha256;Count=$seen.Count}
}

function Get-UpdaterCollectorInputs([string]$Repository) {
    foreach($path in @('scripts/release/shorebird-updater-notices-prepare.ps1','scripts/release/shorebird-updater-notices-crates.ps1','scripts/release/shorebird-updater-notices.ps1','scripts/release/shorebird-updater-notices.lock.json','scripts/release/flutter-runtime-inputs.ps1','scripts/release/artifact-audit-lib.ps1')) {
        Get-ReleaseRuntimeFile $Repository $path
    }
}

function Assert-UpdaterPrivatePath([string]$Repository,[string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    $allowed=$false
    foreach ($directory in @('.private','artifacts')) {
        $base=[IO.Path]::GetFullPath((Join-Path $Repository $directory))+[IO.Path]::DirectorySeparatorChar
        if ($full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) { $allowed=$true }
    }
    if (!$allowed) { throw 'updater_crate_output_outside_workspace' }
    $ancestor=$full
    while (!(Test-Path -LiteralPath $ancestor)) { $ancestor=[IO.Path]::GetDirectoryName($ancestor);if (!$ancestor) { throw 'updater_crate_output_invalid' } }
    Assert-AuditNoLinks $ancestor
    $full
}

function Get-UpdaterCrateArchivePath([string]$Cache,$Crate) {
    Assert-UpdaterCrateIdentity $Crate
    Join-Path $Cache "$($Crate.name)-$($Crate.version)-$($Crate.sha256).crate"
}

function Assert-UpdaterCrateArchive([string]$Path,$Crate,$Limits) {
    Assert-UpdaterCrateIdentity $Crate
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'updater_crate_archive_missing_offline' }
    Assert-AuditNoLinks $Path
    $item=Get-Item -LiteralPath $Path -Force
    if ($item.Length -le 0 -or $item.Length -gt $Limits.ArchiveBytes) { throw 'updater_crate_archive_limit' }
    if ((Get-AuditSha256 $Path) -cne $Crate.sha256) { throw 'updater_crate_archive_checksum_mismatch' }
    [long]$item.Length
}

function Get-UpdaterCrateEntryPath([string]$Name,[string]$Prefix,[bool]$Directory) {
    if (!$Name.StartsWith($Prefix,[StringComparison]::Ordinal) -or $Name.Length -gt 512 -or $Name -match '[\\:\x00-\x1f<>"|?*]') { throw 'updater_crate_entry_path_invalid' }
    $relative=$Name.Substring($Prefix.Length)
    if ($Directory) { $relative=$relative.TrimEnd('/') }
    if (!$relative -and $Directory) { return '' }
    foreach ($part in $relative.Split('/')) {
        if (!$part -or $part -in @('.','..') -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw 'updater_crate_entry_path_invalid' }
    }
    $relative
}

function Read-UpdaterPackageMetadata([string]$Text,$Crate) {
    $tables=[regex]::Matches($Text,'(?ms)^\[package\]\r?\n(.*?)(?=^\[|\z)')
    if ($tables.Count -ne 1) { throw 'updater_crate_manifest_invalid' }
    $values=@{}
    foreach ($key in @('name','version','license','license-file')) {
        $lines=[regex]::Matches($tables[0].Groups[1].Value,"(?m)^$key\s*=\s*(.*?)\r?$")
        if ($lines.Count -gt 1) { throw 'updater_crate_manifest_invalid' }
        if (!$lines.Count) { continue }
        # Cargo publishes normalized single-line package strings. Unsupported
        # syntax is explicit refusal, not a guessed license/path.
        $value=$lines[0].Groups[1].Value
        if ($value -cmatch '^"([^"\\\r\n]*)"\s*(?:#.*)?$' -or $value -cmatch "^'([^'\r\n]*)'\s*(?:#.*)?$") { $values[$key]=$Matches[1] }
        else { throw 'updater_crate_manifest_string_unsupported' }
    }
    if (!$values.ContainsKey('name') -or !$values.ContainsKey('version') -or $values.name -cne $Crate.name -or $values.version -cne $Crate.version) { throw 'updater_crate_manifest_identity_mismatch' }
    [pscustomobject]@{License=$(if($values.ContainsKey('license')){$values.license}else{$null});LicenseFile=$(if($values.ContainsKey('license-file')){$values['license-file']}else{$null})}
}

function Export-UpdaterCrateNotices([string]$Archive,$Crate,[string]$Output,$Limits,[Diagnostics.Stopwatch]$Clock) {
    $compressed=Assert-UpdaterCrateArchive $Archive $Crate $Limits
    $inputStream=[IO.File]::Open($Archive,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($inputStream)).ToLowerInvariant() -cne $Crate.sha256) { $inputStream.Dispose();throw 'updater_crate_archive_checksum_mismatch' }
    $inputStream.Position=0
    $gzip=[IO.Compression.GZipStream]::new($inputStream,[IO.Compression.CompressionMode]::Decompress)
    $tar=[IO.MemoryStream]::new()
    try {
        $buffer=[byte[]]::new(65536)
        while (($count=$gzip.Read($buffer,0,$buffer.Length)) -gt 0) {
            if ($Clock.Elapsed.TotalSeconds -ge $Limits.Seconds) { throw 'updater_crate_deadline' }
            if ($tar.Length+$count -gt $Limits.ExpandedBytes) { throw 'updater_crate_expanded_limit' }
            $tar.Write($buffer,0,$count)
        }
        $tar.Position=0
        $reader=[System.Formats.Tar.TarReader]::new($tar,$true)
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $entries=[Collections.Generic.List[object]]::new()
        $notices=[Collections.Generic.List[object]]::new()
        $prefix="$($Crate.name)-$($Crate.version)/"
        $metadata=$null;$manifest=$null;$noticeBytes=0L
        try {
            while ($null -ne ($entry=$reader.GetNextEntry())) {
                if ($Clock.Elapsed.TotalSeconds -ge $Limits.Seconds) { throw 'updater_crate_deadline' }
                if ($seen.Count -ge $Limits.Entries) { throw 'updater_crate_entry_limit' }
                $directory=$entry.EntryType -eq [System.Formats.Tar.TarEntryType]::Directory
                if (!$directory -and $entry.EntryType -notin @([System.Formats.Tar.TarEntryType]::RegularFile,[System.Formats.Tar.TarEntryType]::V7RegularFile)) { throw 'updater_crate_entry_type_invalid' }
                $relative=Get-UpdaterCrateEntryPath $entry.Name $prefix $directory
                if (!$seen.Add($relative)) { throw 'updater_crate_duplicate_path' }
                if ($directory) { continue }
                if ($entry.Length -lt 0 -or $entry.Length -gt $Limits.ExpandedBytes) { throw 'updater_crate_entry_limit' }
                $isManifest=$relative -ceq 'Cargo.toml'
                $baseName=[IO.Path]::GetFileName($relative)
                $isNotice=$baseName -match '^(?i:LICEN[CS]E|COPYING|COPYRIGHT|NOTICE|PATENTS|AUTHORS)(?:[._ -].*)?$' -or
                    $baseName -match '(?i:third[._ -]?party.*(?:license|notice)|(?:license|notice).*third[._ -]?party)' -or
                    $relative -match '(?i)(^|/)LICENSES?/[^/]+$'
                if (($isNotice -or $isManifest) -and $entry.Length -gt $Limits.NoticeBytes) { throw 'updater_crate_notice_limit' }
                $sha=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
                $capture=if($isNotice -or $isManifest){[IO.MemoryStream]::new()}else{$null}
                $read=0L
                try {
                    while ($read -lt $entry.Length) {
                        if ($Clock.Elapsed.TotalSeconds -ge $Limits.Seconds) { throw 'updater_crate_deadline' }
                        $count=$entry.DataStream.Read($buffer,0,[int][Math]::Min($buffer.Length,$entry.Length-$read))
                        if ($count -le 0) { throw 'updater_crate_entry_truncated' }
                        $sha.AppendData($buffer,0,$count);if($capture){$capture.Write($buffer,0,$count)};$read+=$count
                    }
                    $hash=[Convert]::ToHexString($sha.GetHashAndReset()).ToLowerInvariant()
                    $entries.Add([ordered]@{path=$relative;size=$read;sha256=$hash})
                    if ($isManifest) {
                        $manifest=$capture.ToArray()
                        $metadata=Read-UpdaterPackageMetadata ([Text.UTF8Encoding]::new($false,$true).GetString($manifest)) $Crate
                    }
                    if ($isNotice) {
                        $noticeBytes+=$read
                        if ($noticeBytes -gt $Limits.TotalNoticeBytes) { throw 'updater_crate_notice_limit' }
                        $target=Join-Path $Output "notices/$relative"
                        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))|Out-Null
                        [IO.File]::WriteAllBytes($target,$capture.ToArray())
                        $notices.Add([ordered]@{path="notices/$relative";sourcePath=$relative;size=$read;sha256=$hash;selection='notice-path'})
                    }
                } finally { $sha.Dispose();if($capture){$capture.Dispose()} }
            }
        } finally { $reader.Dispose() }
        if (!$metadata) { throw 'updater_crate_manifest_missing' }
        $issues=[Collections.Generic.List[string]]::new()
        if (!$metadata.License -and !$metadata.LicenseFile) { $issues.Add('license_declaration_missing') }
        if ($metadata.LicenseFile) {
            $licensePath=Get-UpdaterCrateEntryPath ($prefix+$metadata.LicenseFile) $prefix $false
            $matches=@($entries | Where-Object path -CEQ $licensePath)
            if ($matches.Count -ne 1) { throw 'updater_crate_declared_license_missing' }
            if (!@($notices | Where-Object sourcePath -CEQ $licensePath).Count) {
                # Reopen authenticated in-memory tar for the one explicit path.
                $tar.Position=0;$explicitReader=[System.Formats.Tar.TarReader]::new($tar,$true)
                try {
                    while($null -ne ($entry=$explicitReader.GetNextEntry())) {
                        if($entry.Name -cne ($prefix+$licensePath)){continue}
                        if($entry.Length -gt $Limits.NoticeBytes){throw 'updater_crate_notice_limit'}
                        $target=Join-Path $Output "notices/$licensePath"
                        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))|Out-Null
                        $stream=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                        try{$entry.DataStream.CopyTo($stream)}finally{$stream.Dispose()}
                        if((Get-AuditSha256 $target) -cne $matches[0].sha256){throw 'updater_crate_notice_mismatch'}
                        $notices.Add([ordered]@{path="notices/$licensePath";sourcePath=$licensePath;size=$matches[0].size;sha256=$matches[0].sha256;selection='declared-license-file'})
                        $noticeBytes+=$matches[0].size
                        if($noticeBytes -gt $Limits.TotalNoticeBytes){throw 'updater_crate_notice_limit'}
                        break
                    }
                }finally{$explicitReader.Dispose()}
            }
        }
        if (!$notices.Count) { $issues.Add('notice_texts_missing') }
        $issues.Add('nested_vendored_and_copyright_coverage_requires_review')
        [IO.File]::WriteAllBytes((Join-Path $Output 'Cargo.toml'),$manifest)
        $result=[ordered]@{name=$Crate.name;version=$Crate.version;scopes=$Crate.scopes;archiveSha256=$Crate.sha256;archiveBytes=$compressed;expandedBytes=$tar.Length;entryCount=$seen.Count;licenseExpression=$metadata.License;licenseFile=$metadata.LicenseFile;notices=$notices.ToArray();noticeBytes=$noticeBytes;entries=$entries.ToArray();issues=$issues.ToArray();archiveVerified=$true;completeLicenseCoverage=$false;exactLinkedMembership=$false}
        Write-AuditJson (Join-Path $Output 'component.json') $result
        $result
    } finally {$tar.Dispose();$gzip.Dispose();$inputStream.Dispose()}
}
