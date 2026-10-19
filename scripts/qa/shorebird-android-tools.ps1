# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Dot-sourcing is inert. Only an explicitly owned emulator can be restarted;
# package installation, data clearing, cloud mutations and VPN actions are absent.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'android-lifecycle-tools.ps1')
$script:AndroidShorebirdQa = $null

function Initialize-AndroidShorebirdQa {
    param(
        [Parameter(Mandatory)][ValidatePattern('^emulator-[0-9]{4,5}$')][string]$Serial,
        [Parameter(Mandatory)][string]$PrivateOutputDirectory,
        [string]$AndroidSdkPath = (Join-Path $env:LOCALAPPDATA 'Android/Sdk'),
        [switch]$AllowOwnedRuntimeActions
    )
    if ($Serial -ceq 'emulator-5564') { throw 'shorebird_original_emulator_refused' }
    Initialize-AndroidLifecycleQa -Serial $Serial -OutputDirectory $PrivateOutputDirectory -AndroidSdkPath $AndroidSdkPath
    $script:AndroidShorebirdQa = @{ Serial=$Serial; RuntimeAllowed=[bool]$AllowOwnedRuntimeActions }
}

function ConvertFrom-AndroidShorebirdDiagnostics {
    param([Parameter(Mandatory)][string]$Text)
    if ($Text.Length -gt 8192) { throw 'shorebird_diagnostics_oversized' }
    try { $value = ConvertFrom-Json -InputObject $Text -AsHashtable -ErrorAction Stop }
    catch { throw 'shorebird_diagnostics_invalid_json' }
    $expected=@('schema','application','version','uiRevision','platform','coreVersion','vpnPhase',
        'processCrashProtection','errorCode','secureStorageAvailable','updates')
    if ($value -isnot [Collections.IDictionary] -or
        (($value.Keys | Sort-Object) -join ',') -cne (($expected | Sort-Object) -join ',') -or
        $value.schema -ne 1 -or $value.application -cne 'ExVPN' -or $value.platform -cne 'android' -or
        $value.version -cne '0.1.8+29' -or $value.uiRevision -isnot [long] -and $value.uiRevision -isnot [int] -or
        $value.uiRevision -notin @(0,1)) { throw 'shorebird_diagnostics_identity_mismatch' }
    $updates=$value.updates
    $updateKeys=@('dataRevision','dataChannel','dartAvailable','currentDartPatch','nextDartPatch','dartRestartRequired','dartTrack')
    if ($updates -isnot [Collections.IDictionary] -or
        (($updates.Keys | Sort-Object) -join ',') -cne (($updateKeys | Sort-Object) -join ',') -or
        $updates.dartAvailable -isnot [bool] -or $updates.dartRestartRequired -isnot [bool] -or
        $updates.dartTrack -cne 'beta') { throw 'shorebird_diagnostics_updates_invalid' }
    foreach ($key in @('currentDartPatch','nextDartPatch')) {
        $number=$updates[$key]
        if ($null -ne $number -and (($number -isnot [long] -and $number -isnot [int]) -or
            $number -le 0 -or $number -gt [int]::MaxValue)) { throw 'shorebird_diagnostics_patch_invalid' }
    }
    if ($updates.dartAvailable -and
        $updates.dartRestartRequired -ne ($updates.currentDartPatch -ne $updates.nextDartPatch)) {
        throw 'shorebird_diagnostics_transition_inconsistent'
    }
    # Export only the SDK scalars needed for this test. A null/base snapshot on
    # its own does NOT prove successful native-updater initialization.
    [ordered]@{version=$value.version;uiRevision=[int]$value.uiRevision;vpnPhase=$value.vpnPhase
        available=$updates.dartAvailable;current=$updates.currentDartPatch;next=$updates.nextDartPatch
        restartRequired=$updates.dartRestartRequired;track=$updates.dartTrack;nativeInitializationProven=$false}
}

