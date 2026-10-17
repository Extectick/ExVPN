#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Checks', 'Android', 'Windows')][string]$Target = 'Checks',
    [switch]$SkipNativeBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
# Revalidate before any tools modify the working tree. A flag by itself is
# insufficient: missing/dirty/unknown event data retains the full build.
if ($SkipNativeBuild) {
    . (Join-Path $PSScriptRoot 'build-impact-lib.ps1')
    $impact = Get-BuildImpactEventDecision -Repository $repository
    $SkipNativeBuild = [bool]$impact.skipNativeBuild
    Write-Host "Native build selection rechecked: $($impact.reason); skip=$SkipNativeBuild."
}
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
$flutterVersion = & (Join-Path $PSScriptRoot 'flutter-version.ps1') -Flutter $flutter
if ($flutterVersion.frameworkRevision -ne $pin.flutter.revision) { throw 'Flutter SDK pin mismatch.' }
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
foreach ($module in @('native/core', 'native/android', 'native/windows', 'native/appupdater')) {
    Push-Location (Join-Path $repository $module)
    try {
        Invoke-Checked $go @('mod', 'verify')
        Invoke-Checked $go @('test', '-mod=readonly', '-count=1', './...')
        Invoke-Checked $go @('vet', '-mod=readonly', './...')
    } finally { Pop-Location }
}

# The pinned upstream modifications have their own loopback lifetime suite.
# Race checks run once in the Windows job; Android still runs the ordinary
# suite before both JNI ABIs are compiled. The compiler is a local test SDK.
& (Join-Path $repository 'scripts/qa/test-xray-lifecycle.ps1') -Race:($Target -eq 'Windows')
if (!$?) { throw 'Pinned Xray lifecycle checks failed.' }
Invoke-Checked (Join-Path $PSHOME 'pwsh.exe') @(
    '-NoProfile', '-NonInteractive', '-File',
    (Join-Path $repository 'scripts/core/test-xray-patch.ps1')
)
Invoke-Checked (Join-Path $PSHOME 'pwsh.exe') @(
    '-NoProfile', '-NonInteractive', '-File',
    (Join-Path $repository 'scripts/qa/test-android-lifecycle-tools.ps1')
)
Invoke-Checked (Join-Path $PSHOME 'pwsh.exe') @(
    '-NoProfile', '-NonInteractive', '-File',
    (Join-Path $repository 'scripts/qa/test-android-exclusions-selectors.ps1')
)
Invoke-Checked (Join-Path $PSHOME 'pwsh.exe') @(
    '-NoProfile', '-NonInteractive', '-File',
    (Join-Path $repository 'scripts/qa/android-dns-capture/test.ps1')
)
Invoke-Checked (Join-Path $PSHOME 'pwsh.exe') @(
    '-NoProfile', '-NonInteractive', '-File',
    (Join-Path $repository 'scripts/qa/test-windows-transport-lifecycle.ps1')
)
foreach ($powershell in @(
    (Join-Path $PSHOME 'pwsh.exe'),
    (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe')
)) {
    Invoke-Checked $powershell @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $repository 'scripts/qa/test-windows-subscriptions.ps1')
    )
    Invoke-Checked $powershell @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $repository 'scripts/qa/test-teardown-qa.ps1')
    )
}
Invoke-Checked (Join-Path $PSHOME 'pwsh.exe') @(
    '-NoProfile', '-NonInteractive', '-File',
    (Join-Path $repository 'scripts/ci/test-build-impact.ps1')
)

# Read-only release tooling fixtures: stale notice versions/locks/payloads must
# fail before any installer is published. No actual package is installed here.
Invoke-Checked (Join-Path $PSHOME 'pwsh.exe') @(
    '-NoProfile', '-NonInteractive', '-File',
    (Join-Path $repository 'scripts/release/test-notice-inputs.ps1')
)
Invoke-Checked (Join-Path $PSHOME 'pwsh.exe') @(
    '-NoProfile', '-NonInteractive', '-File',
    (Join-Path $repository 'scripts/release/test-artifact-audit.ps1')
)
Invoke-Checked (Join-Path $PSHOME 'pwsh.exe') @(
    '-NoProfile', '-NonInteractive', '-File',
    (Join-Path $repository 'scripts/release/test-android-notices.ps1')
)
Invoke-Checked (Join-Path $PSHOME 'pwsh.exe') @(
    '-NoProfile', '-NonInteractive', '-File',
    (Join-Path $repository 'scripts/release/android-runtime-inventory-test.ps1')
)

if ($Target -eq 'Android') {
    # Compile the independent probe's pure parsers against the prepared SDK.
    # These fixtures do not install the probe or contact a device/server.
    Invoke-Checked (Join-Path $PSHOME 'pwsh.exe') @(
        '-NoProfile', '-NonInteractive', '-File',
        (Join-Path $repository 'scripts/qa/android-https-probe/test.ps1'),
        '-AndroidSdkPath', $env:ANDROID_HOME
    )
    if ($SkipNativeBuild) {
        & (Join-Path $PSScriptRoot 'build-impact-android-tests.ps1')
        if (!$?) { throw 'Standalone Android JVM tests failed.' }
    } else {
        & (Join-Path $repository 'native/android/build.ps1')
        # Keep Gradle's mandatory native/notices input snapshot alive for both
        # the APK and JVM tests; the wrapper restores the environment afterward.
        & (Join-Path $repository 'scripts/bootstrap/build-android-debug.ps1') -RunUnitTests
    }
}
if ($Target -in @('Checks', 'Windows')) {
    # Exercise the actual installer PowerShell runtime, not pwsh-only semantics.
    # Filesystem/file-sharing tests use isolated fixtures; SCM/ACL are mocked.
    Invoke-Checked (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $repository 'scripts/windows/test-installer.ps1')
    )
}
if ($Target -eq 'Windows' -and !$SkipNativeBuild) {
    & (Join-Path $repository 'scripts/windows/build.ps1')
    & (Join-Path $repository 'scripts/windows/prepare-wintun.ps1')
    Push-Location (Join-Path $repository 'apps/exvpn')
    try { Invoke-Checked $flutter @('build', 'windows', '--debug', '--no-pub') }
    finally { Pop-Location }
}

if ($SkipNativeBuild) {
    Write-Host "ExVPN $Target checks completed for a verified QA-only push. Native APK/EXE packaging was skipped: no new native build proof or build artifacts are supplied."
} else {
    Write-Host "ExVPN $Target checks completed. Build artifacts are development packages, not accepted releases."
}
