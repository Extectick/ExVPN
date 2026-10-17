# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# ADB-only QA helpers. Dot-sourcing is inert; all raw output stays in .private.
Set-StrictMode -Version Latest

function Initialize-AndroidLifecycleQa {
    param(
        [Parameter(Mandatory)][ValidatePattern('^emulator-[0-9]{4,5}$')][string]$Serial,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$AndroidSdkPath = $env:ANDROID_HOME
    )
    $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $privateRoot = [IO.Path]::GetFullPath((Join-Path $repository '.private'))
    $output = [IO.Path]::GetFullPath($OutputDirectory)
    if (!$output.StartsWith($privateRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'qa_private_output_required' }
    $entryPath = $output
    while ($entryPath.Length -ge $privateRoot.Length) {
        if (Test-Path -LiteralPath $entryPath) {
            if ((Get-Item -LiteralPath $entryPath).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'qa_output_link_rejected' }
        }
        $entryPath = [IO.Path]::GetDirectoryName($entryPath)
    }
    $adb = Join-Path $AndroidSdkPath 'platform-tools/adb.exe'
    if (!(Test-Path -LiteralPath $adb -PathType Leaf)) { throw 'qa_adb_unavailable' }
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $script:AndroidLifecycleContext = @{ Serial=$Serial; Output=$output; Adb=$adb }
}

function Invoke-AndroidLifecycleAdb {
    param(
        [Parameter(Mandatory)][string[]]$AdbArguments,
        [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]{1,80}$')][string]$Step,
        [ValidateRange(1,60)][int]$TimeoutSeconds=30
    )
    $context = $script:AndroidLifecycleContext
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $context.Adb
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-s', $context.Serial) + $AdbArguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) { throw 'qa_adb_deadline' }
        $output = $stdout.GetAwaiter().GetResult()
        $errorOutput = $stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $context.Output "$Step.stdout.txt"), $output)
        [IO.File]::WriteAllText((Join-Path $context.Output "$Step.stderr.txt"), $errorOutput)
        if ($process.ExitCode -ne 0) { throw 'qa_adb_failed' }
        return $output
    } finally {
        if (!$process.HasExited) { $process.Kill(); $null = $process.WaitForExit(1000) }
        $process.Dispose()
    }
}

function ConvertFrom-AndroidLifecycleProbe {
    param([Parameter(Mandatory)][string]$Output)
    $numbers = @('durationMs','uid','uidRxBytes','uidTxBytes','httpStatus','responseBytes','publicIpFamily','ipv4Answers','ipv6Answers')
    $booleans = @('vpnTransport','success','dnsQueryAttempted')
    $digests = @('bodySha256','publicIpSha256','dnsQuerySha256')
    $errors = @('deadline','network','unsupported_mode','http_status','too_large','invalid_ip_response','invalid_dns_nonce')
    $result = [ordered]@{}
    foreach ($match in [regex]::Matches($Output, '(?m)^INSTRUMENTATION_RESULT: ([a-zA-Z0-9]+)=([^\r\n]*)\r?$')) {
        $key=$match.Groups[1].Value; $value=$match.Groups[2].Value
        if ($result.Contains($key)) { throw 'qa_duplicate_probe_field' }
        if ($key -in $numbers -and $value -match '^-?\d{1,18}$') {
            $number = [long]$value
            if ($number -lt 0 -and !($number -eq -1 -and $key -in @('uidRxBytes','uidTxBytes'))) { throw 'qa_invalid_probe_number' }
            $result[$key] = $number
        } elseif ($key -in $booleans -and $value -cin @('true','false')) { $result[$key] = $value -ceq 'true' }
        elseif ($key -in $digests -and $value -cmatch '^[a-f0-9]{64}$') { $result[$key] = $value }
        elseif ($key -eq 'dnsOutcome' -and $value -cin @('answers','no_answer')) { $result[$key] = $value }
        elseif ($key -eq 'error' -and $value -cin $errors) { $result[$key] = $value }
        else { throw 'qa_invalid_probe_field' }
    }
    if ([regex]::Matches($Output, '(?m)^INSTRUMENTATION_CODE: -1\r?$').Count -ne 1 -or
        !$result.Contains('uid') -or !$result.Contains('vpnTransport') -or !$result.Contains('durationMs')) { throw 'qa_incomplete_probe' }
    if ($result.Contains('error')) {
        if ($result.Contains('success') -and $result.success) { throw 'qa_contradictory_probe' }
        $result.success=$false
    } elseif (!$result.Contains('success')) { throw 'qa_incomplete_probe' }
    return $result
}

