# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param([switch]$WithPinnedParser)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'android-aab-dependencies-lib.ps1')
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$root=Join-Path $repository ('artifacts/qa/aab-fixtures-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$checks=0
function Check([bool]$Value) { if (!$Value) { throw 'aab_fixture_assertion' }; $script:checks++ }
function Reject([scriptblock]$Action,[string]$Code) {
    $observed=''
    try { & $Action | Out-Null } catch { $observed=$_.Exception.Message }
    if ($observed -cne $Code) { throw "aab_fixture_expected_$Code`_got_$observed" }
    $script:checks++
}
function Clone($Value) { $Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable }
$cache=Join-Path $root 'cache'
$artifact=Join-Path $cache 'example.test/library/1.0/hash/library-1.0.jar'
[IO.Directory]::CreateDirectory((Split-Path $artifact)) | Out-Null
[IO.File]::WriteAllText($artifact,'synthetic byte-bound library')
$hash=Get-AuditSha256 $artifact
$node=[ordered]@{index=0;group='example.test';name='library';version='1.0';packaging='';classifier='';sha256=$hash;repositoryIndex=$null}
$metadataHash='a'*64
$decoded=[ordered]@{schema=1;metadataSha256=$metadataHash;libraries=@($node)}
$binding=Get-AabMavenBindings $decoded $cache $metadataHash
Check ($binding.bound.Count -eq 1 -and $binding.unbound.Count -eq 0 -and $binding.bound[0].sha256 -ceq $hash)
$without=Clone $decoded
$without.libraries[0].sha256=$null
$binding=Get-AabMavenBindings $without $cache $metadataHash
Check ($binding.bound.Count -eq 0 -and $binding.unbound[0].reason -ceq 'producer_reported_no_file_digest')
foreach ($invalid in @('.','..','../outside','x/y','x\y','1.+','latest.release','1.0-SNAPSHOT','',42,$null)) {
    $copy=Clone $decoded
    $copy.libraries[0].version=$invalid
    Reject { Get-AabMavenBindings $copy $cache $metadataHash } 'aab_coordinate_invalid'
}
Reject { Get-AabCacheDirectory $cache '../outside' } 'aab_cache_path_outside_root'
Reject { Get-AabCacheDirectory $cache '.' } 'aab_cache_path_outside_root'
foreach ($invalid in @(('b'*64),'12','',42)) {
    $copy=Clone $decoded
    $copy.libraries[0].sha256=$invalid
    $code=if ($invalid -is [string] -and $invalid.Length -eq 64) { 'aab_binary_hash_missing_or_ambiguous' } else { 'aab_digest_invalid' }
    Reject { Get-AabMavenBindings $copy $cache $metadataHash } $code
}
$copy=Clone $decoded
$copy.libraries+=$copy.libraries[0]
Reject { Get-AabMavenBindings $copy $cache $metadataHash } 'aab_duplicate_or_invalid_library'
foreach ($invalid in @(-1,'0',1)) {
    $copy=Clone $decoded; $copy.libraries[0].index=$invalid
    Reject { Get-AabMavenBindings $copy $cache $metadataHash } 'aab_duplicate_or_invalid_library'
}
$copy=Clone $decoded; $copy.libraries[0].packaging='exe'
Reject { Get-AabMavenBindings $copy $cache $metadataHash } 'aab_binary_packaging_unsupported'
$copy=Clone $decoded; $copy.libraries[0].version='2.0'
Reject { Get-AabMavenBindings $copy $cache $metadataHash } 'aab_binary_not_available'
$copy=Clone $decoded; $copy.metadataSha256='b'*64
Reject { Get-AabMavenBindings $copy $cache $metadataHash } 'aab_decoded_identity_invalid'
$copy=Clone $decoded; $copy.libraries=@()
Reject { Get-AabMavenBindings $copy $cache $metadataHash } 'aab_decoded_identity_invalid'
$duplicate=Join-Path (Split-Path (Split-Path $artifact)) 'duplicate/library-1.0.jar'
[IO.Directory]::CreateDirectory((Split-Path $duplicate)) | Out-Null
Copy-Item -LiteralPath $artifact -Destination $duplicate
Reject { Get-AabMavenBindings $decoded $cache $metadataHash } 'aab_binary_hash_missing_or_ambiguous'
Remove-Item -LiteralPath $duplicate
[IO.File]::WriteAllText($artifact,'tampered library')
Reject { Get-AabMavenBindings $decoded $cache $metadataHash } 'aab_binary_hash_missing_or_ambiguous'

$entry='BUNDLE-METADATA/com.android.tools.build.libraries/dependencies.pb'
$producer='BUNDLE-METADATA/com.android.tools.build.gradle/app-metadata.properties'
function FixtureZip([object[]]$Entries) {
    $path=Join-Path $root ([guid]::NewGuid().ToString('N')+'.aab')
    $zip=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($pair in $Entries) {
            $stream=$zip.CreateEntry($pair.name).Open()
            try { $bytes=[Text.Encoding]::UTF8.GetBytes($pair.text); $stream.Write($bytes,0,$bytes.Length) }
            finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
    $path
}
$goodEntries=@(@{name=$entry;text='synthetic protobuf read separately'},@{name=$producer;text="appMetadataVersion=1.1`nandroidGradlePluginVersion=9.1.0`n"})
$zip=FixtureZip $goodEntries
$zipHash=Get-AuditSha256 $zip
$embedded=Get-AabEmbeddedDependencies $zip $zipHash
Check ($embedded.entry -ceq $entry -and $embedded.bytes.Length -eq 34)
Reject { Get-AabEmbeddedDependencies $zip ('b'*64) } 'aab_hash_mismatch'
Reject { Get-AabEmbeddedDependencies ($zip+'.apk') $zipHash } 'aab_input_identity_invalid'
$zip=FixtureZip @($goodEntries[1])
Reject { Get-AabEmbeddedDependencies $zip (Get-AuditSha256 $zip) } 'aab_dependencies_metadata_missing'
$zip=FixtureZip @(@{name=$entry;text=''},$goodEntries[1])
Reject { Get-AabEmbeddedDependencies $zip (Get-AuditSha256 $zip) } 'aab_dependencies_metadata_empty'
$zip=FixtureZip @($goodEntries[0],@{name=$producer;text='androidGradlePluginVersion=9.2.0'})
Reject { Get-AabEmbeddedDependencies $zip (Get-AuditSha256 $zip) } 'aab_producer_not_pinned'
$zip=FixtureZip @($goodEntries[0],@{name=$producer;text="androidGradlePluginVersion=9.1.0`nandroidGradlePluginVersion=9.1.0"})
Reject { Get-AabEmbeddedDependencies $zip (Get-AuditSha256 $zip) } 'aab_producer_not_pinned'
$zip=FixtureZip @($goodEntries[0],$goodEntries[0],$goodEntries[1])
Reject { Get-AabEmbeddedDependencies $zip (Get-AuditSha256 $zip) } 'duplicate_archive_path'
$zip=FixtureZip @($goodEntries[0],@{name=$entry.ToLowerInvariant();text='collision'},$goodEntries[1])
Reject { Get-AabEmbeddedDependencies $zip (Get-AuditSha256 $zip) } 'duplicate_archive_path'
$zip=FixtureZip @($goodEntries[0],$goodEntries[1],@{name='../escape';text='bad'})
Reject { Get-AabEmbeddedDependencies $zip (Get-AuditSha256 $zip) } 'unsafe_relative_path'

$parserResult=$null
if ($WithPinnedParser) {
    $tools=Get-AabPinnedTools (Join-Path $repository '.tools/cache/gradle/caches/modules-2/files-2.1') (Join-Path $PSScriptRoot 'android-aab-dependencies.lock.json')
    $parserResult=Invoke-AabParser 'C:/Program Files/Android/Android Studio/jbr/bin/java.exe' @($tools.files.path) (Join-Path $PSScriptRoot 'AndroidAabDependencies.java') @('--test')
    Check ($parserResult -ceq 'AAB_PROTOBUF_FIXTURES_PASS 18')
}
[ordered]@{status='PASS';checks=$checks;parser=$parserResult} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'proof.json') -Encoding utf8NoBOM
Write-Host "AAB binding fixtures: $checks PASS. $parserResult"
Write-Host "Evidence: $root"
