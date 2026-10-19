# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
# Dot sourcing is inert. The owned installed process must be explicitly bound.
Set-StrictMode -Version Latest
$script:WindowsShorebirdRuntimeAllowed = $false
function Enable-WindowsShorebirdOwnedRuntime {
    # The coordinator calls this only after granting the installed-app stand.
    $script:WindowsShorebirdRuntimeAllowed = $true
}
function Import-WindowsShorebirdObserver {
    if(!('ExvpnShorebirdMsaa' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'shorebird-windows-msaa.cs') -ReferencedAssemblies 'Accessibility','System','System.Core'
    }
}
function Get-WindowsShorebirdBinding {
    $process=@(Get-Process exvpn -ErrorAction Stop)
    if($process.Count -ne 1 -or $process[0].Path -cne 'C:\Program Files\ExVPN\exvpn.exe'){throw 'qa_installed_exvpn_not_unique'}
    [ordered]@{pid=$process[0].Id;start=$process[0].StartTime.ToUniversalTime().Ticks;sha256=(Get-FileHash -LiteralPath $process[0].Path -Algorithm SHA256).Hash.ToLowerInvariant()}
}
function Invoke-WindowsShorebirdAction {
    param([Parameter(Mandatory)][Collections.IDictionary]$Binding,[Parameter(Mandatory)][string]$Action)
    $ErrorActionPreference='Stop'
    if($Action -in @('Выйти','Exit','Выйти из ExVPN…') -and !$script:WindowsShorebirdRuntimeAllowed){throw 'qa_runtime_exit_not_authorized'}
    $null=Invoke-WindowsShorebirdWorker $Binding 'action' $Action
}
function ConvertFrom-WindowsShorebirdDiagnostics {
    param([Parameter(Mandatory)][string]$Text)
    if($Text.Length -gt 8192){throw 'qa_diagnostics_oversized'}
    try {$d=$Text|ConvertFrom-Json -ErrorAction Stop} catch {throw 'qa_diagnostics_invalid'}
    $keys=@('schema','application','version','uiRevision','platform','coreVersion','vpnPhase','processCrashProtection','errorCode','secureStorageAvailable','updates')
    if(($d -isnot [pscustomobject]) -or
        ((@($d.PSObject.Properties.Name)|Sort-Object)-join ',') -cne (($keys|Sort-Object)-join ',') -or
        ($d.schema -isnot [int] -and $d.schema -isnot [long]) -or $d.schema -ne 1 -or
        $d.application -isnot [string] -or $d.application -cne 'ExVPN' -or $d.platform -isnot [string] -or $d.platform -cne 'windows' -or
        $d.version -isnot [string] -or $d.version -cne '0.1.7+28' -or ($d.uiRevision -isnot [int] -and $d.uiRevision -isnot [long]) -or
        $d.uiRevision -notin @(0,1) -or $d.secureStorageAvailable -isnot [bool] -or
        $d.vpnPhase -cnotin @('unavailable','disconnected','requestingPermission','connecting','connected','reconnecting','blocked','error')) {
        throw 'qa_diagnostics_wrong_application'
    }
    $updates=$d.updates
    $updateKeys=@('dataRevision','dataChannel','dartAvailable','currentDartPatch','nextDartPatch','dartRestartRequired','dartTrack')
    if($updates -isnot [pscustomobject] -or
        ((@($updates.PSObject.Properties.Name)|Sort-Object)-join ',') -cne (($updateKeys|Sort-Object)-join ',') -or
        $updates.dartAvailable -isnot [bool] -or $updates.dartRestartRequired -isnot [bool] -or
        $updates.dartTrack -isnot [string] -or $updates.dartTrack -cne 'beta') {
        throw 'qa_diagnostics_updates_invalid'
    }
    foreach($name in @('currentDartPatch','nextDartPatch')) {
        $patch=$updates.$name
        if($null -ne $patch -and (($patch -isnot [int] -and $patch -isnot [long]) -or $patch -le 0 -or $patch -gt [int]::MaxValue)) {
            throw 'qa_diagnostics_patch_invalid'
        }
    }
    if($updates.dartAvailable -and $updates.dartRestartRequired -ne ($updates.currentDartPatch -ne $updates.nextDartPatch)) {
        throw 'qa_diagnostics_transition_inconsistent'
    }
    [ordered]@{version=$d.version;uiRevision=[int]$d.uiRevision;available=$updates.dartAvailable;
        current=$updates.currentDartPatch;next=$updates.nextDartPatch;restartRequired=$updates.dartRestartRequired;
        track=$updates.dartTrack;vpnPhase=$d.vpnPhase;storageAvailable=$d.secureStorageAvailable;nativeInitializationProven=$false}
}
function Invoke-WindowsShorebirdWorker {
    param([Parameter(Mandatory)][Collections.IDictionary]$Binding,
        [Parameter(Mandatory)][ValidateSet('observe','action','openExitMenu')][string]$Operation,[string]$Action='')
    # A COM server may hang inside a single MSAA call. Isolate it in our own
    # disposable PS5 process; the hard timeout never terminates ExVPN.
    if($Binding.pid -le 0 -or $Binding.start -le 0 -or $Binding.sha256 -cnotmatch '\A[a-f0-9]{64}\z') {throw 'qa_process_binding_invalid'}
    $tools=Join-Path $PSScriptRoot 'shorebird-windows-tools.ps1'
    $code = '. '''+$tools.Replace("'","''")+'''; try {' + @'
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
$request=[Console]::In.ReadToEnd()|ConvertFrom-Json -ErrorAction Stop
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Import-WindowsShorebirdObserver
$binding=$request.binding
if($request.operation -eq 'openExitMenu') {
    [ExvpnShorebirdMsaa]::OpenExitMenu([int]$binding.pid,[long]$binding.start,[string]$binding.sha256)
    $value=@{requested=$true;method='real_owned_tray_callback'}
} else {
    $result=[ExvpnShorebirdMsaa]::Run([int]$binding.pid,[long]$binding.start,[string]$binding.sha256,[string]$request.action)
    $snapshot=$null
    if($result.Diagnostics){$snapshot=ConvertFrom-WindowsShorebirdDiagnostics $result.Diagnostics}
    $value=@{nodes=$result.Nodes;actions=@($result.Actions);snapshot=$snapshot}
}
[Console]::Out.Write(($value|ConvertTo-Json -Depth 8 -Compress))
} catch { [Console]::Error.Write('qa_observer_operation_failed'); exit 1 }
'@
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$start
    try {
        $null=$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write((@{binding=$Binding;operation=$Operation;action=$Action}|ConvertTo-Json -Compress))
        $process.StandardInput.Close()
        if(!$process.WaitForExit(20000)){$process.Kill();$process.WaitForExit();throw 'qa_observer_deadline'}
        $output=$stdout.GetAwaiter().GetResult();$null=$stderr.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0 -or $output.Length -gt 16384){throw 'qa_observer_operation_failed'}
        try {$output|ConvertFrom-Json -ErrorAction Stop} catch {throw 'qa_observer_invalid_response'}
    } finally {$process.Dispose()}
}
function Get-WindowsShorebirdObservation {
    param([Parameter(Mandatory)][Collections.IDictionary]$Binding)
    Invoke-WindowsShorebirdWorker $Binding 'observe'
}
function Assert-WindowsShorebirdPhase {
    param([Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][ValidateSet('base','staged','applied','rollbackStaged','rolledBack')][string]$Phase,
        [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$PatchNumber)
    if($Snapshot.available -isnot [bool] -or !$Snapshot.available -or $Snapshot.version -cne '0.1.7+28' -or
        $Snapshot.track -cne 'beta' -or $Snapshot.storageAvailable -isnot [bool] -or !$Snapshot.storageAvailable -or
        $Snapshot.restartRequired -isnot [bool] -or ($Snapshot.uiRevision -isnot [int] -and $Snapshot.uiRevision -isnot [long])) {
        throw 'qa_sdk_unavailable_or_wrong_base'
    }
    $expected=switch($Phase) {
        base {@{current=$null;next=$null;ui=0;restart=$false}}
        staged {@{current=$null;next=$PatchNumber;ui=0;restart=$true}}
        applied {@{current=$PatchNumber;next=$PatchNumber;ui=1;restart=$false}}
        rollbackStaged {@{current=$PatchNumber;next=$null;ui=1;restart=$true}}
        rolledBack {@{current=$null;next=$null;ui=0;restart=$false}}
    }
    if($Snapshot.current -ne $expected.current -or $Snapshot.next -ne $expected.next -or
        $Snapshot.uiRevision -ne $expected.ui -or $Snapshot.restartRequired -ne $expected.restart) {throw 'qa_actual_patch_state_mismatch'}
    [ordered]@{phase=$Phase;current=$Snapshot.current;next=$Snapshot.next;uiRevision=$Snapshot.uiRevision;
        restartRequired=$Snapshot.restartRequired;nativeInitializationProven=($Phase -ceq 'applied')}
}
function Get-WindowsShorebirdContinuity {
    # Fixed installed bytes and opaque user-store hashes only. Never decrypt or
    # parse subscription/appearance contents, and never inspect patch cache.
    $installed='C:\Program Files\ExVPN'
    Import-WindowsShorebirdObserver
    $support=Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'ExVPN contributors/ExVPN'
    $paths=[ordered]@{ui=(Join-Path $installed 'exvpn.exe');engine=(Join-Path $installed 'flutter_windows.dll');
        dartBase=(Join-Path $installed 'data/app.so');appearance=(Join-Path $support 'appearance-v1.json');
        subscriptions=(Join-Path $support 'secure-subscriptions/exvpn_subscriptions_current_v1.dpapi');
        pendingSubscriptions=(Join-Path $support 'secure-subscriptions/exvpn_subscriptions_pending_v1.dpapi')}
    $result=[ordered]@{}
    foreach($key in $paths.Keys) {
        if(!(Test-Path -LiteralPath $paths[$key] -PathType Leaf)) {
            if($key -in @('ui','engine','dartBase','subscriptions')){throw 'qa_continuity_input_missing'}
            $result[$key]=$null;continue
        }
        $item=Get-Item -LiteralPath $paths[$key]
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 512MB){throw 'qa_continuity_input_invalid'}
        $result[$key]=[ExvpnShorebirdMsaa]::Fingerprint($paths[$key])
    }
    if($null -ne $result.pendingSubscriptions){throw 'qa_storage_journal_not_idle'}
    $result
}
function Assert-WindowsShorebirdContinuity {
    param([Parameter(Mandatory)][Collections.IDictionary]$Before,[Parameter(Mandatory)][Collections.IDictionary]$After)
    foreach($name in @('ui','engine','dartBase','appearance','subscriptions','pendingSubscriptions')) {
        if($Before[$name] -cne $After[$name]){throw 'qa_base_or_saved_state_changed'}
    }
    [ordered]@{installedBaseUnchanged=$true;opaqueSubscriptionsUnchanged=$true;appearanceUnchanged=$true}
}
function Open-WindowsShorebirdExitMenu {
    param([Parameter(Mandatory)][Collections.IDictionary]$Binding,[Parameter(Mandatory)]$LastDiagnostics)
    if(!$script:WindowsShorebirdRuntimeAllowed -or $LastDiagnostics.vpnPhase -cne 'disconnected') {throw 'qa_owned_idle_exit_not_authorized'}
    Invoke-WindowsShorebirdWorker $Binding 'openExitMenu'
}
