# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fast-validation-plan.ps1')
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$checks = 0

function Assert-Lanes([string[]]$Paths, [string[]]$Expected) {
    $actual = @((Get-FastValidationPlan -ChangedPaths $Paths).lanes)
    if (($actual -join ',') -cne ($Expected -join ',')) {
        throw "Unexpected selected lanes: $($actual -join ','); expected $($Expected -join ',')."
    }
    $script:checks++
}

$all = @(Get-FastValidationLaneNames)
Assert-Lanes @() @()
Assert-Lanes @('docs/PLAN.md', 'design/concepts/approved.png', 'README.md') @()
Assert-Lanes @('docs/evidence/synthetic-report.json', 'docs/evidence/nested/another-report.json') @()
Assert-Lanes @('docs/evidence/synthetic-report.json', 'packages/exvpn_updates/lib/updater.dart') @('updates', 'app')
Assert-Lanes @('docs/configuration.json') $all
Assert-Lanes @('docs/evidence/runner.json.ps1') $all
Assert-Lanes @('apps/exvpn/lib/ui/home_screen.dart') @('app')
Assert-Lanes @('apps/exvpn/test/new regression_test.dart') @('app')
Assert-Lanes @('apps/exvpn/assets/images/new.png') @('app')
Assert-Lanes @('packages/exvpn_client_state/lib/src/snapshot_codec.dart') @('state', 'app')
Assert-Lanes @('packages/exvpn_updates/pubspec.lock') @('updates', 'app')
Assert-Lanes @('packages/exvpn_domain/lib/src/profile.dart') @('domain', 'state', 'app', 'core', 'android', 'windows', 'installer')
Assert-Lanes @('native/core/new.go') @('domain', 'state', 'app', 'core', 'android', 'windows', 'installer')
Assert-Lanes @('native/patches/xray-lifecycle.patch') @('domain', 'state', 'app', 'core', 'android', 'windows', 'xray', 'installer')
Assert-Lanes @('native\core\go.sum') @('domain', 'state', 'app', 'core', 'android', 'windows', 'installer')
Assert-Lanes @('native/android/bridge/jni.go') @('app', 'android')
Assert-Lanes @('apps/exvpn/android/app/src/main/MainActivity.kt') @('app', 'android')
Assert-Lanes @('native/windows/policy.go') @('app', 'windows', 'installer')
Assert-Lanes @('apps/exvpn/windows/runner/main.cpp') @('app', 'windows', 'installer')
Assert-Lanes @('scripts/bootstrap/toolchain.lock.json') $all
Assert-Lanes @('.github/workflows/verify.yml') $all
Assert-Lanes @('scripts/qa/new-helper.ps1') $all
Assert-Lanes @('new-package/lib/new.dart') $all
Assert-Lanes @('docs/not-documentation.ps1') $all
Assert-Lanes @('AGENTS.md') $all
if (((Get-FastValidationPlan -Full).lanes -join ',') -cne ($all -join ',')) { throw 'Full did not select every lane.' }
$checks++

# Actual Git integration, in an owned ignored fixture; the project's index and
# commits are never changed. Covers staged, unstaged, added, deleted, renamed,
# Unicode/space names, ignored private files, and branch-base changes together.
$fixture = Join-Path $repository ('artifacts/qa/planner-fixture-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$null = Invoke-FastValidationGit $fixture @('init', '--quiet')
foreach ($name in @('staged.dart', 'unstaged.dart', 'deleted.go', 'old.go', 'branch.go')) {
    Set-Content -LiteralPath (Join-Path $fixture $name) -Value 'baseline'
}
Set-Content -LiteralPath (Join-Path $fixture '.gitignore') -Value '.private/'
$null = Invoke-FastValidationGit $fixture @('add', '--all')
$null = Invoke-FastValidationGit $fixture @('-c', 'user.name=ExVPN QA', '-c', 'user.email=qa@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'Planner fixture base')
$base = (Invoke-FastValidationGit $fixture @('rev-parse', 'HEAD')).Trim()
Set-Content -LiteralPath (Join-Path $fixture 'branch.go') -Value 'branch change'
$null = Invoke-FastValidationGit $fixture @('add', '--', 'branch.go')
$null = Invoke-FastValidationGit $fixture @('-c', 'user.name=ExVPN QA', '-c', 'user.email=qa@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'Planner fixture branch')
Set-Content -LiteralPath (Join-Path $fixture 'staged.dart') -Value 'staged change'
$null = Invoke-FastValidationGit $fixture @('add', '--', 'staged.dart')
# Revert its bytes without touching the index: both diffs must still count it.
Set-Content -LiteralPath (Join-Path $fixture 'staged.dart') -Value 'baseline'
Set-Content -LiteralPath (Join-Path $fixture 'unstaged.dart') -Value 'unstaged change'
Set-Content -LiteralPath (Join-Path $fixture 'новый файл.dart') -Value 'untracked source'
$null = Invoke-FastValidationGit $fixture @('mv', '--', 'old.go', 'renamed.go')
# Delete only this exact, just-created fixture file; never remove the workspace.
Remove-Item -LiteralPath (Join-Path $fixture 'deleted.go')
New-Item -ItemType Directory -Path (Join-Path $fixture '.private') | Out-Null
Set-Content -LiteralPath (Join-Path $fixture '.private/local-input.txt') -Value 'ignored fixture'
$actualPaths = @(Get-FastValidationChangedPaths $fixture)
$expectedPaths = @('deleted.go', 'old.go', 'renamed.go', 'staged.dart', 'unstaged.dart', 'новый файл.dart') | Sort-Object
if (($actualPaths -join '|') -cne ($expectedPaths -join '|')) { throw 'Staged/unstaged/untracked/deleted/renamed/Unicode collection failed.' }
$checks++
$withBase = @(Get-FastValidationChangedPaths $fixture -BaseRef $base)
if ($withBase.Count -ne 7 -or 'branch.go' -notin $withBase) { throw 'BaseRef omitted a committed branch change.' }
$checks++
$rejected = $false
try { Get-FastValidationChangedPaths $fixture -BaseRef '--invalid-option' | Out-Null } catch { $rejected = $true }
if (!$rejected) { throw 'Invalid base ref was accepted.' }
$checks++
$before = Get-FastValidationSourceFingerprint $fixture
Set-Content -LiteralPath (Join-Path $fixture '.private/local-input.txt') -Value 'still ignored'
if ((Get-FastValidationSourceFingerprint $fixture) -ne $before) { throw 'Ignored private input entered the source fingerprint.' }
$checks++
Set-Content -LiteralPath (Join-Path $fixture 'новый файл.dart') -Value 'changed new source'
if ((Get-FastValidationSourceFingerprint $fixture) -eq $before) { throw 'Untracked source change did not invalidate the fingerprint.' }
$checks++
Write-Host "Fast-validation planner: $checks checks passed. No project index or system networking changed."
