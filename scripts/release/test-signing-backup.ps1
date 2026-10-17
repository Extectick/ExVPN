# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (!$IsWindows -or [Environment]::Version.Major -lt 10) { throw 'Signing backup fixtures require Windows/PowerShell 7.6/.NET 10.' }
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture = Join-Path $repository ('.private/signing-backup-fixtures-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $fixture '.private/signing'
$public = Join-Path $fixture 'config/signing'
$scripts = Join-Path $fixture 'scripts/release'
foreach ($path in @((Join-Path $source 'android'),(Join-Path $source 'shorebird'),$public,$scripts)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
foreach ($file in @('signing-backup.ps1','SigningBackup.cs')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $scripts }
$certificatePath = Join-Path $public 'android-release-cert.pem'
$patchPublicPath = Join-Path $public 'shorebird-beta-public.pem'
$android = [Security.Cryptography.RSA]::Create(3072)
$patch = [Security.Cryptography.RSA]::Create(4096)
$request = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=ExVPN synthetic fixture',$android,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
$certificate = $request.CreateSelfSigned([datetimeoffset]::UtcNow.AddDays(-1),[datetimeoffset]::UtcNow.AddDays(1))
$originalPassword = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$backupPasswordText = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$backupPassword = ConvertTo-SecureString $backupPasswordText -AsPlainText -Force
$wrongPassword = ConvertTo-SecureString ('incorrect-' + [guid]::NewGuid()) -AsPlainText -Force
function Write-Protected([string]$Path,[byte[]]$Bytes) {
    try { [IO.File]::WriteAllBytes($Path,[Security.Cryptography.ProtectedData]::Protect($Bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)) }
    finally { [Security.Cryptography.CryptographicOperations]::ZeroMemory($Bytes) }
}
[IO.File]::WriteAllBytes((Join-Path $source 'android/release.p12'),$certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12,$originalPassword))
Write-Protected (Join-Path $source 'android/store-password.dpapi') ([Text.Encoding]::UTF8.GetBytes($originalPassword))
Write-Protected (Join-Path $source 'shorebird/beta-private.dpapi') ($patch.ExportPkcs8PrivateKey())
[IO.File]::WriteAllText($certificatePath,$certificate.ExportCertificatePem())
[IO.File]::WriteAllText($patchPublicPath,$patch.ExportSubjectPublicKeyInfoPem())
$originalHashes = @(Get-ChildItem $source -File -Recurse | Get-FileHash | ForEach-Object Hash)
$checks = 0
function Expect-Failure([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (!$failed) { throw 'Expected signing backup refusal.' }
    $script:checks++
}
$wrapper = Join-Path $scripts 'signing-backup.ps1'
$backup = Join-Path $fixture '.private/portable'
$restored = Join-Path $fixture '.private/restored'
try {
    $result = & $wrapper -Mode Export -BackupDirectory $backup -Password $backupPassword
    if ($result.status -ne 'PASS' -or @((Get-ChildItem $backup -File)).Count -ne 2) { throw 'Export verification failed.' }; $checks++
    $result = & $wrapper -Mode Verify -BackupDirectory $backup -Password $backupPassword
    if ($result.status -ne 'PASS') { throw 'Fresh import verification failed.' }; $checks++
    Expect-Failure { & $wrapper -Mode Verify -BackupDirectory $backup -Password $wrongPassword }
    Expect-Failure { & $wrapper -Mode Export -BackupDirectory $backup -Password $backupPassword }
    Expect-Failure { & $wrapper -Mode Export -BackupDirectory (Join-Path $fixture 'tracked-output') -Password $backupPassword }
    Expect-Failure { & $wrapper -Mode Verify -BackupDirectory $backup -Password (ConvertTo-SecureString 'short' -AsPlainText -Force) }
    Expect-Failure { & $wrapper -Mode Restore -BackupDirectory $backup -RestoreDirectory $source -Password $backupPassword }
    $failedDestination = Join-Path $fixture '.private/must-not-exist'
    Expect-Failure { & $wrapper -Mode Restore -BackupDirectory $backup -RestoreDirectory $failedDestination -Password $wrongPassword }
    if (Test-Path $failedDestination) { throw 'Invalid backup created restore directory.' }; $checks++
    $publicBytes = [IO.File]::ReadAllBytes($patchPublicPath)
    [IO.File]::WriteAllText($patchPublicPath,$android.ExportSubjectPublicKeyInfoPem())
    Expect-Failure { & $wrapper -Mode Verify -BackupDirectory $backup -Password $backupPassword }
    [IO.File]::WriteAllBytes($patchPublicPath,$publicBytes)
    $certificateBytes = [IO.File]::ReadAllBytes($certificatePath)
    $otherRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Wrong identity',$android,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $otherCertificate = $otherRequest.CreateSelfSigned([datetimeoffset]::UtcNow.AddDays(-1),[datetimeoffset]::UtcNow.AddDays(1))
    try { [IO.File]::WriteAllText($certificatePath,$otherCertificate.ExportCertificatePem()) } finally { $otherCertificate.Dispose() }
    Expect-Failure { & $wrapper -Mode Verify -BackupDirectory $backup -Password $backupPassword }
    [IO.File]::WriteAllBytes($certificatePath,$certificateBytes)
    $keyFile = Join-Path $backup 'shorebird-beta.pk8'; $keyBytes = [IO.File]::ReadAllBytes($keyFile)
    $damaged = [byte[]]$keyBytes.Clone(); $damaged[-1] = $damaged[-1] -bxor 1; [IO.File]::WriteAllBytes($keyFile,$damaged)
    Expect-Failure { & $wrapper -Mode Verify -BackupDirectory $backup -Password $backupPassword }
    [IO.File]::WriteAllBytes($keyFile,$keyBytes)
    [IO.File]::WriteAllBytes($keyFile,[byte[]]@(1,2,3))
    Expect-Failure { & $wrapper -Mode Verify -BackupDirectory $backup -Password $backupPassword }
    [IO.File]::WriteAllBytes($keyFile,$keyBytes)
    $result = & $wrapper -Mode Restore -BackupDirectory $backup -RestoreDirectory $restored -Password $backupPassword
    if ($result.status -ne 'PASS') { throw 'Restoration failed.' }; $checks++
    # Restore uses new DPAPI ciphertext; re-export proves both recovered keys.
    $second = Join-Path $fixture 'second'; New-Item -ItemType Directory $second | Out-Null
    [ExVpnSigningBackup]::Export($restored,$second,$certificatePath,$patchPublicPath,$backupPassword); $checks++
    $acl = Get-Acl $backup; $allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18')
    if (!$acl.AreAccessRulesProtected -or @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object {$_.IdentityReference.Value -notin $allowed}).Count) { throw 'Backup ACL too broad.' }; $checks++
    if ((@(Get-ChildItem $source -File -Recurse | Get-FileHash | ForEach-Object Hash) -join ',') -cne ($originalHashes -join ',')) { throw 'Source identity was changed.' }; $checks++
    $keytool = 'C:\PROGRA~1\Android\ANDROI~1\jbr\bin\keytool.exe'
    if (!(Test-Path $keytool)) { throw 'keytool required to verify the Android alias.' }
    $priorPassword = $env:EXVPN_QA_BACKUP_PASSWORD
    try {
        $env:EXVPN_QA_BACKUP_PASSWORD = $backupPasswordText
        & $keytool -list -keystore (Join-Path $restored 'android/release.p12') -storetype PKCS12 -storepass:env EXVPN_QA_BACKUP_PASSWORD -alias exvpn *> (Join-Path $fixture 'keytool.log')
        if ($LASTEXITCODE -ne 0) { throw 'Restored Android alias is not readable by keytool.' }; $checks++
    } finally { $env:EXVPN_QA_BACKUP_PASSWORD = $priorPassword }
    [pscustomobject]@{status='PASS';checks=$checks;syntheticKeysOnly=$true;realSigningKeysRead=$false;javaAliasVerified=$true;fixture=$fixture} | ConvertTo-Json
} finally { $certificate.Dispose(); $android.Dispose(); $patch.Dispose(); $backupPassword.Dispose(); $wrongPassword.Dispose() }
