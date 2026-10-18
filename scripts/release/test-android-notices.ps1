#requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'android-notice-inputs.ps1')
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixtureRoot = Join-Path $repository ('artifacts/android-notice-fixtures/' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$checks = 0

function Write-FixtureFile([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
function New-NoticeFixture {
    param([switch]$WithoutSeal, [switch]$Patched)
    $root = Join-Path $fixtureRoot ([Guid]::NewGuid().ToString('N'))
    foreach ($pin in Get-AndroidNoticePinPaths) { Write-FixtureFile (Join-Path $root $pin) 'synthetic pinned source' }
    Write-FixtureFile (Join-Path $root 'apps/exvpn/pubspec.yaml') "name: exvpn`nversion: 0.1.0+9`n"
    Write-FixtureFile (Join-Path $root 'apps/exvpn/lib/build_identity.dart') "const appVersion = '0.1.0';`nconst appBuild = 9;`n"
    $lock = @'
packages:
  fixture_dep:
    dependency: direct main
    description:
      name: fixture_dep
      sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      url: "https://pub.dev"
    source: hosted
    version: "1.2.3"
sdks:
  dart: ">=3.13.0 <4.0.0"
'@
    Write-FixtureFile (Join-Path $root 'apps/exvpn/pubspec.lock') $lock
    $stage = Join-Path $root 'artifacts/android-package-inputs/fixture'
    $native = @()
    foreach ($abi in @('arm64-v8a', 'x86_64')) {
        Write-FixtureFile (Join-Path $root ".tools/artifacts/android-jni/$abi/libexvpn.so") "synthetic $abi JNI"
        $copy = Join-Path $stage "jniLibs/$abi/libexvpn.so"
        Write-FixtureFile $copy "synthetic $abi JNI"
        $native += [ordered]@{ name = "lib/$abi/libexvpn.so"; sha256 = Get-AuditSha256 $copy }
    }
    $bundle = Join-Path $stage 'assets/exvpn_notices'
    Write-FixtureFile (Join-Path $bundle 'README.txt') 'synthetic notices'
    Write-FixtureFile (Join-Path $bundle 'ASSET_SOURCES.md') 'synthetic assets'
    New-Item -ItemType Directory -Path (Join-Path $bundle 'sources') | Out-Null
    $source = Join-Path $bundle 'sources/xray-core.zip'
    $xrayVersion = if ($Patched) { 'v1.0.0-exvpn.1' } else { 'v1.0.0' }
    $zip = [IO.Compression.ZipFile]::Open($source, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $zip.CreateEntry("github.com/xtls/xray-core@$xrayVersion/LICENSE")
        $stream = $entry.Open()
        try { $bytes = [Text.Encoding]::UTF8.GetBytes('synthetic source'); $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    } finally { $zip.Dispose() }
    $sum = Get-AuditGoZipSum $source
    Write-FixtureFile (Join-Path $root 'native/android/go.mod') "module example.org/native`nrequire github.com/xtls/xray-core $xrayVersion`n"
    Write-FixtureFile (Join-Path $root 'native/android/go.sum') "github.com/xtls/xray-core $xrayVersion $sum`n"
    if ($Patched) {
        $patchPath = Join-Path $root 'native/patches/xray-lifecycle.patch'
        $patchLock = Join-Path $root 'native/patches/xray-lifecycle.lock.json'
        Write-AuditJson $patchLock @{
            schemaVersion=1;module='github.com/xtls/xray-core';upstream=@{commit=('a' * 40)}
            patch=@{path='xray-lifecycle.patch';sha256=(Get-AuditSha256 $patchPath)}
            patched=@{version=$xrayVersion;sum=$sum}
        }
        Copy-Item -LiteralPath $patchPath,$patchLock -Destination (Join-Path $bundle 'sources')
        Write-FixtureFile (Join-Path $bundle 'sources/XRAY-EXVPN-NOTICE.txt') 'Synthetic modified-source notice'
    }
    $components = @()
    foreach ($definition in @(
        @('ExVPN','0.1.0+9','runtime-or-asset','own/LICENSE','synthetic pinned source'),
        @('ExVPN copyright','0.1.0+9','runtime-or-asset','own/NOTICE','synthetic pinned source'),
        @('fixture_dep','1.2.3','resolved-dart-package','dart/LICENSE','synthetic dependency license'),
        @('github.com/xtls/xray-core',$xrayVersion,'linked-go-module','xray/LICENSE','synthetic core license')
    )) {
        $notice = Join-Path $bundle $definition[3]
        Write-FixtureFile $notice $definition[4]
        $components += [ordered]@{ name = $definition[0]; version = $definition[1]; scope = $definition[2]; notices = @([ordered]@{ path = $definition[3]; sha256 = Get-AuditSha256 $notice }) }
    }
    $inventory = [ordered]@{
        schema = 1; target = 'Android'; app = @{ version = '0.1.0+9' }
        dartLockSha256 = Get-AuditSha256 (Join-Path $root 'apps/exvpn/pubspec.lock')
        nativeBinaries = $native; components = $components
        dartPackages = @(@{ name = 'fixture_dep'; version = '1.2.3'; source = 'hosted'; sha256 = ('a' * 64) })
    }
    Write-AuditJson (Join-Path $bundle 'inventory.json') $inventory
    if (!$WithoutSeal) { Write-AuditJson (Join-Path $stage 'seal.json') (Get-AndroidNoticeSnapshotState $root $stage) }
    [pscustomobject]@{ Root = $root; Stage = $stage; Bundle = $bundle; Inventory = $inventory }
}

function Assert-Refused([scriptblock]$Action, [string]$Name, [string]$Code = '') {
    $errorText = ''
    try { & $Action | Out-Null } catch { $errorText = $_.Exception.Message }
    if (!$errorText -or ($Code -and $errorText -cne $Code)) { throw "FAIL: $Name ($errorText)" }
    $script:checks++
}
function Save-Inventory($Fixture) { Write-AuditJson (Join-Path $Fixture.Bundle 'inventory.json') $Fixture.Inventory }

$f = New-NoticeFixture -Patched
Assert-AndroidNoticeSeal $f.Root $f.Stage '0.1.0+9'
$checks++
foreach ($name in @('xray-lifecycle.patch','xray-lifecycle.lock.json','XRAY-EXVPN-NOTICE.txt')) {
    $f = New-NoticeFixture -Patched
    # Delete only this exact synthetic fixture file, never a recursive tree.
    Remove-Item -LiteralPath (Join-Path $f.Bundle "sources/$name")
    Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } "missing modified provenance $name"
}
foreach ($name in @('xray-lifecycle.patch','xray-lifecycle.lock.json')) {
    $f = New-NoticeFixture -Patched
    Write-FixtureFile (Join-Path $f.Bundle "sources/$name") 'tampered provenance'
    Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } "tampered modified provenance $name" 'modified_xray_provenance_mismatch'
}
$f = New-NoticeFixture
Assert-AndroidNoticeSeal $f.Root $f.Stage '0.1.0+9'
$checks++
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage '0.1.0+10' } 'Gradle identity drift' 'android_notice_gradle_version_mismatch'
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Root } 'outside staging' 'android_notice_input_directory_outside_staging'
Write-FixtureFile (Join-Path $f.Stage 'seal.json') '{}'
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } 'forged seal' 'android_notice_seal_stale_or_tampered'
$f = New-NoticeFixture -WithoutSeal
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } 'missing seal' 'android_notice_seal_missing'

