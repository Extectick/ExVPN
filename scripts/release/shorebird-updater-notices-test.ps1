# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.4
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'shorebird-updater-notices-crates.ps1')
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture=Join-Path $repo ('artifacts/qa/updater-crate-fixtures-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture)|Out-Null
$script:checks=0
function Check([bool]$Pass,[string]$Name){if(!$Pass){throw "Fixture failed: $Name"};$script:checks++}
function Refuse([scriptblock]$Action,[string]$Code){$rejected=$false;try{& $Action|Out-Null}catch{if($_.Exception.Message -cne $Code){throw};$rejected=$true};Check $rejected $Code}
$initial=Get-UpdaterRemainingLimits (Get-UpdaterCrateLimits) 0 0
Check ($initial.ExpandedBytes -eq 256MB -and $initial.TotalNoticeBytes -eq 128MB) 'actual 4GiB total selects long arithmetic'
$tail=Get-UpdaterRemainingLimits (Get-UpdaterCrateLimits) (4GB-1) (128MB-1)
Check ($tail.ExpandedBytes -eq 1 -and $tail.TotalNoticeBytes -eq 1) 'last byte budget preserved'
Refuse {Get-UpdaterRemainingLimits (Get-UpdaterCrateLimits) 4GB 0} 'updater_crate_total_output_limit'
function Write-Utf8([string]$Path,[string]$Text){[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))|Out-Null;[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
function New-Crate([string]$Name,[array]$Entries){
    $archive=Join-Path $fixture "$Name.crate"
    $file=[IO.File]::Open($archive,[IO.FileMode]::CreateNew)
    $gzip=[IO.Compression.GZipStream]::new($file,[IO.Compression.CompressionLevel]::Optimal)
    $writer=[System.Formats.Tar.TarWriter]::new($gzip,[System.Formats.Tar.TarEntryFormat]::Pax,$true)
    try{
        foreach($spec in $Entries){
            $type=if($spec.ContainsKey('type')){$spec.type}else{[System.Formats.Tar.TarEntryType]::RegularFile}
            $entry=[System.Formats.Tar.PaxTarEntry]::new($type,$spec.path)
            $stream=$null
            if($type -in @([System.Formats.Tar.TarEntryType]::SymbolicLink,[System.Formats.Tar.TarEntryType]::HardLink)){$entry.LinkName='../../foreign'}
            else{$stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($spec.text));$entry.DataStream=$stream}
            try{$writer.WriteEntry($entry)}finally{if($stream){$stream.Dispose()}}
        }
    }finally{$writer.Dispose();$gzip.Dispose();$file.Dispose()}
    [pscustomobject]@{Path=$archive;Crate=@{name='fixture';version='1.0.0';sha256=(Get-AuditSha256 $archive);scopes=@('updater-workspace')}}
}
function Export-Crate($Archive,$Limits=(Get-UpdaterCrateLimits)){
    $output=Join-Path $fixture ([Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($output)|Out-Null
    $result=Export-UpdaterCrateNotices $Archive.Path $Archive.Crate $output $Limits ([Diagnostics.Stopwatch]::StartNew())
    [pscustomobject]@{Result=$result;Output=$output}
}
$manifest="[package]`nname = `"fixture`"`nversion = `"1.0.0`"`nlicense = `"MIT OR Apache-2.0`"`n"
$base=@(@{path='fixture-1.0.0/Cargo.toml';text=$manifest},@{path='fixture-1.0.0/LICENSE-MIT';text="Copyright Synthetic`nFull synthetic MIT text`n"},@{path='fixture-1.0.0/vendor/nested/NOTICE';text="Nested notice must not be truncated`n"},@{path='fixture-1.0.0/src/lib.rs';text='// synthetic source'})
$valid=New-Crate 'valid' $base
$export=Export-Crate $valid
Check ($export.Result.notices.Count -eq 2 -and $export.Result.entryCount -eq 4) 'root and nested notices retained'
foreach($notice in $export.Result.notices){Check ((Get-AuditSha256 (Join-Path $export.Output $notice.path)) -ceq $notice.sha256) 'full notice bytes'}
Check (!$export.Result.completeLicenseCoverage -and !$export.Result.exactLinkedMembership -and $export.Result.issues -contains 'nested_vendored_and_copyright_coverage_requires_review') 'unreviewed coverage remains explicit'
Check ((Assert-UpdaterCrateArchive $valid.Path $valid.Crate (Get-UpdaterCrateLimits)) -gt 0) 'verified cache reusable'
$valid.Crate.sha256='0'*64
Refuse {Export-Crate $valid} 'updater_crate_archive_checksum_mismatch'
$valid.Crate.sha256=Get-AuditSha256 $valid.Path
Refuse {Assert-UpdaterCrateArchive (Join-Path $fixture 'absent.crate') $valid.Crate (Get-UpdaterCrateLimits)} 'updater_crate_archive_missing_offline'
$limits=Get-UpdaterCrateLimits;$limits.ArchiveBytes=1
Refuse {Export-Crate $valid $limits} 'updater_crate_archive_limit'
$limits=Get-UpdaterCrateLimits;$limits.ExpandedBytes=512
Refuse {Export-Crate $valid $limits} 'updater_crate_expanded_limit'
$limits=Get-UpdaterCrateLimits;$limits.Entries=1
Refuse {Export-Crate $valid $limits} 'updater_crate_entry_limit'
$limits=Get-UpdaterCrateLimits;$limits.NoticeBytes=1
Refuse {Export-Crate $valid $limits} 'updater_crate_notice_limit'
$limits=Get-UpdaterCrateLimits;$limits.TotalNoticeBytes=1
Refuse {Export-Crate $valid $limits} 'updater_crate_notice_limit'
$limits=Get-UpdaterCrateLimits;$limits.Seconds=0
Refuse {Export-Crate $valid $limits} 'updater_crate_deadline'
$n=0
foreach($path in @('fixture-1.0.0/../escape','fixture-1.0.0/./alias','fixture-1.0.0/a//b','fixture-1.0.0/a\b','fixture-1.0.0/C:escape','fixture-1.0.0/AUX','fixture-1.0.0/end.','other-1.0.0/LICENSE')){
    $n++;$bad=New-Crate "path-$n" ($base+@{path=$path;text='bad'})
    Refuse {Export-Crate $bad} 'updater_crate_entry_path_invalid'
}
foreach($type in @([System.Formats.Tar.TarEntryType]::SymbolicLink,[System.Formats.Tar.TarEntryType]::HardLink)){
    $bad=New-Crate "$type" ($base+@{path='fixture-1.0.0/unsafe';type=$type})
    Refuse {Export-Crate $bad} 'updater_crate_entry_type_invalid'
}
$bad=New-Crate 'case-alias' ($base+@{path='fixture-1.0.0/license-mit';text='alias'})
Refuse {Export-Crate $bad} 'updater_crate_duplicate_path'
$bad=New-Crate 'manifest-mismatch' @(@{path='fixture-1.0.0/Cargo.toml';text=$manifest.Replace('1.0.0','2.0.0')})
Refuse {Export-Crate $bad} 'updater_crate_manifest_identity_mismatch'
$bad=New-Crate 'missing-manifest' @($base[1])
Refuse {Export-Crate $bad} 'updater_crate_manifest_missing'
$explicit=$manifest+"license-file = `"legal/full-text.md`"`n"
$other=New-Crate 'explicit' @(@{path='fixture-1.0.0/Cargo.toml';text=$explicit},@{path='fixture-1.0.0/legal/full-text.md';text="Exact declared text`n"})
$export=Export-Crate $other
Check ($export.Result.notices.Count -eq 1 -and $export.Result.notices[0].selection -ceq 'declared-license-file' -and [IO.File]::ReadAllText((Join-Path $export.Output 'notices/legal/full-text.md')) -ceq "Exact declared text`n") 'explicit nonstandard license filename retained'
$bad=New-Crate 'missing-explicit' @(@{path='fixture-1.0.0/Cargo.toml';text=$explicit})
Refuse {Export-Crate $bad} 'updater_crate_declared_license_missing'
$none=New-Crate 'no-notices' @(@{path='fixture-1.0.0/Cargo.toml';text=$manifest})
$empty=Export-Crate $none
Check (!$empty.Result.completeLicenseCoverage -and $empty.Result.issues -contains 'notice_texts_missing') 'missing notice never coverage PASS'
$pins=Get-UpdaterCratePins $repo
Check ($pins.Count -eq 282) 'actual exact two-lock membership'
$pinRepo=Join-Path $fixture 'pin-repo'
foreach($path in @('scripts/release/shorebird-updater-notices-crates.lock.json','scripts/release/shorebird-updater-notices.lock.json')+@($pins.Pin.sources.path)){
    $target=Join-Path $pinRepo $path;[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))|Out-Null
    [IO.File]::Copy((Join-Path $repo $path),$target,$false)
}
$pinPath=Join-Path $pinRepo 'scripts/release/shorebird-updater-notices-crates.lock.json'
$original=[IO.File]::ReadAllBytes($pinPath)
$mutable=Get-Content -LiteralPath $pinPath -Raw|ConvertFrom-Json -AsHashtable
$mutable.crates=$mutable.crates[1..($mutable.crates.Count-1)];Write-AuditJson $pinPath $mutable
Refuse {Get-UpdaterCratePins $pinRepo} 'updater_crate_membership_mismatch'
[IO.File]::WriteAllBytes($pinPath,$original)
$mutable=Get-Content -LiteralPath $pinPath -Raw|ConvertFrom-Json -AsHashtable
$mutable.crates[0].sha256='0'*64;Write-AuditJson $pinPath $mutable
Refuse {Get-UpdaterCratePins $pinRepo} 'updater_crate_membership_mismatch'
[IO.File]::WriteAllBytes($pinPath,$original)
$mutable=Get-Content -LiteralPath $pinPath -Raw|ConvertFrom-Json -AsHashtable
$mutable.updaterRevision='a'*40;Write-AuditJson $pinPath $mutable
Refuse {Get-UpdaterCratePins $pinRepo} 'updater_crate_pin_invalid'
[IO.File]::WriteAllBytes($pinPath,$original)
$mutable=Get-Content -LiteralPath $pinPath -Raw|ConvertFrom-Json -AsHashtable
$mutable.schemaVersion=$true;Write-AuditJson $pinPath $mutable
Refuse {Get-UpdaterCratePins $pinRepo} 'updater_crate_pin_invalid'
[IO.File]::WriteAllBytes($pinPath,$original)
$mutable=Get-Content -LiteralPath $pinPath -Raw|ConvertFrom-Json -AsHashtable
$mutable.crates[0].name='../escape';Write-AuditJson $pinPath $mutable
Refuse {Get-UpdaterCratePins $pinRepo} 'updater_crate_identity_invalid'
[IO.File]::WriteAllBytes($pinPath,$original)
$sourcePath=Join-Path $pinRepo $pins.Pin.sources[1].path
[IO.File]::AppendAllText($sourcePath,"`nchanged")
Refuse {Get-UpdaterCratePins $pinRepo} 'shorebird_updater_input_mismatch'
Refuse {Assert-UpdaterPrivatePath $repo (Join-Path $repo 'apps/unsafe')} 'updater_crate_output_outside_workspace'
$offline=Join-Path $fixture 'offline-output'
Refuse {& (Join-Path $PSScriptRoot 'shorebird-updater-notices-prepare.ps1') -CacheDirectory (Join-Path $fixture 'offline-cache') -OutputDirectory $offline} 'updater_crate_archive_missing_offline'
$report=Get-Content -LiteralPath (Join-Path $offline 'report.json') -Raw|ConvertFrom-Json
Check (!$report.acquisitionExplicit -and $report.networkBytes -eq 0 -and $report.verifiedArchives -eq 0 -and $report.status -ceq 'FAILED') 'default offline execution performs no network'
Refuse {& (Join-Path $PSScriptRoot 'shorebird-updater-notices-prepare.ps1') -CacheDirectory (Join-Path $fixture 'offline-cache') -OutputDirectory $offline} 'updater_crate_output_exists_or_overlaps'
Write-Output "Updater crate notices: $script:checks checks passed."
