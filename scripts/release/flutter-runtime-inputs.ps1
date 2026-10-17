# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Pinned SDK inputs and packaged bytes, not a complete runtime/linker inventory.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'artifact-audit-lib.ps1')

function Get-ReleaseRuntimeField($Value, [string]$Name) {
    if ($Value -is [Collections.IDictionary]) { return $Value[$Name] }
    if ($null -ne $Value -and $Value.PSObject.Properties[$Name]) { return $Value.$Name }
    return $null
}

function Invoke-ReleaseRuntimeGit([string]$Root, [string[]]$Arguments) {
    $git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    (Invoke-AuditTool $git (@('-c', 'core.fsmonitor=false', '-C', $Root) + $Arguments) 30).Trim()
}

function Assert-ReleaseRuntimeCheckout([string]$Root, [string]$Revision) {
    Assert-AuditNoLinks $Root
    if ($Revision -cnotmatch '^[a-f0-9]{40}$') { throw 'flutter_runtime_revision_invalid' }
    $actualRoot = Invoke-ReleaseRuntimeGit $Root @('rev-parse', '--show-toplevel')
    if ([IO.Path]::GetFullPath($actualRoot) -ine [IO.Path]::GetFullPath($Root) -or
        (Invoke-ReleaseRuntimeGit $Root @('rev-parse', 'HEAD')) -cne $Revision) { throw 'flutter_runtime_checkout_mismatch' }
    if (Invoke-ReleaseRuntimeGit $Root @('status', '--porcelain', '--untracked-files=no')) { throw 'flutter_runtime_checkout_modified' }
}

function Get-ReleaseRuntimeFile([string]$Root, [string]$Path) {
    $relative = ConvertTo-AuditPath $Path
    $full = Join-Path $Root $relative
    Assert-AuditNoLinks $full
    $file = Get-Item -LiteralPath $full
    if ($file.PSIsContainer -or $file.Length -le 0 -or $file.Length -gt 512MB) { throw 'flutter_runtime_input_size_invalid' }
    [ordered]@{ path = $relative; sha256 = Get-AuditSha256 $full; size = $file.Length }
}

function Get-ReleaseRuntimeJarEngine([string]$JarPath, [string]$EntryPath, [string]$OutputPath = '') {
    # Inspect only the required engine bytes, but reject ambiguous/link entries.
    $zip = [IO.Compression.ZipFile]::OpenRead($JarPath)
    try {
        if ($zip.Entries.Count -gt 30000) { throw 'too_many_archive_entries' }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $selected = $null
        foreach ($entry in $zip.Entries) {
            $name = ConvertTo-AuditPath $entry.FullName.TrimEnd('/')
            if (!$seen.Add($name)) { throw 'duplicate_archive_path' }
            if ((($entry.ExternalAttributes -shr 16) -band 0xf000) -eq 0xa000) { throw 'archive_link_not_allowed' }
            if ($entry.FullName -ceq $EntryPath) { $selected = $entry }
        }
        if (!$selected -or $selected.Length -le 0 -or $selected.Length -gt 512MB) { throw 'flutter_runtime_engine_missing' }
        $stream = $selected.Open()
        try {
            if (!$OutputPath) { $hash = Get-AuditStreamHash $stream $selected.Length }
            else {
                # Only the caller's new, owned staging file is written. Never
                # extract an archive-selected path or modify the SDK/JAR.
                $output = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $digest = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
                try {
                    $buffer = [byte[]]::new(1MB); [long]$total = 0
                    while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $total += $count
                        if ($total -gt $selected.Length) { throw 'archive_entry_length_mismatch' }
                        $digest.AppendData($buffer, 0, $count); $output.Write($buffer, 0, $count)
                    }
                    if ($total -ne $selected.Length) { throw 'archive_entry_length_mismatch' }
                    $hash = [Convert]::ToHexString($digest.GetHashAndReset()).ToLowerInvariant()
                } finally { $digest.Dispose(); $output.Dispose() }
            }
            [ordered]@{ path=$EntryPath; sha256=$hash; size=$selected.Length }
        }
        finally { $stream.Dispose() }
    } finally { $zip.Dispose() }
}

