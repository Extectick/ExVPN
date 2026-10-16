# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Installer,[switch]$IncludeFaults,[switch]$PolicyRecovery,[switch]$Unelevated)
$ErrorActionPreference = 'Stop'
if ($IncludeFaults -and $PolicyRecovery) { throw 'Choose either network faults or policy recovery for this QA bundle.' }
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repository 'scripts/bootstrap/enter-environment.ps1')
. (Join-Path $PSScriptRoot 'installer/package-common.ps1')
$installerPath = [IO.Path]::GetFullPath($Installer)
if (!(Test-Path -LiteralPath $installerPath -PathType Leaf) -or !$installerPath.StartsWith((Join-Path $repository 'artifacts/windows/'), [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($installerPath) -ne '.exe') { throw 'An existing local development installer is required.' }
$artifact = Get-Content -LiteralPath (Join-Path (Split-Path $installerPath) 'artifact.json') -Raw | ConvertFrom-Json
if ($artifact.sha256 -cne (Get-FileHash -LiteralPath $installerPath).Hash.ToLowerInvariant()) { throw 'Installer build has not finished or its hash differs.' }
$version = Get-Content -LiteralPath (Join-Path $repository 'apps/exvpn/pubspec.yaml') -Raw
if ($version -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') { throw 'Version missing.' }
$build = [int]$Matches[2]
if ($artifact.build -ne $build -or $artifact.version -cne $Matches[1]) { throw 'QA source and installer versions differ.' }
$testTarget = if ($PolicyRecovery) { 'integration_test/windows_policy_test.dart' } else { 'integration_test/windows_sandbox_test.dart' }
$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
$output = Join-Path $repository ('artifacts/windows/app-qa-' + $stamp)
$inputRoot = Join-Path $output 'input'
$resultRoot = Join-Path $output 'output'
$sourceRoot = Join-Path $output 'source'
New-Item -ItemType Directory -Path $inputRoot,$resultRoot,$sourceRoot | Out-Null
# Isolate the test target from the ordinary release build directory. Only Git
# source files are copied, never caches, SDKs, credentials or private fixtures.
$files = @(& git -C $repository ls-files --cached --others --exclude-standard -- apps/exvpn packages | Sort-Object -Unique)
if ($LASTEXITCODE -ne 0 -or !$files.Count) { throw 'Source inventory failed.' }
foreach ($relative in $files) {
    $target = Get-OwnedPath $sourceRoot $relative
    $source = Get-OwnedPath $repository $relative
    if (!(Test-Path -LiteralPath $source -PathType Leaf)) { continue }
    if ((Get-Item -LiteralPath $source).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Source links are forbidden.' }
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    Copy-Item -LiteralPath $source -Destination $target
}
$flutter = Join-Path $repository '.tools/flutter/bin/flutter.bat'
Push-Location (Join-Path $sourceRoot 'apps/exvpn')
try {
    & $flutter pub get --offline --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'QA dependencies failed.' }
    & $flutter build windows --release --target $testTarget --dart-define=INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false
    if ($LASTEXITCODE -ne 0) { throw 'QA app compilation failed.' }
} finally { Pop-Location }
$release = Join-Path $sourceRoot 'apps/exvpn/build/windows/x64/runner/Release'
$uiRoot = Join-Path $inputRoot 'ui'
New-Item -ItemType Directory -Path $uiRoot | Out-Null
foreach ($file in Get-PackageTree $release | Where-Object { !$_.PSIsContainer }) {
    $relative = $file.FullName.Substring($release.Length + 1)
    $target = Get-OwnedPath $uiRoot $relative
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $target
}
& (Join-Path $PSScriptRoot 'prepare-msvc-runtime.ps1') -UiDirectory $uiRoot
# The probe is spawned by a GUI and communicates through redirected stdio; it
# needs no console host. Keep its subsystem independent of the desktop token.
& (Join-Path $repository '.tools/go/bin/go.exe') -C (Join-Path $repository 'native/windows') build -trimpath -ldflags=-H=windowsgui -o (Join-Path $uiRoot 'protected-probe.exe') ./cmd/qa-https
if ($LASTEXITCODE -ne 0) { throw 'Probe compilation failed.' }
Copy-Item -LiteralPath (Join-Path $uiRoot 'protected-probe.exe') -Destination (Join-Path $uiRoot 'excluded-probe.exe')
& (Join-Path $repository '.tools/go/bin/go.exe') -C (Join-Path $repository 'native/windows') build -trimpath -o (Join-Path $uiRoot 'qa-guard.exe') ./cmd/qa-guard
if ($LASTEXITCODE -ne 0) { throw 'Read-only guard observer compilation failed.' }
if ($Unelevated) {
    & (Join-Path $repository '.tools/go/bin/go.exe') -C (Join-Path $repository 'native/windows') build -trimpath -o (Join-Path $inputRoot 'qa-desktop.exe') ./cmd/qa-desktop
    if ($LASTEXITCODE -ne 0) { throw 'Limited desktop launcher compilation failed.' }
}
Copy-Item -LiteralPath $installerPath -Destination (Join-Path $inputRoot 'installer.exe')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'installer/package-common.ps1'),(Join-Path $PSScriptRoot 'sandbox/guest-app-qa.ps1'),(Join-Path $PSScriptRoot 'sandbox/guest-app-launch.ps1'),(Join-Path $PSScriptRoot 'sandbox/guest-app-upgrade.ps1') -Destination $inputRoot
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'sandbox/guest-app-faults.ps1') -Destination $inputRoot
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'sandbox/guest-app-policy.ps1') -Destination $inputRoot
$manifest = @(Get-TreeManifest $inputRoot)
[ordered]@{format=1;forbiddenHost=$env:COMPUTERNAME;build=$build;runId=[Guid]::NewGuid().ToString();faults=[bool]($IncludeFaults -or $PolicyRecovery);policyRecovery=$(if ($PolicyRecovery) { 'reset' } else { $null });unelevated=[bool]$Unelevated;files=$manifest} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Encoding utf8NoBOM
[ordered]@{directory=$output;input=$inputRoot;output=$resultRoot} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repository 'artifacts/windows/app-qa-latest.json') -Encoding utf8
Write-Host "Prepared only, not executed: $output"
