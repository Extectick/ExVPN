param([string]$GoPath = '')
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repository 'scripts/bootstrap/enter-environment.ps1') -NativeOnly
if (!$GoPath) { $GoPath = Join-Path $repository '.tools/go/bin/go.exe' }
$output = Join-Path $repository 'artifacts/windows'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$savedOS = $env:GOOS
$savedArch = $env:GOARCH
Push-Location (Join-Path $repository 'native/windows')
try {
    $env:GOOS = 'windows'
    $env:GOARCH = 'amd64'
    & $GoPath build -mod=readonly -trimpath -o (Join-Path $output 'exvpn-service.exe') ./cmd/exvpn-service
    if ($LASTEXITCODE -ne 0) { throw 'Windows service build failed.' }
} finally {
    $env:GOOS = $savedOS
    $env:GOARCH = $savedArch
    Pop-Location
}
Write-Host 'Built artifacts/windows/exvpn-service.exe. Not installed, signed, or system-tested.'
