# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fast-validation-plan.ps1')
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
# Exercise the real scripts/ci dispatch with only suite execution replaced.
# The union must contain each former suite/PowerShell host pair exactly once.
$dispatchAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'run-fast-validation-lane.ps1'), [ref]$null, [ref]$null)
$switches = @($dispatchAst.FindAll({ param($node) $node -is [Management.Automation.Language.SwitchStatementAst] }, $true))
if ($switches.Count -ne 1) { throw 'Lane dispatch switch is not unique.' }
$dispatchSuites = [Collections.Generic.List[object]]::new()
function Invoke-ScriptCheck([string]$RelativePath, [switch]$LegacyPowerShell) {
    $dispatchSuites.Add([pscustomobject]@{ lane=$Lane; suite=$RelativePath; hostVersion=$(if ($LegacyPowerShell) { '5.1' } else { '7' }) })
}
foreach ($Lane in @('scripts', 'ci')) { & ([ScriptBlock]::Create($switches[0].Extent.Text)) }
$expectedSuites = @(
    'scripts/qa/test-fast-validation-plan.ps1|7',
    'scripts/qa/test-fast-validation-runner.ps1|7',
    'scripts/qa/android-https-probe/test.ps1|7',
    'scripts/qa/test-android-lifecycle-tools.ps1|7',
    'scripts/qa/test-shorebird-android-tools.ps1|7',
    'scripts/qa/test-android-exclusions-selectors.ps1|7',
    'scripts/qa/android-dns-capture/test.ps1|7',
    'scripts/qa/test-windows-transport-lifecycle.ps1|7',
    'scripts/qa/test-windows-subscriptions.ps1|7',
    'scripts/qa/test-windows-subscriptions.ps1|5.1',
    'scripts/qa/test-routing-modes-evidence.ps1|7',
    'scripts/qa/test-routing-modes-evidence.ps1|5.1',
    'scripts/qa/test-teardown-qa.ps1|7',
    'scripts/qa/test-teardown-qa.ps1|5.1',
    'scripts/ci/test-build-impact.ps1|7',
    'scripts/release/test-notice-inputs.ps1|7',
    'scripts/release/test-artifact-audit.ps1|7',
    'scripts/release/test-android-notices.ps1|7',
    'scripts/release/android-runtime-inventory-test.ps1|7',
    'scripts/release/test-android-aab-dependencies.ps1|7',
    'scripts/core/test-xray-patch.ps1|7',
    'scripts/release/test-demo-release.ps1|7',
    'scripts/release/test-demo-maven-notices.ps1|7',
    'scripts/release/test-shorebird-pipeline.ps1|7',
    'scripts/release/test-shorebird-publication.ps1|7',
    'scripts/release/test-shorebird-runtime-notices.ps1|7',
    'scripts/release/test-build-demo-android.ps1|7',
    'scripts/windows/test-ci-msvc-runtime.ps1|7',
    'scripts/windows/test-prepare-nsis.ps1|7',
    'scripts/build/test-native-cache.ps1|7',
    'scripts/ota/test-ui-patch.ps1|7',
    'scripts/ota/test-independent-publication.ps1|7',
    'scripts/qa/android-protocol-matrix-tools-test.ps1|7'
)
$actualSuites = @($dispatchSuites | ForEach-Object { $_.suite + '|' + $_.hostVersion })
$ciSuites = @($dispatchSuites | Where-Object lane -CEQ 'ci')
if ((($actualSuites | Sort-Object) -join ',') -cne (($expectedSuites | Sort-Object) -join ',') -or
    $actualSuites.Count -ne 33 -or $ciSuites.Count -ne 1 -or $ciSuites[0].suite -cne 'scripts/ci/test-build-impact.ps1') {
    throw 'Scripts/CI partition lost, duplicated or substituted a required suite or PowerShell host.'
}
$fixture = Join-Path $repository ('artifacts/qa/runner-fixture-' + [Guid]::NewGuid().ToString('N'))
foreach ($directory in @('scripts/qa', 'scripts/bootstrap', 'scripts/ci', 'apps/exvpn/lib', 'native/core', 'native/android', 'native/windows')) {
    New-Item -ItemType Directory -Path (Join-Path $fixture $directory) -Force | Out-Null
}
# Run the real coordinator in an isolated fixture. Replace ONLY its worker with
# a synthetic child; no actual lane, native build, service or network runs here.
foreach ($relative in @(
    'scripts/qa/run-fast-validation.ps1', 'scripts/qa/fast-validation-plan.ps1',
    'scripts/bootstrap/enter-environment.ps1', 'scripts/bootstrap/toolchain.lock.json',
    'scripts/ci/flutter-version.ps1'
)) {
    Copy-Item -LiteralPath (Join-Path $repository $relative) -Destination (Join-Path $fixture $relative)
}
# Read existing pinned SDKs. The junction is ignored and never recursively
# deleted; no SDK contents or installed programs are replaced by this test.
New-Item -ItemType Junction -Path (Join-Path $fixture '.tools') -Target (Join-Path $repository '.tools') | Out-Null
Set-Content -LiteralPath (Join-Path $fixture '.gitignore') -Value ".tools/`nartifacts/`n*.log"
Set-Content -LiteralPath (Join-Path $fixture 'apps/exvpn/pubspec.yaml') -Value 'version: 0.1.0+1'
Set-Content -LiteralPath (Join-Path $fixture 'apps/exvpn/lib/build_identity.dart') -Value "const appVersion = '0.1.0';`nconst appBuild = 1;"
# The real environment reads every native manifest before choosing a pinned
# module proxy. Synthetic workers need no Xray or module download; keep these
# fixture-only manifests explicit instead of modifying the environment helper.
foreach ($module in @('core', 'android', 'windows')) {
    Set-Content -LiteralPath (Join-Path $fixture "native/$module/go.mod") -Value "module example.invalid/coordinator-fixture/$module"
}
$expectedLanes = @(Get-FastValidationLaneNames)
function Assert-CompleteLaneResults($Report) {
    $expected = ($expectedLanes | Sort-Object) -join ','
    $selected = (@($Report.selectedLanes | Sort-Object) -join ',')
    $actual = (@($Report.lanes.lane | Sort-Object) -join ',')
    if ($Report.lanes.Count -ne $expectedLanes.Count -or $selected -cne $expected -or $actual -cne $expected) {
        throw 'Coordinator lost, duplicated or substituted a selected child result.'
    }
}
$null = Invoke-FastValidationGit $fixture @('init', '--quiet')
$worker = Join-Path $fixture 'scripts/qa/run-fast-validation-lane.ps1'
Set-Content -LiteralPath $worker -Value @'
param([string]$Lane, [switch]$FreshGoTests, [int]$TestConcurrency, [switch]$OnlineDependencies)
if ($Lane -eq 'android') { Write-Host 'Intentional child failure fixture.'; exit 7 }
if ($Lane -eq 'ci') { Write-Host 'Intentional CI selector child failure fixture.'; exit 9 }
exit 0
'@
$shell = Join-Path $PSHOME 'pwsh.exe'
$runner = Join-Path $fixture 'scripts/qa/run-fast-validation.ps1'
& $shell -NoProfile -NonInteractive -File $runner -Full *> (Join-Path $fixture 'failure-run.log')
if ($LASTEXITCODE -eq 0) { throw 'Coordinator returned success despite a failed child.' }
$reportPath = Get-ChildItem -LiteralPath (Join-Path $fixture 'artifacts/qa') -Directory -Filter 'fast-*' |
    Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
