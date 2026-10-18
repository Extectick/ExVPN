#requires -Version 7.0
# Read-only helpers. No SDK resolution, binary execution, or network changes.
Set-StrictMode -Version Latest

function Get-AuditSha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-AuditTextHash([string]$Text) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function ConvertTo-AuditPath([string]$Value) {
    if (!$Value -or $Value.Length -gt 1024 -or $Value -match '[\x00-\x1f\x7f:<>"|?*]' -or $Value.StartsWith('/') -or $Value.StartsWith('\')) {
        throw 'unsafe_relative_path'
    }
    $path = $Value.Replace('\', '/')
    foreach ($segment in $path.Split('/')) {
        if (!$segment -or $segment -in '.', '..' -or $segment -match '[. ]$' -or $segment -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)') {
            throw 'unsafe_relative_path'
        }
    }
    $path
}

function Assert-AuditNoLinks([string]$Path) {
    $item = Get-Item -LiteralPath ([IO.Path]::GetFullPath($Path)) -Force
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'linked_input_not_allowed' }
        $item = if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
    }
}

function New-AuditFileMap([switch]$CaseSensitive) {
    $comparer = if ($CaseSensitive) { [StringComparer]::Ordinal } else { [StringComparer]::OrdinalIgnoreCase }
    ,([Collections.Generic.Dictionary[string, object]]::new($comparer))
}

function Get-AuditStreamHash($Stream, [long]$ExpectedBytes) {
    $digest = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $buffer = [byte[]]::new(1MB)
    [long]$total = 0
    try {
        while (($count = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $count
            if ($total -gt $ExpectedBytes) { throw 'archive_entry_length_mismatch' }
            $digest.AppendData($buffer, 0, $count)
        }
        if ($total -ne $ExpectedBytes) { throw 'archive_entry_length_mismatch' }
        [Convert]::ToHexString($digest.GetHashAndReset()).ToLowerInvariant()
    } finally { $digest.Dispose() }
}

function Get-AuditTreeFiles([string]$Root) {
    Assert-AuditNoLinks $Root
    $rootPath = [IO.Path]::GetFullPath($Root)
    $files = New-AuditFileMap
    $directories = [Collections.Generic.Stack[string]]::new()
    $directories.Push($rootPath)
    while ($directories.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $directories.Pop() -Force) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'linked_input_not_allowed' }
            if ($item.PSIsContainer) { $directories.Push($item.FullName); continue }
            $relative = ConvertTo-AuditPath ([IO.Path]::GetRelativePath($rootPath, $item.FullName))
            if ($files.ContainsKey($relative)) { throw 'duplicate_payload_path' }
            $files.Add($relative, [ordered]@{ path = $relative; sha256 = Get-AuditSha256 $item.FullName; size = $item.Length })
            if ($files.Count -gt 30000) { throw 'too_many_payload_files' }
        }
    }
    ,$files
}

