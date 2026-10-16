# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Install','Launch','Inspect')][string]$Action, [switch]$ConfirmDisposableGuest)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$inputRoot = 'C:\ExVPN-Client-QA'
$outputRoot = 'C:\ExVPN-QA'
if (!$ConfirmDisposableGuest -or $env:USERNAME -cne 'WDAGUtilityAccount' -or [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -ine $inputRoot) { throw 'Disposable guest desktop required.' }
$marker = Get-Content -LiteralPath (Join-Path $inputRoot 'client-bundle.json') -Raw | ConvertFrom-Json
if (!$marker.forbiddenHost -or $env:COMPUTERNAME -ieq $marker.forbiddenHost -or !(Test-Path -LiteralPath $outputRoot -PathType Container)) { throw 'Guest isolation preflight failed.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$installer = Join-Path $inputRoot 'ExVPN-0.1.0-1-windows-x64-development.exe'
$uiRoot = 'C:\Program Files\ExVPN'
switch ($Action) {
    'Install' {
        if ((Get-Service ExVPNService -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $uiRoot)) { throw 'Clean client installation required.' }
        if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant() -cne $marker.installerSha256) { throw 'Installer checksum mismatch.' }
        $process = Start-Process -FilePath $installer -ArgumentList ('/S /NETWORK_TESTING=1 /OWNER_SID=' + $identity.User.Value) -WindowStyle Hidden -PassThru
        if (!$process.WaitForExit(180000)) { throw 'Installer timeout; guest retained for inspection.' }
        $process.Refresh()
        if ($process.ExitCode -ne 0) { throw 'Installation failed.' }
    }
    'Launch' {
        if (Get-Process -Name exvpn -ErrorAction SilentlyContinue) { throw 'Client already running.' }
        # Interactive application under the desktop account, never LocalSystem.
        Start-Process -FilePath (Join-Path $uiRoot 'exvpn.exe') -WorkingDirectory $uiRoot | Out-Null
    }
}
$state = Get-Content -LiteralPath 'C:\Program Files\ExVPN Installer\install-state.json' -Raw | ConvertFrom-Json
$service = Get-CimInstance Win32_Service -Filter "Name='ExVPNService'"
[ordered]@{utc=[DateTime]::UtcNow.ToString('o');action=$Action;installerSha256=$marker.installerSha256;serviceRunning=($service.State -eq 'Running');serviceLocalSystem=($service.StartName -eq 'LocalSystem');ownerMatchesDesktop=($state.ownerSid -ceq $identity.User.Value);networkTesting=$state.networkTesting;uiRunning=[bool](Get-Process -Name exvpn -ErrorAction SilentlyContinue);desktopTokenIsAdmin=([Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputRoot ('client-' + $Action.ToLowerInvariant() + '.json')) -Encoding UTF8
