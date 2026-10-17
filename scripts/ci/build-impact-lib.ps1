# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Conservative native-build selection only. Never selects or skips check suites.
Set-StrictMode -Version Latest

function Get-BuildImpactPathKind([string]$Path) {
    if (!$Path -or $Path -match '[\x00-\x20\\]' -or $Path.StartsWith('/') -or $Path -match '(^|/)\.\.?(/|$)') { return 'unknown' }
    # These main packages are compiled by go test ./..., but never imported by
    # the production service (cmd/exvpn-service) or Android JNI (bridge).
    if ($Path -cmatch '^native/windows/cmd/(qa-desktop|qa-guard|qa-https|qa-system)/[a-zA-Z0-9_]+\.go$' -or
        $Path -cin @('native/android/cmd/qa-server/main.go','native/android/cmd/qa-server/main_test.go')) { return 'qa' }
    if ($Path -cin @(
        'apps/exvpn/integration_test/windows_sandbox_test.dart',
        'apps/exvpn/integration_test/windows_policy_test.dart',
        'apps/exvpn/integration_test/windows_subscriptions_test.dart',
        'scripts/windows/prepare-app-sandbox.ps1',
        'scripts/windows/sandbox/guest-system-qa.ps1',
        'scripts/windows/sandbox/guest-qa.ps1',
        'scripts/windows/sandbox/guest-client-qa.ps1',
        'scripts/windows/sandbox/guest-bootstrap-qa.ps1',
        'scripts/windows/sandbox/guest-app-upgrade.ps1',
        'scripts/windows/sandbox/guest-app-qa.ps1',
        'scripts/windows/sandbox/guest-app-policy.ps1',
        'scripts/windows/sandbox/guest-app-network.ps1',
        'scripts/windows/sandbox/guest-app-launch.ps1',
        'scripts/windows/sandbox/guest-app-subscriptions.ps1',
        'scripts/windows/sandbox/guest-app-faults.ps1',
        'scripts/qa/ensure-windows-lifecycle-mapping.ps1',
        'scripts/qa/guest-transport-observe.ps1',
        'scripts/qa/run-windows-transport-lifecycle.ps1',
        'scripts/qa/test-windows-transport-lifecycle.ps1',
        'scripts/qa/windows-transport-lifecycle-lib.ps1',
        'scripts/qa/android-lifecycle-tools.ps1',
        'scripts/qa/test-android-lifecycle-tools.ps1',
        'native/windows/cmd/qa-teardown/main_windows.go',
        'native/windows/cmd/qa-teardown/observe_windows.go',
        'native/windows/cmd/qa-teardown/main_windows_test.go',
        'scripts/qa/android-dns-capture/main.go',
        'scripts/qa/android-dns-capture/main_test.go',
        'scripts/qa/android-dns-capture/test.ps1',
        'scripts/qa/guest-teardown-qa.ps1',
        'scripts/qa/run-windows-teardown.ps1',
        'scripts/qa/teardown-qa-lib.ps1',
        'scripts/qa/test-teardown-qa.ps1',
        'scripts/qa/run-windows-subscriptions.ps1',
        'scripts/qa/test-windows-subscriptions.ps1',
        'scripts/qa/windows-subscriptions-lib.ps1'
    )) { return 'qa' }
    # Documentation may accompany a QA change, but cannot itself authorize a
    # skip. Build inputs such as assets/SOURCES.md and licenses are not here.
    if ($Path -cmatch '^docs/(?:[a-zA-Z0-9_.-]+/)*[a-zA-Z0-9_.-]+\.md$' -or
        $Path -cmatch '^docs/evidence/(?:[a-zA-Z0-9_.-]+/)*[a-zA-Z0-9_.-]+\.json$') { return 'documentation' }
    return 'unknown'
}

function Invoke-BuildImpactGit([string]$Repository,[string[]]$Arguments) {
    $start=[Diagnostics.ProcessStartInfo]::new('git')
    $start.WorkingDirectory=$Repository
    $start.UseShellExecute=$false
    $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    foreach ($argument in @('-c','core.quotepath=false','--no-pager') + $Arguments) { $start.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::new()
    $process.StartInfo=$start
    $started=$false
    try {
        if (!$process.Start()) { throw 'build_impact_git_start_failed' }
        $started=$true
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(15000)) { $process.Kill($true); throw 'build_impact_git_deadline' }
        $output=$stdout.GetAwaiter().GetResult()
        [void]$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'build_impact_git_failed' }
        return $output
    } finally {
        if ($started -and !$process.HasExited) { $process.Kill($true) }
        $process.Dispose()
    }
}

