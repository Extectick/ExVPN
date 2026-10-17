# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare','Refresh','Start','Probe','ClearDns','Crash','Recover','Inspect')][string]$Action,
    [ValidateSet('baseline','connected','connected-cold','outage','outage-cold','disconnected','crashed')][string]$Phase = 'baseline',
    [ValidateSet('disabled','exclude','include')][string]$RoutingMode = 'exclude',
    [switch]$ConfirmDisposableGuest
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$inputRoot = 'C:\ExVPN-System-QA'
$outputRoot = 'C:\ExVPN-QA'
$installRoot = 'C:\Program Files\ExVPN System QA'
if (!$ConfirmDisposableGuest -or [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -ine $inputRoot) { throw 'Explicit disposable guest required.' }
$bundle = Get-Content -LiteralPath 'C:\ExVPN-Package\sandbox-bundle.json' -Raw | ConvertFrom-Json
if ($bundle.format -ne 1 -or !$bundle.forbiddenHost -or $env:COMPUTERNAME -ieq $bundle.forbiddenHost -or !(Test-Path -LiteralPath $outputRoot -PathType Container)) { throw 'Isolation preflight failed.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($Action -ne 'Probe' -and $identity.User.Value -ne 'S-1-5-18') { throw 'System guest runner required.' }
if ($Action -eq 'Probe' -and $env:USERNAME -cne 'WDAGUtilityAccount') { throw 'Guest desktop probe account required.' }
if ($bundle.PSObject.Properties['routingModes']) {
    if (($bundle.routingModes -join ',') -cne 'disabled,exclude,include' -or !$bundle.controllerHarness -or $bundle.installedServiceIpcTested) { throw 'Three-mode controller marker required.' }
    foreach ($name in @('qa-manifest.json','guest-system-qa.ps1')) {
        $records = @($bundle.files | Where-Object file -CEQ $name)
        if ($records.Count -ne 1 -or $records[0].sha256 -cne (Get-FileHash -LiteralPath (Join-Path $inputRoot $name)).Hash.ToLowerInvariant()) { throw 'Guest runner/manifest checksum mismatch.' }
    }
}
$manifest = Get-Content -LiteralPath (Join-Path $inputRoot 'qa-manifest.json') -Raw | ConvertFrom-Json
$commonRecord = @($manifest.files | Where-Object file -CEQ 'package-common.ps1')
if ($commonRecord.Count -ne 1 -or $commonRecord[0].sha256 -cne (Get-FileHash -LiteralPath (Join-Path $inputRoot 'package-common.ps1')).Hash.ToLowerInvariant()) { throw 'Protected-package helper checksum mismatch.' }
. (Join-Path $inputRoot 'package-common.ps1')
if ($Action -ne 'Prepare') { Assert-ProtectedPackage $installRoot }
function Save-Report([string]$Name, $Value) {
    if ($bundle.PSObject.Properties['runId']) { $Value.runId = $bundle.runId }
    $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outputRoot $Name) -Encoding UTF8
}
function Get-NativeReport {
    $path = Join-Path $outputRoot 'native-network.json'
    if (!(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -gt 65536) { throw 'Native report unavailable.' }
    $native = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($native.routingMode -cne $RoutingMode -or !$native.controllerHarness -or $native.installedServiceIpcTested -or $native.phase -cne 'running' -or $native.guardReadFailed -or !$native.guardArmed) { throw 'Guarded native harness report required.' }
    if ($bundle.PSObject.Properties['runId'] -and $native.runId -cne $bundle.runId) { throw 'Native run identity mismatch.' }
    $native
}
function Wait-NativeSnapshot([long]$AfterSequence) {
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $native = Get-NativeReport
        if ([long]$native.sequence -gt $AfterSequence) { return $native }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Fresh native snapshot timed out.'
}
function Get-NetworkFingerprint {
    $routes = @(Get-NetRoute | Select-Object InterfaceIndex,DestinationPrefix,NextHop,RouteMetric,Protocol,PolicyStore | Sort-Object InterfaceIndex,DestinationPrefix,NextHop)
    $dns = @(Get-DnsClientServerAddress | Select-Object InterfaceIndex,AddressFamily,ServerAddresses | Sort-Object InterfaceIndex,AddressFamily)
    $bytes = [Text.Encoding]::UTF8.GetBytes(([ordered]@{routes=$routes;dns=$dns} | ConvertTo-Json -Depth 5 -Compress))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
switch ($Action) {
    'Refresh' {
        if ((Get-Process -Name 'qa-system' -ErrorAction SilentlyContinue) -or (Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue)) { throw 'Test process/adapter must be stopped before refresh.' }
        $record = @($manifest.files | Where-Object file -CEQ 'qa-system.exe')
        if ($record.Count -ne 1 -or $record[0].sha256 -cne (Get-FileHash -LiteralPath (Join-Path $inputRoot 'qa-system.exe') -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Harness checksum mismatch.' }
        Copy-Item -LiteralPath (Join-Path $inputRoot 'qa-system.exe') -Destination (Join-Path $installRoot 'qa-system.exe') -Force
        Set-ProtectedPackageACL (Join-Path $installRoot 'qa-system.exe')
    }
    'Prepare' {
        if (Test-Path -LiteralPath $installRoot) { throw 'Test installation already exists.' }
        if ((Get-Service ExVPNService -ErrorAction SilentlyContinue) -or (Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue)) { throw 'Clean disposable guest required.' }
        $expected = @('qa-system.exe','protected-probe.exe','excluded-probe.exe','wintun.dll','exvpn-service.exe','package-common.ps1')
        if ($manifest.files.Count -ne $expected.Count) { throw 'Unexpected manifest.' }
        foreach ($name in $expected) {
            $records = @($manifest.files | Where-Object file -CEQ $name)
            if ($records.Count -ne 1 -or $records[0].sha256 -cne (Get-FileHash -LiteralPath (Join-Path $inputRoot $name) -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Test input checksum mismatch.' }
        }
        if ((Get-AuthenticodeSignature -LiteralPath (Join-Path $inputRoot 'wintun.dll')).Status -ne 'Valid') { throw 'Wintun signature invalid.' }
        New-Item -ItemType Directory -Path $installRoot | Out-Null
        Set-ProtectedPackageACL $installRoot -Directory
        foreach ($name in $expected) {
            Copy-Item -LiteralPath (Join-Path $inputRoot $name) -Destination (Join-Path $installRoot $name)
            Set-ProtectedPackageACL (Join-Path $installRoot $name)
        }
        Assert-ProtectedPackage $installRoot
        Save-Report 'prepared.json' ([ordered]@{status='prepared';utc=[DateTime]::UtcNow.ToString('o');networkBeforeSha256=(Get-NetworkFingerprint)})
    }
    'Start' {
        if (Get-Process -Name 'qa-system' -ErrorAction SilentlyContinue) { throw 'Test process already running.' }
        if ((Get-Service ExVPNService -ErrorAction SilentlyContinue) -or (Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue)) { throw 'Clean controller-only guest required.' }
        $pendingCommand = [IO.File]::ReadAllText((Join-Path $inputRoot 'command.txt'))
        if ($pendingCommand.Trim()) { throw 'Clear the host-owned command before starting a mode.' }
        foreach ($name in @('native-network.json','guard-inspection.json')) {
            $path = Join-Path $outputRoot $name
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
        }
        $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1
        if (!$route) { throw 'Guest default route missing.' }
        $process = Start-Process -FilePath (Join-Path $installRoot 'qa-system.exe') -ArgumentList ('-confirm-disposable-guest -interface-index ' + [int]$route.InterfaceIndex + ' -routing-mode ' + $RoutingMode) -WorkingDirectory $installRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $outputRoot ('harness-'+$RoutingMode+'-stdout.txt')) -RedirectStandardError (Join-Path $outputRoot ('harness-'+$RoutingMode+'-stderr.txt'))
        Save-Report 'process.json' ([ordered]@{pid=$process.Id;routingMode=$RoutingMode;utc=[DateTime]::UtcNow.ToString('o');controllerHarness=$true;installedServiceIpcTested=$false})
    }
    'Probe' {
        $results = @()
        $captured = $Phase -in @('connected','connected-cold','outage','outage-cold')
        $probeModes = @('numeric','health')
        if ($captured) { $probeModes += 'dns-tun' }
        foreach ($probe in @('protected-probe.exe','excluded-probe.exe')) {
            foreach ($mode in $probeModes) {
                $before = $null; $after = $null
                if ($captured) { $before = Get-NativeReport }
                $output = & (Join-Path $installRoot $probe) -mode $mode
                if ($LASTEXITCODE -ne 0) { throw 'Probe process failed.' }
                if ($captured) {
                    # Read the sequence after process exit, then wait another
                    # publication. The numeric counters have no health traffic.
                    $last = Get-NativeReport
                    $after = Wait-NativeSnapshot ([long]$last.sequence)
                }
                $record = [ordered]@{executable=$probe;result=($output | ConvertFrom-Json)}
                if ($captured) {
                    $record.fixtureNumericUploadDelta = [long]$after.numericuplink - [long]$before.numericuplink
                    $record.fixtureNumericDownloadDelta = [long]$after.numericdownlink - [long]$before.numericdownlink
                    $record.guardArmedBefore = [bool]$before.guardArmed
                    $record.guardArmedAfter = [bool]$after.guardArmed
                    $record.fixtureStopped = [bool]$after.fixtureStopped
                }
                $results += $record
            }
        }
        Save-Report ('probes-' + $RoutingMode + '-' + $Phase + '.json') ([ordered]@{routingMode=$RoutingMode;phase=$Phase;utc=[DateTime]::UtcNow.ToString('o');controllerHarness=$true;installedServiceIpcTested=$false;desktopTokenIsAdmin=([Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator));probes=$results})
    }
    'ClearDns' {
        Clear-DnsClientCache
        Save-Report 'dns-cache-cleared.json' ([ordered]@{utc=[DateTime]::UtcNow.ToString('o');cleared=$true})
    }
    'Crash' {
        $processes = @(Get-Process -Name 'qa-system' -ErrorAction Stop)
        if ($processes.Count -ne 1 -or $processes[0].Path -ine (Join-Path $installRoot 'qa-system.exe')) { throw 'Unexpected test process.' }
        Stop-Process -InputObject $processes[0] -Force
        Save-Report 'crashed.json' ([ordered]@{utc=[DateTime]::UtcNow.ToString('o');controllerProcessTerminated=$true;installedScmCrashTested=$false})
    }
    'Recover' {
        if (Get-Process -Name 'qa-system' -ErrorAction SilentlyContinue) { throw 'Test process must be stopped first.' }
        & (Join-Path $installRoot 'exvpn-service.exe') recover-guard
        if ($LASTEXITCODE -ne 0) { throw 'Owned guard recovery failed.' }
    }
    'Inspect' {
        # Disconnect publishes its receipt just before process teardown. Wait
        # for that owned process to finish rather than racing the final Close.
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while ((Get-Process -Name 'qa-system' -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        & (Join-Path $installRoot 'qa-system.exe') -confirm-disposable-guest -inspect-guard
        if ($LASTEXITCODE -ne 0) { throw 'Guard inspection failed.' }
        Save-Report ('inspection-'+$RoutingMode+'.json') ([ordered]@{routingMode=$RoutingMode;utc=[DateTime]::UtcNow.ToString('o');harnessRunning=[bool](Get-Process -Name 'qa-system' -ErrorAction SilentlyContinue);adapterPresent=[bool](Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue);networkSha256=(Get-NetworkFingerprint);servicePresent=[bool](Get-Service ExVPNService -ErrorAction SilentlyContinue)})
    }
}