function Get-ReleaseFlutterRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][ValidateSet('Android','Windows')][string]$Target,
        [ValidateSet('ordinary','shorebird')][string]$FlutterRuntime = 'ordinary',
        [ValidateSet('','debug','release')][string]$FlutterBuildMode = ''
    )
    if ($Target -cnotin @('Android','Windows') -or $FlutterRuntime -cnotin @('ordinary','shorebird') -or $FlutterBuildMode -cnotin @('','debug','release')) { throw 'flutter_runtime_selector_invalid' }
    $mode = $FlutterBuildMode
    if (!$mode) { $mode = if ($Target -ceq 'Android' -and $FlutterRuntime -ceq 'ordinary') { 'debug' } else { 'release' } }
    if (($Target -ceq 'Windows' -or $FlutterRuntime -ceq 'shorebird') -and $mode -cne 'release') { throw 'flutter_runtime_mode_unsupported' }
    $pinPath = if ($FlutterRuntime -ceq 'ordinary') { 'scripts/bootstrap/toolchain.lock.json' } else { 'scripts/bootstrap/shorebird.lock.json' }
    $pinFile = Get-ReleaseRuntimeFile $Repository $pinPath
    $pin = Get-Content -LiteralPath (Join-Path $Repository $pinPath) -Raw | ConvertFrom-Json -AsHashtable
    if ($pin.schemaVersion -ne 1 -or $pin.flutter.version -cnotmatch '^\d+\.\d+\.\d+$' -or
        $pin.flutter.dartVersion -cnotmatch '^\d+\.\d+\.\d+$' -or $pin.flutter.revision -cnotmatch '^[a-f0-9]{40}$') { throw 'flutter_runtime_pin_invalid' }
    $cli = $null
    if ($FlutterRuntime -ceq 'ordinary') {
        if ($pin.flutter.folder -cne 'flutter') { throw 'flutter_runtime_sdk_path_invalid' }
        $sdkRelative = '.tools/flutter'
    } else {
        if ($pin.cli.version -cnotmatch '^\d+\.\d+\.\d+$' -or $pin.cli.folder -cne "shorebird-$($pin.cli.version)" -or
            $pin.cli.repository -cne 'https://github.com/shorebirdtech/shorebird.git' -or
            $pin.flutter.repository -cne 'https://github.com/shorebirdtech/flutter.git' -or
            $pin.flutter.engineRevision -cnotmatch '^[a-f0-9]{40}$') { throw 'flutter_runtime_pin_invalid' }
        $cliRoot = Join-Path $Repository ".tools/$($pin.cli.folder)"
        Assert-ReleaseRuntimeCheckout $cliRoot $pin.cli.revision
        $entry = Get-ReleaseRuntimeFile $cliRoot 'bin/shorebird.ps1'
        $lock = Get-ReleaseRuntimeFile $cliRoot 'pubspec.lock'
        if ($entry.sha256 -cne $pin.cli.powershellEntrypointSha256 -or $lock.sha256 -cne $pin.cli.pubspecLockSha256) { throw 'flutter_runtime_cli_pin_mismatch' }
        $cli = [ordered]@{ version=$pin.cli.version; revision=$pin.cli.revision; entrypointSha256=$entry.sha256; dependencyLockSha256=$lock.sha256 }
        $sdkRelative = ".tools/$($pin.cli.folder)/bin/cache/flutter/$($pin.flutter.revision)"
    }
    $sdkRoot = Join-Path $Repository $sdkRelative
    Assert-ReleaseRuntimeCheckout $sdkRoot $pin.flutter.revision
    # Ordinary's archive pin lacks a separate engine hash; derive it from the
    # committed engine.version of the exact pinned framework, never the stamp alone.
    $engine = Invoke-ReleaseRuntimeGit $sdkRoot @('show', "$($pin.flutter.revision):bin/internal/engine.version")
    if ($engine -cnotmatch '^[a-f0-9]{40}$' -or ($FlutterRuntime -ceq 'shorebird' -and $engine -cne $pin.flutter.engineRevision)) { throw 'flutter_runtime_engine_pin_mismatch' }
    foreach ($path in @('bin/internal/engine.version','bin/cache/engine.stamp','bin/cache/dart-sdk/version','bin/cache/flutter.version.json')) { Assert-AuditNoLinks (Join-Path $sdkRoot $path) }
    if (([IO.File]::ReadAllText((Join-Path $sdkRoot 'bin/internal/engine.version'))).Trim() -cne $engine -or
        ([IO.File]::ReadAllText((Join-Path $sdkRoot 'bin/cache/engine.stamp'))).Trim() -cne $engine) { throw 'flutter_runtime_engine_stamp_mismatch' }
    if (([IO.File]::ReadAllText((Join-Path $sdkRoot 'bin/cache/dart-sdk/version'))).Trim() -cne $pin.flutter.dartVersion) { throw 'flutter_runtime_dart_version_mismatch' }
    $version = Get-Content -LiteralPath (Join-Path $sdkRoot 'bin/cache/flutter.version.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($version.frameworkRevision -cne $pin.flutter.revision -or $version.frameworkVersion -cne $pin.flutter.version -or
        $version.engineRevision -cne $engine -or $version.dartSdkVersion -cne $pin.flutter.dartVersion) { throw 'flutter_runtime_version_metadata_mismatch' }
    $identity = [ordered]@{
        schema=1; kind=$FlutterRuntime; target=$Target; buildMode=$mode
        flutterVersion=$pin.flutter.version; flutterRevision=$pin.flutter.revision; engineRevision=$engine; dartVersion=$pin.flutter.dartVersion
        pin=[ordered]@{path=$pinPath;sha256=$pinFile.sha256}; cli=$cli
    }
    $notices = [Collections.Generic.List[object]]::new()
    foreach ($definition in @(@('Flutter framework',$pin.flutter.version,'LICENSE'), @('Dart runtime',$pin.flutter.dartVersion,'bin/cache/dart-sdk/LICENSE'))) {
        $file = Get-ReleaseRuntimeFile $sdkRoot $definition[2]
        $notices.Add([ordered]@{name=$definition[0];version=$definition[1];path=$file.path;sha256=$file.sha256;size=$file.size})
    }
    $artifacts = [Collections.Generic.List[object]]::new()
    $engines = [Collections.Generic.List[object]]::new()
    if ($Target -ceq 'Windows') {
        $dir = 'bin/cache/artifacts/engine/windows-x64-release'
        $file = Get-ReleaseRuntimeFile $sdkRoot "$dir/license.windows_flutter.md"
        $notices.Add([ordered]@{name='Flutter Windows engine';version=$pin.flutter.revision;path=$file.path;sha256=$file.sha256;size=$file.size})
        $binary = Get-ReleaseRuntimeFile $sdkRoot "$dir/flutter_windows.dll"
        $artifacts.Add($binary)
        $engines.Add([ordered]@{path='ui/flutter_windows.dll';sha256=$binary.sha256;size=$binary.size})
    } else {
        foreach ($abi in @(@('android-arm64','arm64-v8a'),@('android-x64','x86_64'))) {
            $suffix = if ($mode -ceq 'release') { '-release' } else { '' }
            $dir = "bin/cache/artifacts/engine/$($abi[0])$suffix"
            $file = Get-ReleaseRuntimeFile $sdkRoot "$dir/license.flutter_jar_zip.md"
            $notices.Add([ordered]@{name="Flutter engine $($abi[0])";version=$pin.flutter.revision;path=$file.path;sha256=$file.sha256;size=$file.size})
            $jar = Get-ReleaseRuntimeFile $sdkRoot "$dir/flutter.jar"
            $binary = Get-ReleaseRuntimeJarEngine (Join-Path $sdkRoot $jar.path) "lib/$($abi[1])/libflutter.so"
            if ((Get-AuditSha256 (Join-Path $sdkRoot $jar.path)) -cne $jar.sha256) { throw 'flutter_runtime_inputs_changed' }
            $artifacts.Add($jar); $engines.Add($binary)
        }
    }
    [pscustomobject]@{
        SdkRoot=[IO.Path]::GetFullPath($sdkRoot); Identity=$identity
        Evidence=[ordered]@{schema=1;identity=$identity;notices=$notices.ToArray();sdkArtifacts=$artifacts.ToArray();engineBinaries=$engines.ToArray()}
    }
}

