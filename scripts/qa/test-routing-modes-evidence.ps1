# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'routing-modes-evidence.ps1')
$runId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
$checks = 0
function New-Evidence([string]$Mode,[string]$Phase,[bool]$ProtectedVpn,[bool]$SelectedVpn) {
    $captured = $Phase -in @('connected-cold','outage-cold')
    $outage = $Phase -ceq 'outage-cold'
    $probes = @()
    foreach ($spec in @(@('protected-probe.exe',$ProtectedVpn),@('excluded-probe.exe',$SelectedVpn))) {
        foreach ($probeMode in @('numeric','health','dns-tun')) {
            if (!$captured -and $probeMode -ceq 'dns-tun') { continue }
            $success = if ($outage) { $probeMode -ceq 'numeric' -and !$spec[1] } else { $true }
            $result = [ordered]@{mode=$probeMode;success=[bool]$success}
            if ($success -and $probeMode -cne 'dns-tun') {
                $result.httpStatus = if ($probeMode -ceq 'numeric') { 200 } else { 204 }
                $result.egressIpSha256 = 'a' * 64
            }
            $probes += [ordered]@{executable=$spec[0];result=$result;guardArmedBefore=$true;guardArmedAfter=$true;fixtureStopped=$outage;fixtureNumericUploadDelta=$(if ($captured -and !$outage -and $probeMode -ceq 'numeric' -and $spec[1]) { 500 } else { 0 });fixtureNumericDownloadDelta=$(if ($captured -and !$outage -and $probeMode -ceq 'numeric' -and $spec[1]) { 800 } else { 0 })}
        }
    }
    [ordered]@{runId=$runId;routingMode=$Mode;phase=$Phase;controllerHarness=$true;installedServiceIpcTested=$false;desktopTokenIsAdmin=$false;probes=$probes} | ConvertTo-Json -Depth 8 | ConvertFrom-Json
}
function Reject([string]$Name,[scriptblock]$Mutation,[string]$Mode='exclude',[string]$Phase='connected-cold') {
    $value = New-Evidence $Mode $Phase ($Mode -ne 'include') ($Mode -ne 'exclude')
    & $Mutation $value
    $rejected = $false
    try { $null = Assert-RoutingModeEvidence $value $Mode $Phase $runId } catch { $rejected = $true }
    if (!$rejected) { throw "Accepted invalid routing evidence: $Name" }
    $script:checks++
}
# These concrete rows are the independent contract, not inferred from results.
foreach ($case in @(@('disabled',$true,$true),@('exclude',$true,$false),@('include',$false,$true))) {
    foreach ($phase in @('baseline','connected-cold','outage-cold','disconnected')) {
        $evidence = New-Evidence $case[0] $phase $case[1] $case[2]
        $verified = Assert-RoutingModeEvidence $evidence $case[0] $phase $runId
        if (!$verified.passed -or $verified.installedServiceIpcTested) { throw 'Valid matrix case rejected/misreported.' }
        $checks++
    }
}
Reject 'missing independent process' { param($v) $v.probes = @($v.probes | Where-Object executable -CEQ 'protected-probe.exe') }
Reject 'duplicate result' { param($v) $v.probes[3] = $v.probes[0] }
Reject 'guard absent before request' { param($v) $v.probes[0].guardArmedBefore = $false }
Reject 'guard absent after request' { param($v) $v.probes[0].guardArmedAfter = $false }
Reject 'fixture stopped in connected phase' { param($v) $v.probes[0].fixtureStopped = $true }
Reject 'VPN counter missing' { param($v) $v.probes[0].fixtureNumericUploadDelta = 0 }
Reject 'VPN has no download' { param($v) $v.probes[0].fixtureNumericDownloadDelta = 0 }
Reject 'DIRECT request traversed VPN' { param($v) $v.probes[3].fixtureNumericUploadDelta = 100 }
Reject 'negative counter delta' { param($v) $v.probes[3].fixtureNumericDownloadDelta = -1 }
Reject 'blocked selected DIRECT' { param($v) $v.probes[3].result.success = $false } 'exclude' 'outage-cold'
Reject 'protected numeric fallback' { param($v) $v.probes[0].result.success = $true } 'exclude' 'outage-cold'
Reject 'selected include fallback' { param($v) $v.probes[3].result.success = $true } 'include' 'outage-cold'
Reject 'TUN DNS fallback' { param($v) $v.probes[5].result.success = $true } 'include' 'outage-cold'
Reject 'warm/cached DNS health masked outage' { param($v) $v.probes[4].result.success = $true } 'exclude' 'outage-cold'
Reject 'wrong numeric HTTPS status' { param($v) $v.probes[0].result.httpStatus = 204 }
Reject 'missing egress digest' { param($v) $v.probes[0].result.egressIpSha256 = '' }
Reject 'untruthful installed IPC coverage' { param($v) $v.installedServiceIpcTested = $true }
Reject 'foreign run' { param($v) $v.runId = 'bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee' }
Reject 'wrong mode' { param($v) $v.routingMode = 'include' }
Reject 'string success instead of bool' { param($v) $v.probes[0].result.success = 'true' }
Write-Host "Routing evidence checks passed: $checks (synthetic only; no network or guest execution)."
