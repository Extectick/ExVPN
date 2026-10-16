#requires -Version 7.0
[CmdletBinding()]
param([ValidateSet('Checks', 'Android', 'Windows')][string]$Target = 'Checks')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repository 'scripts/bootstrap/enter-environment.ps1')

function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE." }
}

$go = Join-Path $repository '.tools/go/bin/go.exe'
$dart = Join-Path $repository '.tools/flutter/bin/dart.bat'
$flutter = Join-Path $repository '.tools/flutter/bin/flutter.bat'
$pin = Get-Content -LiteralPath (Join-Path $repository 'scripts/bootstrap/toolchain.lock.json') -Raw | ConvertFrom-Json
if ((& $go version) -ne "go version go$($pin.go.version) windows/amd64") { throw 'Go SDK pin mismatch.' }
$flutterVersion = (& $flutter --version --machine) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $flutterVersion.frameworkRevision -ne $pin.flutter.revision) { throw 'Flutter SDK pin mismatch.' }
$pubspec = Get-Content -LiteralPath (Join-Path $repository 'apps/exvpn/pubspec.yaml') -Raw
$identity = Get-Content -LiteralPath (Join-Path $repository 'apps/exvpn/lib/build_identity.dart') -Raw
$version = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (!$version.Success -or
    !$identity.Contains("const appVersion = '$($version.Groups[1].Value)';") -or
    !$identity.Contains("const appBuild = $($version.Groups[2].Value);")) {
    throw 'Displayed app identity must match pubspec.yaml version/build.'
}

foreach ($package in @('packages/exvpn_domain', 'packages/exvpn_client_state', 'packages/exvpn_updates')) {
    Push-Location (Join-Path $repository $package)
    try {
        Invoke-Checked $dart @('pub', 'get', '--enforce-lockfile')
        Invoke-Checked $dart @('analyze', '--fatal-infos')
        Invoke-Checked $dart @('test')
    } finally { Pop-Location }
}

Push-Location (Join-Path $repository 'apps/exvpn')
try {
    Invoke-Checked $flutter @('pub', 'get', '--enforce-lockfile')
    Invoke-Checked $flutter @('analyze', '--fatal-infos')
    Invoke-Checked $flutter @('test')
} finally { Pop-Location }

# These tests use loopback sockets and temporary named pipes only. They never
# install services/drivers, mutate WFP, or change routes/DNS on the runner.
foreach ($module in @('native/core', 'native/android', 'native/windows')) {
    Push-Location (Join-Path $repository $module)
    try {
        Invoke-Checked $go @('mod', 'verify')
        Invoke-Checked $go @('test', '-mod=readonly', '-count=1', './...')
        Invoke-Checked $go @('vet', '-mod=readonly', './...')
    } finally { Pop-Location }
}

if ($Target -eq 'Android') {
    & (Join-Path $repository 'native/android/build.ps1')
    & (Join-Path $repository 'scripts/bootstrap/build-android-debug.ps1')
}
if ($Target -eq 'Windows') {
    & (Join-Path $repository 'scripts/windows/build.ps1')
    & (Join-Path $repository 'scripts/windows/prepare-wintun.ps1')
    Push-Location (Join-Path $repository 'apps/exvpn')
    try { Invoke-Checked $flutter @('build', 'windows', '--debug', '--no-pub') }
    finally { Pop-Location }
}

Write-Host "ExVPN $Target checks completed. Build artifacts are development packages, not accepted releases."