function Invoke-AndroidLifecycleProbe {
    param(
        [Parameter(Mandatory)][ValidateSet('health','trace4','ip4','ip6','numeric','dns')][string]$Mode,
        [Parameter(Mandatory)][string]$Step
    )
    # One synchronous invocation at a time; never run this package's text-input
    # instrumentation concurrently. A completed process alone is not success.
    $output = Invoke-AndroidLifecycleAdb -Step $Step -AdbArguments @('shell','am','instrument','-w','-e','mode',$Mode,'ru.exvpn.netprobe/ru.exvpn.netprobe.HttpsProbe')
    ConvertFrom-AndroidLifecycleProbe $output
}

function ConvertFrom-AndroidLifecycleVpnUi {
    param([Parameter(Mandatory)][string]$Output, [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('observe','connect','disconnect')][string]$Command)
    $fields=@('mechanism','runId','command','status','beforePhase','afterPhase','actionAttempted','actionAccepted','targetCount','nodesVisited','durationMs')
    $statuses=@('observed','completed','invalid_command','invalid_run','ownership_error','ownership_cleanup_failed',
        'window_unavailable','wrong_window_package','tree_too_large','stale_target','target_missing','ambiguous_target',
        'invalid_target','phase_unavailable','phase_conflict','precondition_failed','edit_or_dialog_visible',
        'action_rejected','action_error','accepted_unconfirmed','terminal_state','accessibility_error','deadline')
    $phases=@('unknown','disconnected','connected','connecting','requesting_permission','reconnecting','blocked','error')
    $values=[ordered]@{}; $codes=0
    foreach ($line in ($Output -split '\r?\n')) {
        if ($line -ceq '') { continue }
        if ($line -ceq 'INSTRUMENTATION_CODE: -1') { $codes++; continue }
        $match=[regex]::Match($line,'\AINSTRUMENTATION_RESULT: ([a-zA-Z0-9]+)=([^\r\n]*)\z')
        if (!$match.Success) { throw 'qa_invalid_vpn_ui_output' }
        $key=$match.Groups[1].Value; $value=$match.Groups[2].Value
        if ($key -cnotin $fields -or $values.Contains($key)) { throw 'qa_invalid_vpn_ui_field' }
        $values[$key]=$value
    }
    if ($codes -ne 1 -or $values.Count -ne $fields.Count -or
        $values.mechanism -cne 'instrumentation_semantics_v1' -or $values.runId -cne $RunId -or
        $RunId -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' -or
        $RunId -ceq '00000000-0000-0000-0000-000000000000' -or $values.command -cne $Command -or
        $values.status -cnotin $statuses -or $values.beforePhase -cnotin $phases -or $values.afterPhase -cnotin $phases) { throw 'qa_invalid_vpn_ui_contract' }
    foreach ($key in @('actionAttempted','actionAccepted')) {
        if ($values[$key] -cnotin @('true','false')) { throw 'qa_invalid_vpn_ui_boolean' }
        $values[$key]=$values[$key] -ceq 'true'
    }
    foreach ($key in @('targetCount','nodesVisited','durationMs')) {
        if ($values[$key] -cnotmatch '^(0|[1-9][0-9]{0,8})$') { throw 'qa_invalid_vpn_ui_number' }
        $values[$key]=[long]$values[$key]
    }
    if ($values.targetCount -gt 1 -or $values.nodesVisited -gt 2048 -or $values.durationMs -gt 35000 -or
        ($values.actionAccepted -and !$values.actionAttempted)) { throw 'qa_contradictory_vpn_ui_result' }
    if ($Command -ceq 'observe' -and ($values.actionAttempted -or $values.actionAccepted)) { throw 'qa_observe_attempted_action' }
    if ($values.status -ceq 'observed' -and ($Command -cne 'observe' -or $values.beforePhase -ceq 'unknown' -or
        $values.beforePhase -cne $values.afterPhase -or $values.targetCount -ne 1)) { throw 'qa_invalid_vpn_ui_observation' }
    if ($values.status -ceq 'completed') {
        $expected=if ($Command -ceq 'connect') { 'connected' } else { 'disconnected' }
        if ($Command -ceq 'observe' -or !$values.actionAccepted -or $values.afterPhase -cne $expected -or
            $values.targetCount -ne 1 -or ($Command -ceq 'connect' -and $values.beforePhase -cne 'disconnected') -or
            ($Command -ceq 'disconnect' -and $values.beforePhase -cnotin @('connected','reconnecting','blocked'))) { throw 'qa_invalid_vpn_ui_completion' }
    }
    if ($values.status -cin @('accepted_unconfirmed','terminal_state') -and !$values.actionAccepted) { throw 'qa_invalid_vpn_ui_acceptance' }
    if ($values.status -ceq 'action_rejected' -and (!$values.actionAttempted -or $values.actionAccepted)) { throw 'qa_invalid_vpn_ui_rejection' }
    if ($values.status -cin @('invalid_command','invalid_run','ownership_error','observed','precondition_failed') -and $values.actionAttempted) { throw 'qa_invalid_vpn_ui_precondition' }
    if ($values.status -ceq 'action_error' -and !$values.actionAttempted) { throw 'qa_invalid_vpn_ui_action_error' }
    return $values
}

