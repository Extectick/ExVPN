# SPDX-License-Identifier: Apache-2.0
# Pure validators shared by the disposable guest and host runner (PS 5.1+).
Set-StrictMode -Version Latest

function Get-SubscriptionQaPaths($Marker) {
    if (($Marker.format -isnot [int] -and $Marker.format -isnot [long]) -or $Marker.format -ne 1 -or $Marker.subscriptionUi -isnot [bool] -or !$Marker.subscriptionUi -or
        $Marker.unelevated -isnot [bool] -or !$Marker.unelevated -or
        ($Marker.build -isnot [int] -and $Marker.build -isnot [long]) -or $Marker.build -le 0 -or
        $Marker.runId -isnot [string] -or $Marker.runId -cnotmatch '^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$' -or
        $Marker.runId -ceq '00000000-0000-0000-0000-000000000000' -or
        $Marker.subscriptionPhase -cnotin @('edit','reopen') -or
        $Marker.forbiddenHost -isnot [string] -or !$Marker.forbiddenHost -or
        $null -ne $Marker.policyRecovery -or
        ($Marker.transportCycles -isnot [int] -and $Marker.transportCycles -isnot [long]) -or $Marker.transportCycles -ne 0) { throw 'subscription_marker_invalid' }
    foreach ($name in @('faults','providerMatrix','networkRecovery')) {
        if ($Marker.$name -isnot [bool] -or $Marker.$name) { throw 'subscription_vpn_mode_forbidden' }
    }
    [pscustomobject]@{
        runId=$Marker.runId;phase=$Marker.subscriptionPhase
        output=(Join-Path 'C:\ExVPN-Lifecycle-QA-Results' $Marker.runId)
        data=(Join-Path 'C:\ProgramData\ExVPN Subscription QA' $Marker.runId)
        backup=(Join-Path 'C:\Program Files\ExVPN Subscription QA Backup' $Marker.runId)
    }
}

function Assert-SubscriptionNoLinks([string]$Path) {
    $current=[IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'subscription_reparse_forbidden' }
        }
        $current=[IO.Path]::GetDirectoryName($current)
    }
}

function Assert-SubscriptionReport($Report, $Marker, [string]$ExecutableSha256) {
    $paths=Get-SubscriptionQaPaths $Marker
    if ($Report.runId -cne $paths.runId -or $Report.phase -cne $paths.phase -or
        ($Report.processId -isnot [int] -and $Report.processId -isnot [long]) -or $Report.processId -le 0 -or
        $Report.executableSha256 -cne $ExecutableSha256 -or $ExecutableSha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'subscription_report_identity_invalid' }
    foreach($name in @('frameworkPassed','passed','storagePathOverride','syntheticInputOnly','ordinaryUserTokenTested','storedPlaintextCanariesAbsent','pendingJournalAbsent')) {
        if ($Report.$name -isnot [bool] -or !$Report.$name) { throw 'subscription_report_not_passed' }
    }
    foreach($name in @('vpnInitialized','vpnActionsPerformed','httpRequestsPerformed','defaultStorageLocationTested')) {
        if ($Report.$name -isnot [bool] -or $Report.$name) { throw 'subscription_report_scope_invalid' }
    }
    foreach($name in @('snapshotSha256','ciphertextSha256')) {
        if ($Report.$name -isnot [string] -or $Report.$name -cnotmatch '^[a-f0-9]{64}$') { throw 'subscription_report_digest_invalid' }
    }
    if ($paths.phase -ceq 'edit') {
        foreach($name in @('awaitingReopen','cancelPreservedWorkingListAndSelection','cancelPersistedWorkingList','explicitReplacementApplied')) {
            if ($Report.$name -isnot [bool] -or !$Report.$name) { throw 'subscription_edit_incomplete' }
        }
    } else {
        foreach($name in @('differentProcessFromEdit','coldRestoreMatched','ownedGroupsDeletedThroughUi','emptyStatePersisted')) {
            if ($Report.$name -isnot [bool] -or !$Report.$name) { throw 'subscription_reopen_incomplete' }
        }
        if ($Report.awaitingReopen -isnot [bool] -or $Report.awaitingReopen) { throw 'subscription_reopen_incomplete' }
    }
}

function Assert-SubscriptionColdPair($Edit, $Reopen) {
    if ($Edit.runId -cne $Reopen.runId -or $Edit.phase -cne 'edit' -or $Reopen.phase -cne 'reopen' -or
        $Edit.processId -eq $Reopen.processId -or $Edit.version -cne $Reopen.version -or
        $Edit.executableSha256 -cne $Reopen.executableSha256 -or
        $Edit.snapshotSha256 -cne $Reopen.snapshotSha256 -or $Edit.ciphertextSha256 -cne $Reopen.ciphertextSha256) { throw 'subscription_cold_restore_mismatch' }
}