function Get-AuditZipFiles([string]$Path, [switch]$GoModule, [switch]$Apk) {
    if ($Apk -and $GoModule) { throw 'apk_go_module_mode_conflict' }
    Assert-AuditNoLinks $Path
    # APK entries are Android's case-sensitive virtual filesystem. AAPT can
    # legitimately emit res/zR.png and res/zr.png. They are never extracted to
    # the Windows filesystem here. All generic/Windows/Go archives retain the
    # stricter historical case-insensitive collision guard unless APK is explicit.
    $files = New-AuditFileMap -CaseSensitive:$Apk
    $comparer = if ($Apk) { [StringComparer]::Ordinal } else { [StringComparer]::OrdinalIgnoreCase }
    $seen = [Collections.Generic.HashSet[string]]::new($comparer)
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        if ($zip.Entries.Count -gt 30000) { throw 'too_many_archive_entries' }
        [long]$total = 0
        foreach ($entry in $zip.Entries) {
            # Unix symlinks and ambiguous directory entries are never extracted.
            if ((($entry.ExternalAttributes -shr 16) -band 0xf000) -eq 0xa000) { throw 'archive_link_not_allowed' }
            $directory = $entry.FullName.EndsWith('/')
            $relative = ConvertTo-AuditPath $entry.FullName.TrimEnd('/')
            if (!$seen.Add($relative)) { throw 'duplicate_archive_path' }
            if ($directory) {
                if ($GoModule) { throw 'module_zip_directory_not_supported' }
                continue
            }
            if ($files.ContainsKey($relative)) { throw 'duplicate_archive_path' }
            $total += $entry.Length
            if ($entry.Length -gt 1GB -or $total -gt 4GB) { throw 'archive_size_limit' }
            $stream = $entry.Open()
            try { $hash = Get-AuditStreamHash $stream $entry.Length }
            finally { $stream.Dispose() }
            $files.Add($relative, [ordered]@{ path = $relative; sha256 = $hash; size = $entry.Length })
        }
    } finally { $zip.Dispose() }
    foreach ($name in $files.Keys) {
        $parent = $name
        while ($parent.Contains('/')) {
            $parent = $parent.Substring(0, $parent.LastIndexOf('/'))
            if ($files.ContainsKey($parent)) { throw 'archive_file_directory_collision' }
        }
    }
    ,$files
}

function Read-AuditZipBytes([string]$Path, [string]$EntryPath, [long]$MaximumBytes = 16MB) {
    $safe = ConvertTo-AuditPath $EntryPath
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $zip.GetEntry($safe)
        if (!$entry -or $entry.Length -gt $MaximumBytes) { throw 'archive_entry_missing_or_too_large' }
        $stream = $entry.Open()
        $buffer = [IO.MemoryStream]::new()
        $chunk = [byte[]]::new(1MB)
        try {
            while (($count = $stream.Read($chunk, 0, $chunk.Length)) -gt 0) {
                if ($buffer.Length + $count -gt $entry.Length) { throw 'archive_entry_length_mismatch' }
                $buffer.Write($chunk, 0, $count)
            }
            if ($buffer.Length -ne $entry.Length) { throw 'archive_entry_length_mismatch' }
            return ,$buffer.ToArray()
        }
        finally { $stream.Dispose(); $buffer.Dispose() }
    } finally { $zip.Dispose() }
}

function Get-AuditGoZipSum([string]$Path) {
    $files = Get-AuditZipFiles $Path -GoModule
    # Go orders UTF-8 bytes; UTF-16 ordinal order differs for supplementary names.
    $names = [string[]]@($files.Keys | ForEach-Object { [Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($_)) + [char]0 + $_ })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    # Go's documented h1 dirhash: sorted UTF-8 names, SHA-256, two spaces, LF.
    $lines = [Text.StringBuilder]::new()
    foreach ($encoded in $names) {
        $name = $encoded.Substring($encoded.IndexOf([char]0) + 1)
        [void]$lines.Append($files[$name].sha256).Append('  ').Append($name).Append("`n")
    }
    'h1:' + [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($lines.ToString())))
}

function Add-AuditFinding($Findings, [string]$Code, [string]$Subject = '') {
    $Findings.Add([ordered]@{ code = $Code; subject = $Subject; severity = 'blocker' })
}

function Test-AuditManifest($Manifest, $Files, $Findings) {
    if ($Manifest.format -ne 1 -or !$Manifest.trees -or @($Manifest.trees.Keys).Count -ne 3) { throw 'unsupported_package_manifest' }
    $expected = New-AuditFileMap
    foreach ($tree in @('ui', 'service', 'control')) {
        if (!$Manifest.trees.Contains($tree)) { throw 'missing_package_tree' }
        foreach ($file in $Manifest.trees[$tree]) {
            $path = "$tree/$(ConvertTo-AuditPath $file.path)"
            if ($file.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $expected.ContainsKey($path)) { throw 'invalid_package_file_record' }
            $expected.Add($path, $file)
            if (!$Files.ContainsKey($path)) { Add-AuditFinding $Findings 'packaged_file_missing' $path }
            elseif ($Files[$path].sha256 -cne $file.sha256) { Add-AuditFinding $Findings 'packaged_file_hash_mismatch' $path }
        }
    }
    foreach ($path in $Files.Keys) {
        if ($path -ne 'package.json' -and !$expected.ContainsKey($path)) { Add-AuditFinding $Findings 'unmanifested_payload_file' $path }
    }
}

