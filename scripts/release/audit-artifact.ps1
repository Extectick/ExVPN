#requires -Version 7.0
<# Offline, read-only release inventory audit. Exit 0 requires no blockers;
   2 means incomplete/failed release evidence; 1 means invalid input/tool failure.
   Does not install/execute an APK/installer or sign anything. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArtifactPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$NoticesDirectory = '',
    [ValidatePattern('^$|^[a-fA-F0-9]{64}$')][string]$ExpectedSignerSha256 = '',
    [string]$AndroidSdkPath = '',
    [string]$JavaPath = 'C:/Program Files/Android/Android Studio/jbr/bin/java.exe',
    [ValidateSet('ordinary','shorebird')][string]$FlutterRuntime = 'ordinary',
    [ValidateSet('','debug','release')][string]$FlutterBuildMode = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'artifact-audit-lib.ps1')
. (Join-Path $PSScriptRoot 'nsis-audit-lib.ps1')
. (Join-Path $PSScriptRoot 'notice-inputs.ps1')
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$inputPath = [IO.Path]::GetFullPath($ArtifactPath)
$output = [IO.Path]::GetFullPath($OutputDirectory)
$allowedOutput = [IO.Path]::GetFullPath((Join-Path $repository 'artifacts/release-audit')) + [IO.Path]::DirectorySeparatorChar
if (!$output.StartsWith($allowedOutput, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $output)) {
    throw 'Choose a new output directory below artifacts/release-audit; existing evidence is never overwritten.'
}
$outputParent = [IO.Path]::GetDirectoryName($output)
while (!(Test-Path -LiteralPath $outputParent)) { $outputParent = [IO.Path]::GetDirectoryName($outputParent) }
Assert-AuditNoLinks $outputParent
Assert-AuditNoLinks $inputPath
New-Item -ItemType Directory -Path $output | Out-Null
$findings = [Collections.Generic.List[object]]::new()
$native = [Collections.Generic.List[object]]::new()
$toolsUsed = [Collections.Generic.List[object]]::new()
$inventory = $null
$noticeFiles = New-AuditFileMap
$noticeRoot = ''
$noticeSource = 'missing'
$sourceZip = ''
$sourceCorrespondence = [ordered]@{ present = $false; zipSha256 = ''; linkedModuleSum = ''; actualGoSum = ''; matched = $false; patch = $null }
$signature = [ordered]@{ verified = $false; trustedSignerMatched = $false; debug = $false; certificateSha256 = @() }
$nsisEvidence = [ordered]@{ verified=$false }
$flutterRuntimeEvidence = $null
$flutterRuntimeInputs = $null
$pinPaths = @('apps/exvpn/pubspec.yaml', 'apps/exvpn/pubspec.lock', 'scripts/bootstrap/toolchain.lock.json',
    'scripts/windows/wintun.lock.json', 'scripts/windows/msvc-runtime.lock.json', 'scripts/windows/nsis.lock.json',
    'native/windows/go.mod', 'native/windows/go.sum', 'native/android/go.mod', 'native/android/go.sum',
    'native/core/go.mod', 'native/core/go.sum', 'LICENSE', 'NOTICE',
    'native/patches/xray-lifecycle.lock.json', 'native/patches/xray-lifecycle.patch',
    'scripts/release/audit-artifact.ps1', 'scripts/release/artifact-audit-lib.ps1', 'scripts/release/notice-inputs.ps1',
    'scripts/release/nsis-audit-lib.ps1', 'scripts/release/archive-inspector.lock.json',
    'scripts/bootstrap/shorebird.lock.json', 'scripts/release/flutter-runtime-inputs.ps1',
    'scripts/release/android-engine-transform.lock.json')
$pinEvidence = @($pinPaths | Sort-Object -CaseSensitive -Culture en-US | ForEach-Object {
    [ordered]@{ path = $_; sha256 = Get-AuditSha256 (Join-Path $repository $_) }
})