$report = Get-Content -LiteralPath (Join-Path $reportPath 'summary.json') -Raw | ConvertFrom-Json
Assert-CompleteLaneResults $report
$dispatch = @([regex]::Matches((Get-Content -LiteralPath (Join-Path $fixture 'failure-run.log') -Raw), '(?m)^\[([a-z]+)\] started\s*$') | ForEach-Object { $_.Groups[1].Value })
if (($dispatch -join ',') -cne ($report.executionOrder -join ',') -or ($dispatch[0..3] -join ',') -cne 'scripts,ci,app,core') {
    throw 'Real coordinator did not dispatch the complete planned order.'
}
$failed = @($report.lanes | Where-Object status -eq 'failed')
if ($report.status -ne 'failed' -or $failed.Count -ne 2 -or
    @($failed | Where-Object { $_.lane -ceq 'android' -and $_.exitCode -eq 7 }).Count -ne 1 -or
    @($failed | Where-Object { $_.lane -ceq 'ci' -and $_.exitCode -eq 9 }).Count -ne 1 -or !$report.sourceUnchanged) {
    throw 'Coordinator lost a child result or failed for an unrelated reason.'
}

Set-Content -LiteralPath $worker -Value @'
param([string]$Lane, [switch]$FreshGoTests, [int]$TestConcurrency, [switch]$OnlineDependencies)
if ($Lane -eq 'core') {
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    Set-Content -LiteralPath (Join-Path $root 'changed-during-run.dart') -Value 'synthetic edit'
}
exit 0
'@
& $shell -NoProfile -NonInteractive -File $runner -Full *> (Join-Path $fixture 'drift-run.log')
if ($LASTEXITCODE -eq 0) { throw 'Coordinator accepted a source edit during the run.' }
$reportPath = Get-ChildItem -LiteralPath (Join-Path $fixture 'artifacts/qa') -Directory -Filter 'fast-*' |
    Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
$report = Get-Content -LiteralPath (Join-Path $reportPath 'summary.json') -Raw | ConvertFrom-Json
Assert-CompleteLaneResults $report
if ($report.status -ne 'source-changed-during-run' -or $report.sourceUnchanged -or
    @($report.lanes | Where-Object status -ne 'passed').Count) {
    throw 'Coordinator did not distinguish source drift from child failure.'
}
Write-Host "Fast-validation runner: all $($expectedSuites.Count) scripts/CI suites retained; Android/CI child exits 7/9 and concurrent source edit rejected; all $($expectedLanes.Count) selected child results preserved exactly once."