function Get-BuildImpactDecision {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [string]$EventName='',
        [string]$Before='',
        [string]$After='',
        [string]$ExpectedHead=''
    )
    $result=[ordered]@{skipNativeBuild=$false;reason='full_by_default';commitCount=0;changedEntries=0;qaEntries=0}
    if ($EventName -cne 'push') { $result.reason='full_non_push'; return $result }
    if ($Before -cnotmatch '^[a-f0-9]{40}$' -or $After -cnotmatch '^[a-f0-9]{40}$' -or
        $ExpectedHead -cnotmatch '^[a-f0-9]{40}$' -or $Before -ceq ('0'*40) -or
        $After -ceq ('0'*40) -or $After -cne $ExpectedHead -or $Before -ceq $After) {
        $result.reason='full_unverified_push_range'; return $result
    }
    try {
        $Repository=[IO.Path]::GetFullPath($Repository)
        $head=(Invoke-BuildImpactGit $Repository @('rev-parse','--verify','HEAD^{commit}')).Trim()
        if ($head -cne $After) { $result.reason='full_head_mismatch'; return $result }
        if ((Invoke-BuildImpactGit $Repository @('rev-parse','--is-shallow-repository')).Trim() -cne 'false') {
            $result.reason='full_shallow_history'; return $result
        }
        if (Invoke-BuildImpactGit $Repository @('status','--porcelain=v1','-z','--untracked-files=all')) {
            $result.reason='full_dirty_checkout'; return $result
        }
        [void](Invoke-BuildImpactGit $Repository @('cat-file','-e',($Before+'^{commit}')))
        [void](Invoke-BuildImpactGit $Repository @('merge-base','--is-ancestor',$Before,$After))
        $range=$Before+'..'+$After
        if (Invoke-BuildImpactGit $Repository @('rev-list','--min-parents=2',$range,'--')) {
            $result.reason='full_merge_commit'; return $result
        }
        $countText=(Invoke-BuildImpactGit $Repository @('rev-list','--count',$range,'--')).Trim()
        if ($countText -cnotmatch '^\d{1,3}$' -or [int]$countText -lt 1 -or [int]$countText -gt 200) {
            $result.reason='full_unbounded_range'; return $result
        }
        $result.commitCount=[int]$countText
        # Inspect every pushed commit, including edits reverted later in the
        # push. --no-renames turns a rename into D+A; deletions always build.
        $changes=Invoke-BuildImpactGit $Repository @('log','--format=','--name-status','-z','--no-renames',$range,'--')
        $tokens=$changes.Split([char]0)
        if ($tokens.Length -lt 3 -or $tokens[-1] -cne '' -or ($tokens.Length % 2) -ne 1) {
            $result.reason='full_unrecognized_diff'; return $result
        }
        for ($index=0; $index -lt $tokens.Length-1; $index+=2) {
            $result.changedEntries++
            if ($tokens[$index] -cnotin @('A','M')) { $result.reason='full_deleted_renamed_or_changed_type'; return $result }
            $kind=Get-BuildImpactPathKind $tokens[$index+1]
            if ($kind -ceq 'unknown') { $result.reason='full_production_or_unknown_path'; return $result }
            if ($kind -ceq 'qa') { $result.qaEntries++ }
        }
        if ($result.qaEntries -eq 0) { $result.reason='full_no_qa_changes'; return $result }
        $result.skipNativeBuild=$true
        $result.reason='qa_only_verified_push'
    } catch {
        # Missing base/objects, an unavailable git executable, parse errors,
        # and any unexpected condition all retain the full native build.
        $result.skipNativeBuild=$false
        $result.reason='full_git_or_selector_error'
    }
    return $result
}

function Get-BuildImpactEventDecision([string]$Repository) {
    $decision=[ordered]@{skipNativeBuild=$false;reason='full_unverified_event';commitCount=0;changedEntries=0;qaEntries=0}
    try {
        if ($env:GITHUB_EVENT_NAME -cne 'push') {
            $decision.reason='full_non_push'
        } elseif ($env:GITHUB_EVENT_PATH -and (Get-Item -LiteralPath $env:GITHUB_EVENT_PATH).Length -le 10MB) {
            $event=Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json -AsHashtable
            if ($event.before -is [string] -and $event.after -is [string]) {
                $decision=Get-BuildImpactDecision -Repository $Repository -EventName $env:GITHUB_EVENT_NAME -Before $event.before -After $event.after -ExpectedHead $env:GITHUB_SHA
            }
        }
    } catch { $decision.skipNativeBuild=$false; $decision.reason='full_event_or_selector_error' }
    return $decision
}