function Get-AndroidShorebirdDiagnosticsFromUi {
    param([Parameter(Mandatory)][System.Xml.XmlDocument]$Tree)
    if ($Tree.SelectNodes('//node').Count -gt 2048) { throw 'shorebird_ui_tree_oversized' }
    $candidates=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($node in $Tree.SelectNodes('//node[@package="ru.exvpn.exvpn"]')) {
        foreach ($attribute in @('text','content-desc')) {
            $label=$node.GetAttribute($attribute)
            if ($label.Length -gt 16384) { continue }
            $start=$label.IndexOf('{');$end=$label.LastIndexOf('}')
            if ($start -ge 0 -and $end -gt $start) {
                $candidate=$label.Substring($start,$end-$start+1)
                if ($candidate.Contains('"currentDartPatch"') -and $candidate.Contains('"application"')) {
                    $null=$candidates.Add($candidate)
                }
            }
        }
    }
    if ($candidates.Count -ne 1) { throw 'shorebird_diagnostics_ui_missing_or_ambiguous' }
    ConvertFrom-AndroidShorebirdDiagnostics (@($candidates)[0])
}

function Assert-AndroidShorebirdPhase {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Snapshot,
        [Parameter(Mandatory)][ValidateSet('base','staged','applied','rollbackStaged','rolledBack')][string]$Phase,
        [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$PatchNumber
    )
    if (!$Snapshot.available -or $Snapshot.track -cne 'beta' -or $Snapshot.version -cne '0.1.8+29') {
        throw 'shorebird_sdk_unavailable_or_wrong_base'
    }
    $expected=switch ($Phase) {
        base { @{current=$null;next=$null;ui=0;restart=$false} }
        staged { @{current=$null;next=$PatchNumber;ui=0;restart=$true} }
        applied { @{current=$PatchNumber;next=$PatchNumber;ui=1;restart=$false} }
        rollbackStaged { @{current=$PatchNumber;next=$null;ui=1;restart=$true} }
        rolledBack { @{current=$null;next=$null;ui=0;restart=$false} }
    }
    if ($Snapshot.current -ne $expected.current -or $Snapshot.next -ne $expected.next -or
        $Snapshot.uiRevision -ne $expected.ui -or $Snapshot.restartRequired -ne $expected.restart) {
        throw 'shorebird_actual_patch_state_mismatch'
    }
    [ordered]@{phase=$Phase;current=$Snapshot.current;next=$Snapshot.next;uiRevision=$Snapshot.uiRevision
        restartRequired=$Snapshot.restartRequired;nativeInitializationProven=($Phase -ceq 'applied')}
}

