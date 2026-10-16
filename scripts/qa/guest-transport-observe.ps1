# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
# Read-only observer. Service control and tunnel cleanup belong to guest-app-qa.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Baseline','Connected','Observe','Finish')][string]$Action,
    [ValidateRange(0,60)][int]$Step=0,
    [switch]$ConfirmDisposableGuest
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$inputRoot='C:\ExVPN-App-QA'
$serviceExe='C:\Program Files\ExVPN Service\exvpn-service.exe'
if (!$ConfirmDisposableGuest -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne 'S-1-5-18' -or [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -ine $inputRoot) { throw 'transport_disposable_system_runner_required' }
$marker=Get-Content -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Raw | ConvertFrom-Json
if (!$marker.forbiddenHost -or $env:COMPUTERNAME -ieq $marker.forbiddenHost -or !$marker.unelevated -or $marker.faults -or $marker.providerMatrix -or $marker.networkRecovery -or $marker.transportCycles -lt 3 -or $marker.transportCycles -gt 20 -or $marker.runId -notmatch '^[a-f0-9-]{36}$') { throw 'transport_guest_marker_rejected' }
$parsedRun=[guid]::Empty
if (![guid]::TryParseExact($marker.runId,'D',[ref]$parsedRun) -or $parsedRun -eq [guid]::Empty) { throw 'transport_run_id_rejected' }
$outputRoot=Join-Path 'C:\ExVPN-Lifecycle-QA-Results' $marker.runId
if (($Action -in @('Connected','Observe') -and ($Step -lt 1 -or $Step -gt 3*$marker.transportCycles)) -or ($Action -notin @('Connected','Observe') -and $Step -ne 0)) { throw 'transport_step_rejected' }
$common=@($marker.files | Where-Object path -CEQ 'package-common.ps1')
if ($common.Count -ne 1 -or $common[0].sha256 -cne (Get-FileHash -LiteralPath (Join-Path $inputRoot 'package-common.ps1')).Hash.ToLowerInvariant()) { throw 'transport_helper_hash_mismatch' }
. (Join-Path $inputRoot 'package-common.ps1')
Assert-TreeManifest $inputRoot $marker.files @('sandbox-bundle.json')
Assert-ProtectedPackage 'C:\Program Files\ExVPN UI QA Control'
$state=Get-Content -LiteralPath 'C:\Program Files\ExVPN UI QA Control\state.json' -Raw | ConvertFrom-Json
Assert-ProtectedPackage 'C:\Program Files\ExVPN Service'
$installed=Get-Content -LiteralPath 'C:\Program Files\ExVPN Installer\install-state.json' -Raw | ConvertFrom-Json
if ($state.build -ne $marker.build -or $installed.build -ne $marker.build -or $installed.ownerSid -cne $state.ownerSid -or (Get-FileHash -LiteralPath $serviceExe).Hash.ToLowerInvariant() -cne $state.serviceSha256) { throw 'transport_service_identity_mismatch' }
Assert-TreeManifest 'C:\Program Files\ExVPN Service' $installed.trees.service

function Get-NetworkHash {
    $routes=@(Get-NetRoute | Select-Object InterfaceIndex,DestinationPrefix,NextHop,RouteMetric,Protocol,PolicyStore | Sort-Object InterfaceIndex,DestinationPrefix,NextHop,RouteMetric,Protocol,PolicyStore)
    $dns=@(Get-DnsClientServerAddress | Select-Object InterfaceIndex,AddressFamily,ServerAddresses | Sort-Object InterfaceIndex,AddressFamily)
    $json=[ordered]@{routes=$routes;dns=$dns} | ConvertTo-Json -Depth 5 -Compress
    $sha=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Read-TransportFixtureMetadata([string]$PrivateRoot,[int]$FixtureStep) {
    if ($FixtureStep -lt 1 -or $FixtureStep -gt 60) { throw 'transport_fixture_step_rejected' }
    # PS5.1 returns a JSON array as one pipeline object. Assignment preserves
    # that array; an outer @() would incorrectly wrap it in a second array.
    $fixtures=Get-Content -LiteralPath (Join-Path $PrivateRoot 'manifest.json') -Raw | ConvertFrom-Json
    $names=@('VLESS TCP','VLESS REALITY','VLESS Vision','VLESS XHTTP','XHTTP REALITY','VLESS gRPC','VMess','Shadowsocks')
    if ($fixtures.Count -ne 8 -or @($fixtures | Where-Object {$_.name -cnotin $names -or ($_.port -isnot [int] -and $_.port -isnot [long]) -or $_.port -lt 1024 -or $_.port -gt 65535}).Count -or @($fixtures.name | Sort-Object -Unique).Count -ne 8 -or @($fixtures.port | Sort-Object -Unique).Count -ne 8) { throw 'transport_fixture_metadata_rejected' }
    $ports=@($fixtures | ForEach-Object {[int]$_.port})
    $selectedName=@('VLESS gRPC','VLESS XHTTP','XHTTP REALITY')[($FixtureStep-1)%3]
    $selected=@($fixtures | Where-Object name -CEQ $selectedName)[0]
    # A generated VLESS URI supplies only the expected endpoint for this
    # read-only observer. Its credentials are never returned or logged.
    $endpoints=@()
    foreach($line in Get-Content -LiteralPath (Join-Path $PrivateRoot 'subscription.txt')) {
        if (!$line.StartsWith('vless://')) { continue }
        $uri=$null
        if (![uri]::TryCreate($line,[UriKind]::Absolute,[ref]$uri)) { throw 'transport_fixture_uri_rejected' }
        if ($uri.Port -eq $selected.port -and [uri]::UnescapeDataString($uri.Fragment.TrimStart('#')) -ceq $selectedName) { $endpoints+=@($uri.Host) }
    }
    $address=$null
    if ($endpoints.Count -ne 1 -or ![Net.IPAddress]::TryParse($endpoints[0],[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'transport_fixture_endpoint_rejected' }
    [ordered]@{ports=$ports;selectedPort=[int]$selected.port;selectedFixtureIndex=([array]::IndexOf($ports,[int]$selected.port)+1);address=$address}
}
function Read-TcpSnapshot([int]$ServiceProcessId) {
    $metadata=Read-TransportFixtureMetadata 'C:\ExVPN-App-QA-Private' $Step
    $ports=$metadata.ports
    $address=$metadata.address
    $started=[DateTime]::UtcNow
    $connections=@(Get-NetTCPConnection -ErrorAction Stop | Where-Object {$_.RemotePort -in $ports} | ForEach-Object {
        $remote=$null; $sameEndpoint=$false
        if ([Net.IPAddress]::TryParse($_.RemoteAddress,[ref]$remote)) {
            if ($remote.IsIPv4MappedToIPv6) { $remote=$remote.MapToIPv4() }
            $sameEndpoint=$remote.Equals($address)
        }
        [ordered]@{fixtureIndex=([array]::IndexOf($ports,[int]$_.RemotePort)+1);state=$_.State.ToString();owningProcess=$_.OwningProcess;ownedByService=($_.OwningProcess -eq $ServiceProcessId);ownerZero=($_.OwningProcess -eq 0);selectedEndpoint=($sameEndpoint -and $_.RemotePort -eq $metadata.selectedPort);localAddress=$_.LocalAddress;localPort=$_.LocalPort;remoteAddress=$_.RemoteAddress;remotePort=$_.RemotePort}
    })
    $ended=[DateTime]::UtcNow
    $netstatPath=Join-Path $outputRoot ('transport-netstat-'+$Action.ToLowerInvariant()+'-'+$Step+'.log')
    & (Join-Path $env:SystemRoot 'System32\netstat.exe') -ano -p tcp | Set-Content -LiteralPath $netstatPath -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'transport_netstat_observation_failed' }
    [ordered]@{runId=$marker.runId;step=$Step;action=$Action;queryStartedUtc=$started.ToString('o');queryFinishedUtc=$ended.ToString('o');servicePid=$ServiceProcessId;selectedFixtureIndex=$metadata.selectedFixtureIndex;connections=$connections} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $outputRoot ('transport-tcp-'+$Action.ToLowerInvariant()+'-'+$Step+'.json')) -Encoding utf8
    [ordered]@{selectedFixtureIndex=$metadata.selectedFixtureIndex;selectedServiceEstablishedConnections=@($connections | Where-Object {$_.selectedEndpoint -and $_.ownedByService -and $_.state -ceq 'Established'}).Count;selectedOtherOwnerEstablishedConnections=@($connections | Where-Object {$_.selectedEndpoint -and !$_.ownedByService -and $_.state -ceq 'Established'}).Count;tcpQueryMs=[int]($ended-$started).TotalMilliseconds}
}
function Read-Sample {
    $service=Get-CimInstance Win32_Service -Filter "Name='ExVPNService'"
    if (!$service -or $service.StartName -cne 'LocalSystem' -or ($service.PathName -cne $state.original -and $service.PathName -cne $state.qaCommand) -or $service.State -ne 'Running') { throw 'transport_service_not_owned_and_running' }
    $guard=& (Join-Path $inputRoot 'ui\qa-guard.exe') | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $guard.readFailed) { throw 'transport_guard_observation_failed' }
    $process=Get-Process -Id $service.ProcessId -ErrorAction Stop
    if ($process.Path -ine $serviceExe) { throw 'transport_service_pid_mismatch' }
    [ordered]@{
        runId=$marker.runId;action=$Action;step=$Step;utc=[DateTime]::UtcNow.ToString('o')
        servicePid=[int]$service.ProcessId;serviceStartedUtc=$process.StartTime.ToUniversalTime().ToString('o')
        serviceRunning=$true;qaBinding=($service.PathName -ceq $state.qaCommand);productionBinding=($service.PathName -ceq $state.original)
        tunnelAbsent=(!(Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue));guardArmed=[bool]$guard.guardArmed
        networkSha256=Get-NetworkHash
        privateBytes=[long]$process.PrivateMemorySize64;handleCount=$process.HandleCount;threadCount=$process.Threads.Count
        # These OS metrics are evidence, not a claim to enumerate Go caches.
        internalCacheObjectsObserved=$false
    }
}
$baselinePath=Join-Path $outputRoot 'transport-baseline.json'
$destination=Join-Path $outputRoot $(if ($Action -eq 'Baseline') { 'transport-baseline.json' } elseif ($Action -eq 'Finish') { 'transport-finish.json' } elseif ($Action -eq 'Connected') { 'transport-connected-'+$Step+'.json' } else { 'transport-observe-'+$Step+'.json' })
try {
    if ($Action -eq 'Baseline' -and (Test-Path -LiteralPath $baselinePath)) { throw 'transport_baseline_already_exists' }
    $sample=Read-Sample
    if ($Action -eq 'Baseline') {
        $sample.passed=$sample.qaBinding -and $sample.tunnelAbsent -and !$sample.guardArmed
    } else {
        $baseline=Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
        if ($baseline.runId -cne $marker.runId -or !$baseline.passed) { throw 'transport_stale_baseline' }
        $sample.sameServiceProcess=$sample.servicePid -eq $baseline.servicePid -and $sample.serviceStartedUtc -ceq $baseline.serviceStartedUtc
        $sample.networkRestored=$sample.networkSha256 -ceq $baseline.networkSha256
        if ($Action -in @('Connected','Observe')) {
            $tcp=Read-TcpSnapshot $sample.servicePid
            foreach($key in $tcp.Keys) { $sample[$key]=$tcp[$key] }
        }
        if ($Action -eq 'Connected') {
            $sample.passed=!$sample.tunnelAbsent -and $sample.guardArmed -and $sample.sameServiceProcess -and $sample.qaBinding -and $sample.selectedServiceEstablishedConnections -gt 0
        } else {
            $sample.passed=$sample.tunnelAbsent -and !$sample.guardArmed -and $sample.networkRestored
            if ($Action -eq 'Observe') { $sample.passed=$sample.passed -and $sample.sameServiceProcess -and $sample.qaBinding }
            else { $sample.passed=$sample.passed -and $sample.productionBinding }
        }
    }
    $sample | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $destination -Encoding utf8
    if (!$sample.passed) { exit 1 }
} catch {
    [ordered]@{runId=$marker.runId;action=$Action;step=$Step;passed=$false;error='transport_observation_failed'} | ConvertTo-Json | Set-Content -LiteralPath $destination -Encoding utf8
    exit 1
}
