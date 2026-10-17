#requires -Version 7.0
[CmdletBinding()]
param([ValidateSet('arm64-v8a','x86_64','all')][string]$Abi = 'all')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repository 'scripts/bootstrap/enter-environment.ps1')
$ndkPath = Join-Path $env:ANDROID_HOME 'ndk/27.1.12297006'
$ndkMetadata = Get-Content -LiteralPath (Join-Path $ndkPath 'source.properties') -Raw
if ($ndkMetadata -notmatch '(?m)^Pkg\.Revision\s*=\s*27\.1\.12297006\s*$') { throw 'Android JNI requires pinned NDK 27.1.12297006.' }
$lock = Get-Content -LiteralPath (Join-Path $repository 'scripts/bootstrap/toolchain.lock.json') -Raw | ConvertFrom-Json
$go = Join-Path $repository '.tools/go/bin/go.exe'
if ((& $go version) -ne "go version go$($lock.go.version) windows/amd64") { throw 'Go does not match toolchain pin.' }
$ndkBin = Join-Path $ndkPath 'toolchains/llvm/prebuilt/windows-x86_64/bin'
$clang = Join-Path $ndkBin 'clang.exe'
$readelf = Join-Path $ndkBin 'llvm-readelf.exe'
$targets = @(
    @{ abi='arm64-v8a'; arch='arm64'; target='aarch64-linux-android30'; machine='AArch64' },
    @{ abi='x86_64'; arch='amd64'; target='x86_64-linux-android30'; machine='Advanced Micro Devices X86-64' }
) | Where-Object { $Abi -eq 'all' -or $_.abi -eq $Abi }
$saved = @{}
foreach ($name in @('GOOS','GOARCH','CGO_ENABLED','CC','CGO_CFLAGS','CGO_LDFLAGS')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
Push-Location $PSScriptRoot
try {
    $env:GOOS='android'; $env:CGO_ENABLED='1'
    $env:CGO_CFLAGS='-O2 -fPIC'
    foreach ($target in $targets) {
        $env:GOARCH=$target.arch
        $env:CC=('"{0}" --target={1}' -f $clang,$target.target)
        $output = Join-Path $repository ('.tools/artifacts/android-jni/' + $target.abi)
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        $library = Join-Path $output 'libexvpn.so'
        & $go build -mod=readonly -buildvcs=false -trimpath -buildmode=c-shared '-ldflags=-s -w -buildid= -checklinkname=0 -extldflags=-Wl,-z,max-page-size=16384,-z,common-page-size=16384' -o $library ./bridge
        if ($LASTEXITCODE -ne 0) { throw "JNI compilation failed for $($target.abi)." }
        $header = (& $readelf --file-header $library) -join "`n"
        if ($LASTEXITCODE -ne 0 -or -not $header.Contains($target.machine) -or $header -notmatch 'Type:\s+DYN') { throw 'Invalid Android ELF library.' }
        $segments = (& $readelf --program-headers $library) -join "`n"
        foreach ($segment in @($segments -split "`n" | Where-Object { $_ -match '^\s*LOAD\s' })) {
            $alignment = ($segment.Trim() -split '\s+')[-1]
            if ([Convert]::ToUInt64($alignment.Substring(2),16) -lt 16384) { throw 'JNI library is not 16 KiB aligned.' }
        }
        $symbols = (& $readelf --dyn-syms $library) -join "`n"
        if ($symbols -notmatch 'Java_ru_exvpn_exvpn_NativeCore_start' -or $symbols -notmatch 'JNI_OnLoad') { throw 'JNI exports are missing.' }
        [ordered]@{abi=$target.abi;minimumApi=30;core='26.10.10-exvpn.4';go=$lock.go.version;ndk='27.1.12297006';sha256=(Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash;bytes=(Get-Item -LiteralPath $library).Length;runtimeVerified=$false} |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'build-evidence.json') -Encoding utf8
        Write-Host "Built Android JNI: $($target.abi)"
    }
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
    Pop-Location
}
