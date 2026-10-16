# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Pure request/report validation, also exercised without Sandbox.
function Test-TransportTrue($Value) { $Value -is [bool] -and $Value }
function Test-TransportFalse($Value) { $Value -is [bool] -and !$Value }
function Test-TransportInteger($Value) { $Value -is [int] -or $Value -is [long] }
function Assert-TransportRunId([string]$RunId) {
    $parsed=[guid]::Empty
    if ($RunId -cnotmatch '^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$' -or ![guid]::TryParseExact($RunId,'D',[ref]$parsed) -or $parsed -eq [guid]::Empty) { throw 'transport_run_id_rejected' }
}
function Assert-TransportPreparedResults([string]$Directory,$Expected) {
    $entries=@(Get-ChildItem -LiteralPath $Directory -Force)
    if ($entries.Count -lt 1 -or $entries.Count -gt 2 -or @($entries | Where-Object { $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.Name -cnotin @('transport-reservation.json','upgrade-report.json') -or $_.Length -gt 65536 }).Count) { throw 'transport_results_already_used' }
    $reservation=Get-Content -LiteralPath (Join-Path $Directory 'transport-reservation.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($reservation.Count -ne $Expected.Count) { throw 'transport_reservation_mismatch' }
    foreach($name in $Expected.Keys) {
        if (!$reservation.Contains($name) -or $reservation[$name] -cne $Expected[$name] -or
            ((Test-TransportInteger $Expected[$name]) -and !(Test-TransportInteger $reservation[$name])) -or
            ($Expected[$name] -is [string] -and $reservation[$name] -isnot [string])) { throw 'transport_reservation_mismatch' }
    }
    $upgradePath=Join-Path $Directory 'upgrade-report.json'
    if (Test-Path -LiteralPath $upgradePath) {
        $upgrade=Get-Content -LiteralPath $upgradePath -Raw | ConvertFrom-Json -AsHashtable
        if ($upgrade.runId -cne $Expected.runId -or !(Test-TransportTrue $upgrade.passed) -or
            !(Test-TransportInteger $upgrade.exitCode) -or $upgrade.exitCode -ne 0 -or
            !(Test-TransportInteger $upgrade.installedBuild) -or $upgrade.installedBuild -ne $Expected.build -or
            !(Test-TransportInteger $upgrade.upgradedFromBuild) -or $upgrade.upgradedFromBuild -lt 1 -or $upgrade.upgradedFromBuild -ge $Expected.build) { throw 'transport_upgrade_report_mismatch' }
    }
}
function Assert-TransportMarker($Marker,[string]$HostName) {
    if ($Marker.format -ne 1 -or $Marker.forbiddenHost -ine $HostName -or !(Test-TransportTrue $Marker.unelevated) -or
        !(Test-TransportFalse $Marker.faults) -or !(Test-TransportFalse $Marker.providerMatrix) -or !(Test-TransportFalse $Marker.networkRecovery) -or
        !(Test-TransportInteger $Marker.transportCycles) -or $Marker.transportCycles -lt 3 -or $Marker.transportCycles -gt 20 -or
        $Marker.runId -cnotmatch '^[a-f0-9-]{36}$') { throw 'transport_marker_rejected' }
    Assert-TransportRunId $Marker.runId
}
function Get-TransportRequest([string]$Path,[string]$RunId,[int]$ExpectedStep,[int]$TotalSteps) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if ((Get-Item -LiteralPath $Path).Length -gt 4096) { throw 'transport_request_too_large' }
    try {
        $text=[IO.File]::ReadAllText($Path)
        $document=[Text.Json.JsonDocument]::Parse($text)
        try {
            if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object -or @($document.RootElement.EnumerateObject()).Count -ne 3) { throw 'invalid_request_fields' }
        } finally { $document.Dispose() }
        $value=$text | ConvertFrom-Json -AsHashtable
    } catch { throw 'transport_request_invalid_json' }
    if ($value.Count -ne 3 -or !$value.Contains('runId') -or !$value.Contains('step') -or !$value.Contains('action') -or
        $value.runId -cne $RunId -or $value.action -cne 'observe-disconnect' -or
        !(Test-TransportInteger $value.step) -or $value.step -lt 1 -or $value.step -gt $TotalSteps) { throw 'transport_request_rejected' }
    if ($value.step -lt $ExpectedStep) { return $null }
    if ($value.step -ne $ExpectedStep) { throw 'transport_request_out_of_order' }
    $value
}
function Assert-TransportSample($Sample,[string]$RunId,[int]$Step) {
    if ($Sample.runId -cne $RunId -or !(Test-TransportInteger $Sample.step) -or $Sample.step -ne $Step -or $Sample.action -cne 'Observe' -or
        !(Test-TransportTrue $Sample.passed) -or !(Test-TransportTrue $Sample.sameServiceProcess) -or !(Test-TransportTrue $Sample.qaBinding) -or
        !(Test-TransportTrue $Sample.serviceRunning) -or !(Test-TransportTrue $Sample.tunnelAbsent) -or !(Test-TransportFalse $Sample.guardArmed) -or !(Test-TransportTrue $Sample.networkRestored)) { throw 'transport_sample_failed' }
}
function Assert-TransportFlutter($Report,[string]$RunId,[int]$Cycles) {
    if ($Report.runId -cne $RunId -or !(Test-TransportInteger $Report.transportCycles) -or $Report.transportCycles -ne $Cycles -or
        !(Test-TransportTrue $Report.frameworkPassed) -or !(Test-TransportTrue $Report.allProtocolsPassed) -or !(Test-TransportTrue $Report.ordinaryUserTokenTested) -or
        !(Test-TransportTrue $Report.cleanupDisconnected) -or !(Test-TransportFalse $Report.nativeVpnMocked) -or !(Test-TransportFalse $Report.distinctEgressTested) -or $Report.profiles.Count -ne 3*$Cycles) { throw 'transport_flutter_failed' }
    $names=@('VLESS gRPC','VLESS XHTTP','XHTTP REALITY')
    for ($index=0; $index -lt $Report.profiles.Count; $index++) {
        $value=$Report.profiles[$index]
        if ($value.name -cne $names[$index%3] -or !(Test-TransportInteger $value.cycle) -or $value.cycle -ne [math]::Floor($index/3)+1 -or
            !(Test-TransportTrue $value.passed) -or !(Test-TransportTrue $value.explicitDisconnect) -or !(Test-TransportTrue $value.disconnectObserved) -or
            !(Test-TransportTrue $value.trafficCountersIncreased) -or $value.state -cne 'connected' -or !(Test-TransportTrue $value.numericHttps.success) -or
            $value.numericHttps.httpStatus -ne 200 -or !(Test-TransportTrue $value.tunDns.success) -or $value.hostnameHttps.httpStatus -ne 204) { throw 'transport_flutter_profile_failed' }
    }
}