function Get-AndroidLifecycleQaProcessId {
    param([Parameter(Mandatory)][string]$ProcessList)
    if ([regex]::Matches($ProcessList,'(?m)^\s*PID\s+NAME\s*\r?$').Count -ne 1) { throw 'qa_process_list_unavailable' }
    $processMatches=[regex]::Matches($ProcessList,'(?m)^\s*([1-9][0-9]{0,9})\s+ru\.exvpn\.netprobe(?::[^\r\n]*)?\s*\r?$')
    if ($processMatches.Count -gt 1) { throw 'qa_probe_process_ambiguous' }
    if ($processMatches.Count -eq 0) { return 0L }
    if ($processMatches[0].Value.Trim() -cnotmatch '^[1-9][0-9]{0,9}\s+ru\.exvpn\.netprobe$') { throw 'qa_probe_process_ambiguous' }
    return [long]$processMatches[0].Groups[1].Value
}

function Test-AndroidLifecycleVpnUiOwner {
    param([Parameter(Mandatory)][string]$Marker, [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][long]$ProcessId, [Parameter(Mandatory)][string]$ProcessStat)
    if (![regex]::IsMatch($RunId,'\A[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\z') -or
        $RunId -ceq '00000000-0000-0000-0000-000000000000') { return $false }
    $match=[regex]::Match($Marker,'\A([a-f0-9-]{36})\r?\n([1-9][0-9]{0,9})\r?\n([1-9][0-9]{0,18})\r?\n?\z')
    if (!$match.Success -or $match.Groups[1].Value -cne $RunId -or [long]$match.Groups[2].Value -ne $ProcessId) { return $false }
    $end=$ProcessStat.LastIndexOf(')')
    if ($end -lt 0 -or $ProcessStat.Length -gt 4096 -or $ProcessStat -cnotmatch ('\A'+[regex]::Escape([string]$ProcessId)+' \(')) { return $false }
    $statFields=$ProcessStat.Substring($end+1).Trim() -split '\s+'
    return $statFields.Count -gt 19 -and $statFields[19] -ceq $match.Groups[3].Value
}

function Stop-AndroidLifecycleOwnedVpnUiProbe {
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$Serial)
    # The process must have created this run's marker before touching accessibility.
    # A leftover marker alone is insufficient: compare both live PID and start ticks.
    $authorized=$false
    try {
        if ($script:AndroidLifecycleContext.Serial -cne $Serial) { return 'cleanup_refused' }
        $marker=Invoke-AndroidLifecycleAdb -Step "$Step-owner" -TimeoutSeconds 3 -AdbArguments @('shell','run-as','ru.exvpn.netprobe','cat','files/qa-vpn-ui-owner.txt')
        $list=Invoke-AndroidLifecycleAdb -Step "$Step-owner-pid" -TimeoutSeconds 3 -AdbArguments @('shell','ps','-A','-o','PID,NAME')
        $probeProcessId=Get-AndroidLifecycleQaProcessId $list
        if ($probeProcessId -le 0) { return 'already_exited' }
        $stat=Invoke-AndroidLifecycleAdb -Step "$Step-owner-start" -TimeoutSeconds 3 -AdbArguments @('shell','cat',"/proc/$probeProcessId/stat")
        if (!(Test-AndroidLifecycleVpnUiOwner $marker $RunId $probeProcessId $stat) -or
            $script:AndroidLifecycleContext.Serial -cne $Serial) { return 'cleanup_refused' }
        $authorized=$true
        $null=Invoke-AndroidLifecycleAdb -Step "$Step-probe-stop" -TimeoutSeconds 3 -AdbArguments @('shell','am','force-stop','ru.exvpn.netprobe')
        $after=Invoke-AndroidLifecycleAdb -Step "$Step-probe-stopped" -TimeoutSeconds 3 -AdbArguments @('shell','ps','-A','-o','PID,NAME')
        if ((Get-AndroidLifecycleQaProcessId $after) -ne 0) { return 'cleanup_failed' }
        return 'stopped_owned_probe'
    } catch { return $(if ($authorized) { 'cleanup_failed' } else { 'cleanup_refused' }) }
}

