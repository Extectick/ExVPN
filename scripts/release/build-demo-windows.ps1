# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+\+[1-9][0-9]*$')][string]$ReleaseVersion = '0.1.0+18',
    [ValidateSet('demo','preview')][string]$Delivery = 'demo'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repository 'scripts/bootstrap/enter-environment.ps1')
. (Join-Path $PSScriptRoot 'demo-release-lib.ps1')
. (Join-Path $PSScriptRoot 'notice-inputs.ps1')
$app = Join-Path $repository 'apps/exvpn'
$version = Get-NoticeAppVersion ([IO.File]::ReadAllText((Join-Path $app 'pubspec.yaml'))) ([IO.File]::ReadAllText((Join-Path $app 'lib/build_identity.dart')))
if ($version -cne $ReleaseVersion -or ($Delivery -ceq 'demo' -and $ReleaseVersion -cne '0.1.0+18')) { throw 'demo_version_mismatch' }
$parts = $version.Split('+')
$output = Join-Path $repository "artifacts/$Delivery/windows"
if (Test-Path -LiteralPath $output) { throw 'demo_output_exists' }
New-Item -ItemType Directory -Path $output | Out-Null
$flutter = Join-Path $repository '.tools/flutter/bin/flutter.bat'
$lock = Get-DemoSha256 (Join-Path $app 'pubspec.lock')
Push-Location $app
try {
    & $flutter pub get --offline --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'demo_pub_failed' }
    & $flutter build windows --release --pub --dart-define=EXVPN_DEMO=false
    if ($LASTEXITCODE -ne 0) { throw 'demo_windows_build_failed' }
} finally { Pop-Location }
if ((Get-DemoSha256 (Join-Path $app 'pubspec.lock')) -cne $lock) { throw 'demo_lock_changed' }
$packageRoot = Join-Path $repository 'artifacts/windows'
$previous = @(Get-ChildItem -LiteralPath $packageRoot -Directory -Filter 'package-*' | ForEach-Object FullName)
$runtime = & (Join-Path $repository 'scripts/windows/prepare-ci-msvc-runtime.ps1')
if (!$runtime.RuntimeDirectory -or !$runtime.DumpbinPath) { throw 'demo_msvc_preparation_failed' }
& (Join-Path $repository 'scripts/windows/build-installer.ps1') -FlutterRuntime ordinary -RuntimeDirectory $runtime.RuntimeDirectory -DumpbinPath $runtime.DumpbinPath
if (!$?) { throw 'demo_installer_build_failed' }
$new = @(Get-ChildItem -LiteralPath $packageRoot -Directory -Filter 'package-*' | Where-Object FullName -CNotIn $previous)
if ($new.Count -ne 1) { throw 'demo_package_ambiguous' }
$package = $new[0].FullName
$artifact = Get-Content -LiteralPath (Join-Path $package 'artifact.json') -Raw | ConvertFrom-Json
if ($artifact.version -cne $parts[0] -or $artifact.build -ne [int]$parts[1] -or $artifact.signed) { throw 'demo_installer_metadata_invalid' }
$installer = Join-Path $package $artifact.file
if ((Get-DemoSha256 $installer) -cne $artifact.sha256) { throw 'demo_installer_hash_mismatch' }
Export-DemoAudit -Target Windows -ArtifactPath $package -OutputDirectory $output -ExpectedVersion $version
$destination = Join-Path $output $(if ($Delivery -ceq 'demo') { 'ExVPN-0.1.0-demo-windows-x64.exe' } else { $artifact.file })
Copy-Item -LiteralPath $installer -Destination $destination
[IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $package 'payload/control'), (Join-Path $output 'windows-notices.zip'))
$source = (& git -C $repository rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $source -cnotmatch '^[a-f0-9]{40}$') { throw 'demo_source_commit_missing' }
[ordered]@{
    schema=1;version=$version;sourceCommit=$source;runtime='ordinary';syntheticProfiles=$false
    artifact=(Get-DemoAssetRecord $destination);authenticodeSigned=$false;stableReady=$false
    notices=(Get-DemoAssetRecord (Join-Path $output 'windows-notices.zip'))
    networkTestingOptInRequired=$true;dartOtaAvailable=$false
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output 'windows-build.json') -Encoding utf8
Write-Host 'Windows demo installer, corresponding-source notices and incomplete SBOM staged.'
