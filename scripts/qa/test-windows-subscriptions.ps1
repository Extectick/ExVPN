# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'windows-subscriptions-lib.ps1')
$checks=0
function Good([bool]$Value,[string]$Label) {if(!$Value){throw "fixture_failed:$Label"};$script:checks++}
function Bad([scriptblock]$Action,[string]$Label) {$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Good $failed $Label}
function Marker {
    [pscustomobject]@{format=1;runId='3ad3e97f-8130-4ce8-b382-254532b6f3dc';build=13;forbiddenHost='QA-HOST';subscriptionUi=$true;subscriptionPhase='edit';unelevated=$true;faults=$false;providerMatrix=$false;networkRecovery=$false;transportCycles=0;policyRecovery=$null}
}
function Report([string]$Phase='edit') {
    [pscustomobject]@{runId=(Marker).runId;phase=$Phase;version='0.1.0+13';processId=$(if($Phase -ceq 'edit'){101}else{102});executableSha256=('a'*64);snapshotSha256=('b'*64);ciphertextSha256=('c'*64);frameworkPassed=$true;passed=$true;storagePathOverride=$true;syntheticInputOnly=$true;ordinaryUserTokenTested=$true;storedPlaintextCanariesAbsent=$true;pendingJournalAbsent=$true;vpnInitialized=$false;vpnActionsPerformed=$false;httpRequestsPerformed=$false;defaultStorageLocationTested=$false;awaitingReopen=($Phase -ceq 'edit');cancelPreservedWorkingListAndSelection=$true;cancelPersistedWorkingList=$true;explicitReplacementApplied=$true;differentProcessFromEdit=$true;coldRestoreMatched=$true;ownedGroupsDeletedThroughUi=$true;emptyStatePersisted=$true}
}
$m=Marker;$paths=Get-SubscriptionQaPaths $m
Good ($paths.data -ceq ('C:\ProgramData\ExVPN Subscription QA\'+$m.runId) -and $paths.output -ceq ('C:\ExVPN-Lifecycle-QA-Results\'+$m.runId)) 'fixed data and output roots'
foreach($phase in @('edit','reopen')){$m=Marker;$m.subscriptionPhase=$phase;[void](Get-SubscriptionQaPaths $m);$r=Report $phase;Assert-SubscriptionReport $r $m ('a'*64);Good $true ('valid phase '+$phase)}
foreach($value in @('1',$true,0)){$m=Marker;$m.format=$value;Bad {Get-SubscriptionQaPaths $m} 'typed marker format'}
foreach($field in @('subscriptionUi','unelevated')){$m=Marker;$m.$field=$false;Bad {Get-SubscriptionQaPaths $m} ('required '+$field);$m=Marker;$m.$field='true';Bad {Get-SubscriptionQaPaths $m} ('boolean '+$field)}
foreach($field in @('faults','providerMatrix','networkRecovery')){$m=Marker;$m.$field=$true;Bad {Get-SubscriptionQaPaths $m} ('VPN mode '+$field);$m=Marker;$m.$field='false';Bad {Get-SubscriptionQaPaths $m} ('typed '+$field)}
foreach($run in @('', '../outside', '00000000-0000-0000-0000-000000000000', ((Marker).runId+'\child'), (Marker).runId.ToUpperInvariant())){$m=Marker;$m.runId=$run;Bad {Get-SubscriptionQaPaths $m} 'invalid run'}
foreach($phase in @('', 'EDIT', '../edit')){$m=Marker;$m.subscriptionPhase=$phase;Bad {Get-SubscriptionQaPaths $m} 'invalid phase'}
foreach($value in @(3,'0',$true)){$m=Marker;$m.transportCycles=$value;Bad {Get-SubscriptionQaPaths $m} 'transport prohibited'}
$m=Marker;$m.policyRecovery='reset';Bad {Get-SubscriptionQaPaths $m} 'policy recovery prohibited'
foreach($field in @('frameworkPassed','passed','storagePathOverride','ordinaryUserTokenTested','pendingJournalAbsent')){$r=Report;$r.$field=$false;Bad {Assert-SubscriptionReport $r (Marker) ('a'*64)} ('required report '+$field)}
$r=Report;$r.frameworkPassed='true';Bad {Assert-SubscriptionReport $r (Marker) ('a'*64)} 'typed framework result'
foreach($field in @('vpnInitialized','vpnActionsPerformed','httpRequestsPerformed','defaultStorageLocationTested')){$r=Report;$r.$field=$true;Bad {Assert-SubscriptionReport $r (Marker) ('a'*64)} ('report scope '+$field)}
$r=Report;$r.executableSha256='d'*64;Bad {Assert-SubscriptionReport $r (Marker) ('a'*64)} 'wrong executable'
$r=Report;$r.processId='101';Bad {Assert-SubscriptionReport $r (Marker) ('a'*64)} 'typed PID'
$r=Report;$r.runId='7ad3e97f-8130-4ce8-b382-254532b6f3dc';Bad {Assert-SubscriptionReport $r (Marker) ('a'*64)} 'stale report'
$edit=Report;$reopen=Report 'reopen';Assert-SubscriptionColdPair $edit $reopen;Good $true 'two-process exact restore'
foreach($field in @('runId','version','executableSha256','snapshotSha256','ciphertextSha256')){$reopen=Report 'reopen';$reopen.$field='different';Bad {Assert-SubscriptionColdPair $edit $reopen} ('cold identity '+$field)}
$reopen=Report 'reopen';$reopen.processId=$edit.processId;Bad {Assert-SubscriptionColdPair $edit $reopen} 'widget rebuild is not cold restore'
$reopen=Report 'reopen';$reopen.coldRestoreMatched=$false;$m=Marker;$m.subscriptionPhase='reopen';Bad {Assert-SubscriptionReport $reopen $m ('a'*64)} 'unconfirmed cold restore'
Write-Host "Windows subscription QA validators: $checks checks PASS; no guest, process, storage or network mutations."
