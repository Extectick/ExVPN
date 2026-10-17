# SPDX-License-Identifier: Apache-2.0
# Pure evidence checks: no processes, networking or filesystem mutations.
Set-StrictMode -Version Latest
function Assert-RoutingModeEvidence {
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][ValidateSet('disabled','exclude','include')][string]$RoutingMode,
        [Parameter(Mandatory)][ValidateSet('baseline','connected-cold','outage-cold','disconnected')][string]$Phase,
        [Parameter(Mandatory)][string]$RunId
    )
    if ($Report.runId -cne $RunId -or $Report.routingMode -cne $RoutingMode -or $Report.phase -cne $Phase -or
        $Report.controllerHarness -isnot [bool] -or !$Report.controllerHarness -or
        $Report.installedServiceIpcTested -isnot [bool] -or $Report.installedServiceIpcTested -or
        $Report.desktopTokenIsAdmin -isnot [bool]) { throw 'Routing evidence identity/coverage mismatch.' }
    $captured = $Phase -in @('connected-cold','outage-cold')
    $outage = $Phase -ceq 'outage-cold'
    $modes = @('numeric','health')
    if ($captured) { $modes += 'dns-tun' }
    if (@($Report.probes).Count -ne (2 * $modes.Count)) { throw 'Routing evidence is incomplete.' }
    foreach ($probe in @('protected-probe.exe','excluded-probe.exe')) {
        $selected = $probe -ceq 'excluded-probe.exe'
        $throughVpn = $RoutingMode -ceq 'disabled' -or ($RoutingMode -ceq 'exclude' -and !$selected) -or ($RoutingMode -ceq 'include' -and $selected)
        foreach ($mode in $modes) {
            $records = @($Report.probes | Where-Object { $_.executable -ceq $probe -and $_.result.mode -ceq $mode })
            if ($records.Count -ne 1) { throw 'Missing/duplicate independent probe evidence.' }
            $record = $records[0]
            $expectedSuccess = !$outage -or ($mode -ceq 'numeric' -and !$throughVpn)
            if ($record.result.success -isnot [bool] -or $record.result.success -ne $expectedSuccess) { throw 'HTTPS/DNS routing or outage requirement failed.' }
            if ($record.result.success -and $mode -ne 'dns-tun') {
                $status = if ($mode -ceq 'numeric') { 200 } else { 204 }
                if ($record.result.httpStatus -ne $status) { throw 'Unexpected HTTPS response.' }
                if ($mode -ceq 'numeric' -and $record.result.egressIpSha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Numeric HTTPS egress evidence missing.' }
            }
            if ($captured) {
                if ($record.guardArmedBefore -isnot [bool] -or !$record.guardArmedBefore -or $record.guardArmedAfter -isnot [bool] -or !$record.guardArmedAfter -or
                    $record.fixtureStopped -isnot [bool] -or $record.fixtureStopped -ne $outage -or
                    $record.fixtureNumericUploadDelta -lt 0 -or $record.fixtureNumericDownloadDelta -lt 0) { throw 'Guard/fixture evidence failed.' }
                if (!$outage -and $mode -ceq 'numeric') {
                    if ($throughVpn -and ($record.fixtureNumericUploadDelta -le 0 -or $record.fixtureNumericDownloadDelta -le 0)) { throw 'VPN numeric request did not traverse the fixture.' }
                    if (!$throughVpn -and ($record.fixtureNumericUploadDelta -ne 0 -or $record.fixtureNumericDownloadDelta -ne 0)) { throw 'DIRECT numeric request unexpectedly traversed the fixture.' }
                }
            }
        }
    }
    [pscustomobject]@{routingMode=$RoutingMode;phase=$Phase;passed=$true;independentProbeCount=2;controllerHarness=$true;installedServiceIpcTested=$false;desktopTokenIsAdmin=$Report.desktopTokenIsAdmin}
}