$f = New-NoticeFixture
[IO.File]::AppendAllText((Join-Path $f.Root 'native/core/go.mod'), "`n// pin changed")
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } 'current pin changed' 'android_notice_seal_stale_or_tampered'
$f = New-NoticeFixture
Write-FixtureFile (Join-Path $f.Root '.tools/artifacts/android-jni/x86_64/libexvpn.so') 'new native build'
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } 'native source changed' 'android_notice_native_snapshot_stale'
$f = New-NoticeFixture
Write-FixtureFile (Join-Path $f.Stage 'jniLibs/x86_64/libexvpn.so') 'tampered snapshot'
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } 'native snapshot modified' 'android_notice_native_snapshot_stale'
$f = New-NoticeFixture
Write-FixtureFile (Join-Path $f.Stage 'jniLibs/x86_64/extra.so') 'extra'
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } 'extra native file' 'android_notice_jni_file_set_mismatch'
$f = New-NoticeFixture
Write-FixtureFile (Join-Path $f.Stage 'assets/outside.txt') 'outside'
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } 'unexpected asset root' 'android_notice_asset_outside_bundle'
$f = New-NoticeFixture
Write-FixtureFile (Join-Path $f.Bundle 'unlisted.txt') 'extra'
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } 'unlisted bundle file' 'android_notice_unlisted_bundle_file'
$f = New-NoticeFixture
Write-FixtureFile (Join-Path $f.Bundle 'own/LICENSE') 'tampered'
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } 'modified license text' 'android_notice_text_hash_mismatch'
$f = New-NoticeFixture
Write-FixtureFile (Join-Path $f.Bundle 'README.txt') ''
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } 'empty required notice' 'android_notice_required_file_missing'
$f = New-NoticeFixture
$f.Inventory.components[0].notices[0].path = '../outside'
Save-Inventory $f
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } 'notice path traversal' 'unsafe_relative_path'
$f = New-NoticeFixture
$f.Inventory.target = 'Windows'
Save-Inventory $f
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } 'other platform notices' 'android_notice_wrong_target'
$f = New-NoticeFixture
$f.Inventory.dartPackages[0].sha256 = ('b' * 64)
Save-Inventory $f
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } 'wrong pub package digest' 'android_notice_dart_pin_mismatch'
$f = New-NoticeFixture
$f.Inventory.dartPackages += $f.Inventory.dartPackages[0]
Save-Inventory $f
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } 'duplicate Dart package' 'android_notice_dart_set_mismatch'
$f = New-NoticeFixture
$f.Inventory.nativeBinaries[0].sha256 = ('f' * 64)
Save-Inventory $f
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } 'inventory for another native build'
$f = New-NoticeFixture
Write-FixtureFile (Join-Path $f.Root 'apps/exvpn/pubspec.yaml') "name: exvpn`nversion: 0.1.0+10`n"
Write-FixtureFile (Join-Path $f.Root 'apps/exvpn/lib/build_identity.dart') "const appVersion = '0.1.0';`nconst appBuild = 10;`n"
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } 'old notices for new app version'
$f = New-NoticeFixture
Write-FixtureFile (Join-Path $f.Root 'native/android/go.sum') "github.com/xtls/xray-core v1.0.0 h1:wrong`n"
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } 'wrong corresponding source' 'android_notice_xray_source_mismatch'
$f = New-NoticeFixture
Write-FixtureFile (Join-Path $f.Stage 'unexpected.txt') 'unexpected root file'
Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } 'unexpected stage input' 'unexpected_android_package_input'
function New-FixtureApk($Fixture, [string]$Change = '') {
    $apk = Join-Path $Fixture.Root ('fixture-' + [Guid]::NewGuid().ToString('N') + '.apk')
    $seal = Get-Content -LiteralPath (Join-Path $Fixture.Stage 'seal.json') -Raw | ConvertFrom-Json -AsHashtable
    $zip = [IO.Compression.ZipFile]::Open($apk, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($group in @(@{ Source='jniLibs'; Prefix='lib'; Files=$seal.nativeFiles }, @{ Source='assets'; Prefix='assets'; Files=$seal.assetFiles })) {
            foreach ($file in $group.Files) {
                $path = "$($group.Prefix)/$($file.path)"
                if ($Change -eq 'missing-native' -and $path -eq 'lib/x86_64/libexvpn.so') { continue }
                if ($Change -eq 'missing-notice' -and $path -eq 'assets/exvpn_notices/own/LICENSE') { continue }
                $bytes = [IO.File]::ReadAllBytes((Join-Path $Fixture.Stage "$($group.Source)/$($file.path)"))
                if (($Change -eq 'changed-native' -and $path -eq 'lib/x86_64/libexvpn.so') -or ($Change -eq 'changed-notice' -and $path -eq 'assets/exvpn_notices/own/LICENSE')) { $bytes[0] = $bytes[0] -bxor 1 }
                if ($Change -eq 'notice-case-renamed' -and $path -ceq 'assets/exvpn_notices/own/LICENSE') { $path = 'assets/exvpn_notices/own/license' }
                if ($Change -eq 'native-case-renamed' -and $path -ceq 'lib/x86_64/libexvpn.so') { $path = 'lib/x86_64/libexvpn.SO' }
                $stream = $zip.CreateEntry($path).Open()
                try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            }
        }
        foreach ($abi in @('arm64-v8a', 'x86_64')) {
            if ($Change -eq 'missing-flutter' -and $abi -eq 'arm64-v8a') { continue }
            $stream = $zip.CreateEntry("lib/$abi/libflutter.so").Open()
            try { $stream.WriteByte(42) } finally { $stream.Dispose() }
            if ($Fixture.Inventory.Contains('runtime')) {
                $stream = $zip.CreateEntry("lib/$abi/libapp.so").Open()
                try { $stream.WriteByte(43) } finally { $stream.Dispose() }
            }
        }
        # Other application assets are permitted, but new notice/native entries
        # must be part of the verified snapshot rather than silently appended.
        $extra = switch ($Change) {
            'extra-notice' { 'assets/exvpn_notices/unlisted.txt' }
            'extra-abi' { 'lib/armeabi-v7a/libexvpn.so' }
            'foreign-abi-only' { 'lib/armeabi-v7a/libdartjni.so' }
            'x86-dependency' { 'lib/x86/libdependency.so' }
            'case-alias' { 'assets/EXVPN_NOTICES/README.txt' }
            default { 'assets/flutter_assets/example.txt' }
        }
        $stream = $zip.CreateEntry($extra).Open()
        try { $stream.WriteByte(42) } finally { $stream.Dispose() }
        if ($Change -eq 'resource-case-pair') {
            foreach ($name in @('res/zR.png', 'res/zr.png')) {
                $stream = $zip.CreateEntry($name).Open()
                try { $stream.WriteByte(43) } finally { $stream.Dispose() }
            }
        }
    } finally { $zip.Dispose() }
    $apk
}
$f = New-NoticeFixture
$apk = New-FixtureApk $f
Assert-AndroidPackagedNotices $f.Root $f.Stage $apk
$checks++
$apk = New-FixtureApk $f 'resource-case-pair'
Assert-AndroidPackagedNotices $f.Root $f.Stage $apk
$checks++
$apk = New-FixtureApk $f 'notice-case-renamed'
Assert-Refused { Assert-AndroidPackagedNotices $f.Root $f.Stage $apk } 'APK notice case is exact' 'android_packaged_native_or_notice_mismatch'
$apk = New-FixtureApk $f 'native-case-renamed'
Assert-Refused { Assert-AndroidPackagedNotices $f.Root $f.Stage $apk } 'APK native library case is exact' 'android_packaged_incomplete_abi'
foreach ($change in @('changed-native', 'missing-native', 'changed-notice', 'missing-notice', 'extra-notice', 'extra-abi', 'foreign-abi-only', 'x86-dependency', 'missing-flutter', 'case-alias')) {
    $apk = New-FixtureApk $f $change
    Assert-Refused { Assert-AndroidPackagedNotices $f.Root $f.Stage $apk } "final APK $change"
}

