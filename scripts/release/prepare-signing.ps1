#requires -Version 7.0
<#
.SYNOPSIS
Creates local Android signing and Shorebird beta patch keys once.
.DESCRIPTION
Private material stays under .private/signing with a restricted ACL. Passwords
and the patch private key are protected with current-user Windows DPAPI. Keep a
secure backup before distribution: DPAPI alone is not a portable backup.
Existing identities are never replaced. No certificate is installed or trusted.
#>
[CmdletBinding()]
param([string]$JavaHome = 'C:\PROGRA~1\Android\ANDROI~1\jbr')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (!$IsWindows) { throw 'This local key provisioner requires Windows DPAPI.' }
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$privateRoot = Join-Path $repository '.private/signing'
$publicRoot = Join-Path $repository 'config/signing'
$keytool = Join-Path $JavaHome 'bin/keytool.exe'
if (!(Test-Path -LiteralPath $keytool -PathType Leaf)) { throw 'Java keytool is missing.' }
$keyPaths = @('android/release.p12', 'android/store-password.dpapi', 'shorebird/beta-private.dpapi')
if ((Test-Path -LiteralPath $privateRoot) -or (Test-Path -LiteralPath $publicRoot)) {
    throw 'Signing output already exists. Preserve it; inspect or restore the existing identity instead of generating a replacement.'
}
New-Item -ItemType Directory -Path $privateRoot | Out-Null
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetOwner($identity)
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @($identity, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
}
Set-Acl -LiteralPath $privateRoot -AclObject $acl
foreach ($leaf in @('android', 'shorebird')) {
    New-Item -ItemType Directory -Path (Join-Path $privateRoot $leaf) | Out-Null
}
New-Item -ItemType Directory -Path $publicRoot | Out-Null
$rsa = [Security.Cryptography.RSA]::Create(4096)
$privateDer = $null
$passwordBytes = $null
$previousPassword = $env:EXVPN_SETUP_KEY_PASSWORD
try {
    $privateDer = $rsa.ExportPkcs8PrivateKey()
    $protectedKey = [Security.Cryptography.ProtectedData]::Protect(
        $privateDer, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllBytes((Join-Path $privateRoot 'shorebird/beta-private.dpapi'), $protectedKey)
    [IO.File]::WriteAllText((Join-Path $publicRoot 'shorebird-beta-public.pem'),
        $rsa.ExportSubjectPublicKeyInfoPem() + "`n", [Text.UTF8Encoding]::new($false))

    $passwordBytes = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    $env:EXVPN_SETUP_KEY_PASSWORD = [Convert]::ToBase64String($passwordBytes)
    $passwordUtf8 = [Text.Encoding]::UTF8.GetBytes($env:EXVPN_SETUP_KEY_PASSWORD)
    try {
        [IO.File]::WriteAllBytes((Join-Path $privateRoot 'android/store-password.dpapi'),
            [Security.Cryptography.ProtectedData]::Protect($passwordUtf8, $null,
                [Security.Cryptography.DataProtectionScope]::CurrentUser))
    } finally { [Security.Cryptography.CryptographicOperations]::ZeroMemory($passwordUtf8) }
    $storePath = Join-Path $privateRoot 'android/release.p12'
    $keyArguments = @('-keystore', $storePath, '-storetype', 'PKCS12', '-alias', 'exvpn',
        '-storepass:env', 'EXVPN_SETUP_KEY_PASSWORD')
    & $keytool '-genkeypair' @keyArguments '-keypass:env' 'EXVPN_SETUP_KEY_PASSWORD' `
        '-keyalg' 'RSA' '-keysize' '3072' '-validity' '10000' '-dname' 'CN=ExVPN' '-noprompt' `
        *> (Join-Path $privateRoot 'android/keytool-private.log')
    if ($LASTEXITCODE -ne 0) { throw 'Android key generation failed; preserve private output for inspection.' }
    & $keytool '-exportcert' @keyArguments '-rfc' '-file' (Join-Path $publicRoot 'android-release-cert.pem') `
        *> (Join-Path $privateRoot 'android/export-private.log')
    if ($LASTEXITCODE -ne 0) { throw 'Android public certificate export failed.' }
} finally {
    $env:EXVPN_SETUP_KEY_PASSWORD = $previousPassword
    if ($privateDer) { [Security.Cryptography.CryptographicOperations]::ZeroMemory($privateDer) }
    if ($passwordBytes) { [Security.Cryptography.CryptographicOperations]::ZeroMemory($passwordBytes) }
    $rsa.Dispose()
}
foreach ($relative in $keyPaths) {
    if (!(Get-Item -LiteralPath (Join-Path $privateRoot $relative)).Length) { throw 'Incomplete signing identity.' }
}
[pscustomobject]@{
    PrivateDirectory = $privateRoot
    AndroidCertificate = Join-Path $publicRoot 'android-release-cert.pem'
    ShorebirdPublicKey = Join-Path $publicRoot 'shorebird-beta-public.pem'
    ProtectedBy = 'Restricted ACL; Windows current-user DPAPI for passwords and patch key'
    CloudActions = 0
}
