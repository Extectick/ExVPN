# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'build-impact-lib.ps1')
. (Join-Path $PSScriptRoot 'build-impact-android-lib.ps1')
$checks=0
function Check([bool]$Condition,[string]$Label) {
    if (!$Condition) { throw "Build-impact regression failed: $Label" }
    $script:checks++
}
function Reject([scriptblock]$Operation,[string]$ErrorCode,[string]$Label) {
    $rejected=$false
    try { $null=& $Operation } catch { $rejected=$_.Exception.Message -like "$ErrorCode*" }
    Check $rejected $Label
}
$qa='apps/exvpn/integration_test/windows_sandbox_test.dart'
$qaOther='scripts/qa/guest-transport-observe.ps1'
$production='apps/exvpn/lib/main.dart'
$controller='native/windows/controller.go'
$expandedQaPaths=@(
    'native/windows/cmd/qa-teardown/main_windows.go',
    'native/windows/cmd/qa-teardown/observe_windows.go',
    'native/windows/cmd/qa-teardown/main_windows_test.go',
    'scripts/qa/android-dns-capture/main.go',
    'scripts/qa/android-dns-capture/main_test.go',
    'scripts/qa/android-dns-capture/test.ps1',
    'scripts/qa/guest-teardown-qa.ps1',
    'scripts/qa/run-windows-teardown.ps1',
    'scripts/qa/teardown-qa-lib.ps1',
    'scripts/qa/test-teardown-qa.ps1'
)
foreach ($path in $expandedQaPaths) {
    Check ((Get-BuildImpactPathKind $path) -ceq 'qa') "reviewed diagnostic path: $path"
}
foreach ($path in @(
    $controller,
    'native/windows/cmd/qa-teardown/new_windows.go',
    'native/windows/cmd/qa-teardown/nested/main_windows.go',
    'native/windows/cmd/qa-teardown/go.mod',
    'scripts/qa/android-dns-capture/new.go',
    'scripts/qa/android-dns-capture/nested/main.go',
    'scripts/qa/android-dns-capture/README.md',
    'scripts/qa/run-windows-teardown-extra.ps1',
    'Scripts/qa/android-dns-capture/main.go'
)) {
    Check ((Get-BuildImpactPathKind $path) -ceq 'unknown') "diagnostic allowlist does not widen to neighbors: $path"
}
foreach ($path in @($qa,$qaOther,'native/windows/cmd/qa-desktop/output_windows_test.go','native/android/cmd/qa-server/main.go','scripts/windows/sandbox/guest-app-upgrade.ps1','scripts/qa/test-android-lifecycle-tools.ps1')) {
    Check ((Get-BuildImpactPathKind $path) -ceq 'qa') "known standalone QA path: $path"
}
foreach ($path in @('docs/PLAN.md','docs/evidence/android-lifecycle-build11.json')) {
    Check ((Get-BuildImpactPathKind $path) -ceq 'documentation') 'documentation is supplementary only'
}
foreach ($path in @($production,'native/core/runtime.go','native/windows/cmd/exvpn-service/main_windows.go','native/windows/cmd/qa-new/main.go','native/windows/cmd/qa-desktop/child/new.go','apps/exvpn/integration_test/new_target.dart','scripts/qa/run-fast-validation-lane.ps1','scripts/qa/test-xray-lifecycle.ps1','scripts/qa/race-compiler.lock.json','scripts/qa/android-https-probe/HttpsProbe.java','scripts/bootstrap/toolchain.lock.json','scripts/ci/verify.ps1','.github/workflows/verify.yml','docs/anything.ps1','apps/exvpn/assets/SOURCES.md','Apps/exvpn/integration_test/windows_sandbox_test.dart','../docs/PLAN.md','docs/../PLAN.md','docs\PLAN.md',"docs/PLAN.md`n")) {
    Check ((Get-BuildImpactPathKind $path) -ceq 'unknown') "unknown or build input stays full: $path"
}

