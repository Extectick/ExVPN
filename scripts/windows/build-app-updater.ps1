# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param([string]$GoPath = '', [switch]$ValidateOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AppUpdaterBuildPins([string]$Pubspec, [string]$ConfigText, [string]$GoMod) {
    $versions = [regex]::Matches($Pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)\+([1-9]\d*)\s*$')
    if ($versions.Count -ne 1 -or [long]$versions[0].Groups[2].Value -gt [int]::MaxValue) { throw 'Invalid updater application identity.' }
    $config = $ConfigText | ConvertFrom-Json
    $expectedFields = @('schema','channel','keyId','publicKey','feedUrl')
    if (@($config.PSObject.Properties.Name).Count -ne $expectedFields.Count -or
        @($config.PSObject.Properties.Name | Where-Object { $_ -cnotin $expectedFields }).Count -ne 0 -or
        ($config.schema -isnot [int] -and $config.schema -isnot [long]) -or $config.schema -ne 1 -or
        $config.channel -isnot [string] -or $config.keyId -isnot [string] -or
        $config.publicKey -isnot [string] -or $config.feedUrl -isnot [string] -or
        $config.channel -cne 'beta' -or $config.keyId -cnotmatch '^[A-Za-z0-9._-]{1,128}$' -or
        $config.feedUrl -cne 'https://github.com/Extectick/ExVPN/releases/download/windows-beta/windows-x64.json') {
        throw 'Invalid pinned Windows updater feed configuration.'
    }
    try { $publicKey = [Convert]::FromBase64String($config.publicKey) }
    catch { throw 'Invalid pinned Windows updater public key.' }
    if ($publicKey.Length -ne 32 -or [Convert]::ToBase64String($publicKey) -cne $config.publicKey) { throw 'Invalid pinned Windows updater public key.' }
    if ($GoMod -cnotmatch '\Amodule github\.com/Extectick/ExVPN/native/appupdater\r?\n\s*go 1\.27\.2\s*\z') {
        throw 'The Windows updater must use the exact Go 1.27.2 standard library only.'
    }
    [pscustomobject]@{
        appVersion=$versions[0].Groups[1].Value
        appBuild=$versions[0].Groups[2].Value
        updateChannel=$config.channel
        manifestFeed=$config.feedUrl
        manifestKeyID=$config.keyId
        manifestPublicKey=$config.publicKey
    }
}

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$pins = Get-AppUpdaterBuildPins (Get-Content -LiteralPath (Join-Path $repository 'apps/exvpn/pubspec.yaml') -Raw) `
    (Get-Content -LiteralPath (Join-Path $repository 'config/updates/windows-beta.json') -Raw) `
    (Get-Content -LiteralPath (Join-Path $repository 'native/appupdater/go.mod') -Raw)
$toolchain = Get-Content -LiteralPath (Join-Path $repository 'scripts/bootstrap/toolchain.lock.json') -Raw | ConvertFrom-Json
if ($toolchain.go.version -cne '1.27.2') { throw 'Windows updater Go pin differs from the toolchain lock.' }
if (!$GoPath) { $GoPath = Join-Path $repository '.tools/go/bin/go.exe' }
$environmentNames = @('GOOS','GOARCH','CGO_ENABLED','GOTOOLCHAIN','GOWORK','GOPROXY','GOSUMDB','GOFLAGS')
$savedEnvironment = @{}
foreach ($name in $environmentNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    $env:GOOS='windows'; $env:GOARCH='amd64'; $env:CGO_ENABLED='0'
    $env:GOTOOLCHAIN='local'; $env:GOWORK='off'; $env:GOPROXY='off'; $env:GOSUMDB='off'; $env:GOFLAGS=''
    if ((& $GoPath version) -cne 'go version go1.27.2 windows/amd64' -or $LASTEXITCODE -ne 0) { throw 'Windows updater requires the pinned Go 1.27.2 SDK.' }
    if ($ValidateOnly) {
        Write-Host "Windows updater pins validated for $($pins.appVersion)+$($pins.appBuild); no build performed."
        return
    }
    $output = Join-Path $repository 'artifacts/windows/exvpn-updater.exe'
    New-Item -ItemType Directory -Force -Path (Split-Path $output) | Out-Null
    $flags = @('-H=windowsgui')
    foreach ($property in $pins.PSObject.Properties) { $flags += '-X'; $flags += "main.$($property.Name)=$($property.Value)" }
    Push-Location (Join-Path $repository 'native/appupdater')
    try {
        & $GoPath build -mod=readonly -trimpath -buildvcs=false -ldflags ($flags -join ' ') -o $output .
        if ($LASTEXITCODE -ne 0) { throw 'Windows app updater build failed.' }
        $info = ((& $GoPath version -m -json $output) -join "`n") | ConvertFrom-Json -AsHashtable
        if ($LASTEXITCODE -ne 0 -or $info.GoVersion -cne 'go1.27.2' -or
            $info.Path -cne 'github.com/Extectick/ExVPN/native/appupdater' -or
            $info.Main.Path -cne 'github.com/Extectick/ExVPN/native/appupdater' -or
            ($info.ContainsKey('Deps') -and @($info.Deps).Count -ne 0)) { throw 'Windows updater embedded module identity differs from its pins.' }
    } finally { Pop-Location }
    Write-Host 'Built artifacts/windows/exvpn-updater.exe. Not installed, signed, or runtime-tested.'
} finally {
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
}