function Assert-ReleaseFlutterRuntimeEvidence($Actual, $Expected) {
    if (!$Actual -or ($Actual | ConvertTo-Json -Depth 12 -Compress) -cne ($Expected | ConvertTo-Json -Depth 12 -Compress)) { throw 'flutter_runtime_evidence_mismatch' }
}

function Assert-ReleaseFlutterNotices($Inventory, $Runtime) {
    Assert-ReleaseFlutterRuntimeEvidence (Get-ReleaseRuntimeField $Inventory 'runtime') $Runtime
    foreach ($notice in $Runtime.notices) {
        $matches = @($Inventory.components | Where-Object { $_.name -ceq $notice.name })
        if ($matches.Count -ne 1 -or $matches[0].version -cne $notice.version -or $matches[0].notices.Count -ne 1 -or
            $matches[0].notices[0].sha256 -cne $notice.sha256) { throw 'flutter_runtime_notice_mismatch' }
    }
}

function Get-ReleasePackagedFlutterEvidence($Runtime, $Files, [switch]$RequireByteMatch) {
    $engines = [Collections.Generic.List[object]]::new()
    $dart = [Collections.Generic.List[object]]::new()
    $bound = $true
    foreach ($expected in $Runtime.engineBinaries) {
        if (!$Files.ContainsKey($expected.path)) { throw 'flutter_runtime_packaged_engine_missing' }
        $actual = $Files[$expected.path]
        if ($actual.size -le 0 -or $actual.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'flutter_runtime_packaged_engine_invalid' }
        $matches = $actual.sha256 -ceq $expected.sha256 -and $actual.size -eq $expected.size
        $bound = $bound -and $matches
        $engines.Add([ordered]@{path=$expected.path;sha256=$actual.sha256;size=$actual.size;sdkSha256=$expected.sha256;sdkBytesMatched=$matches})
    }
    if ($RequireByteMatch -and !$bound) { throw 'flutter_runtime_packaged_engine_mismatch' }
    $dartPaths = if ($Runtime.identity.target -ceq 'Windows') { @('ui/data/app.so') }
        elseif ($Runtime.identity.buildMode -ceq 'release') { @('lib/arm64-v8a/libapp.so','lib/x86_64/libapp.so') }
        else { @('assets/flutter_assets/kernel_blob.bin') }
    foreach ($path in $dartPaths) {
        if (!$Files.ContainsKey($path) -or $Files[$path].size -le 0 -or $Files[$path].sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'flutter_runtime_packaged_dart_missing' }
        $dart.Add([ordered]@{path=$path;sha256=$Files[$path].sha256;size=$Files[$path].size})
    }
    [ordered]@{schema=1;identity=$Runtime.identity;engineBytesBound=$bound;engineBinaries=$engines.ToArray();dartBinaries=$dart.ToArray();completeLinkInventory=$false}
}

