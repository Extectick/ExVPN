# SPDX-License-Identifier: Apache-2.0
# Synthetic local Git/report fixtures; no network, application builds or keys.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'artifact-audit-lib.ps1')
. (Join-Path $PSScriptRoot 'shorebird-pipeline-lib.ps1')
. (Join-Path $PSScriptRoot 'shorebird-publication-lib.ps1')
$root=Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) ('.private/preview-proof-tests/'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $root 'docs/evidence') -Force | Out-Null
$path=Join-Path $root 'docs/evidence/full.json'
$report=@{schemaVersion=1;mode='Full';status='passed';sourceUnchanged=$true;sourceFingerprintBefore=('a'*64);sourceFingerprintAfter=('a'*64);lanes=@(1..12|ForEach-Object {@{lane="lane$_";status='passed';exitCode=0}})}
$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path -Encoding utf8NoBOM
$versionedPath=Join-Path $root 'docs/evidence/full-v0.1.14.json'
Copy-Item -LiteralPath $path -Destination $versionedPath
$null=Invoke-ShorebirdGit $root @('init','--quiet')
$null=Invoke-ShorebirdGit $root @('add','docs/evidence/full.json')
$null=Invoke-ShorebirdGit $root @('add','docs/evidence/full-v0.1.14.json')
$null=Invoke-ShorebirdGit $root @('-c','user.name=ExVPN QA','-c','user.email=qa@example.invalid','-c','commit.gpgsign=false','commit','--quiet','-m','fixture')
$commit=Invoke-ShorebirdGit $root @('rev-parse','HEAD')
$proof=@{automatedTests='passed';automatedEvidence=@{sourceCommit=$commit;path='docs/evidence/full.json';sha256=(Get-AuditSha256 $path)}}
$script:checks=0
function Check([bool]$Condition) { if (!$Condition) { throw 'preview_test_evidence_fixture_failed' }; $script:checks++ }
function Reject([scriptblock]$Action) { try { & $Action|Out-Null } catch { $script:checks++;return }; throw 'preview_test_evidence_not_rejected' }
$safe=Get-IndependentPreviewAutomatedChecks $proof $root $commit
Check ($safe.status -ceq 'passed' -and $safe.evidence.sha256 -ceq $proof.automatedEvidence.sha256)
$versioned=$proof|ConvertTo-Json -Depth 8|ConvertFrom-Json -AsHashtable
$versioned.automatedEvidence.path='docs/evidence/full-v0.1.14.json'
$versionedSafe=Get-IndependentPreviewAutomatedChecks $versioned $root $commit
Check ($versionedSafe.status -ceq 'passed')
$legacy=Get-IndependentPreviewAutomatedChecks @{automatedTests='not_run_by_user_request'} $root $commit
Check ($legacy.status -ceq 'not_run_by_user_request' -and $null -eq $legacy.evidence)
Reject { Get-IndependentPreviewAutomatedChecks @{automatedTests='passed'} $root $commit }
Reject { Get-IndependentPreviewAutomatedChecks @{automatedTests='not_run_by_user_request';automatedEvidence=@{}} $root $commit }
foreach ($change in @(@('sourceCommit',('f'*40)),@('path','../private.json'),@('path','docs/evidence/../private.json'),@('path','docs/evidence/full..json'),@('sha256',('b'*64)))) {
    $bad=$proof|ConvertTo-Json -Depth 8|ConvertFrom-Json -AsHashtable
    $bad.automatedEvidence[$change[0]]=$change[1]
    Reject { Get-IndependentPreviewAutomatedChecks $bad $root $commit }
}
$report.status='failed'
$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path -Encoding utf8NoBOM
$proof.automatedEvidence.sha256=Get-AuditSha256 $path
Reject { Get-IndependentPreviewAutomatedChecks $proof $root $commit }
$null=Invoke-ShorebirdGit $root @('add','docs/evidence/full.json')
$null=Invoke-ShorebirdGit $root @('-c','user.name=ExVPN QA','-c','user.email=qa@example.invalid','-c','commit.gpgsign=false','commit','--quiet','-m','failed fixture')
$proof.automatedEvidence.sourceCommit=Invoke-ShorebirdGit $root @('rev-parse','HEAD')
Reject { Get-IndependentPreviewAutomatedChecks $proof $root $proof.automatedEvidence.sourceCommit }
[pscustomobject]@{Status='PASS';Checks=$script:checks;Scope='Preview source test evidence only'}
