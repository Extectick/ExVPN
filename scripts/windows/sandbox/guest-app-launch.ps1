# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
param([switch]$ConfirmDisposableGuest)
$ErrorActionPreference = 'Stop'
$inputRoot = 'C:\ExVPN-App-QA'
$outputRoot = 'C:\ExVPN-App-QA-Results'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$marker = Get-Content -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Raw | ConvertFrom-Json
if (!$ConfirmDisposableGuest -or $identity.User.Value -eq 'S-1-5-18' -or $env:COMPUTERNAME -ieq $marker.forbiddenHost -or [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -ine $inputRoot) { throw 'Disposable interactive user runner required.' }
$state = Get-Content -LiteralPath 'C:\Program Files\ExVPN UI QA Control\state.json' -Raw | ConvertFrom-Json
if ($identity.User.Value -cne $state.ownerSid -or (Get-Process -Name exvpn -ErrorAction SilentlyContinue)) { throw 'QA desktop identity/state mismatch.' }
$admin = [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
[ordered]@{desktopUser=$true;administratorToken=$admin} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputRoot 'launch-report.json') -Encoding utf8
# Visible application is intentional; test input is synthesized inside Flutter.
$process = Start-Process -FilePath 'C:\Program Files\ExVPN UI QA\exvpn.exe' -PassThru -WindowStyle Normal
if (!$process.WaitForExit(1200000)) { Stop-Process -Id $process.Id; throw 'Bounded Flutter test deadline exceeded.' }
[ordered]@{exitCode=$process.ExitCode} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputRoot 'exit-report.json') -Encoding utf8
exit $process.ExitCode
