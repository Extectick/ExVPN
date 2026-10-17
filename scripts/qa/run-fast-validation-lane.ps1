# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('domain', 'state', 'updates', 'app', 'core', 'android', 'windows', 'xray', 'installer', 'scripts', 'ci')][string]$Lane,
    [switch]$FreshGoTests,
    [ValidateRange(1, 16)][int]$TestConcurrency = 2,
    [switch]$OnlineDependencies
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repository 'scripts/bootstrap/enter-environment.ps1')
$go = Join-Path $repository '.tools/go/bin/go.exe'
# Direct Dart SDK avoids competing Flutter startup locks across pure Dart lanes.
$dart = Join-Path $repository '.tools/flutter/bin/cache/dart-sdk/bin/dart.exe'
$flutter = Join-Path $repository '.tools/flutter/bin/flutter.bat'

function Invoke-Check([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Lane $Lane command failed with exit code $LASTEXITCODE." }
}

function Invoke-ScriptCheck([string]$RelativePath, [switch]$LegacyPowerShell) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $passed = $false
    try {
        $script = Join-Path $repository $RelativePath
        if ($LegacyPowerShell) {
            Invoke-Check (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script
            )
        } else {
            & $script
            if (!$?) { throw "QA suite failed: $RelativePath" }
        }
        $passed = $true
    } finally {
        $timer.Stop()
        # No arguments, fixture contents or private paths enter this record.
        # The coordinator already retains this lane's log, including failures.
        $timing = [ordered]@{
            suite = $RelativePath
            powershell = $(if ($LegacyPowerShell) { '5.1' } else { '7' })
            passed = $passed
            elapsedMilliseconds = $timer.ElapsedMilliseconds
        }
        Write-Output ('EXVPN_SUITE_TIMING ' + ($timing | ConvertTo-Json -Compress))
    }
}

switch ($Lane) {
    { $_ -in @('domain', 'state', 'updates', 'app') } {
        $directories = @{ domain='packages/exvpn_domain'; state='packages/exvpn_client_state'; updates='packages/exvpn_updates'; app='apps/exvpn' }
        Set-Location -LiteralPath (Join-Path $repository $directories[$Lane])
        $pub = @('pub', 'get', '--enforce-lockfile')
        if (!$OnlineDependencies) { $pub += '--offline' }
        if ($Lane -eq 'app') {
            Invoke-Check $flutter $pub
            Invoke-Check $flutter @('analyze', '--no-pub', '--fatal-infos')
            Invoke-Check $flutter @('test', '--no-pub', '--concurrency', "$TestConcurrency", '--reporter', 'expanded')
        } else {
            Invoke-Check $dart $pub
            Invoke-Check $dart @('analyze', '--fatal-infos')
            Invoke-Check $dart @('test', '--concurrency', "$TestConcurrency", '--reporter', 'expanded')
        }
        break
    }
    { $_ -in @('core', 'android', 'windows') } {
        Set-Location -LiteralPath (Join-Path $repository "native/$Lane")
        Invoke-Check $go @('mod', 'verify')
        $arguments = @('test', '-mod=readonly', '-p', "$TestConcurrency", '-parallel', "$TestConcurrency", '-timeout', '5m')
        if ($FreshGoTests) { $arguments += '-count=1' }
        $arguments += './...'
        Invoke-Check $go $arguments
        Invoke-Check $go @('vet', '-mod=readonly', '-p', "$TestConcurrency", './...')
        break
    }
    'xray' {
        & (Join-Path $PSScriptRoot 'test-xray-lifecycle.ps1') -TestConcurrency $TestConcurrency
        if (!$?) { throw 'Pinned Xray transport lifecycle regression failed.' }
        break
    }
    'installer' {
        # This suite only mutates its own disposable file fixtures. SCM/ACL are
        # mocked; the actual installer is NOT run on the development host.
        Invoke-Check (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
            (Join-Path $repository 'scripts/windows/test-installer.ps1')
        )
        break
    }
    'ci' {
        # This suite owns a unique temporary Git fixture and process-local
        # GitHub environment. It shares no mutable fixture with scripts.
        Invoke-ScriptCheck 'scripts/ci/test-build-impact.ps1'
        break
    }
    'scripts' {
        foreach ($directory in @('scripts', 'native')) {
            foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repository $directory) -Recurse -File -Filter '*.ps1') {
                $errors = $null
                $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
                if ($errors.Count) { throw "PowerShell parse failure in $($file.Name)." }
            }
        }
        Invoke-ScriptCheck 'scripts/qa/test-fast-validation-plan.ps1'
        Invoke-ScriptCheck 'scripts/qa/test-fast-validation-runner.ps1'
        Invoke-ScriptCheck 'scripts/qa/android-https-probe/test.ps1'
        Invoke-ScriptCheck 'scripts/qa/test-android-lifecycle-tools.ps1'
        Invoke-ScriptCheck 'scripts/qa/android-dns-capture/test.ps1'
        Invoke-ScriptCheck 'scripts/qa/test-windows-transport-lifecycle.ps1'
        Invoke-ScriptCheck 'scripts/qa/test-windows-subscriptions.ps1'
        Invoke-ScriptCheck 'scripts/qa/test-windows-subscriptions.ps1' -LegacyPowerShell
        Invoke-ScriptCheck 'scripts/qa/test-teardown-qa.ps1'
        Invoke-ScriptCheck 'scripts/qa/test-teardown-qa.ps1' -LegacyPowerShell
        Invoke-ScriptCheck 'scripts/release/test-notice-inputs.ps1'
        Invoke-ScriptCheck 'scripts/release/test-artifact-audit.ps1'
        Invoke-ScriptCheck 'scripts/release/test-android-notices.ps1'
        Invoke-ScriptCheck 'scripts/release/android-runtime-inventory-test.ps1'
        Invoke-ScriptCheck 'scripts/release/test-android-aab-dependencies.ps1'
        Invoke-ScriptCheck 'scripts/core/test-xray-patch.ps1'
        break
    }
}