function Invoke-AndroidLifecycleVpnUi {
    param([Parameter(Mandatory)][ValidateSet('observe','connect','disconnect')][string]$Command,
        [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]{1,50}$')][string]$Step)
    $serial=$script:AndroidLifecycleContext.Serial
    if ($serial -cnotmatch '^emulator-[0-9]{4,5}$') { throw 'qa_invalid_serial' }
    $runId=[guid]::NewGuid().ToString('D')
    $mutex=[Threading.Mutex]::new($false, "ExVPN.AndroidVpnUi.$serial")
    $owned=$false; $watch=[Diagnostics.Stopwatch]::StartNew()
    try {
        try { $owned=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned=$true }
        if (!$owned) { throw 'qa_vpn_ui_busy' }
        $before=Invoke-AndroidLifecycleAdb -Step "$Step-processes" -TimeoutSeconds 5 -AdbArguments @('shell','ps','-A','-o','PID,NAME')
        if ((Get-AndroidLifecycleQaProcessId $before) -ne 0) { throw 'qa_probe_already_running' }
        try {
            $output=Invoke-AndroidLifecycleAdb -Step "$Step-instrument" -TimeoutSeconds 35 -AdbArguments @('shell','am','instrument','-w','-e','command',$Command,'-e','runId',$runId,'ru.exvpn.netprobe/ru.exvpn.netprobe.VpnUiProbe')
        } catch {
            if ($_.Exception.Message -cne 'qa_adb_deadline') { throw 'qa_vpn_ui_instrumentation_failed' }
            $cleanup=Stop-AndroidLifecycleOwnedVpnUiProbe -RunId $runId -Step $Step -Serial $serial
            # The UI action may have reached ExVPN before a Binder timeout. Never retry.
            return [ordered]@{mechanism='instrumentation_semantics_v1';runId=$runId;command=$Command;
                status='host_deadline';beforePhase='unknown';afterPhase='unknown';actionAttempted=$null;
                actionAccepted=$null;timeoutCleanup=$cleanup;hostDurationMs=$watch.ElapsedMilliseconds}
        }
        $result=ConvertFrom-AndroidLifecycleVpnUi -Output $output -RunId $runId -Command $Command
        $result.timeoutCleanup='not_needed'; $result.hostDurationMs=$watch.ElapsedMilliseconds
        return $result
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Read-AndroidLifecycleUi {
    param([Parameter(Mandatory)][string]$Step)
    $output = Invoke-AndroidLifecycleAdb -Step $Step -AdbArguments @('exec-out','uiautomator','dump','/dev/tty')
    $start = $output.IndexOf('<?xml', [StringComparison]::Ordinal)
    $end = $output.LastIndexOf('</hierarchy>', [StringComparison]::Ordinal)
    if ($start -lt 0 -or $end -le $start) { throw 'qa_ui_xml_unavailable' }
    $xml = [Xml.XmlDocument]::new()
    $xml.XmlResolver = $null
    $xml.LoadXml($output.Substring($start, $end + '</hierarchy>'.Length - $start))
    return $xml
}

function Find-AndroidLifecycleLabel {
    param([Parameter(Mandatory)][xml]$Tree, [Parameter(Mandatory)][string]$Label)
    $nodes = @($Tree.SelectNodes('//node') | Where-Object { $_.GetAttribute('content-desc') -ceq $Label -or $_.GetAttribute('text') -ceq $Label })
    if ($nodes.Count -ne 1) { throw 'qa_unique_ui_target_required' }
    return $nodes[0]
}

function Invoke-AndroidLifecycleTap {
    param([Parameter(Mandatory)][Xml.XmlElement]$Node, [Parameter(Mandatory)][string]$Step)
    if ($Node.GetAttribute('package') -cne 'ru.exvpn.exvpn') { throw 'qa_wrong_ui_package' }
    $bounds = [regex]::Match($Node.GetAttribute('bounds'), '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$')
    if (!$bounds.Success) { throw 'qa_invalid_ui_bounds' }
    $x1=[int]$bounds.Groups[1].Value; $y1=[int]$bounds.Groups[2].Value
    $x2=[int]$bounds.Groups[3].Value; $y2=[int]$bounds.Groups[4].Value
    if ($x2 -le $x1 -or $y2 -le $y1) { throw 'qa_empty_ui_bounds' }
    $x=[int](($x1+$x2)/2); $y=[int](($y1+$y2)/2)
    $null = Invoke-AndroidLifecycleAdb -Step $Step -AdbArguments @('shell','input','tap',[string]$x,[string]$y)
}