$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('ExVPN-BuildImpact-'+[guid]::NewGuid().ToString('N'))
$fixture=Join-Path $testRoot 'repository'
New-Item -ItemType Directory -Path $fixture | Out-Null
function Git([string[]]$Arguments) { Invoke-BuildImpactGit $fixture $Arguments }
function Write-Fixture([string]$Path,[string]$Value) {
    $file=Join-Path $fixture $Path
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file)) | Out-Null
    [IO.File]::WriteAllText($file,$Value,[Text.UTF8Encoding]::new($false))
}
function Commit-Fixture {
    [void](Git @('add','--all'))
    [void](Git @('commit','--quiet','-m','synthetic build-impact fixture'))
    (Git @('rev-parse','HEAD')).Trim()
}
function From-Base { [void](Git @('checkout','--quiet','--detach',$script:base)) }
function Decision([string]$Before=$script:base,[string]$Event='push',[string]$Expected='') {
    $head=(Git @('rev-parse','HEAD')).Trim()
    if (!$Expected) { $Expected=$head }
    Get-BuildImpactDecision -Repository $fixture -EventName $Event -Before $Before -After $head -ExpectedHead $Expected
}
function Must-Build($Decision,[string]$Label) { Check (!$Decision.skipNativeBuild) $Label }
$savedEnvironment=@{}
foreach ($name in @('GITHUB_EVENT_NAME','GITHUB_EVENT_PATH','GITHUB_SHA','GITHUB_OUTPUT')) { $savedEnvironment[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
try {
    $unitTask=":app:testDebugUnitTest SKIPPED`n"
    $graph=Get-AndroidJvmTaskGraph (":app:packageDebugResources SKIPPED`n:app:bundleDebugClassesToRuntimeJar SKIPPED`n:plugin:bundleLibCompileToJarDebug SKIPPED`n"+$unitTask)
    Check ($graph.taskCount -eq 4) 'JVM graph permits intermediate resource packages/class JARs'
    foreach ($task in @('assembleDebug','packageDebug','packageDebugBundle','bundleRelease','signDebugBundle','installDebug','publishRelease','packageUnexpected')) {
        Reject { Get-AndroidJvmTaskGraph ($unitTask+":app:$task SKIPPED`n") } 'android_jvm_packaging_task_present' "JVM graph forbids final/native packaging: $task"
    }
    Reject { Get-AndroidJvmTaskGraph ($unitTask+":plugin:assembleDebug SKIPPED`n") } 'android_jvm_packaging_task_present' 'dependency APK packaging is also forbidden'
    Reject { Get-AndroidJvmTaskGraph ($unitTask+":app:verifyExVpnPackageInputs SKIPPED`n") } 'android_jvm_package_snapshot_task_present' 'JVM graph cannot consume package snapshot'
    Reject { Get-AndroidJvmTaskGraph ($unitTask+":app:externalNativeBuildDebug SKIPPED`n") } 'android_jvm_native_build_task_present' 'JVM graph forbids native CMake packaging'
    Reject { Get-AndroidJvmTaskGraph ':app:compileDebugKotlin SKIPPED' } 'android_jvm_unit_task_missing_or_ambiguous' 'missing unit task cannot pass graph check'
    Reject { Get-AndroidJvmTaskGraph ($unitTask+$unitTask) } 'android_jvm_unit_task_missing_or_ambiguous' 'ambiguous repeated unit task cannot pass graph check'
    $junitDirectory=Join-Path $testRoot 'junit'
    [IO.Directory]::CreateDirectory($junitDirectory) | Out-Null
    $junitFile=Join-Path $junitDirectory 'TEST-synthetic.xml'
    [IO.File]::WriteAllText($junitFile,'<testsuite name="ru.exvpn.SyntheticTest" tests="1" failures="0" errors="0" skipped="0"><testcase name="synthetic" /></testsuite>')
    Check ((Get-AndroidJvmResult $junitDirectory).tests -eq 1) 'ordinary JUnit counters and testcase evidence pass'
    foreach ($invalid in @(
        '<testsuite tests="0" failures="0" errors="0" skipped="0"/>',
        '<testsuite tests="2" failures="0" errors="0" skipped="0"><testcase name="synthetic" /></testsuite>',
        '<testsuite tests="1" failures="0" errors="0" skipped="1"><testcase name="synthetic" /></testsuite>',
        '<testsuite tests="1" failures="0" errors="0" skipped="0"><testcase name="synthetic"><failure/></testcase></testsuite>',
        '<testsuite tests="invalid" failures="0" errors="0" skipped="0"/>',
        '<unexpected />'
    )) {
        [IO.File]::WriteAllText($junitFile,$invalid)
        Reject { Get-AndroidJvmResult $junitDirectory } 'android_jvm_' 'empty, skipped, invalid or inconsistent JUnit evidence fails'
    }

    [void](Git @('init','--quiet','--initial-branch=main','--object-format=sha1'))
    foreach ($setting in @(@('user.name','ExVPN synthetic QA'),@('user.email','qa@example.invalid'),@('commit.gpgsign','false'),@('core.autocrlf','false'),@('core.hooksPath',(Join-Path $testRoot 'no-hooks')))) {
        [void](Git (@('config','--local')+$setting))
    }
    Write-Fixture $qa 'qa baseline'
    Write-Fixture $qaOther 'second qa baseline'
    Write-Fixture $production 'production baseline'
    Write-Fixture $controller 'controller baseline'
    Write-Fixture 'docs/PLAN.md' 'documentation baseline'
    $script:base=Commit-Fixture

    Write-Fixture $qa 'qa changed'
    $qaCommit=Commit-Fixture
    $decision=Decision
    Check ($decision.skipNativeBuild -and $decision.reason -ceq 'qa_only_verified_push' -and $decision.commitCount -eq 1) 'one QA-only commit skips native builds'
    foreach ($eventName in @('pull_request','workflow_dispatch','schedule','')) { Must-Build (Decision -Event $eventName) 'non-push events always build' }
    Must-Build (Decision -Before ('0'*40)) 'initial push builds'
    Must-Build (Decision -Before '') 'missing push base builds'
    Must-Build (Decision -Before ('f'*40)) 'unavailable base commit builds'
    Must-Build (Decision -Before 'HEAD~1') 'untrusted revision syntax builds'
    Must-Build (Decision -Expected $script:base) 'event SHA disagreement builds'
    Must-Build (Get-BuildImpactDecision -Repository $fixture -EventName push -Before $script:base -After $script:base -ExpectedHead $script:base) 'checkout does not equal event after'
    Must-Build (Get-BuildImpactDecision -Repository $fixture -EventName push -Before $qaCommit -After $qaCommit -ExpectedHead $qaCommit) 'empty push range builds'
    Must-Build (Get-BuildImpactDecision -Repository (Join-Path $testRoot 'missing') -EventName push -Before $script:base -After $qaCommit -ExpectedHead $qaCommit) 'git invocation failure builds'
    Write-Fixture 'untracked.txt' 'dirty'
    Must-Build (Decision) 'untracked checkout mutation builds'
    Remove-Item -LiteralPath (Join-Path $fixture 'untracked.txt')
    Write-Fixture $qa 'unstaged mutation'
    Must-Build (Decision) 'unstaged checkout mutation builds'
    [void](Git @('checkout','--',$qa))
    [IO.File]::WriteAllText((Join-Path $fixture '.git/shallow'),$qaCommit+"`n")
    try { Must-Build (Decision) 'shallow history builds' }
    finally { Remove-Item -LiteralPath (Join-Path $fixture '.git/shallow') }

    From-Base
    Write-Fixture 'native/windows/cmd/qa-desktop/new_test.go' 'synthetic standalone test'
    [void](Commit-Fixture)
    Check ((Decision).skipNativeBuild) 'new Go file in reviewed standalone command is QA-only'
    foreach ($path in $expandedQaPaths) {
        From-Base
        Write-Fixture $path 'synthetic reviewed diagnostic'
        [void](Commit-Fixture)
        $decision=Decision
        Check ($decision.skipNativeBuild -and $decision.qaEntries -eq 1 -and $decision.commitCount -eq 1) "exact diagnostic-only push skips packaging: $path"
    }
    foreach ($path in @($controller,'native/core/go.sum','scripts/bootstrap/toolchain.lock.json','scripts/qa/android-dns-capture/not-reviewed.ps1')) {
        From-Base
        foreach ($qaPath in $expandedQaPaths) { Write-Fixture $qaPath 'diagnostics mixed with a full-build input' }
        Write-Fixture $path 'non-QA change'
        [void](Commit-Fixture)
        Must-Build (Decision) "all diagnostic paths cannot hide a full-build input: $path"
    }
    foreach ($pair in @(
        @('native/windows/cmd/qa-teardown/main_windows.go','native/windows/cmd/qa-teardown/observe_windows.go'),
        @('scripts/qa/android-dns-capture/main.go','scripts/qa/android-dns-capture/main_test.go')
    )) {
        From-Base
        Write-Fixture ($pair[0]) 'diagnostic baseline'
        $diagnosticBase=Commit-Fixture
        [void](Git @('rm','--quiet','--',$pair[0]))
        [void](Commit-Fixture)
        Must-Build (Decision -Before $diagnosticBase) "diagnostic deletion remains full: $($pair[0])"
        [void](Git @('checkout','--quiet','--detach',$diagnosticBase))
        [void](Git @('mv','--',$pair[0],$pair[1]))
        [void](Commit-Fixture)
        Must-Build (Decision -Before $diagnosticBase) "diagnostic-to-diagnostic rename remains full: $($pair[0])"
    }
    From-Base
    Write-Fixture $controller 'controller change in an earlier commit'
    [void](Commit-Fixture)
    Write-Fixture $controller 'controller baseline'
    Write-Fixture ($expandedQaPaths[0]) 'diagnostic after controller revert'
    [void](Commit-Fixture)
    Must-Build (Decision) 'controller edit and revert cannot be hidden by a diagnostic-only final diff'
    From-Base
    Write-Fixture ($expandedQaPaths[0]) 'first diagnostic commit'
    [void](Commit-Fixture)
    Write-Fixture ($expandedQaPaths[3]) 'second diagnostic commit'
    [void](Commit-Fixture)
    $decision=Decision
    Check ($decision.skipNativeBuild -and $decision.commitCount -eq 2 -and $decision.qaEntries -eq 2) 'both diagnostic families qualify across an entire QA-only push'
    From-Base
    Write-Fixture $qa 'qa plus docs'
    Write-Fixture 'docs/PLAN.md' 'docs changed'
    Write-Fixture 'docs/evidence/synthetic.json' '{}'
    [void](Commit-Fixture)
    Check ((Decision).skipNativeBuild) 'QA plus documentation skips native builds'
    From-Base
    Write-Fixture 'docs/PLAN.md' 'documentation only'
    [void](Commit-Fixture)
    Must-Build (Decision) 'documentation alone cannot authorize skip'

    foreach ($path in @($production,'native/core/runtime.go','native/android/bridge/main.go','native/windows/go.mod','apps/exvpn/pubspec.lock','scripts/bootstrap/toolchain.lock.json','.github/workflows/verify.yml','scripts/ci/build-impact-lib.ps1','scripts/qa/run-fast-validation-lane.ps1','unexpected.txt')) {
        From-Base
        Write-Fixture $qa 'qa changed alongside non-QA'
        Write-Fixture $path 'non-QA change'
        [void](Commit-Fixture)
        Must-Build (Decision) "QA cannot hide production/toolchain/CI/unknown edits: $path"
    }
    From-Base
    [void](Git @('rm','--quiet','--',$qa))
    [void](Commit-Fixture)
    Must-Build (Decision) 'QA deletion still builds'
    From-Base
    [void](Git @('mv',$qa,'apps/exvpn/integration_test/windows_policy_test.dart'))
    [void](Commit-Fixture)
    Must-Build (Decision) 'QA-to-QA rename still builds'
    From-Base
    [void](Git @('mv',$production,'apps/exvpn/integration_test/windows_policy_test.dart'))
    [void](Commit-Fixture)
    Must-Build (Decision) 'production-to-QA rename builds'

    From-Base
    Write-Fixture $qa 'first QA commit'
    [void](Commit-Fixture)
    Write-Fixture $qaOther 'second QA commit'
    [void](Commit-Fixture)
    $decision=Decision
    Check ($decision.skipNativeBuild -and $decision.commitCount -eq 2) 'whole multi-commit QA-only push qualifies'
    From-Base
    Write-Fixture $production 'earlier production commit'
    [void](Commit-Fixture)
    Write-Fixture $qa 'latest QA commit'
    [void](Commit-Fixture)
    Must-Build (Decision) 'earlier production commit is not hidden by QA HEAD'
    Write-Fixture $production 'production baseline'
    [void](Commit-Fixture)
    Must-Build (Decision) 'reverted production edit remains full across push history'

    From-Base
    Write-Fixture $qa 'merge first side'
    $firstSide=Commit-Fixture
    From-Base
    Write-Fixture $qaOther 'merge second side'
    $secondSide=Commit-Fixture
    Must-Build (Decision -Before $firstSide) 'non-ancestor push base builds'
    [void](Git @('merge','--quiet','--no-edit','--no-ff',$firstSide))
    Must-Build (Decision) 'merge commits stay full even when their paths look QA-only'

    # Exercise the actual workflow entry point and append-only GITHUB_OUTPUT
    # outside the repository so the synthetic checkout remains clean.
    [void](Git @('checkout','--quiet','--detach',$qaCommit))
    $eventPath=Join-Path $testRoot 'push.json'
    $outputPath=Join-Path $testRoot 'github-output.txt'
    $env:GITHUB_EVENT_NAME='push'; $env:GITHUB_EVENT_PATH=$eventPath; $env:GITHUB_SHA=$qaCommit; $env:GITHUB_OUTPUT=$outputPath
    @{before=$script:base;after=$qaCommit}|ConvertTo-Json|Set-Content -LiteralPath $eventPath -Encoding utf8NoBOM
    $entryResult=(& (Join-Path $PSScriptRoot 'build-impact.ps1') -Repository $fixture)|ConvertFrom-Json
    Check ($entryResult.skipNativeBuild -and [IO.File]::ReadAllText($outputPath).Contains("skip_native_build=true`n")) 'entry point publishes proven QA-only result'
    Check ((Get-BuildImpactEventDecision $fixture).skipNativeBuild) 'verify entry can independently revalidate the same event'
    Write-Fixture $production 'mutation after initial selection'
    Must-Build (Get-BuildImpactEventDecision $fixture) 'verify revalidation denies a checkout changed after selection'
    [void](Git @('checkout','--',$production))
    [IO.File]::WriteAllText($eventPath,'{broken')
    $entryResult=(& (Join-Path $PSScriptRoot 'build-impact.ps1') -Repository $fixture)|ConvertFrom-Json
    Check (!$entryResult.skipNativeBuild -and [IO.File]::ReadAllText($outputPath).Contains("skip_native_build=false`n")) 'malformed event publishes full-build fallback'
    $env:GITHUB_EVENT_PATH=Join-Path $testRoot 'missing-event.json'
    $entryResult=(& (Join-Path $PSScriptRoot 'build-impact.ps1') -Repository $fixture)|ConvertFrom-Json
    Check (!$entryResult.skipNativeBuild) 'missing event file publishes full-build fallback'
    $env:GITHUB_EVENT_NAME='workflow_dispatch'
    $entryResult=(& (Join-Path $PSScriptRoot 'build-impact.ps1') -Repository $fixture)|ConvertFrom-Json
    Check (!$entryResult.skipNativeBuild) 'dispatch never consults missing push data'
} finally {
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process') }
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if (!$resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '^ExVPN-BuildImpact-[a-f0-9]{32}$') { throw 'build_impact_fixture_cleanup_boundary_failed' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host "Build-impact selector: $checks checks passed. No network, SDK build, or host settings changed."
