#requires -Version 7.0
# Android packaging checks; no build/cache/network mutation. Engine binding
# may recalculate a pinned transform in a new artifacts staging directory.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'notice-inputs.ps1')
. (Join-Path $PSScriptRoot 'artifact-audit-lib.ps1')

function Get-AndroidNoticePinPaths {
    @('apps/exvpn/pubspec.yaml', 'apps/exvpn/pubspec.lock', 'apps/exvpn/lib/build_identity.dart',
      'apps/exvpn/android/app/build.gradle.kts', 'scripts/bootstrap/toolchain.lock.json',
      'scripts/bootstrap/shorebird.lock.json', 'scripts/release/flutter-runtime-inputs.ps1',
      'scripts/release/android-engine-transform.lock.json',
      'native/core/go.mod', 'native/core/go.sum', 'native/android/go.mod', 'native/android/go.sum',
      'native/patches/xray-lifecycle.lock.json', 'native/patches/xray-lifecycle.patch',
      'scripts/release/collect-notices.ps1', 'scripts/release/notice-inputs.ps1',
      'scripts/release/artifact-audit-lib.ps1', 'scripts/release/android-notice-inputs.ps1',
      'scripts/release/prepare-android-notices.ps1', 'scripts/release/verify-android-notices.ps1',
      'LICENSE', 'NOTICE')
}

function Assert-AndroidNoticeDirectory([string]$Repository, [string]$InputDirectory) {
    $allowed = [IO.Path]::GetFullPath((Join-Path $Repository 'artifacts/android-package-inputs')) + [IO.Path]::DirectorySeparatorChar
    $inputPath = [IO.Path]::GetFullPath($InputDirectory)
    if (!$inputPath.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'android_notice_input_directory_outside_staging' }
    Assert-AuditNoLinks $inputPath
    foreach ($item in Get-ChildItem -LiteralPath $inputPath -Force) {
        if ($item.Name -cnotin @('jniLibs', 'assets', 'seal.json')) { throw 'unexpected_android_package_input' }
    }
}

