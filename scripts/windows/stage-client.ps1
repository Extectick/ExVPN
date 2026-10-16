# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceExecutable,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'client-bundle.ps1')
$source = (Resolve-Path -LiteralPath $SourceExecutable).Path
if ([IO.Path]::GetFileName($source) -ne 'exvpn.exe') { throw 'Select exvpn.exe from the built Flutter bundle.' }
$sourceRoot = [IO.Path]::GetDirectoryName($source)
$files = @(Get-ExVpnBundleFiles $sourceRoot)
$bytes = ($files | Measure-Object Length -Sum).Sum
if ($bytes -gt 1GB) { throw 'UI bundle exceeds the controlled staging size limit.' }
if ($CheckOnly) { Write-Host "UI bundle preflight passed: $($files.Count) files. No files installed."; return }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run staging from an administrator PowerShell.' }
$destinationRoot = Join-Path (Get-ExVpnProgramFiles) 'ExVPN'
if (Test-Path -LiteralPath $destinationRoot) { throw 'UI installation exists. Controlled upgrade is a separate operation.' }
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)')
$fileAcl = [Security.AccessControl.FileSecurity]::new()
$fileAcl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x1200a9;;;BU)')
New-Item -ItemType Directory -Path $destinationRoot | Out-Null
Set-Acl -LiteralPath $destinationRoot -AclObject $acl
$manifest = @()
foreach ($file in $files) {
    $relative = $file.FullName.Substring($sourceRoot.TrimEnd([IO.Path]::DirectorySeparatorChar).Length + 1)
    $target = [IO.Path]::GetFullPath((Join-Path $destinationRoot $relative))
    if (!$target.StartsWith($destinationRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'UI copy escaped installation root.' }
    New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($target)) | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $target
    Set-Acl -LiteralPath $target -AclObject $fileAcl
    $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest += [ordered]@{ path = $relative; sha256 = $hash }
}
$manifest | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $destinationRoot 'installed-files.json') -Encoding utf8
Set-Acl -LiteralPath (Join-Path $destinationRoot 'installed-files.json') -AclObject $fileAcl
foreach ($directory in Get-ChildItem -LiteralPath $destinationRoot -Directory -Recurse -Force) {
    Set-Acl -LiteralPath $directory.FullName -AclObject $acl
}
$installed = Assert-ExVpnProtectedClient (Join-Path $destinationRoot 'exvpn.exe')
Write-Host "UI bundle staged under protected Program Files. Service not installed or started: $installed"
