# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
param([switch]$ConfirmDisposableGuest)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$inputRoot = 'C:\ExVPN-App-QA'
$outputRoot = 'C:\ExVPN-App-QA-Results'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (!$ConfirmDisposableGuest -or $identity.User.Value -eq 'S-1-5-18' -or [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -ine $inputRoot) { throw 'Disposable desktop administrator required.' }
$marker = Get-Content -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Raw | ConvertFrom-Json
if (!$marker.forbiddenHost -or $env:COMPUTERNAME -ieq $marker.forbiddenHost -or !(Test-Path -LiteralPath $outputRoot -PathType Container)) { throw 'Guest isolation failed.' }
if (![Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or $identity.Owner.Value -ne 'S-1-5-32-544') { throw 'An elevated administrator token with protected default ownership is required.' }
$common = @($marker.files | Where-Object path -CEQ 'package-common.ps1')
if ($common.Count -ne 1 -or $common[0].sha256 -cne (Get-FileHash -LiteralPath (Join-Path $inputRoot 'package-common.ps1')).Hash.ToLowerInvariant()) { throw 'Helper checksum mismatch.' }
. (Join-Path $inputRoot 'package-common.ps1')
Assert-TreeManifest $inputRoot $marker.files @('sandbox-bundle.json')
if (Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue) { throw 'Guest must start disconnected.' }
$before = Get-Content -LiteralPath 'C:\Program Files\ExVPN Installer\install-state.json' -Raw | ConvertFrom-Json
if ($before.ownerSid -cne $identity.User.Value -or $before.build -ge $marker.build) { throw 'Upgrade identity/version mismatch.' }
foreach ($process in Get-Process -Name exvpn -ErrorAction SilentlyContinue) {
    if ($process.Path -ine 'C:\Program Files\ExVPN\exvpn.exe') { throw 'An unrelated ExVPN process is running.' }
    Stop-Process -Id $process.Id -Force
    $process.WaitForExit(10000) | Out-Null
}
$install = Start-Process -FilePath (Join-Path $inputRoot 'installer.exe') -ArgumentList @('/S',('/OWNER_SID=' + $before.ownerSid),'/NETWORK_TESTING=1') -PassThru -Wait -WindowStyle Hidden
$after = Get-Content -LiteralPath 'C:\Program Files\ExVPN Installer\install-state.json' -Raw | ConvertFrom-Json
$passed = $install.ExitCode -eq 0 -and $after.build -eq $marker.build -and $after.ownerSid -ceq $before.ownerSid
[ordered]@{passed=$passed;exitCode=$install.ExitCode;upgradedFromBuild=$before.build;installedBuild=$after.build} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputRoot 'upgrade-report.json') -Encoding utf8
if (!$passed) { throw 'Development upgrade failed.' }
