# SPDX-License-Identifier: Apache-2.0
# Pure helpers shared by the cloud-independent AOT builder and its fixtures.
Set-StrictMode -Version Latest

function Get-ExvpnOtaSha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-ExvpnOtaTextSha256([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-ExvpnOtaNoLinks([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if (((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'ota_path_link_rejected'
            }
        }
        $next = [IO.Path]::GetDirectoryName($cursor)
        if ($next -eq $cursor) { break }
        $cursor = $next
    }
}

function Resolve-ExvpnOtaPath([string]$BaseDirectory, [string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'ota_path_missing' }
    $absolute = if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path)) }
    Assert-ExvpnOtaNoLinks $absolute
    $absolute
}

function Test-ExvpnOtaProtectedPath([string]$Path) {
    $value = $Path.Replace('\','/')
    if ($value -match '(^|/)(build|\.dart_tool|\.gradle|\.cxx|ephemeral|\.idea)/') { return $false }
    if ($value -match '^apps/exvpn/(test|integration_test)/' -or $value -match '^packages/[^/]+/(test|example)/') { return $false }
    if ($value -match '^apps/exvpn/lib/.+\.dart$' -and $value -ne 'apps/exvpn/lib/build_identity.dart') { return $false }
    if ($value -match '^packages/[^/]+/lib/.+\.dart$') { return $false }
    if ($value -match '^apps/exvpn/\.(flutter-plugins-dependencies|metadata)$') { return $false }
    return $value -match '^(apps/exvpn/|packages/[^/]+/|native/|config/|scripts/bootstrap/)' -or $value -match '^(pubspec\.(yaml|lock)|melos\.yaml|\.gitmodules|\.gitattributes)$'
}

function Get-ExvpnOtaProtectedInputs([string]$Repository) {
    $root = [IO.Path]::GetFullPath($Repository)
    $paths = @(& git -C $root -c core.quotepath=false ls-files --cached --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) { throw 'ota_git_inventory_failed' }
    # Flutter folder assets include ignored files too. Do not let .gitignore
    # hide a newly added resource from the native/assets compatibility gate.
    $assets = Join-Path $root 'apps/exvpn/assets'
    if (Test-Path -LiteralPath $assets -PathType Container) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $assets -Recurse -Force)) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'ota_path_link_rejected' }
            if (!$entry.PSIsContainer) { $paths += [IO.Path]::GetRelativePath($root,$entry.FullName).Replace('\','/') }
        }
    }
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($relative in @($paths | Sort-Object -Unique -CaseSensitive)) {
        if (!(Test-ExvpnOtaProtectedPath $relative)) { continue }
        if ($relative -match '(^|/)\.\.?(/|$)' -or [IO.Path]::IsPathRooted($relative)) { throw 'ota_git_path_invalid' }
        $path = Resolve-ExvpnOtaPath $root $relative
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw 'ota_protected_input_missing' }
        $entries.Add([ordered]@{path=$relative.Replace('\','/');sha256=(Get-ExvpnOtaSha256 $path)})
    }
    $entries.ToArray()
}

function Get-ExvpnOtaInputsFingerprint([object[]]$Inputs) {
    $lines = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sorted = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($item in $Inputs) {
        if ($item.path -isnot [string] -or $item.sha256 -isnot [string] -or $item.sha256 -cnotmatch '^[a-f0-9]{64}$' -or !$seen.Add($item.path)) { throw 'ota_input_record_invalid' }
        if ($item.path -match '[\r\n\x00]' -or $item.path.Contains('\')) { throw 'ota_input_record_invalid' }
        $sorted.Add($item.path, $item)
    }
    foreach ($item in $sorted.Values) {
        $lines.Add($item.path + "`t" + $item.sha256)
    }
    Get-ExvpnOtaTextSha256 (($lines -join "`n") + "`n")
}

function Get-ExvpnOtaFingerprint([object[]]$Inputs) { Get-ExvpnOtaInputsFingerprint $Inputs }

function Assert-ExvpnOtaProtectedInputs([string]$Repository, [object[]]$Expected) {
    if ($Expected.Count -eq 0) { throw 'ota_protected_inputs_empty' }
    foreach ($record in $Expected) {
        if (!(Test-ExvpnOtaProtectedPath $record.path)) { throw 'ota_protected_policy_invalid' }
    }
    $expectedFingerprint = Get-ExvpnOtaInputsFingerprint $Expected
    $actual = @(Get-ExvpnOtaProtectedInputs $Repository)
    if ((Get-ExvpnOtaInputsFingerprint $actual) -cne $expectedFingerprint) { throw 'ota_native_assets_dependencies_changed' }
    $expectedFingerprint
}

function Assert-ExvpnOtaVersion([string]$Repository, [string]$Version) {
    if ($Version -cnotmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\+([1-9]\d*)$') { throw 'ota_version_invalid' }
    $pieces = $Version.Split('+')
    $pubspec = [IO.File]::ReadAllText((Join-Path $Repository 'apps/exvpn/pubspec.yaml'))
    $identity = [IO.File]::ReadAllText((Join-Path $Repository 'apps/exvpn/lib/build_identity.dart'))
    if ($pubspec -cnotmatch ('(?m)^version:\s*' + [regex]::Escape($Version) + '\s*$') -or
        $identity -cnotmatch ("const appVersion = '" + [regex]::Escape($pieces[0]) + "';") -or
        $identity -cnotmatch ('const appBuild = ' + [regex]::Escape($pieces[1]) + ';')) { throw 'ota_base_version_changed' }
}

function New-ExvpnOtaHashSignature([string]$AotHash, [Security.Cryptography.RSA]$PrivateKey) {
    if ($AotHash -cnotmatch '^[a-f0-9]{64}$' -or $PrivateKey.KeySize -ne 4096) { throw 'ota_signing_input_invalid' }
    $signature = $PrivateKey.SignData([Text.Encoding]::UTF8.GetBytes($AotHash), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    if (!$PrivateKey.VerifyData([Text.Encoding]::UTF8.GetBytes($AotHash), $signature, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)) { throw 'ota_signature_self_check_failed' }
    [Convert]::ToBase64String($signature)
}

function Get-ExvpnOtaAotPlan([string]$Target) {
    if ($Target -cnotin @('Windows','Android')) { throw 'ota_target_invalid' }
    if ($Target -ceq 'Windows') {
        return ,([ordered]@{arch='x86_64';key='windows-x64';platform='windows-x64';genSnapshot='bin/cache/artifacts/engine/windows-x64-release/gen_snapshot.exe'})
    }
    @(
        [ordered]@{arch='aarch64';key='android-arm64';platform='android-arm64';genSnapshot='bin/cache/artifacts/engine/android-arm64-release/windows-x64/gen_snapshot.exe'}
        [ordered]@{arch='x86_64';key='android-x64';platform='android-x64';genSnapshot='bin/cache/artifacts/engine/android-x64-release/windows-x64/gen_snapshot.exe'}
    )
}

function Assert-ExvpnOtaElf([string]$Path, [string]$Architecture) {
    if ($Architecture -cnotin @('x86_64','aarch64')) { throw 'ota_elf_architecture_invalid' }
    $header = [byte[]]::new(64)
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 4096 -or $stream.Read($header,0,$header.Length) -ne $header.Length) { throw 'ota_elf_invalid' }
    } finally { $stream.Dispose() }
    $machine = if ($Architecture -ceq 'aarch64') { 183 } else { 62 }
    if ($header[0] -ne 0x7f -or $header[1] -ne 0x45 -or $header[2] -ne 0x4c -or $header[3] -ne 0x46 -or
        $header[4] -ne 2 -or $header[5] -ne 1 -or [BitConverter]::ToUInt16($header,18) -ne $machine) { throw 'ota_elf_invalid' }
}
