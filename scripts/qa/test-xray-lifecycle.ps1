# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$Race,
    [ValidateRange(1, 100)][int]$Count = 1,
    [ValidateRange(1, 16)][int]$TestConcurrency = 2
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repository 'scripts/bootstrap/enter-environment.ps1') -NativeOnly
$go = Join-Path $repository '.tools/go/bin/go.exe'
$pin = Get-Content -LiteralPath (Join-Path $repository 'native/patches/xray-lifecycle.lock.json') -Raw | ConvertFrom-Json
$module = "$($pin.module)@$($pin.patched.version)"
$resolved = ((& $go mod download -json $module) -join "`n") | ConvertFrom-Json -AsHashtable
if ($LASTEXITCODE -ne 0 -or $resolved['Error'] -or !$resolved['Dir'] -or
    $resolved.Sum -cne $pin.patched.sum -or $resolved.GoModSum -cne $pin.patched.goModSum) {
    throw 'Cannot test source that differs from the pinned modified Xray module.'
}
$previousCC = $env:CC
$previousCgo = $env:CGO_ENABLED
try {
    if ($Race) {
        $env:CC = & (Join-Path $PSScriptRoot 'prepare-race-compiler.ps1')
        $env:CGO_ENABLED = '1'
    }
    Push-Location -LiteralPath $resolved.Dir
    try {
        $packages = @('./transport/internet', './transport/internet/grpc', './transport/internet/splithttp', './app/proxyman/outbound', './proxy/tun')
        $arguments = @('test', '-mod=readonly', '-p', "$TestConcurrency", '-parallel', "$TestConcurrency",
            '-count', "$Count", '-timeout', '3m', '-run', '^TestExVPN')
        if ($Race) { $arguments += '-race' }
        & $go @arguments @packages
        if ($LASTEXITCODE -ne 0) { throw 'Xray lifecycle behavioral regression failed.' }
        & $go vet -mod=readonly -p $TestConcurrency @packages
        if ($LASTEXITCODE -ne 0) { throw 'Xray lifecycle vet failed.' }
    } finally { Pop-Location }
} finally {
    $env:CC = $previousCC
    $env:CGO_ENABLED = $previousCgo
}
Write-Host "Pinned Xray lifecycle tests passed (race=$Race, count=$Count). Loopback only; no host networking changes."
