# SPDX-License-Identifier: Apache-2.0
#requires -Version 5.1
param([switch]$ConfirmDisposableGuest)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$inputRoot = 'C:\ExVPN-Bootstrap-QA'
$outputRoot = 'C:\ExVPN-Bootstrap-Results'
$installRoot = 'C:\Program Files\ExVPN Bootstrap QA'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (!$ConfirmDisposableGuest -or $identity.User.Value -ne 'S-1-5-18' -or [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -ine $inputRoot) { throw 'Disposable System runner required.' }
$marker = Get-Content -LiteralPath (Join-Path $inputRoot 'sandbox-bundle.json') -Raw | ConvertFrom-Json
if (!$marker.forbiddenHost -or $env:COMPUTERNAME -ieq $marker.forbiddenHost -or !(Test-Path -LiteralPath $outputRoot -PathType Container)) { throw 'Guest isolation failed.' }
$expected = @('qa-bootstrap.exe','protected-probe.exe','package-common.ps1')
foreach ($name in $expected) {
    $records = @($marker.files | Where-Object file -CEQ $name)
    if ($records.Count -ne 1 -or $records[0].sha256 -cne (Get-FileHash -LiteralPath (Join-Path $inputRoot $name)).Hash.ToLowerInvariant()) { throw 'Input checksum mismatch.' }
}
if (Get-Process -Name qa-bootstrap -ErrorAction SilentlyContinue) { throw 'QA process already running.' }
. (Join-Path $inputRoot 'package-common.ps1')
if (!(Test-Path -LiteralPath $installRoot)) { New-Item -ItemType Directory -Path $installRoot | Out-Null; Set-ProtectedPackageACL $installRoot -Directory }
Assert-ProtectedPackage $installRoot
foreach ($name in $expected) {
    Copy-Item -LiteralPath (Join-Path $inputRoot $name) -Destination (Join-Path $installRoot $name) -Force
    Set-ProtectedPackageACL (Join-Path $installRoot $name)
}
if (Get-NetAdapter -Name 'ExVPN-Tunnel' -ErrorAction SilentlyContinue) { throw 'Guest tunnel must be disconnected.' }
$service = Get-Service ExVPNService -ErrorAction SilentlyContinue
$restoreService = $service -and $service.Status -eq 'Running'
try {
    # Prevent the idle desktop client from starting a concurrent connection.
    # The native test separately refuses existing guard filters before mutation.
    if ($restoreService) { Stop-Service ExVPNService; (Get-Service ExVPNService).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(20)) }
    & (Join-Path $installRoot 'qa-bootstrap.exe') '-test.run=TestSandboxBootstrapNetworkPolicy' '-test.v' '-test.timeout=90s' *> (Join-Path $outputRoot 'bootstrap-tests.log')
    $result = $LASTEXITCODE
} finally {
    if ($restoreService) { Start-Service ExVPNService }
}
exit $result