function Get-AndroidShorebirdInstalledIdentity {
    param([Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]{1,45}$')][string]$Step)
    if (!$script:AndroidShorebirdQa -or $script:AndroidShorebirdQa.Serial -cne $script:AndroidLifecycleContext.Serial) {
        throw 'shorebird_emulator_owner_missing'
    }
    $dump=Invoke-AndroidLifecycleAdb -Step "$Step-package" -AdbArguments @('shell','dumpsys','package','ru.exvpn.exvpn')
    $version=[regex]::Matches($dump,'(?m)^\s*versionName=([^\r\n]+)\r?$')
    $build=[regex]::Matches($dump,'(?m)^\s*versionCode=([0-9]+)\b')
    $uid=[regex]::Matches($dump,'(?m)^\s*userId=([0-9]+)\b')
    $path=(Invoke-AndroidLifecycleAdb -Step "$Step-path" -AdbArguments @('shell','pm','path','ru.exvpn.exvpn')).Trim()
    if ($version.Count -ne 1 -or $version[0].Groups[1].Value.Trim() -cne '0.1.8' -or
        $build.Count -ne 1 -or $build[0].Groups[1].Value -cne '29' -or $uid.Count -ne 1 -or
        $path -cnotmatch '\Apackage:(/data/app/[-A-Za-z0-9_=/+.~]+/base\.apk)\z') {
        throw 'shorebird_installed_identity_mismatch'
    }
    $apkPath=$Matches[1]
    $sha=(Invoke-AndroidLifecycleAdb -Step "$Step-apk-sha" -AdbArguments @('shell','sha256sum',$apkPath)).Trim()
    if ($sha -cnotmatch ('\A([a-f0-9]{64})\s+'+[regex]::Escape($apkPath)+'\z')) { throw 'shorebird_apk_hash_invalid' }
    [ordered]@{version='0.1.8';build=29;uid=[int]$uid[0].Groups[1].Value;apkSha256=$Matches[1]}
}

function Assert-AndroidShorebirdUnchangedApk {
    param([Parameter(Mandatory)][Collections.IDictionary]$Before,
        [Parameter(Mandatory)][Collections.IDictionary]$After,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedSha256)
    foreach ($state in @($Before,$After)) {
        if ($state.version -cne '0.1.8' -or $state.build -ne 29 -or $state.uid -lt 10000 -or
            $state.apkSha256 -cne $ExpectedSha256) { throw 'shorebird_apk_continuity_failed' }
    }
    if ($Before.uid -ne $After.uid) { throw 'shorebird_uid_changed' }
    $true
}

function Invoke-AndroidShorebirdColdRestart {
    param([Parameter(Mandatory)][Collections.IDictionary]$LastDiagnostics,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedApkSha256,
        [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]{1,35}$')][string]$Step)
    if (!$script:AndroidShorebirdQa.RuntimeAllowed -or $LastDiagnostics.vpnPhase -cne 'disconnected') {
        throw 'shorebird_owned_idle_restart_not_authorized'
    }
    $before=Get-AndroidShorebirdInstalledIdentity "$Step-before"
    $null=Assert-AndroidShorebirdUnchangedApk $before $before $ExpectedApkSha256
    $services=Invoke-AndroidLifecycleAdb -Step "$Step-services" -AdbArguments @('shell','dumpsys','activity','services','ru.exvpn.exvpn')
    if ($services -notmatch 'ACTIVITY MANAGER SERVICES' -or $services.Contains('ServiceRecord{')) {
        throw 'shorebird_active_service_restart_refused'
    }
    $old=(Invoke-AndroidLifecycleAdb -Step "$Step-old-pid" -AdbArguments @('shell','pidof','ru.exvpn.exvpn')).Trim()
    if ($old -cnotmatch '\A[1-9][0-9]*\z') { throw 'shorebird_old_process_identity_missing' }
    $null=Invoke-AndroidLifecycleAdb -Step "$Step-stop" -AdbArguments @('shell','am','force-stop','ru.exvpn.exvpn')
    $remaining=(Invoke-AndroidLifecycleAdb -Step "$Step-stopped" -AdbArguments @('shell','sh','-c','"pidof ru.exvpn.exvpn || true"')).Trim()
    if ($remaining) { throw 'shorebird_old_process_still_alive' }
    $null=Invoke-AndroidLifecycleAdb -Step "$Step-launch" -AdbArguments @('shell','am','start','-W','-n','ru.exvpn.exvpn/.MainActivity')
    $new=(Invoke-AndroidLifecycleAdb -Step "$Step-new-pid" -AdbArguments @('shell','pidof','ru.exvpn.exvpn')).Trim()
    if ($new -cnotmatch '\A[1-9][0-9]*\z' -or $new -ceq $old) { throw 'shorebird_new_process_not_confirmed' }
    $after=Get-AndroidShorebirdInstalledIdentity "$Step-after"
    $null=Assert-AndroidShorebirdUnchangedApk $before $after $ExpectedApkSha256
    [ordered]@{oldProcessAbsentObserved=$true;newProcessObserved=$true;apkUnchanged=$true;uidUnchanged=$true;method='owned_idle_force_stop_and_activity_start'}
}
