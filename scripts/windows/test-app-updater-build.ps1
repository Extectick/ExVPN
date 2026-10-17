# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$checks = 0
function Assert-UpdaterRefused([scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw 'Invalid app updater build input was accepted.' }
    $script:checks++
}
function Import-UpdaterFunction([string]$Script, [string]$Name) {
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw 'Updater source failed syntax validation.' }
    $definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name }, $false))
    if ($definitions.Count -ne 1) { throw 'Expected exactly one updater input function.' }
    return [scriptblock]::Create($definitions[0].Extent.Text)
}
# Load pure input functions, never the build or elevated installer entry point.
. (Import-UpdaterFunction (Join-Path $PSScriptRoot 'build-app-updater.ps1') 'Get-AppUpdaterBuildPins')
. (Import-UpdaterFunction (Join-Path $PSScriptRoot 'installer/package.ps1') 'Resolve-PackageNetworkTesting')
. (Import-UpdaterFunction (Join-Path $PSScriptRoot 'installer/package.ps1') 'Get-PackageMaintenanceControl')
$module = "module github.com/Extectick/ExVPN/native/appupdater`n`ngo 1.27.2`n"
$config = [ordered]@{
    schema=1; channel='beta'; keyId='synthetic-beta-1'
    publicKey=[Convert]::ToBase64String([byte[]](0..31))
    feedUrl='https://github.com/Extectick/ExVPN/releases/download/windows-beta/windows-x64.json'
}
function Read-FixturePins { Get-AppUpdaterBuildPins 'version: 0.1.0+21' ($config | ConvertTo-Json -Compress) $module }
$pins = Read-FixturePins
if ($pins.appVersion -cne '0.1.0' -or $pins.appBuild -cne '21' -or $pins.manifestKeyID -cne 'synthetic-beta-1') { throw 'Updater pins lost the application identity.' }; $checks++
Assert-UpdaterRefused { Get-AppUpdaterBuildPins "version: 0.1.0+21`nversion: 0.1.0+22" ($config | ConvertTo-Json) $module }
Assert-UpdaterRefused { Get-AppUpdaterBuildPins 'version: 0.1.0+2147483648' ($config | ConvertTo-Json) $module }
Assert-UpdaterRefused { Get-AppUpdaterBuildPins 'version: 0.1.0+0' ($config | ConvertTo-Json) $module }
foreach ($field in @('schema','channel','keyId','publicKey','feedUrl')) {
    $original = $config[$field]
    try {
        $config[$field] = switch ($field) { 'schema' { '1' }; 'channel' { 'stable' }; 'keyId' { 'unsafe key' }; 'publicKey' { [Convert]::ToBase64String([byte[]](0..30)) }; 'feedUrl' { 'https://untrusted.invalid/windows-x64.json' } }
        Assert-UpdaterRefused { Read-FixturePins }
    } finally { $config[$field] = $original }
}
foreach ($badFeed in @(
    'http://github.com/Extectick/ExVPN/releases/download/windows-beta/windows-x64.json',
    'https://github.com/Extectick/ExVPN/releases/download/windows-beta/windows-x64.json?token=synthetic',
    'https://github.com/Extectick/other/releases/download/windows-beta/windows-x64.json'
)) {
    $original = $config.feedUrl
    try { $config.feedUrl=$badFeed; Assert-UpdaterRefused { Read-FixturePins } }
    finally { $config.feedUrl=$original }
}
$config.extra='unsupported'; Assert-UpdaterRefused { Read-FixturePins }; $config.Remove('extra')
$original=$config.keyId
try { $config.keyId=123; Assert-UpdaterRefused { Read-FixturePins } } finally { $config.keyId=$original }
$original=$config.publicKey
try { $config.publicKey=" $original"; Assert-UpdaterRefused { Read-FixturePins } } finally { $config.publicKey=$original }
foreach ($badModule in @($module.Replace('1.27.2','1.27.1'), $module.Replace('native/appupdater','native/other'), ($module + "`nrequire example.invalid/extra v1.0.0`n"))) {
    Assert-UpdaterRefused { Get-AppUpdaterBuildPins 'version: 0.1.0+21' ($config | ConvertTo-Json) $badModule }
}
if ((Resolve-PackageNetworkTesting $null $false $false) -cne $false) { throw 'Fresh install enabled network testing.' }; $checks++
foreach ($current in @($false,$true)) {
    $state=[pscustomobject]@{networkTesting=$current}
    if ((Resolve-PackageNetworkTesting $state $false $false) -cne $current) { throw 'Upgrade changed an existing network-testing gate without an explicit switch.' }; $checks++
    foreach ($requested in @($false,$true)) {
        if ((Resolve-PackageNetworkTesting $state $true $requested) -cne $requested) { throw 'Explicit network-testing switch was not respected.' }; $checks++
    }
}
foreach ($badValue in @('true','false',0,1,$null)) {
    Assert-UpdaterRefused { Resolve-PackageNetworkTesting ([pscustomobject]@{networkTesting=$badValue}) $false $false }
}
if ((Get-PackageMaintenanceControl $true) -ne 129 -or (Get-PackageMaintenanceControl $false) -ne 128) { throw 'Automatic update selected the manual disconnect control.' }; $checks++
Write-Host "$checks updater build-pin and installer network-testing fixture checks passed. No builds, downloads, native execution, or installation performed."