function Get-AuditGoPins([string]$ModPath, [string]$SumPath) {
    $pins = @{}
    $inRequire = $false
    foreach ($line in [IO.File]::ReadAllLines($ModPath)) {
        if ($line -match '^require\s+\(') { $inRequire = $true; continue }
        if ($inRequire -and $line -match '^\)') { $inRequire = $false; continue }
        $match = if ($inRequire) { [regex]::Match($line, '^\s*(\S+)\s+(v\S+)(?:\s+//.*)?$') } else { [regex]::Match($line, '^require\s+(\S+)\s+(v\S+)(?:\s+//.*)?$') }
        if ($match.Success) { $pins[$match.Groups[1].Value] = @{ version = $match.Groups[2].Value; sum = '' } }
    }
    foreach ($line in [IO.File]::ReadAllLines($SumPath)) {
        if ($line -match '^(\S+) (v\S+) (h1:[A-Za-z0-9+/=]+)$' -and $pins.ContainsKey($Matches[1]) -and $pins[$Matches[1]].version -ceq $Matches[2]) {
            $pins[$Matches[1]].sum = $Matches[3]
        }
    }
    if (!$pins.Count) { throw 'empty_go_pins' }
    $pins
}

function Invoke-AuditTool([string]$Executable, [string[]]$Arguments, [int]$TimeoutSeconds = 60) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['GOTOOLCHAIN'] = 'local'
    $start.Environment['GOWORK'] = 'off'
    foreach ($arg in $Arguments) { $start.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (!$process.Start()) { throw 'audit_tool_start_failed' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) { $process.Kill($true); throw 'audit_tool_timeout' }
        $text = $stdout.GetAwaiter().GetResult()
        [void]$stderr.GetAwaiter().GetResult()
        # External diagnostics are not printed or copied into release reports.
        if ($process.ExitCode -ne 0) { throw 'audit_tool_failed' }
        $text
    } finally { $process.Dispose() }
}

function Test-AuditAppUpdaterIdentity([System.Collections.IDictionary]$Info) {
    $module = 'github.com/Extectick/ExVPN/native/appupdater'
    return $Info.Contains('Path') -and $Info['Path'] -ceq $module -and
        $Info.Contains('Main') -and $Info['Main'] -is [System.Collections.IDictionary] -and $Info['Main']['Path'] -ceq $module -and
        (!$Info['Main'].Contains('Replace') -or $null -eq $Info['Main']['Replace'])
}

function Get-AuditWindowsNativePaths($Files) {
    $paths = @('service/exvpn-service.exe')
    if ($Files.ContainsKey('ui/exvpn-updater.exe')) { $paths += 'ui/exvpn-updater.exe' }
    return ,$paths
}

