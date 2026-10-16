#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$NdkPath = (Join-Path $env:LOCALAPPDATA 'Android/Sdk/ndk/27.1.12297006')
)

# E1 compile feasibility only: builds an Android CLI ELF, not an APK/AAR or VpnService.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This script uses the Windows x64 Android NDK toolchain.' }
$repository = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$goPath = Join-Path $repository '.tools/go/bin/go.exe'
$toolchainLock = Get-Content -LiteralPath (Join-Path $repository 'scripts/bootstrap/toolchain.lock.json') -Raw | ConvertFrom-Json
if (-not (Test-Path -LiteralPath $goPath)) { throw 'Run scripts/bootstrap/bootstrap.ps1 -Component Go first.' }
$goVersion = & $goPath version
if ($LASTEXITCODE -ne 0 -or $goVersion -ne "go version go$($toolchainLock.go.version) windows/amd64") {
    throw 'The Go SDK does not match the repository toolchain pin.'
}
$ndkProperties = Get-Content -LiteralPath (Join-Path $NdkPath 'source.properties') -Raw
if ($ndkProperties -notmatch '(?m)^Pkg\.Revision\s*=\s*27\.1\.12297006\s*$') {
    throw 'This feasibility build is pinned to Android NDK 27.1.12297006 (r27b).'
}
$ndkBin = Join-Path $NdkPath 'toolchains/llvm/prebuilt/windows-x86_64/bin'
$clang = Join-Path $ndkBin 'clang.exe'
$clangxx = Join-Path $ndkBin 'clang++.exe'
$readelf = Join-Path $ndkBin 'llvm-readelf.exe'
foreach ($tool in @($clang, $clangxx, $readelf)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Missing NDK tool: $tool" }
}
$outputDirectory = Join-Path $repository '.tools/artifacts/android'
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$binary = Join-Path $outputDirectory 'exvpn-core-arm64'
$processSettings = @{
    GOTOOLCHAIN = 'local'
    GOOS = 'android'
    GOARCH = 'arm64'
    CGO_ENABLED = '1'
    CC = ('"{0}" --target=aarch64-linux-android30' -f $clang)
    CXX = ('"{0}" --target=aarch64-linux-android30' -f $clangxx)
    GOCACHE = (Join-Path $repository '.tools/cache/go-build')
}
$previousSettings = @{}
foreach ($name in $processSettings.Keys) {
    $previousSettings[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

Push-Location (Join-Path $repository 'native/core')
try {
    foreach ($name in $processSettings.Keys) {
        [Environment]::SetEnvironmentVariable($name, $processSettings[$name], 'Process')
    }
    # Xray v26.10.10 README's Android recipe requires -checklinkname=0 because
    # anet v0.0.5 references private Go/x.net IPv6 zone caches. This relaxes the
    # Go linker check only for this Android build. Keep the toolchain pinned;
    # device runtime validation remains required when Go or anet changes.
    # https://github.com/XTLS/Xray-core/blob/v26.10.10/README.md#reproducible-releases
    # NDK r27 needs explicit 16 KiB LOAD/RELRO alignment; runtime on 16 KiB
    # devices is still a separate test. https://developer.android.com/guide/practices/page-sizes
    & $goPath build -mod=readonly -buildvcs=false -trimpath -buildmode=pie '-ldflags=-s -w -buildid= -checklinkname=0 -extldflags=-Wl,-z,max-page-size=16384,-z,common-page-size=16384' -o $binary ./cmd/exvpn-core
    if ($LASTEXITCODE -ne 0) { throw 'Android arm64 core cross-compilation failed.' }

    $elfHeader = (& $readelf --file-header $binary) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $elfHeader -notmatch 'Machine:\s+AArch64' -or $elfHeader -notmatch 'Class:\s+ELF64' -or $elfHeader -notmatch 'Type:\s+DYN') {
        throw 'The output is not the expected AArch64 ELF64 position-independent executable.'
    }
    $elfProgramHeaders = (& $readelf --program-headers $binary) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $elfProgramHeaders -notmatch 'Requesting program interpreter: /system/bin/linker64') {
        throw 'The output does not use the Android 64-bit dynamic linker.'
    }
    $loadSegments = @($elfProgramHeaders -split "`n" | Where-Object { $_ -match '^\s*LOAD\s' })
    if ($loadSegments.Count -eq 0) { throw 'The ELF has no load segments.' }
    foreach ($segment in $loadSegments) {
        $alignmentHex = ($segment.Trim() -split '\s+')[-1]
        if ([Convert]::ToUInt64($alignmentHex.Substring(2), 16) -lt 16384) { throw 'An ELF load segment is not 16 KiB aligned.' }
    }
    $relroSegments = @($elfProgramHeaders -split "`n" | Where-Object { $_ -match '^\s*GNU_RELRO\s' })
    if ($relroSegments.Count -eq 0) { throw 'The ELF has no RELRO protection segment.' }
    foreach ($segment in $relroSegments) {
        $fields = $segment.Trim() -split '\s+'
        $virtualAddress = [Convert]::ToUInt64($fields[2].Substring(2), 16)
        $memorySize = [Convert]::ToUInt64($fields[5].Substring(2), 16)
        if (($virtualAddress + $memorySize) % 16384 -ne 0) { throw 'An ELF RELRO end address is not 16 KiB aligned.' }
    }
    $elfNotes = (& $readelf --notes $binary) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $elfNotes -notmatch 'description data: 1e 00 00 00') { throw 'The ELF Android note does not report minimum API 30.' }
    $buildInfo = (& $goPath version -m $binary) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $buildInfo -notmatch 'GOOS=android' -or $buildInfo -notmatch 'GOARCH=arm64' -or $buildInfo -notmatch 'CGO_ENABLED=1') {
        throw 'The Go build settings do not match the expected Android target.'
    }
    $moduleText = Get-Content -LiteralPath 'go.mod' -Raw
    $xrayVersion = [regex]::Match($moduleText, 'github\.com/xtls/xray-core\s+(\S+)').Groups[1].Value
    if (-not $xrayVersion -or -not $buildInfo.Contains($xrayVersion)) { throw 'The ELF build information does not contain the pinned Xray module.' }

    $elfHeader | Set-Content -LiteralPath (Join-Path $outputDirectory 'elf-header.txt') -Encoding utf8
    $elfProgramHeaders | Set-Content -LiteralPath (Join-Path $outputDirectory 'elf-program-headers.txt') -Encoding utf8
    $elfNotes | Set-Content -LiteralPath (Join-Path $outputDirectory 'elf-notes.txt') -Encoding utf8
    $buildInfo | Set-Content -LiteralPath (Join-Path $outputDirectory 'go-build-info.txt') -Encoding utf8
    $evidence = [ordered]@{
        artifact = 'exvpn-core-arm64'
        format = 'Android arm64 ELF CLI; not APK or AAR'
        minimumAndroidApi = 30
        go = $toolchainLock.go.version
        ndk = '27.1.12297006'
        xrayModule = $xrayVersion
        linknameCheckDisabled = $true
        linknameReason = 'Pinned Xray Android recipe; anet v0.0.5 private IPv6 zone-cache links'
        sha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()
        bytes = (Get-Item -LiteralPath $binary).Length
        compileValidated = $true
        elfTargetValidated = $true
        elf16KiBLoadAndRelroAlignmentValidated = $true
        androidRuntimeValidated = $false
        vpnServiceValidated = $false
        systemTunnelValidated = $false
    }
    $evidence | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $outputDirectory 'build-evidence.json') -Encoding utf8
    $evidence | ConvertTo-Json -Depth 4
    Write-Host "Android compile-only artifact: $binary"
} finally {
    foreach ($name in $previousSettings.Keys) {
        if ($null -eq $previousSettings[$name]) {
            Remove-Item -LiteralPath ('Env:' + [IO.Path]::DirectorySeparatorChar + $name) -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $previousSettings[$name], 'Process')
        }
    }
    Pop-Location
}