function Get-ReleaseAndroidStripTool([string]$Repository, [string]$AndroidSdkPath) {
    $pinPath = 'scripts/release/android-engine-transform.lock.json'
    $pinFile = Get-ReleaseRuntimeFile $Repository $pinPath
    $pin = Get-Content -LiteralPath (Join-Path $Repository $pinPath) -Raw | ConvertFrom-Json -AsHashtable
    # There is only one approved transform, with no caller-selected commands or
    # switches. A different NDK/host/algorithm needs a reviewed pin update.
    if ($pin.schemaVersion -ne 1 -or $pin.method -cne 'ndk_llvm_strip' -or
        $pin.host -cne 'windows-x86_64' -or $pin.ndkVersion -cne '28.2.13676358' -or
        $pin.tool.path -cne 'toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-strip.exe' -or
        $pin.tool.sha256 -cnotmatch '^[a-f0-9]{64}$' -or ($pin.tool.size -isnot [long] -and $pin.tool.size -isnot [int]) -or
        $pin.tool.size -le 0 -or $pin.tool.size -gt 512MB -or
        $pin.sourceProperties.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
        ($pin.sourceProperties.size -isnot [long] -and $pin.sourceProperties.size -isnot [int]) -or
        $pin.sourceProperties.size -le 0 -or $pin.sourceProperties.size -gt 16KB -or
        ($pin.arguments -isnot [Collections.IList]) -or
        ($pin.arguments | ConvertTo-Json -Compress) -cne '["--strip-unneeded","-o","output","input"]') {
        throw 'flutter_runtime_strip_pin_invalid'
    }
    if (!$IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) { throw 'flutter_runtime_strip_host_unsupported' }
    $ndkRoot = Join-Path $AndroidSdkPath "ndk/$($pin.ndkVersion)"
    $source = Get-ReleaseRuntimeFile $ndkRoot 'source.properties'
    $tool = Get-ReleaseRuntimeFile $ndkRoot $pin.tool.path
    if ($source.sha256 -cne $pin.sourceProperties.sha256 -or $source.size -ne $pin.sourceProperties.size -or
        $tool.sha256 -cne $pin.tool.sha256 -or $tool.size -ne $pin.tool.size) { throw 'flutter_runtime_strip_tool_mismatch' }
    $revisions = [regex]::Matches([IO.File]::ReadAllText((Join-Path $ndkRoot 'source.properties')), '(?m)^Pkg\.Revision\s*=\s*([^\r\n]+)\s*$')
    if ($revisions.Count -ne 1 -or $revisions[0].Groups[1].Value.Trim() -cne $pin.ndkVersion) { throw 'flutter_runtime_strip_ndk_mismatch' }
    [pscustomobject]@{
        Executable=(Join-Path $ndkRoot $tool.path)
        Evidence=[ordered]@{method=$pin.method;pin=[ordered]@{path=$pinPath;sha256=$pinFile.sha256};ndkVersion=$pin.ndkVersion;host=$pin.host;tool=$tool;sourceProperties=$source;arguments=$pin.arguments}
    }
}

