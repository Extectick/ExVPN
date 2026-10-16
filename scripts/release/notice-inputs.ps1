# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Read-only validation shared by the notice collector and its regression tests.
Set-StrictMode -Version Latest

function Get-NoticeAppVersion([string]$Pubspec, [string]$BuildIdentity) {
    $versions = [regex]::Matches($Pubspec, '(?m)^version: *(\d+\.\d+\.\d+)\+(\d+)\s*$')
    if ($versions.Count -ne 1) { throw 'Expected exactly one application SemVer/build.' }
    $version = $versions[0].Groups[1].Value
    $build = $versions[0].Groups[2].Value
    $displayVersions = [regex]::Matches($BuildIdentity, '(?m)^const appVersion = ''([^'']+)'';\r?$')
    $displayBuilds = [regex]::Matches($BuildIdentity, '(?m)^const appBuild = (\d+);\r?$')
    if ($displayVersions.Count -ne 1 -or $displayBuilds.Count -ne 1 -or
        $displayVersions[0].Groups[1].Value -cne $version -or $displayBuilds[0].Groups[1].Value -cne $build) {
        throw 'Displayed application identity differs from the package version.'
    }
    "$version+$build"
}

function Get-NoticeScalar([string]$Text, [string]$Key, [int]$Indent) {
    # This accepts pub's generated lockfile representation only, not arbitrary
    # YAML (anchors, multiline values and implicit conversion are not supported).
    $matches = [regex]::Matches($Text, '(?m)^' + (' ' * $Indent) + [regex]::Escape($Key) + ': *([^\r\n]+)\r?$')
    if ($matches.Count -ne 1) { throw "Missing or duplicate generated field: $Key." }
    $value = $matches[0].Groups[1].Value.Trim()
    $scalar = [regex]::Match($value, '^(?:"(?<value>[^"\\]*)"|''(?<value>[^'']*)''|(?<value>[A-Za-z0-9_./:+-]+))(?: +#[^\r\n]*)?$')
    if (!$scalar.Success) { throw "Unsupported generated scalar: $Key." }
    $scalar.Groups['value'].Value
}

function Get-NoticeLockedPackages([string]$LockText) {
    $section = [regex]::Match($LockText, '(?ms)^packages:\r?\n(?<body>.*?)(?=^sdks:\r?$)')
    if (!$section.Success) { throw 'Expected the generated packages/sdks lockfile sections.' }
    $entries = [regex]::Matches($section.Groups['body'].Value, '(?ms)^  (?<name>[a-z][a-z0-9_]*):\r?\n(?<body>.*?)(?=^  [a-z][a-z0-9_]*:\r?$|\z)')
    if (!$entries.Count) { throw 'The generated lockfile contains no packages.' }
    if (($entries | ForEach-Object Value) -join '' -cne $section.Groups['body'].Value) { throw 'Unsupported generated package section.' }
    $result = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $entries) {
        $name = $entry.Groups['name'].Value
        if ($result.ContainsKey($name)) { throw 'Duplicate package in generated lockfile.' }
        $body = $entry.Groups['body'].Value
        $source = Get-NoticeScalar $body 'source' 4
        $version = Get-NoticeScalar $body 'version' 4
        if ($source -notin @('hosted', 'path', 'sdk') -or $version -notmatch '^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.+-]+)?$') {
            throw 'Unsupported dependency source or version in lockfile.'
        }
        $record = [ordered]@{ name=$name; version=$version; source=$source }
        if ($source -eq 'hosted') {
            $record.sha256 = Get-NoticeScalar $body 'sha256' 6
            $record.url = Get-NoticeScalar $body 'url' 6
            if ((Get-NoticeScalar $body 'name' 6) -cne $name -or
                $record.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $record.url -cne 'https://pub.dev') {
                throw 'Hosted dependency identity, checksum or source is not pinned to pub.dev.'
            }
        }
        $result.Add($name, $record)
    }
    return ,$result
}

function Get-NoticeDartInputs([string]$Repository, [string]$LockText, [string]$PackageConfigPath) {
    $locked = Get-NoticeLockedPackages $LockText
    $config = Get-Content -LiteralPath $PackageConfigPath -Raw | ConvertFrom-Json
    if ($config.configVersion -ne 2) { throw 'Unsupported package_config schema.' }
    $configUri = [Uri]::new([IO.Path]::GetFullPath($PackageConfigPath))
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $resolved = [Collections.Generic.List[object]]::new()
    foreach ($package in $config.packages) {
        if (!$seen.Add($package.name)) { throw 'Duplicate resolved Dart package.' }
        $uri = [Uri]::new($configUri, $package.rootUri)
        if (!$uri.IsFile) { throw 'Package config must reference local pinned sources.' }
        $root = [IO.Path]::GetFullPath($uri.LocalPath).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if ($package.name -ceq 'exvpn') {
            if ($root -ine [IO.Path]::GetFullPath((Join-Path $Repository 'apps/exvpn'))) { throw 'Unexpected application package root.' }
            continue
        }
        if (!$locked.ContainsKey($package.name)) { throw 'Resolved Dart package is missing from pubspec.lock.' }
        $pin = $locked[$package.name]
        if ($pin.source -ne 'hosted') { continue }
        $expected = [IO.Path]::GetFullPath((Join-Path $Repository ".tools/cache/pub/hosted/pub.dev/$($pin.name)-$($pin.version)"))
        if ($root -ine $expected) { throw 'Resolved package root does not match its locked name and version.' }
        $spec = Get-Content -LiteralPath (Join-Path $root 'pubspec.yaml') -Raw
        if ((Get-NoticeScalar $spec 'name' 0) -cne $pin.name -or (Get-NoticeScalar $spec 'version' 0) -cne $pin.version) {
            throw 'Resolved package source identity differs from pubspec.lock.'
        }
        $hashFile = Join-Path $Repository ".tools/cache/pub/hosted-hashes/pub.dev/$($pin.name)-$($pin.version).sha256"
        if ((Get-Content -LiteralPath $hashFile -Raw).Trim() -cne $pin.sha256) { throw 'Pub cache metadata differs from the locked archive checksum.' }
        $resolved.Add([ordered]@{ name=$pin.name; version=$pin.version; root=$root; archiveSha256=$pin.sha256 })
    }
    if (!$seen.Contains('exvpn')) { throw 'Application is missing from package_config.' }
    foreach ($name in $locked.Keys) {
        if (!$seen.Contains($name)) { throw 'A locked dependency is missing from package_config.' }
    }
    $resolved.ToArray()
}