function Get-AndroidNoticeSnapshotState(
    [string]$Repository, [string]$InputDirectory, [string]$ExpectedVersion = '',
    [ValidateSet('ordinary','shorebird')][string]$FlutterRuntime = 'ordinary',
    [ValidateSet('','debug','release')][string]$FlutterBuildMode = ''
) {
    Assert-AndroidNoticeDirectory $Repository $InputDirectory
    $version = Get-NoticeAppVersion ([IO.File]::ReadAllText((Join-Path $Repository 'apps/exvpn/pubspec.yaml'))) ([IO.File]::ReadAllText((Join-Path $Repository 'apps/exvpn/lib/build_identity.dart')))
    if ($ExpectedVersion -and $version -cne $ExpectedVersion) { throw 'android_notice_gradle_version_mismatch' }
    $dartLockPath = Join-Path $Repository 'apps/exvpn/pubspec.lock'
    $dartLockHash = Get-AuditSha256 $dartLockPath
    $pins = @((Get-AndroidNoticePinPaths) | Sort-Object -CaseSensitive -Culture en-US | ForEach-Object {
        $pin = Join-Path $Repository $_
        Assert-AuditNoLinks $pin
        [ordered]@{ path = $_; sha256 = Get-AuditSha256 $pin }
    })
    $jni = Get-AuditTreeFiles (Join-Path $InputDirectory 'jniLibs')
    if ($jni.Count -ne 2) { throw 'android_notice_jni_file_set_mismatch' }
    $nativeHashes = @{}
    foreach ($abi in @('arm64-v8a', 'x86_64')) {
        $relative = "$abi/libexvpn.so"
        if (!$jni.ContainsKey($relative)) { throw 'android_notice_jni_abi_missing' }
        $source = Join-Path $Repository ".tools/artifacts/android-jni/$relative"
        Assert-AuditNoLinks $source
        if ($jni[$relative].sha256 -cne (Get-AuditSha256 $source)) { throw 'android_notice_native_snapshot_stale' }
        $nativeHashes["lib/$relative"] = $jni[$relative].sha256
    }
    $assets = Get-AuditTreeFiles (Join-Path $InputDirectory 'assets')
    foreach ($path in $assets.Keys) {
        if (!$path.StartsWith('exvpn_notices/', [StringComparison]::Ordinal)) { throw 'android_notice_asset_outside_bundle' }
    }
    $bundle = Join-Path $InputDirectory 'assets/exvpn_notices'
    $bundleFiles = Get-AuditTreeFiles $bundle
    $inventory = Get-Content -LiteralPath (Join-Path $bundle 'inventory.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($inventory.target -cne 'Android') { throw 'android_notice_wrong_target' }
    $runtime = $null
    if ($inventory.Contains('runtime')) {
        $resolvedRuntime = Get-ReleaseFlutterRuntime -Repository $Repository -Target Android -FlutterRuntime $FlutterRuntime -FlutterBuildMode $FlutterBuildMode
        $runtime = $resolvedRuntime.Evidence
    } elseif ($FlutterRuntime -cne 'ordinary' -or $FlutterBuildMode -cnotin @('','debug')) {
        throw 'flutter_runtime_evidence_missing'
    }
    # Legacy ordinary snapshots retain their existing checks. Every newly
    # collected snapshot carries runtime evidence; Shorebird never accepts legacy.
    Assert-NoticePackageBinding $inventory $version $dartLockHash $nativeHashes $runtime
    $allowedFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in @('inventory.json', 'README.txt', 'ASSET_SOURCES.md', 'sources/xray-core.zip')) {
        [void]$allowedFiles.Add($path)
        if (!$bundleFiles.ContainsKey($path) -or !$bundleFiles[$path].size) { throw 'android_notice_required_file_missing' }
    }
    foreach ($component in $inventory.components) {
        if (!$component.notices.Count) { throw 'android_notice_component_text_missing' }
        foreach ($notice in $component.notices) {
            $path = ConvertTo-AuditPath $notice.path
            [void]$allowedFiles.Add($path)
            if ($notice.sha256 -cnotmatch '^[a-f0-9]{64}$' -or !$bundleFiles.ContainsKey($path) -or !$bundleFiles[$path].size -or $bundleFiles[$path].sha256 -cne $notice.sha256) { throw 'android_notice_text_hash_mismatch' }
        }
    }
    $goPins = Get-AuditGoPins (Join-Path $Repository 'native/android/go.mod') (Join-Path $Repository 'native/android/go.sum')
    $xrayPin = $goPins['github.com/xtls/xray-core']
    if (!$xrayPin -or !$xrayPin.sum -or (Get-AuditGoZipSum (Join-Path $bundle 'sources/xray-core.zip')) -cne $xrayPin.sum) { throw 'android_notice_xray_source_mismatch' }
    $patchEvidence = Get-NoticeXrayPatch $Repository $xrayPin.version $xrayPin.sum
    if ($patchEvidence) {
        Assert-NoticeXraySourceBundle $patchEvidence $bundleFiles
        foreach ($path in @('sources/xray-lifecycle.patch', 'sources/xray-lifecycle.lock.json', 'sources/XRAY-EXVPN-NOTICE.txt')) {
            [void]$allowedFiles.Add($path)
            if (!$bundleFiles[$path].size) { throw 'android_notice_required_file_missing' }
        }
    }
    foreach ($path in $bundleFiles.Keys) {
        if (!$allowedFiles.Contains($path)) { throw 'android_notice_unlisted_bundle_file' }
    }
    foreach ($own in @(@('ExVPN', 'LICENSE'), @('ExVPN copyright', 'NOTICE'))) {
        $component = @($inventory.components | Where-Object { $_.name -ceq $own[0] })
        $hash = Get-AuditSha256 (Join-Path $Repository $own[1])
        if ($component.Count -ne 1 -or !@($component[0].notices | Where-Object { $_.sha256 -ceq $hash }).Count) { throw 'android_notice_own_text_mismatch' }
    }
    $locked = Get-NoticeLockedPackages ([IO.File]::ReadAllText($dartLockPath))
    $hosted = @($locked.Values | Where-Object { $_.source -ceq 'hosted' })
    if (!$inventory['dartPackages'] -or $inventory.dartPackages.Count -ne $hosted.Count) { throw 'android_notice_dart_set_mismatch' }
    $seenDart = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($package in $inventory.dartPackages) {
        if (!$seenDart.Add($package.name) -or !$locked.ContainsKey($package.name) -or $package.source -cne 'hosted' -or $package.version -cne $locked[$package.name].version -or $package.sha256 -cne $locked[$package.name].sha256) { throw 'android_notice_dart_pin_mismatch' }
        $component = @($inventory.components | Where-Object { $_.scope -ceq 'resolved-dart-package' -and $_.name -ceq $package.name -and $_.version -ceq $package.version })
        if ($component.Count -ne 1) { throw 'android_notice_dart_component_missing' }
    }
    [ordered]@{
        schema = 1; appVersion = $version; dartLockSha256 = $dartLockHash; pins = $pins
        runtime = $runtime
        nativeFiles = @($jni.Values | Sort-Object { $_.path } -CaseSensitive -Culture en-US)
        assetFiles = @($assets.Values | Sort-Object { $_.path } -CaseSensitive -Culture en-US)
    }
}

