#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OwnerSid,
    [Parameter(Mandatory)][string]$ClientExecutable,
    [switch]$EnableNetworkTesting
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'client-bundle.ps1')
if ($OwnerSid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { throw 'A local user account SID is required.' }
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$source = Join-Path $repository 'artifacts/windows/exvpn-service.exe'
if (!(Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Build the service first.' }
$wintun = Join-Path $repository 'artifacts/windows/wintun.dll'
$wintunNotice = Join-Path $repository 'artifacts/windows/Wintun-LICENSE.txt'
if (!(Test-Path -LiteralPath $wintunNotice -PathType Leaf)) { throw 'Pinned Wintun license notice is missing.' }
if (!(Test-Path -LiteralPath $wintun -PathType Leaf) -or (Get-AuthenticodeSignature -LiteralPath $wintun).Status -ne 'Valid') { throw 'Prepare the pinned, signed Wintun DLL first.' }
$pin = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'wintun.lock.json') -Raw | ConvertFrom-Json
if ((Get-FileHash -LiteralPath $wintun -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pin.dllSha256) { throw 'Wintun DLL does not match the reviewed pin.' }
$client = Assert-ExVpnProtectedClient $ClientExecutable
if (Get-Service -Name ExVPNService -ErrorAction SilentlyContinue) { throw 'Service already exists; use a controlled upgrade, do not overwrite a running service.' }
$installRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'ExVPN Service'
# Creating a fresh, non-reparse directory avoids following a pre-created target.
if (Test-Path -LiteralPath $installRoot) { throw 'Installation directory already exists; inspect it before a controlled upgrade.' }
New-Item -ItemType Directory -Path $installRoot | Out-Null
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)')
Set-Acl -LiteralPath $installRoot -AclObject $acl
$fileAcl = [Security.AccessControl.FileSecurity]::new()
$fileAcl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x1200a9;;;BU)')
$destination = Join-Path $installRoot 'exvpn-service.exe'
Copy-Item -LiteralPath $source -Destination $destination
Copy-Item -LiteralPath $wintun -Destination (Join-Path $installRoot 'wintun.dll')
Copy-Item -LiteralPath $wintunNotice -Destination $installRoot
# File ownership must also be privileged: an ordinary-user owner can replace
# its DACL even when the current inherited ACE grants only read/execute.
foreach ($installedFile in @($destination, (Join-Path $installRoot 'wintun.dll'), (Join-Path $installRoot 'Wintun-LICENSE.txt'))) {
    Set-Acl -LiteralPath $installedFile -AclObject $fileAcl
}
$binaryPath = '"' + $destination + '" -owner-sid ' + $OwnerSid + ' -client "' + $client + '"'
if ($EnableNetworkTesting) { $binaryPath += ' -network-testing' }
New-Service -Name ExVPNService -BinaryPathName $binaryPath -DisplayName 'ExVPN Service' -Description 'ExVPN controlled native tunnel service' -StartupType Automatic -DependsOn BFE | Out-Null
Write-Host 'Service installed but not started. Native network validation is still required.'