try {
    $toolchain = Get-Content -LiteralPath (Join-Path $repository 'scripts/bootstrap/toolchain.lock.json') -Raw | ConvertFrom-Json -AsHashtable
    $appText = [IO.File]::ReadAllText((Join-Path $repository 'apps/exvpn/pubspec.yaml'))
    $versionMatch = [regex]::Match($appText, '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?\+[1-9][0-9]*)\s*$')
    if (!$versionMatch.Success) { throw 'invalid_expected_app_version' }
    $expectedVersion = $versionMatch.Groups[1].Value
    $dartLockPath = Join-Path $repository 'apps/exvpn/pubspec.lock'
    $dartLockHash = Get-AuditSha256 $dartLockPath
    $dartPins = Get-NoticeLockedPackages ([IO.File]::ReadAllText($dartLockPath))
    $appVersion = ''
    $nativePaths = @()

    if (Test-Path -LiteralPath $inputPath -PathType Container) {
        $target = 'Windows'
        $payload = Join-Path $inputPath 'payload'
        $files = Get-AuditTreeFiles $payload
        $manifest = Get-Content -LiteralPath (Join-Path $payload 'package.json') -Raw | ConvertFrom-Json -AsHashtable
        Test-AuditManifest $manifest $files $findings
        $appVersion = "$($manifest.version)+$($manifest.build)"
        if (!$files.ContainsKey('ui/exvpn.exe')) { Add-AuditFinding $findings 'windows_ui_binary_missing' }
        else {
            $uiIdentity = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $payload 'ui/exvpn.exe'))
            if ($uiIdentity.ProductVersion -cne $appVersion -or $uiIdentity.FileVersion -cne $appVersion) { Add-AuditFinding $findings 'windows_ui_version_mismatch' }
        }
        if ($manifest.development) { Add-AuditFinding $findings 'development_package' }
        $artifact = Get-Content -LiteralPath (Join-Path $inputPath 'artifact.json') -Raw | ConvertFrom-Json -AsHashtable
        $artifactName = ConvertTo-AuditPath $artifact.file
        if ($artifactName.Contains('/') -or ! $artifactName.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { throw 'invalid_installer_filename' }
        $artifactFile = Join-Path $inputPath $artifactName
        Assert-AuditNoLinks $artifactFile
        $artifactHash = Get-AuditSha256 $artifactFile
        if ($artifact.sha256 -cne $artifactHash -or "$($artifact.version)+$($artifact.build)" -cne $appVersion) { Add-AuditFinding $findings 'installer_artifact_manifest_mismatch' }
        $authenticode = Get-AuthenticodeSignature -LiteralPath $artifactFile
        $signature.verified = $authenticode.Status -eq 'Valid'
        if ($authenticode.SignerCertificate) {
            $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($authenticode.SignerCertificate.RawData)).ToLowerInvariant()
            $signature.certificateSha256 = @($digest)
            $signature.trustedSignerMatched = !!$ExpectedSignerSha256 -and $digest -ceq $ExpectedSignerSha256.ToLowerInvariant()
        }
        if (!$signature.verified) { Add-AuditFinding $findings 'windows_signature_not_valid' }
        $inspectorPin = Get-Content (Join-Path $PSScriptRoot 'archive-inspector.lock.json') -Raw | ConvertFrom-Json
        if (Test-Path -LiteralPath (Join-Path $repository ".tools/7zip-$($inspectorPin.version)")) {
            $nsisEvidence = Get-AuditNsisEvidence $repository $artifactFile $output $files
            foreach ($tool in $nsisEvidence.tools) { $toolsUsed.Add([ordered]@{name='7zip/' + $tool.name;sha256=$tool.sha256}) }
        } else {
            # No download or implicit preparation during the offline audit.
            Add-AuditFinding $findings 'nsis_embedded_payload_not_independently_verified'
        }
        $nativePaths = @('service/exvpn-service.exe')
        $noticeRoot = Join-Path $payload 'control/notices'
        if (Test-Path -LiteralPath (Join-Path $noticeRoot 'inventory.json')) { $noticeSource = if ($nsisEvidence.verified) { 'installer-payload-verified' } else { 'staged-payload' } }
        $wintun = Get-Content -LiteralPath (Join-Path $repository 'scripts/windows/wintun.lock.json') -Raw | ConvertFrom-Json -AsHashtable
        if (!$files.ContainsKey('service/wintun.dll') -or $files['service/wintun.dll'].sha256 -cne $wintun.dllSha256) { Add-AuditFinding $findings 'wintun_pin_mismatch' }
        $msvc = Get-Content -LiteralPath (Join-Path $repository 'scripts/windows/msvc-runtime.lock.json') -Raw | ConvertFrom-Json -AsHashtable
        foreach ($runtime in $msvc.files) {
            $path = 'ui/' + (ConvertTo-AuditPath $runtime.file)
            if (!$files.ContainsKey($path) -or $files[$path].sha256 -cne $runtime.sha256) { Add-AuditFinding $findings 'msvc_runtime_pin_mismatch' $path }
        }
        $nsis = Get-Content -LiteralPath (Join-Path $repository 'scripts/windows/nsis.lock.json') -Raw | ConvertFrom-Json -AsHashtable
        foreach ($field in @('version', 'sha256', 'compilerSha256')) {
            if ($manifest.installer[$field] -cne $nsis[$field]) { Add-AuditFinding $findings 'nsis_pin_mismatch' $field }
        }
        foreach ($required in @('LICENSE', 'NOTICE', 'NSIS-3.13.txt', 'Microsoft-Visual-Studio-2026-Community.txt', 'MSVC-REDISTRIBUTION.md')) {
            if (!$files.ContainsKey("control/$required")) { Add-AuditFinding $findings 'windows_distribution_notice_missing' $required }
        }
        $evidenceScope = 'Final installer SHA/signature and separate staged payload; EXE contents are not independently extracted.'
        if ($nsisEvidence.verified) {
            $evidenceScope = 'Final NSIS installer payload independently extracted and byte-matched to staging; uninstaller maintenance scripts and compiler-pinned plugins verified. Installer instruction semantics and runtime behavior are separate gates.'
        }
    } else {
        $target = 'Android'
        if (![IO.Path]::GetExtension($inputPath).Equals('.apk', [StringComparison]::OrdinalIgnoreCase)) { throw 'expected_apk_or_windows_package_directory' }
        $artifactFile = $inputPath
        $artifactName = [IO.Path]::GetFileName($artifactFile)
        $artifactHash = Get-AuditSha256 $artifactFile
        $files = Get-AuditZipFiles $artifactFile
        $AndroidSdkPath = Get-ReleaseAndroidSdkPath $AndroidSdkPath
        $buildTools = Join-Path $AndroidSdkPath 'build-tools/36.0.0'
        $aapt = Join-Path $buildTools 'aapt2.exe'
        $signerJar = Join-Path $buildTools 'lib/apksigner.jar'
        foreach ($path in @($aapt, $signerJar, $JavaPath)) {
            Assert-AuditNoLinks $path
            $toolsUsed.Add([ordered]@{ name = [IO.Path]::GetFileName($path); sha256 = Get-AuditSha256 $path })
        }
        $badging = Invoke-AuditTool $aapt @('dump', 'badging', $artifactFile)
        $packageMatch = [regex]::Match($badging, "(?m)^package: name='([^']+)' versionCode='([0-9]+)' versionName='([^']+)'")
        if (!$packageMatch.Success) { throw 'apk_identity_unreadable' }
        if ($packageMatch.Groups[1].Value -cne 'ru.exvpn.exvpn') { Add-AuditFinding $findings 'apk_package_mismatch' }
        $appVersion = "$($packageMatch.Groups[3].Value)+$($packageMatch.Groups[2].Value)"
        if ($badging -match '(?m)^application-debuggable') { Add-AuditFinding $findings 'apk_debuggable' }
        try {
            $signerText = Invoke-AuditTool $JavaPath @('-jar', $signerJar, 'verify', '--verbose', '--print-certs', $artifactFile)
            $signature.verified = $true
            $signature.debug = $signerText -match '(?im)^Signer #\d+ certificate DN:.*(?:CN=Android Debug|CN=AndroidDebug)'
            $signature.certificateSha256 = @([regex]::Matches($signerText, '(?im)^Signer #\d+ certificate SHA-256 digest: ([a-f0-9]{64})\s*$') | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() } | Sort-Object -Unique)
            $signature.trustedSignerMatched = !!$ExpectedSignerSha256 -and $signature.certificateSha256.Count -eq 1 -and $signature.certificateSha256[0] -ceq $ExpectedSignerSha256.ToLowerInvariant()
            if ($signature.debug) { Add-AuditFinding $findings 'android_debug_signer' }
        } catch { Add-AuditFinding $findings 'android_signature_not_verified' }
        try { Assert-AuditAndroidAbiCoverage $files } catch { Add-AuditFinding $findings $_.Exception.Message }
        $nativePaths = @('lib/arm64-v8a/libexvpn.so', 'lib/x86_64/libexvpn.so')
        $bundles = @($files.Keys | Where-Object { $_ -cmatch '^assets/(?:exvpn_notices|notices)/inventory\.json$' })
        if ($bundles.Count -gt 1) { throw 'ambiguous_apk_notice_bundle' }
        if ($bundles.Count -eq 1) {
            $prefix = $bundles[0].Substring(0, $bundles[0].Length - 'inventory.json'.Length)
            foreach ($path in $files.Keys) {
                if ($path.StartsWith($prefix, [StringComparison]::Ordinal)) { $noticeFiles.Add($path.Substring($prefix.Length), $files[$path]) }
            }
            $inventory = [Text.UTF8Encoding]::new($false, $true).GetString((Read-AuditZipBytes $artifactFile $bundles[0])) | ConvertFrom-Json -AsHashtable
            if ($noticeFiles.ContainsKey('sources/xray-core.zip')) {
                $sourceZip = Join-Path $output 'inspected-xray-core.zip'
                [IO.File]::WriteAllBytes($sourceZip, (Read-AuditZipBytes $artifactFile ($prefix + 'sources/xray-core.zip') 256MB))
            }
            $noticeSource = 'actual-apk-entries'
        } else { Add-AuditFinding $findings 'apk_notice_bundle_missing' }
        Add-AuditFinding $findings 'android_gradle_maven_runtime_inventory_missing'
        $evidenceScope = 'Actual APK ZIP entries, manifest identity, native build info and APK signature; Maven and Dart link coverage incomplete.'
    }

    if ($appVersion -cne $expectedVersion) { Add-AuditFinding $findings 'artifact_app_version_differs_from_checkout' }
    if (!$ExpectedSignerSha256) { Add-AuditFinding $findings 'release_signer_not_pinned' }
    elseif (!$signature.trustedSignerMatched) { Add-AuditFinding $findings 'release_signer_mismatch' }
    if ($NoticesDirectory) {
        # Explicit sidecars are useful for generator QA but never replace proof
        # that this artifact actually distributes its notices.
        $noticeRoot = [IO.Path]::GetFullPath($NoticesDirectory)
        $noticeSource = 'external-sidecar'
        Add-AuditFinding $findings 'external_notices_are_not_artifact_contents'
    }
    if ($noticeSource -in 'staged-payload', 'installer-payload-verified', 'external-sidecar') {
        $noticeFiles = Get-AuditTreeFiles $noticeRoot
        $inventory = Get-Content -LiteralPath (Join-Path $noticeRoot 'inventory.json') -Raw | ConvertFrom-Json -AsHashtable
        if ($noticeFiles.ContainsKey('sources/xray-core.zip')) { $sourceZip = Join-Path $noticeRoot 'sources/xray-core.zip' }
    }

    try {
        $flutterRuntimeInputs = Get-ReleaseFlutterRuntime -Repository $repository -Target $target -FlutterRuntime $FlutterRuntime -FlutterBuildMode $FlutterBuildMode
        Assert-ReleaseFlutterNotices $inventory $flutterRuntimeInputs.Evidence
        $flutterRuntimeEvidence = if ($target -ceq 'Android') {
            Get-ReleaseAndroidPackagedFlutterEvidence $flutterRuntimeInputs $files $repository -AndroidSdkPath $AndroidSdkPath
        } else { Get-ReleasePackagedFlutterEvidence $flutterRuntimeInputs.Evidence $files -RequireByteMatch }
        if ($target -ceq 'Android' -and !$flutterRuntimeEvidence.engineBytesBound) {
            Add-AuditFinding $findings 'android_flutter_engine_bytes_not_bound'
        }
        if ($target -ceq 'Windows' -and $manifest.Contains('flutterRuntime')) {
            Assert-ReleaseFlutterRuntimeEvidence $manifest.flutterRuntime $flutterRuntimeEvidence
        } elseif ($target -ceq 'Windows' -and $FlutterRuntime -ceq 'shorebird') {
            Add-AuditFinding $findings 'windows_flutter_runtime_metadata_missing'
        }
    } catch {
        $code = if ($_.Exception.Message -cmatch '^flutter_runtime_[a-z0-9_]+$') { $_.Exception.Message } else { 'flutter_runtime_inputs_unavailable' }
        Add-AuditFinding $findings $code
    }

    $go = Join-Path $repository '.tools/go/bin/go.exe'
    Assert-AuditNoLinks $go
    $toolsUsed.Add([ordered]@{ name = 'go.exe'; sha256 = Get-AuditSha256 $go })
    if ((Invoke-AuditTool $go @('version')).Trim() -cne "go version go$($toolchain.go.version) windows/amd64") { throw 'inspection_go_version_mismatch' }
    $moduleRoot = Join-Path $repository "native/$($target.ToLowerInvariant())"
    $goPins = Get-AuditGoPins (Join-Path $moduleRoot 'go.mod') (Join-Path $moduleRoot 'go.sum')
    foreach ($path in $nativePaths) {
        if (!$files.ContainsKey($path)) { Add-AuditFinding $findings 'native_binary_missing' $path; continue }
        if ($target -eq 'Android') {
            $binaryPath = Join-Path $output ("inspected-native-$($native.Count).so")
            [IO.File]::WriteAllBytes($binaryPath, (Read-AuditZipBytes $artifactFile $path 512MB))
        } else { $binaryPath = Join-Path $payload $path }
        $info = (Invoke-AuditTool $go @('version', '-m', '-json', $binaryPath)) | ConvertFrom-Json -AsHashtable
        $native.Add((Test-AuditGoBinary $info $path $files[$path].sha256 $goPins $toolchain.go.version $findings))
    }
    if ($inventory) {
        Test-AuditNotices $inventory $noticeFiles $native $target $appVersion $dartLockHash $findings
        $declaredDart = @{}
        if ($inventory['dartPackages']) {
            foreach ($package in $inventory.dartPackages) {
                if ($declaredDart.ContainsKey($package.name)) { throw 'duplicate_notice_dart_package' }
                $declaredDart[$package.name] = $package
                if (!$dartPins.ContainsKey($package.name) -or $dartPins[$package.name].source -cne 'hosted' -or $package.source -cne 'hosted' -or $package.version -cne $dartPins[$package.name].version -or $package.sha256 -cne $dartPins[$package.name].sha256) {
                    Add-AuditFinding $findings 'notice_dart_package_pin_mismatch' $package.name
                }
            }
            foreach ($package in $dartPins.Values) {
                if ($package.source -eq 'hosted' -and !$declaredDart.ContainsKey($package.name)) { Add-AuditFinding $findings 'notice_dart_package_missing' $package.name }
            }
        } else { Add-AuditFinding $findings 'notice_dart_package_checksums_missing' }
        foreach ($component in $inventory.components) {
            if ($component.scope -eq 'resolved-dart-package' -and (!$dartPins.ContainsKey($component.name) -or $dartPins[$component.name].version -cne $component.version)) {
                Add-AuditFinding $findings 'notice_dart_component_version_mismatch' $component.name
            }
        }
        $expectedRuntime = @{ 'Go runtime' = $toolchain.go.version }
        if ($flutterRuntimeInputs) {
            $expectedRuntime['Flutter framework'] = $flutterRuntimeInputs.Identity.flutterVersion
            $expectedRuntime['Dart runtime'] = $flutterRuntimeInputs.Identity.dartVersion
        }
        foreach ($name in $expectedRuntime.Keys) {
            $matches = @($inventory.components | Where-Object name -CEQ $name)
            if ($matches.Count -ne 1 -or $matches[0].version -cne $expectedRuntime[$name]) { Add-AuditFinding $findings 'runtime_notice_version_mismatch' $name }
        }
        foreach ($name in @('ExVPN', 'ExVPN copyright')) {
            $ownFile = if ($name -eq 'ExVPN') { 'LICENSE' } else { 'NOTICE' }
            $ownHash = Get-AuditSha256 (Join-Path $repository $ownFile)
            $ownComponents = @($inventory.components | Where-Object name -CEQ $name)
            if ($ownComponents.Count -ne 1 -or !@($ownComponents[0].notices | Where-Object sha256 -CEQ $ownHash).Count) { Add-AuditFinding $findings 'own_notice_content_mismatch' $name }
        }
    } else { Add-AuditFinding $findings 'notice_inventory_missing' }
    if ($sourceZip) {
        $xray = @($native | ForEach-Object { $_.modules } | Where-Object { $_.name -ceq 'github.com/xtls/xray-core' } | ForEach-Object { $_.sum } | Sort-Object -Unique)
        $sourceCorrespondence.present = $true
        $sourceCorrespondence.zipSha256 = Get-AuditSha256 $sourceZip
        $sourceCorrespondence.actualGoSum = Get-AuditGoZipSum $sourceZip
        if ($xray.Count -eq 1) { $sourceCorrespondence.linkedModuleSum = $xray[0] }
        $sourceCorrespondence.matched = $xray.Count -eq 1 -and $sourceCorrespondence.actualGoSum -ceq $xray[0]
        if (!$sourceCorrespondence.matched) { Add-AuditFinding $findings 'xray_source_does_not_match_linked_module' }
        $modifiedXray = @($native | ForEach-Object { $_.modules } | Where-Object {
            $_.name -ceq 'github.com/xtls/xray-core' -and $_.version -match '-exvpn\.'
        } | ForEach-Object {
            # Native inspection returns OrderedDictionary records. Select-Object
            # does not expose their keys as properties without this projection.
            [pscustomobject]@{version=$_.version;sum=$_.sum}
        } | Select-Object -Property version,sum -Unique)
        if ($modifiedXray.Count) {
            try {
                if ($modifiedXray.Count -ne 1) { throw 'multiple_modified_xray_versions' }
                $patchEvidence = Get-NoticeXrayPatch $repository $modifiedXray[0].version $modifiedXray[0].sum
                $sourceCorrespondence.patch = [ordered]@{
                    upstreamCommit=$patchEvidence.upstreamCommit; sha256=$patchEvidence.patchSha256; included=$false
                }
                Assert-NoticeXraySourceBundle $patchEvidence $noticeFiles
                $sourceCorrespondence.patch.included = $true
            } catch { Add-AuditFinding $findings 'xray_patch_provenance_missing_or_mismatched' }
        }
    } else { Add-AuditFinding $findings 'xray_corresponding_source_missing' }
    # Resolved pub packages are a superset, not evidence of the final Dart/native
    # link graph. Preserve this release blocker rather than manufacture coverage.
    Add-AuditFinding $findings 'dart_flutter_runtime_link_inventory_incomplete'
    Add-AuditFinding $findings 'license_expressions_and_distribution_obligations_not_fully_reviewed'
    foreach ($pin in $pinEvidence) {
        if ((Get-AuditSha256 (Join-Path $repository $pin.path)) -cne $pin.sha256) { throw 'source_pins_changed_during_audit' }
    }
    if ($flutterRuntimeInputs) {
        $runtimeAfter = Get-ReleaseFlutterRuntime -Repository $repository -Target $target -FlutterRuntime $FlutterRuntime -FlutterBuildMode $FlutterBuildMode
        Assert-ReleaseFlutterRuntimeEvidence $runtimeAfter.Evidence $flutterRuntimeInputs.Evidence
    }
    if ((Get-AuditSha256 $artifactFile) -cne $artifactHash) { throw 'artifact_changed_during_audit' }
    if ($target -eq 'Windows') {
        $after = Get-AuditTreeFiles $payload
        if ($after.Count -ne $files.Count) { throw 'payload_changed_during_audit' }
        foreach ($path in $files.Keys) {
            if (!$after.ContainsKey($path) -or $after[$path].sha256 -cne $files[$path].sha256) { throw 'payload_changed_during_audit' }
        }
    }
    if ($noticeSource -eq 'external-sidecar') {
        $afterNotices = Get-AuditTreeFiles $noticeRoot
        if ($afterNotices.Count -ne $noticeFiles.Count) { throw 'external_notices_changed_during_audit' }
        foreach ($path in $noticeFiles.Keys) {
            if (!$afterNotices.ContainsKey($path) -or $afterNotices[$path].sha256 -cne $noticeFiles[$path].sha256) { throw 'external_notices_changed_during_audit' }
        }
    }
    $noticeFileSet = @($noticeFiles.Keys | Sort-Object -CaseSensitive -Culture en-US | ForEach-Object {
        [ordered]@{ path = $_; sha256 = $noticeFiles[$_].sha256; size = $noticeFiles[$_].size }
    })
    $noticeEvidence = [ordered]@{
        source = $noticeSource; fileCount = $noticeFiles.Count
        inventorySha256 = $(if ($noticeFiles.ContainsKey('inventory.json')) { $noticeFiles['inventory.json'].sha256 } else { '' })
        fileSetSha256 = $(if ($noticeFiles.Count) { Get-AuditTextHash ($noticeFileSet | ConvertTo-Json -Depth 5 -Compress) } else { '' })
        xraySource = $sourceCorrespondence
    }
    $report = [ordered]@{
        schema = 1; target = $target; appVersion = $appVersion; expectedAppVersion = $expectedVersion
        artifact = [ordered]@{ file = $artifactName; sha256 = $artifactHash; bytes = (Get-Item -LiteralPath $artifactFile).Length }
        evidenceScope = $evidenceScope; noticeSource = $noticeSource; noticeEvidence = $noticeEvidence; complete = $false; releaseReady = $findings.Count -eq 0
        signature = $signature; pins = $pinEvidence; tools = @($toolsUsed | Sort-Object { $_.name } -CaseSensitive -Culture en-US)
        counts = [ordered]@{ files = $files.Count; nativeBinaries = $native.Count; noticeComponents = $(if ($inventory) { $inventory.components.Count } else { 0 }) }
        nativeBinaries = $native.ToArray()
        flutterRuntime = $flutterRuntimeEvidence
        nsisExtraction = $nsisEvidence
        findings = @($findings | Sort-Object { $_.code }, { $_.subject } -CaseSensitive -Culture en-US -Unique)
    }
    Write-AuditJson (Join-Path $output 'sbom.cdx.json') (New-AuditSbom $target $appVersion $artifactHash $files $native $inventory -WindowsPayloadVerified:$nsisEvidence.verified)
    Write-AuditJson (Join-Path $output 'audit.json') $report
    $summary = @("ExVPN $appVersion / $target", "Artifact SHA-256: $artifactHash", "Files: $($files.Count); native binaries: $($native.Count); notice components: $($report.counts.noticeComponents)",
        "Notice evidence: $noticeSource", "Coverage: INCOMPLETE; release readiness: BLOCKED", $evidenceScope, '', 'Release blockers:') + @($report.findings | ForEach-Object { "- $($_.code)$(if ($_.subject) { ': ' + $_.subject })" })
    [IO.File]::WriteAllText((Join-Path $output 'audit.txt'), ($summary -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    Write-Host "$target artifact audit: $($report.findings.Count) release blockers; $($files.Count) files; $($report.counts.noticeComponents) notice components."
    Write-Host "Reports: $output"
    if ($findings.Count) { exit 2 }
    exit 0
} catch {
    # Do not print raw external-tool output, manifest contents, or local secrets.
    $safeCode = if ($_.Exception.Message -cmatch '^[a-z][a-z0-9_]{2,100}$') { $_.Exception.Message } else { 'invalid_input_or_inspection_failure' }
    Write-AuditJson (Join-Path $output 'audit.json') ([ordered]@{ schema = 1; complete = $false; releaseReady = $false; error = $safeCode; errorLocation = [ordered]@{ file = [IO.Path]::GetFileName($_.InvocationInfo.ScriptName); line = $_.InvocationInfo.ScriptLineNumber } })
    Write-Error "Artifact audit failed: $safeCode"
    exit 1
}
