# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.6
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Export','Verify','Restore')][string]$Mode,
    [Parameter(Mandatory)][string]$BackupDirectory,
    [string]$RestoreDirectory,
    [Security.SecureString]$Password
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (!$IsWindows -or [Environment]::Version.Major -lt 10) { throw 'Requires Windows, PowerShell 7.6 and .NET 10.' }
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$source = Join-Path $repository '.private/signing'
$certificate = Join-Path $repository 'config/signing/android-release-cert.pem'
$publicKey = Join-Path $repository 'config/signing/shorebird-beta-public.pem'
function Assert-PlainPath([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Signing paths must not contain a link or junction.'
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}
function New-PrivateDirectory([string]$Path) {
    Assert-PlainPath $Path
    $projectPrefix = $repository.TrimEnd('\') + '\'
    $privatePrefix = (Join-Path $repository '.private').TrimEnd('\') + '\'
    if ($Path.StartsWith($projectPrefix,[StringComparison]::OrdinalIgnoreCase) -and !$Path.StartsWith($privatePrefix,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Inside the repository, signing outputs must stay under .private.'
    }
    if (Test-Path -LiteralPath $Path) { throw 'Destination exists; signing material is never overwritten.' }
    if (!(Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($Path)) -PathType Container)) { throw 'Destination parent must exist.' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($sid); $acl.SetAccessRuleProtection($true, $false)
    foreach ($owner in @($sid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($owner,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    # Establish the ACL before writing any key material.
    [IO.Directory]::CreateDirectory($Path) | Out-Null
    Set-Acl -LiteralPath $Path -AclObject $acl
}
$backup = [IO.Path]::GetFullPath($BackupDirectory)
foreach ($path in @($backup,$source,$certificate,$publicKey)) { Assert-PlainPath $path }
if ($Mode -eq 'Export' -and (Test-Path -LiteralPath $backup)) { throw 'Backup destination exists.' }
if ($Mode -eq 'Restore') {
    if (!$RestoreDirectory) { throw 'Restore requires a new RestoreDirectory; existing keys are never replaced.' }
    $restore = [IO.Path]::GetFullPath($RestoreDirectory)
    Assert-PlainPath $restore
    if (Test-Path -LiteralPath $restore) { throw 'Restore destination exists.' }
}
if (!$Password) { $Password = Read-Host 'Backup passphrase (16+ characters; keep separately)' -AsSecureString }
if ($Password.Length -lt 16 -or $Password.Length -gt 1024) { throw 'Use a backup passphrase of 16 to 1024 characters.' }
if (!('ExVpnSigningBackup' -as [type])) {
    $references = @(Get-ChildItem (Join-Path $PSHOME 'ref') -Filter '*.dll' | ForEach-Object FullName) + @([Security.Cryptography.ProtectedData].Assembly.Location,[Security.Cryptography.Pkcs.Pkcs12Builder].Assembly.Location)
    Add-Type -Path (Join-Path $PSScriptRoot 'SigningBackup.cs') -ReferencedAssemblies $references
}
try {
    switch ($Mode) {
        Export {
            New-PrivateDirectory $backup
            [ExVpnSigningBackup]::Export($source,$backup,$certificate,$publicKey,$Password)
        }
        Verify { [ExVpnSigningBackup]::Verify($backup,$certificate,$publicKey,$Password) }
        Restore {
            # Validate the whole backup before creating a restoration directory.
            [ExVpnSigningBackup]::Verify($backup,$certificate,$publicKey,$Password)
            New-PrivateDirectory $restore
            [ExVpnSigningBackup]::Restore($backup,$restore,$certificate,$publicKey,$Password)
        }
    }
} catch { throw 'Signing backup operation failed. Existing identities are preserved. Check the passphrase, trusted public keys and destination; partial new outputs are not a verified backup.' }
[pscustomobject]@{status='PASS';operation=$Mode;privateKeysLogged=$false;existingKeysReplaced=$false;publicIdentityVerified=$true}