# Pin/SDK validation is exercised with actual synthetic Git checkouts by
# test-notice-inputs. Here substitute only that read-only SDK resolver to test
# propagation through the real seal and ZIP checks without a real build.
$savedRuntimeResolver = (Get-Item Function:Get-ReleaseFlutterRuntime).ScriptBlock
$runtimeFixtureEvidence = [ordered]@{
    schema=1; identity=[ordered]@{schema=1;kind='shorebird';target='Android';buildMode='release';flutterRevision=('a' * 40);engineRevision=('b' * 40)}
    notices=@([ordered]@{name='Flutter framework';version='3.47.7';path='LICENSE';sha256=(Get-AuditTextHash 'synthetic runtime notice');size=24})
    sdkArtifacts=@()
    engineBinaries=@(@{path='lib/arm64-v8a/libflutter.so';sha256=(Get-AuditTextHash '*');size=1},@{path='lib/x86_64/libflutter.so';sha256=(Get-AuditTextHash '*');size=1})
}
try {
    function Get-ReleaseFlutterRuntime($Repository,$Target,$FlutterRuntime='ordinary',$FlutterBuildMode='') {
        $evidence=$runtimeFixtureEvidence | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable
        $evidence.identity.kind=$FlutterRuntime
        $evidence.identity.buildMode=if($FlutterBuildMode){$FlutterBuildMode}elseif($FlutterRuntime -ceq 'ordinary'){'debug'}else{'release'}
        [pscustomobject]@{Evidence=$evidence;Identity=$evidence.identity}
    }
    $f=New-NoticeFixture
    Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage -FlutterRuntime shorebird -FlutterBuildMode release } 'legacy cannot become Shorebird' 'flutter_runtime_evidence_missing'
    $f.Inventory.runtime=$runtimeFixtureEvidence
    Write-FixtureFile (Join-Path $f.Bundle 'flutter/NOTICE.txt') 'synthetic runtime notice'
    $f.Inventory.components+=@{name='Flutter framework';version='3.47.7';scope='runtime-or-asset';notices=@(@{path='flutter/NOTICE.txt';sha256=(Get-AuditTextHash 'synthetic runtime notice')})}
    Save-Inventory $f
    Write-AuditJson (Join-Path $f.Stage 'seal.json') (Get-AndroidNoticeSnapshotState $f.Root $f.Stage -FlutterRuntime shorebird -FlutterBuildMode release)
    Assert-AndroidNoticeSeal $f.Root $f.Stage -FlutterRuntime shorebird -FlutterBuildMode release
    $checks++
    Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage } 'ordinary default cannot accept Shorebird' 'flutter_runtime_evidence_mismatch'
    Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage -FlutterRuntime shorebird -FlutterBuildMode debug } 'mode mismatch cannot accept seal' 'flutter_runtime_evidence_mismatch'
    $apk=New-FixtureApk $f
    $packageRuntime=Assert-AndroidPackagedNotices $f.Root $f.Stage $apk -FlutterRuntime shorebird -FlutterBuildMode release -PassThruRuntime
    if (!$packageRuntime.engineBytesBound -or $packageRuntime.dartBinaries.Count -ne 2 -or $packageRuntime.completeLinkInventory) { throw 'Packaged runtime identity was lost or overstated.' }
    $checks++
    $f.Inventory.runtime=$null; Save-Inventory $f
    Assert-Refused { Assert-AndroidNoticeSeal $f.Root $f.Stage -FlutterRuntime shorebird -FlutterBuildMode release } 'null runtime evidence' 'flutter_runtime_evidence_mismatch'
} finally { Set-Item Function:Get-ReleaseFlutterRuntime $savedRuntimeResolver }
Write-Host "Android notice snapshot fixtures: $checks PASS. No APK build, SDK download, device access or shared build-directory changes."