function Get-NoticeBinaryName([string]$Target, $Info, [string]$GoVersion) {
    if ($Info.GoVersion -cne "go$GoVersion") { throw 'Native binary Go runtime differs from the pinned SDK.' }
    $settings = @{}
    foreach ($setting in $Info.Settings) {
        if ($settings.ContainsKey($setting.Key)) { throw 'Duplicate native build setting.' }
        $settings[$setting.Key] = $setting.Value
    }
    if ($Target -eq 'Windows' -and $settings.GOOS -ceq 'windows' -and $settings.GOARCH -ceq 'amd64' -and $settings['-buildmode'] -ceq 'exe') {
        return 'service/exvpn-service.exe'
    }
    if ($Target -eq 'Android' -and $settings.GOOS -ceq 'android' -and $settings['-buildmode'] -ceq 'c-shared') {
        if ($settings.GOARCH -ceq 'arm64') { return 'lib/arm64-v8a/libexvpn.so' }
        if ($settings.GOARCH -ceq 'amd64') { return 'lib/x86_64/libexvpn.so' }
    }
    throw 'Native binary does not match the requested platform, ABI or build mode.'
}

function Assert-NoticePackageBinding($Inventory, [string]$AppVersion, [string]$DartLockSha256, [System.Collections.IDictionary]$NativeHashes) {
    if ($Inventory.schema -ne 1 -or $Inventory.app.version -cne $AppVersion -or $Inventory.dartLockSha256 -cne $DartLockSha256) {
        throw 'Notices do not match this application version and Dart lockfile.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($binary in $Inventory.nativeBinaries) {
        if (!$seen.Add($binary.name) -or !$NativeHashes.Contains($binary.name) -or $binary.sha256 -cne $NativeHashes[$binary.name]) {
            throw 'Notices do not match the exact staged native payload.'
        }
    }
    if ($seen.Count -ne $NativeHashes.Count) { throw 'A staged native binary has no notice evidence.' }
    foreach ($name in @('ExVPN', 'ExVPN copyright')) {
        $entries = @($Inventory.components | Where-Object { $_.name -ceq $name })
        if ($entries.Count -ne 1 -or $entries[0].version -cne $AppVersion) { throw 'Application notices have an incorrect version.' }
    }
}

function Get-NoticeXrayPatch([string]$Repository, [string]$Version, [string]$ModuleSum) {
    # Historical stock artifacts still resolve to their original public module.
    # ExVPN prereleases must be backed by the committed patch and exact h1.
    if ($Version -notmatch '-exvpn\.') { return $null }
    $lockPath = Join-Path $Repository 'native/patches/xray-lifecycle.lock.json'
    $patchPath = Join-Path $Repository 'native/patches/xray-lifecycle.patch'
    $pin = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    if ($pin.schemaVersion -ne 1 -or $pin.module -cne 'github.com/xtls/xray-core' -or
        $pin.patch.path -cne 'xray-lifecycle.patch' -or
        $pin.patch.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $pin.upstream.commit -cnotmatch '^[a-f0-9]{40}$' -or
        $pin.patched.version -cne $Version -or !$ModuleSum -or
        $pin.patched.sum -cne $ModuleSum) {
        throw 'Modified Xray binary does not match the committed patch pin.'
    }
    if ((Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pin.patch.sha256) {
        throw 'Modified Xray source patch differs from its committed checksum.'
    }
    [pscustomobject]@{
        lockPath = $lockPath
        patchPath = $patchPath
        sourceUrl = 'https://github.com/Extectick/ExVPN/tree/main/native/patches'
        upstreamCommit = $pin.upstream.commit
        patchSha256 = $pin.patch.sha256
        version = $Version
        moduleSum = $ModuleSum
    }
}

function Assert-NoticeXraySourceBundle($PatchEvidence, $NoticeFiles) {
    $requiredSources = @{
        'sources/xray-lifecycle.patch' = $PatchEvidence.patchSha256
        'sources/xray-lifecycle.lock.json' = (Get-FileHash -LiteralPath $PatchEvidence.lockPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    foreach ($entry in $requiredSources.GetEnumerator()) {
        if (!$NoticeFiles.ContainsKey($entry.Key) -or $NoticeFiles[$entry.Key].sha256 -cne $entry.Value) {
            throw 'modified_xray_provenance_mismatch'
        }
    }
    if (!$NoticeFiles.ContainsKey('sources/XRAY-EXVPN-NOTICE.txt')) { throw 'modified_xray_notice_missing' }
}
