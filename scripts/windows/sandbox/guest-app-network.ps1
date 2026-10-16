# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
param(
    [Parameter(Mandatory)][ValidateSet('Prepare','Down','Up','Recover','Watchdog','Finish')][string]$Action,
    [switch]$ConfirmDisposableGuest,
    [string]$ExpectedRunId='',
    [string]$ExpectedWatchdogToken=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$inputRoot='C:\ExVPN-App-QA'
$outputRoot='C:\ExVPN-App-QA-Results'
$controlRoot='C:\Program Files\ExVPN UI QA Control'
$networkStateFile=Join-Path $controlRoot 'network-state.json'
$watchdogReadyFile=Join-Path $controlRoot 'network-watchdog-ready.json'
$serviceExe='C:\Program Files\ExVPN Service\exvpn-service.exe'
if (!$ConfirmDisposableGuest -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18' -or [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -ine $inputRoot) { throw 'Disposable System runner required.' }
$marker=Get-Content -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Raw | ConvertFrom-Json
# An earlier watchdog cannot act after the owner has staged a new session.
if ($Action -eq 'Watchdog' -and $ExpectedRunId -cne $marker.runId) { exit 0 }
if (!$marker.forbiddenHost -or $env:COMPUTERNAME -ieq $marker.forbiddenHost -or !$marker.networkRecovery -or !$marker.providerMatrix -or !$marker.unelevated -or $marker.faults -or $marker.runId -notmatch '^[a-f0-9-]{36}$') { throw 'Explicit network recovery guest marker required.' }
trap {
    [ordered]@{runId=$marker.runId;action=$Action;error='guest_network_control_failed';line=$_.InvocationInfo.ScriptLineNumber;exceptionType=$_.Exception.GetType().FullName;category=$_.CategoryInfo.Category.ToString()} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputRoot ('network-error-'+$Action+'.json')) -Encoding utf8
    exit 1
}
$common=@($marker.files | Where-Object path -CEQ 'package-common.ps1')
if ($common.Count -ne 1 -or $common[0].sha256 -cne (Get-FileHash -LiteralPath (Join-Path $inputRoot 'package-common.ps1')).Hash.ToLowerInvariant()) { throw 'Helper checksum mismatch.' }
. (Join-Path $inputRoot 'package-common.ps1')
Assert-TreeManifest $inputRoot $marker.files @('sandbox-bundle.json')
Assert-ProtectedPackage $controlRoot
$qaState=Get-Content -LiteralPath (Join-Path $controlRoot 'state.json') -Raw | ConvertFrom-Json
$service=Get-CimInstance Win32_Service -Filter "Name='ExVPNService'"
if (!$service -or $service.StartName -ne 'LocalSystem' -or ($service.PathName -cne $qaState.original -and $service.PathName -cne $qaState.qaCommand) -or (Get-FileHash -LiteralPath $serviceExe).Hash.ToLowerInvariant() -cne $qaState.serviceSha256) { throw 'Owned service identity differs.' }
function Read-Guard {
    $raw=& (Join-Path $inputRoot 'ui\qa-guard.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Guard observer failed.' }
    $guard=$raw | ConvertFrom-Json
    if ($guard.readFailed) { throw 'Guard is unreadable.' }
    [bool]$guard.guardArmed
}
function Save-ProtectedJson([string]$Path,$Value) {
    # The independent recovery watchdog must never observe a partially written
    # state. Both names are confined to the protected control directory.
    $temporary=Join-Path $controlRoot ('network-'+[Guid]::NewGuid().ToString('N')+'.tmp')
    try {
        $Value | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporary -Encoding utf8
        Set-ProtectedPackageACL $temporary
        # Windows PowerShell 5.1 coerces $null to an empty string for this
        # overload; NullString supplies the actual null backup-file argument.
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}
function Save-NetworkState($State) { Save-ProtectedJson $networkStateFile $State }
function Read-NetworkState {
    $state=Get-Content -LiteralPath $networkStateFile -Raw | ConvertFrom-Json
    $adapterGuid=[Guid]::Empty
    if ($state.runId -cne $marker.runId -or ![Guid]::TryParseExact($state.adapterGuid,'D',[ref]$adapterGuid) -or $adapterGuid -eq [Guid]::Empty -or $state.adapterIndex -lt 1) { throw 'Network state ownership mismatch.' }
    $state
}
function Owned-Adapter($State) {
    $matchesAdapter=@(Get-NetAdapter -IncludeHidden | Where-Object { ([Guid]$_.InterfaceGuid).ToString('D') -ieq $State.adapterGuid })
    if ($matchesAdapter.Count -ne 1 -or $matchesAdapter[0].ifIndex -ne $State.adapterIndex -or $matchesAdapter[0].Name -cne $State.adapterName -or $matchesAdapter[0].InterfaceDescription -cne 'Microsoft Hyper-V Network Adapter') { throw 'Recorded guest adapter changed; no guessed recovery.' }
    $matchesAdapter[0]
}
function Enable-OwnedAdapter($State) {
    $adapter=Owned-Adapter $State
    if ($adapter.Status -eq 'Disabled') { $adapter | Enable-NetAdapter -Confirm:$false }
    $deadline=[DateTime]::UtcNow.AddSeconds(25)
    do {
        $adapter=Owned-Adapter $State
        if ($adapter.Status -eq 'Up') { break }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Guest adapter did not return.' }
        Start-Sleep -Milliseconds 300
    } while ($true)
    $State.restorePending=$false
    Save-NetworkState $State
}
$report=[ordered]@{runId=$marker.runId;utc=[DateTime]::UtcNow.ToString('o');action=$Action}
switch ($Action) {
    'Prepare' {
        if ((Read-Guard) -or (Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue)) { throw 'Disconnected guest required.' }
        if (Test-Path -LiteralPath $networkStateFile) {
            $old=Get-Content -LiteralPath $networkStateFile -Raw | ConvertFrom-Json
            if ($old.restorePending) { throw 'A prior adapter recovery remains pending.' }
        }
        $adapters=@(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -ceq 'Microsoft Hyper-V Network Adapter' })
        if ($adapters.Count -ne 1) { throw 'Exactly one disposable Hyper-V adapter required.' }
        $adapter=$adapters[0]
        $state=[ordered]@{runId=$marker.runId;adapterGuid=([Guid]$adapter.InterfaceGuid).ToString('D');adapterIndex=[int]$adapter.ifIndex;adapterName=$adapter.Name;restorePending=$false;restoreDeadlineUtc='';watchdogToken='';originalUp=$true}
        Save-NetworkState $state
        $report.singleGuestAdapter=$true
        $report.adapterUp=$true
        $report.powerStates=(& powercfg.exe /a)
    }
    'Down' {
        $state=Read-NetworkState
        $adapter=Owned-Adapter $state
        if ($state.restorePending -or $adapter.Status -ne 'Up' -or $service.PathName -cne $qaState.qaCommand -or $service.State -ne 'Running' -or !(Read-Guard) -or !(Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue)) { throw 'Active owned tunnel required before network fault.' }
        $state.restorePending=$true
        $state.restoreDeadlineUtc=[DateTime]::UtcNow.AddSeconds(90).ToString('o')
        $state.watchdogToken=[Guid]::NewGuid().ToString()
        Save-NetworkState $state
        $arguments='-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ExVPN-App-QA\guest-app-network.ps1 -Action Watchdog -ConfirmDisposableGuest -ExpectedRunId '+$marker.runId+' -ExpectedWatchdogToken '+$state.watchdogToken
        $watchdog=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -WindowStyle Hidden -PassThru
        if (!$watchdog -or $watchdog.HasExited) { throw 'Adapter recovery watchdog did not start.' }
        $readyDeadline=[DateTime]::UtcNow.AddSeconds(15)
        do {
            if ($watchdog.HasExited -or [DateTime]::UtcNow -gt $readyDeadline) { throw 'Adapter recovery watchdog did not acknowledge readiness.' }
            if (Test-Path -LiteralPath $watchdogReadyFile) {
                $ready=Get-Content -LiteralPath $watchdogReadyFile -Raw | ConvertFrom-Json
                if ($ready.runId -ceq $marker.runId -and $ready.token -ceq $state.watchdogToken -and $ready.processId -eq $watchdog.Id) { break }
            }
            Start-Sleep -Milliseconds 200
        } while ($true)
        $adapter | Disable-NetAdapter -Confirm:$false
        $report.adapterDisabled=(Owned-Adapter $state).Status -eq 'Disabled'
        $report.guardArmed=Read-Guard
        $report.restoreWatchdogStarted=$true
        $report.restoreWatchdogReady=$true
        if (!$report.adapterDisabled -or !$report.guardArmed) { throw 'Adapter fault or persistent guard was not observed.' }
    }
    'Up' {
        $state=Read-NetworkState
        if (!$state.restorePending -or !(Read-Guard)) { throw 'Expected guarded adapter fault is missing.' }
        Enable-OwnedAdapter $state
        Clear-DnsClientCache
        $report.adapterUp=(Owned-Adapter $state).Status -eq 'Up'
        $report.guardArmed=Read-Guard
        $report.systemDnsCacheCleared=$true
        if (!$report.guardArmed) { throw 'Guard did not survive adapter restoration.' }
    }
    'Recover' {
        $state=Read-NetworkState
        Enable-OwnedAdapter $state
        $report.adapterUp=$true
        $report.guardArmed=Read-Guard
    }
    'Watchdog' {
        $state=Read-NetworkState
        $deadline=[DateTime]::Parse($state.restoreDeadlineUtc).ToUniversalTime()
        if (!$state.restorePending -or $ExpectedWatchdogToken -notmatch '^[a-f0-9-]{36}$' -or $ExpectedWatchdogToken -cne $state.watchdogToken -or $deadline -gt [DateTime]::UtcNow.AddSeconds(95) -or $deadline -lt [DateTime]::UtcNow) { throw 'Invalid recovery deadline or identity.' }
        Save-ProtectedJson $watchdogReadyFile ([ordered]@{runId=$marker.runId;token=$state.watchdogToken;processId=$PID})
        while ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 500
            $state=Read-NetworkState
            if (!$state.restorePending) { exit 0 }
        }
        Enable-OwnedAdapter $state
        $report.adapterUp=$true
        $report.guardArmed=Read-Guard
        $report.automaticRestore=$true
    }
    'Finish' {
        $state=Read-NetworkState
        if ($state.restorePending -or (Owned-Adapter $state).Status -ne 'Up' -or (Read-Guard) -or (Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue)) { throw 'Network QA cleanup is incomplete.' }
        $report.adapterUp=$true
        $report.originalAdapterRestored=$true
        $report.guardArmed=$false
        $report.tunnelAbsent=$true
    }
}
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $outputRoot ('network-'+$Action+'.json')) -Encoding utf8