function Assert-AndroidNoticeNativeInfo([string]$Repository, [string]$InputDirectory) {
    $toolchain = Get-Content -LiteralPath (Join-Path $Repository 'scripts/bootstrap/toolchain.lock.json') -Raw | ConvertFrom-Json -AsHashtable
    $go = Join-Path $Repository '.tools/go/bin/go.exe'
    $goPins = Get-AuditGoPins (Join-Path $Repository 'native/android/go.mod') (Join-Path $Repository 'native/android/go.sum')
    $evidence = [Collections.Generic.List[object]]::new()
    $findings = [Collections.Generic.List[object]]::new()
    foreach ($abi in @('arm64-v8a', 'x86_64')) {
        $binary = Join-Path $InputDirectory "jniLibs/$abi/libexvpn.so"
        $info = (Invoke-AuditTool $go @('version', '-m', '-json', $binary)) | ConvertFrom-Json -AsHashtable
        $evidence.Add((Test-AuditGoBinary $info "lib/$abi/libexvpn.so" (Get-AuditSha256 $binary) $goPins $toolchain.go.version $findings))
    }
    $bundle = Join-Path $InputDirectory 'assets/exvpn_notices'
    $inventory = Get-Content -LiteralPath (Join-Path $bundle 'inventory.json') -Raw | ConvertFrom-Json -AsHashtable
    $version = Get-NoticeAppVersion ([IO.File]::ReadAllText((Join-Path $Repository 'apps/exvpn/pubspec.yaml'))) ([IO.File]::ReadAllText((Join-Path $Repository 'apps/exvpn/lib/build_identity.dart')))
    Test-AuditNotices $inventory (Get-AuditTreeFiles $bundle) $evidence 'Android' $version (Get-AuditSha256 (Join-Path $Repository 'apps/exvpn/pubspec.lock')) $findings
    if ($findings.Count) { throw 'android_notice_embedded_native_binding_failed' }
}

function Assert-AndroidNoticeSeal(
    [string]$Repository, [string]$InputDirectory, [string]$ExpectedVersion = '',
    [ValidateSet('ordinary','shorebird')][string]$FlutterRuntime = 'ordinary',
    [ValidateSet('','debug','release')][string]$FlutterBuildMode = ''
) {
    $state = Get-AndroidNoticeSnapshotState $Repository $InputDirectory $ExpectedVersion -FlutterRuntime $FlutterRuntime -FlutterBuildMode $FlutterBuildMode
    $sealPath = Join-Path $InputDirectory 'seal.json'
    if (!(Test-Path -LiteralPath $sealPath -PathType Leaf)) { throw 'android_notice_seal_missing' }
    Assert-AuditNoLinks $sealPath
    $seal = Get-Content -LiteralPath $sealPath -Raw | ConvertFrom-Json -AsHashtable
    # Rebuild the complete expected state from bytes/current pins; a matching
    # self-declared seal hash is not enough to make stale or corrupt input valid.
    if (($state | ConvertTo-Json -Depth 12 -Compress) -cne ($seal | ConvertTo-Json -Depth 12 -Compress)) { throw 'android_notice_seal_stale_or_tampered' }
}

function Assert-AndroidPackagedNotices(
    [string]$Repository, [string]$InputDirectory, [string]$ApkPath,
    [ValidateSet('ordinary','shorebird')][string]$FlutterRuntime = 'ordinary',
    [ValidateSet('','debug','release')][string]$FlutterBuildMode = '',
    [switch]$PassThruRuntime,
    [string]$AndroidSdkPath = ''
) {
    # Inspect final ZIP bytes: preBuild verification alone cannot detect AGP
    # transformations (such as a second native strip) or omitted assets.
    Assert-AndroidNoticeSeal $Repository $InputDirectory -FlutterRuntime $FlutterRuntime -FlutterBuildMode $FlutterBuildMode
    $seal = Get-Content -LiteralPath (Join-Path $InputDirectory 'seal.json') -Raw | ConvertFrom-Json -AsHashtable
    $expected = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($file in $seal.nativeFiles) { $expected.Add("lib/$($file.path)", $file) }
    foreach ($file in $seal.assetFiles) { $expected.Add("assets/$($file.path)", $file) }
    $actual = Get-AuditZipFiles $ApkPath -Apk
    Assert-AuditAndroidAbiCoverage $actual
    foreach ($path in $expected.Keys) {
        if (!$actual.ContainsKey($path) -or $actual[$path].sha256 -cne $expected[$path].sha256 -or $actual[$path].size -ne $expected[$path].size) {
            throw 'android_packaged_native_or_notice_mismatch'
        }
    }
    foreach ($path in $actual.Keys) {
        if (($path.StartsWith('assets/exvpn_notices/', [StringComparison]::OrdinalIgnoreCase) -or $path -imatch '^lib/[^/]+/libexvpn\.so$') -and !$expected.ContainsKey($path)) {
            throw 'android_packaged_unexpected_native_or_notice'
        }
    }
    if ($seal.runtime) {
        $resolvedRuntime = Get-ReleaseFlutterRuntime -Repository $Repository -Target Android -FlutterRuntime $FlutterRuntime -FlutterBuildMode $FlutterBuildMode
        Assert-ReleaseFlutterRuntimeEvidence $resolvedRuntime.Evidence $seal.runtime
        $runtimeEvidence = Get-ReleaseAndroidPackagedFlutterEvidence $resolvedRuntime $actual $Repository -AndroidSdkPath $AndroidSdkPath
        if ($PassThruRuntime) { $runtimeEvidence }
    } elseif ($PassThruRuntime) { throw 'flutter_runtime_evidence_missing' }
}