function Invoke-ReleaseRuntimeStrip([string]$Executable, [string]$InputPath, [string]$OutputPath) {
    # Exact pinned AGP StripDebugSymbolsRunnable transform. No shell, network,
    # arbitrary extra options, cache writes, or invocation of build tasks.
    try { [void](Invoke-AuditTool $Executable @('--strip-unneeded','-o',$OutputPath,$InputPath) 30) }
    catch { throw 'flutter_runtime_strip_execution_failed' }
}

function Get-ReleaseAndroidPackagedFlutterEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ResolvedRuntime,
        [Parameter(Mandatory)]$Files,
        [Parameter(Mandatory)][string]$Repository,
        [string]$AndroidSdkPath = (Join-Path $env:LOCALAPPDATA 'Android/Sdk')
    )
    $runtime = $ResolvedRuntime.Evidence
    if ($runtime.identity.target -cne 'Android' -or $runtime.identity.buildMode -cnotin @('debug','release')) { throw 'flutter_runtime_strip_target_invalid' }
    Assert-ReleaseFlutterRuntimeEvidence $ResolvedRuntime.Identity $runtime.identity
    $result = Get-ReleasePackagedFlutterEvidence $runtime $Files
    $result.rawSdkBytesMatched = $result.engineBytesBound
    $result.bindingMethod = if ($result.engineBytesBound) { 'raw_sdk' } else { 'unbound' }
    if ($result.engineBytesBound) { return $result }

    $tool = Get-ReleaseAndroidStripTool $Repository $AndroidSdkPath
    # Restrict source selection to the two engine JARs produced by the resolver.
    # The APK hash/size map is read by callers from actual ZIP entries.
    if (@($runtime.engineBinaries).Count -ne 2 -or @($runtime.sdkArtifacts).Count -ne 2) { throw 'flutter_runtime_strip_source_set_invalid' }
    $stageParent = Join-Path $Repository 'artifacts'
    if (!(Test-Path -LiteralPath $stageParent)) { Assert-AuditNoLinks $Repository; [void][IO.Directory]::CreateDirectory($stageParent) }
    Assert-AuditNoLinks $stageParent
    $stage = Join-Path $stageParent ('flutter-engine-check-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)
    $stagePrefix = [IO.Path]::GetFullPath($stage) + [IO.Path]::DirectorySeparatorChar
    $owned = [Collections.Generic.List[string]]::new()
    $bound = $true
    try {
        foreach ($abi in @(@('android-arm64','arm64-v8a'),@('android-x64','x86_64'))) {
            $suffix = if ($runtime.identity.buildMode -ceq 'release') { '-release' } else { '' }
            $jarPath = "bin/cache/artifacts/engine/$($abi[0])$suffix/flutter.jar"
            $entryPath = "lib/$($abi[1])/libflutter.so"
            $jars = @($runtime.sdkArtifacts | Where-Object { $_.path -ceq $jarPath })
            $engines = @($runtime.engineBinaries | Where-Object { $_.path -ceq $entryPath })
            $rows = @($result.engineBinaries | Where-Object { $_.path -ceq $entryPath })
            if ($jars.Count -ne 1 -or $engines.Count -ne 1 -or $rows.Count -ne 1) { throw 'flutter_runtime_strip_source_set_invalid' }
            $jar = Get-ReleaseRuntimeFile $ResolvedRuntime.SdkRoot $jarPath
            Assert-ReleaseFlutterRuntimeEvidence $jar $jars[0]
            $inputFile = Join-Path $stage "$($abi[1])-input.so"
            $outputFile = Join-Path $stage "$($abi[1])-stripped.so"
            $owned.Add($inputFile); $owned.Add($outputFile)
            $source = Get-ReleaseRuntimeJarEngine (Join-Path $ResolvedRuntime.SdkRoot $jarPath) $entryPath $inputFile
            Assert-ReleaseFlutterRuntimeEvidence $source $engines[0]
            if ((Get-AuditSha256 $inputFile) -cne $source.sha256) { throw 'flutter_runtime_inputs_changed' }
            Invoke-ReleaseRuntimeStrip $tool.Executable $inputFile $outputFile
            $stripped = Get-ReleaseRuntimeFile $stage ([IO.Path]::GetFileName($outputFile))
            if ((Get-AuditSha256 $inputFile) -cne $source.sha256 -or
                (Get-AuditSha256 (Join-Path $ResolvedRuntime.SdkRoot $jarPath)) -cne $jar.sha256) { throw 'flutter_runtime_inputs_changed' }
            $row = $rows[0]
            $matches = $row.sha256 -ceq $stripped.sha256 -and $row.size -eq $stripped.size
            $row.bindingMethod = if ($row.sdkBytesMatched) { 'raw_sdk' } elseif ($matches) { 'verified_ndk_strip' } else { 'unbound' }
            $row.transformation = [ordered]@{
                method='ndk_llvm_strip';recalculated=$true;toolchain=$tool.Evidence
                sourceJar=$jar;sourceEntry=$source
                output=[ordered]@{sha256=$stripped.sha256;size=$stripped.size};outputBytesMatched=$matches
            }
            $bound = $bound -and ($row.sdkBytesMatched -or $matches)
        }
        foreach ($sourceJar in $runtime.sdkArtifacts) {
            Assert-ReleaseFlutterRuntimeEvidence (Get-ReleaseRuntimeFile $ResolvedRuntime.SdkRoot $sourceJar.path) $sourceJar
        }
        $toolAfter = Get-ReleaseAndroidStripTool $Repository $AndroidSdkPath
        Assert-ReleaseFlutterRuntimeEvidence $toolAfter.Evidence $tool.Evidence
        $result.engineBytesBound = $bound
        $result.bindingMethod = if ($bound) { 'verified_ndk_strip' } else { 'unbound' }
        return $result
    } finally {
        # Exact files from this new private staging directory only, no recursive
        # deletion and no edits to the original package, SDK or prior evidence.
        foreach ($path in $owned) {
            if (![IO.Path]::GetFullPath($path).StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'flutter_runtime_strip_cleanup_path_invalid' }
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
        if (@(Get-ChildItem -LiteralPath $stage -Force).Count -eq 0) { Remove-Item -LiteralPath $stage }
    }
}