function Test-AuditGoBinary($Info, [string]$RelativePath, [string]$Sha256, $Pins, [string]$GoVersion, $Findings) {
    if ($Info.GoVersion -cne "go$GoVersion") { Add-AuditFinding $Findings 'native_go_version_mismatch' $RelativePath }
    $dependencies = @(if ($Info.Contains('Deps') -and $null -ne $Info['Deps']) { $Info['Deps'] })
    if ($RelativePath -ceq 'ui/exvpn-updater.exe') {
        if (!(Test-AuditAppUpdaterIdentity $Info)) { throw 'native_updater_identity_mismatch' }
        if ($dependencies.Count) { throw 'native_updater_dependencies_present' }
    } elseif (!$dependencies.Count) { throw 'native_module_information_missing' }
    $settings = @{}
    foreach ($setting in $Info.Settings) { $settings[$setting.Key] = $setting.Value }
    $expected = switch ($RelativePath) {
        'service/exvpn-service.exe' { @('windows', 'amd64') }
        'ui/exvpn-updater.exe' { @('windows', 'amd64') }
        'lib/arm64-v8a/libexvpn.so' { @('android', 'arm64') }
        'lib/x86_64/libexvpn.so' { @('android', 'amd64') }
        default { throw 'unexpected_native_binary' }
    }
    if ($settings['GOOS'] -cne $expected[0] -or $settings['GOARCH'] -cne $expected[1]) { Add-AuditFinding $Findings 'native_platform_mismatch' $RelativePath }
    if ($RelativePath -ceq 'ui/exvpn-updater.exe' -and $settings['-buildmode'] -cne 'exe') { Add-AuditFinding $Findings 'native_platform_mismatch' $RelativePath }
    $modules = [Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($module in $dependencies) {
        if ($module.Path.StartsWith('github.com/Extectick/ExVPN/')) { continue }
        if ($seen.ContainsKey($module.Path)) { throw 'duplicate_embedded_module' }
        $seen[$module.Path] = $true
        if ($module['Replace']) { Add-AuditFinding $Findings 'external_go_module_replacement' $module.Path }
        if (!$Pins.ContainsKey($module.Path) -or $Pins[$module.Path].version -cne $module.Version -or !$Pins[$module.Path].sum -or $Pins[$module.Path].sum -cne $module.Sum) {
            Add-AuditFinding $Findings 'native_module_pin_mismatch' "$($module.Path)@$($module.Version)"
        }
        $modules.Add([ordered]@{ name = $module.Path; version = $module.Version; sum = $module.Sum })
    }
    [ordered]@{ path = $RelativePath; sha256 = $Sha256; go = $Info.GoVersion; modules = @($modules | Sort-Object { $_.name } -CaseSensitive -Culture en-US) }
}

function Assert-AuditAndroidAbiCoverage($Files) {
    # A dependency must not advertise an ABI which lacks the VPN core or Flutter
    # engine. Inspect final ZIP entries, not the Gradle DSL's intended filters.
    $allowed = @('arm64-v8a', 'x86_64')
    foreach ($path in $Files.Keys) {
        if ($path -cmatch '^lib/([^/]+)/[^/]+\.so$' -and $Matches[1] -cnotin $allowed) {
            throw 'android_packaged_unsupported_abi'
        }
    }
    foreach ($abi in $allowed) {
        foreach ($library in @('libexvpn.so', 'libflutter.so')) {
            if (!$Files.ContainsKey("lib/$abi/$library")) { throw 'android_packaged_incomplete_abi' }
        }
    }
}

function Test-AuditNotices($Inventory, $Files, $Native, [string]$Target, [string]$AppVersion, [string]$DartLockHash, $Findings) {
    if ($Inventory.schema -ne 1 -or $Inventory.target -cne $Target -or !$Inventory.components.Count) { throw 'invalid_notice_inventory' }
    if (!$Inventory['app'] -or $Inventory.app.version -cne $AppVersion) { Add-AuditFinding $Findings 'notice_app_identity_missing_or_mismatch' }
    if (!$Inventory['dartLockSha256'] -or $Inventory.dartLockSha256 -cne $DartLockHash) { Add-AuditFinding $Findings 'notice_dart_lock_missing_or_mismatch' }
    $components = @{}
    foreach ($component in $Inventory.components) {
        if (!$component.name -or !$component.version -or !$component.scope -or !$component.notices.Count) { throw 'invalid_notice_component' }
        $key = "$($component.scope)/$($component.name)@$($component.version)"
        if ($components.ContainsKey($key)) { throw 'duplicate_notice_component' }
        $components[$key] = $component
        foreach ($notice in $component.notices) {
            $path = ConvertTo-AuditPath $notice.path
            if ($notice.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'invalid_notice_hash' }
            if (!$Files.ContainsKey($path)) { Add-AuditFinding $Findings 'notice_file_missing' $path }
            elseif ($Files[$path].sha256 -cne $notice.sha256) { Add-AuditFinding $Findings 'notice_file_hash_mismatch' $path }
        }
        if ($component.name -in 'ExVPN', 'ExVPN copyright' -and $component.version -cne $AppVersion) {
            Add-AuditFinding $Findings 'notice_component_version_stale' $component.name
        }
    }
    foreach ($name in @('ExVPN', 'ExVPN copyright')) {
        if (!@($Inventory.components | Where-Object name -CEQ $name).Count) { Add-AuditFinding $Findings 'own_notice_missing' $name }
    }
    $usedNative = @{}
    foreach ($binary in $Native) {
        if ($binary.path -ceq 'ui/exvpn-updater.exe' -and !$components.ContainsKey("runtime-or-asset/Go runtime@$($binary.go.Substring(2))")) {
            Add-AuditFinding $Findings 'stdlib_go_runtime_notice_missing' $binary.path
        }
        $matches = @($Inventory.nativeBinaries | Where-Object { $_.sha256 -ceq $binary.sha256 })
        if ($matches.Count -ne 1) { Add-AuditFinding $Findings 'notice_native_hash_not_bound' $binary.path; continue }
        $declared = $matches[0]
        $usedNative[$declared.name] = $true
        if ((ConvertTo-AuditPath $declared.name) -cne $binary.path) { Add-AuditFinding $Findings 'notice_native_path_not_bound' $binary.path }
        if ($declared.go -cne $binary.go) { Add-AuditFinding $Findings 'notice_native_go_mismatch' $binary.path }
        $declaredModules = @{}
        foreach ($module in $declared.modules) {
            if ($module.Path.StartsWith('github.com/Extectick/ExVPN/')) { continue }
            if ($declaredModules.ContainsKey($module.Path)) { throw 'duplicate_notice_native_module' }
            $declaredModules[$module.Path] = $module
        }
        if ($declaredModules.Count -ne $binary.modules.Count) { Add-AuditFinding $Findings 'notice_native_module_set_mismatch' $binary.path }
        foreach ($module in $binary.modules) {
            $key = "linked-go-module/$($module.name)@$($module.version)"
            if (!$components.ContainsKey($key) -or $components[$key].moduleSum -cne $module.sum) { Add-AuditFinding $Findings 'linked_module_notice_missing_or_mismatch' $module.name }
            if (!$declaredModules.ContainsKey($module.name) -or $declaredModules[$module.name].Version -cne $module.version -or $declaredModules[$module.name].Sum -cne $module.sum -or $declaredModules[$module.name]['Replace']) {
                Add-AuditFinding $Findings 'notice_native_module_mismatch' $module.name
            }
        }
    }
    foreach ($declared in $Inventory.nativeBinaries) {
        if (!$usedNative.ContainsKey($declared.name)) { Add-AuditFinding $Findings 'notice_native_binary_not_in_artifact' $declared.name }
    }
}

function New-AuditSbom([string]$Target, [string]$AppVersion, [string]$ArtifactHash, $Files, $Native, $Inventory, [switch]$WindowsPayloadVerified) {
    $rootRef = 'exvpn:' + $Target.ToLowerInvariant() + ':' + $ArtifactHash
    $components = [Collections.Generic.List[object]]::new()
    $modules = @{}
    foreach ($nativeFile in $Native) {
        foreach ($module in $nativeFile.modules) { $modules["$($module.name)@$($module.version)"] = $module }
    }
    foreach ($key in @($modules.Keys | Sort-Object -CaseSensitive -Culture en-US)) {
        $module = $modules[$key]
        $properties = [Collections.Generic.List[object]]::new()
        $properties.Add([ordered]@{ name = 'exvpn:evidence'; value = 'actual-native-build-info' })
        $properties.Add([ordered]@{ name = 'exvpn:go-module-sum'; value = $module.sum })
        if ($Inventory) {
            foreach ($declared in @($Inventory.components | Where-Object { $_.scope -ceq 'linked-go-module' -and $_.name -ceq $module.name -and $_.version -ceq $module.version })) {
                foreach ($notice in @($declared.notices | Sort-Object { $_.path } -CaseSensitive -Culture en-US)) {
                    $properties.Add([ordered]@{ name = 'exvpn:notice-sha256:' + $notice.path; value = $notice.sha256 })
                }
            }
        }
        $components.Add([ordered]@{ type = 'library'; 'bom-ref' = 'go:' + (Get-AuditTextHash $key); name = $module.name; version = $module.version; properties = $properties.ToArray() })
    }
    foreach ($file in @($Files.Values | Sort-Object { $_.path } -CaseSensitive -Culture en-US)) {
        $components.Add([ordered]@{ type = 'file'; 'bom-ref' = 'file:' + (Get-AuditTextHash $file.path); name = $file.path; hashes = @([ordered]@{ alg = 'SHA-256'; content = $file.sha256 }); properties = @(
            [ordered]@{ name = 'exvpn:evidence'; value = $(if ($Target -eq 'Android') { 'actual-apk-entry' } elseif ($WindowsPayloadVerified) { 'actual-nsis-payload-entry' } else { 'staged-payload-file' }) },
            [ordered]@{ name = 'exvpn:size'; value = [string]$file.size }
        ) })
    }
    if ($Inventory) {
        foreach ($component in @($Inventory.components | Sort-Object { $_.scope }, { $_.name }, { $_.version } -CaseSensitive -Culture en-US)) {
            if ($component.scope -eq 'linked-go-module') { continue }
            $key = "$($component.scope)/$($component.name)@$($component.version)"
            $properties = [Collections.Generic.List[object]]::new()
            $properties.Add([ordered]@{ name = 'exvpn:evidence'; value = 'notice-inventory-declaration-not-link-proof' })
            $properties.Add([ordered]@{ name = 'exvpn:inventory-scope'; value = $component.scope })
            foreach ($notice in @($component.notices | Sort-Object { $_.path } -CaseSensitive -Culture en-US)) {
                $properties.Add([ordered]@{ name = 'exvpn:notice-sha256:' + $notice.path; value = $notice.sha256 })
            }
            $components.Add([ordered]@{ type = 'library'; 'bom-ref' = 'notice:' + (Get-AuditTextHash $key); name = $component.name; version = $component.version; properties = $properties.ToArray() })
        }
    }
    [ordered]@{
        '$schema' = 'http://cyclonedx.org/schema/bom-1.6.schema.json'
        bomFormat = 'CycloneDX'; specVersion = '1.6'; version = 1
        metadata = [ordered]@{ component = [ordered]@{ type = 'application'; 'bom-ref' = $rootRef; name = 'ExVPN'; version = $AppVersion; hashes = @([ordered]@{ alg = 'SHA-256'; content = $ArtifactHash }); properties = @(
            [ordered]@{ name = 'exvpn:platform'; value = $Target },
            [ordered]@{ name = 'exvpn:coverage'; value = 'incomplete; see audit.json; not a release approval' }
        ) } }
        components = $components.ToArray()
        compositions = @([ordered]@{ aggregate = 'incomplete'; assemblies = @($rootRef) })
    }
}

function Write-AuditJson([string]$Path, $Value) {
    # LF/UTF-8, sorted input arrays and ordered objects: no clocks, random IDs or
    # absolute local paths in evidence. Relocating the same inputs is reproducible.
    $json = (($Value | ConvertTo-Json -Depth 40) -replace "`r`n", "`n") + "`n"
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}
