// SPDX-License-Identifier: Apache-2.0
using System;
using System.IO;
using System.Security;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Cryptography.Pkcs;
using System.Formats.Asn1;

// Standard PKCS#12 and encrypted PKCS#8 only. No custom encryption format.
public static class ExVpnSigningBackup {
    private static readonly PbeParameters Pbe = new(PbeEncryptionAlgorithm.Aes256Cbc, HashAlgorithmName.SHA256, 600000);
    private static readonly X509KeyStorageFlags Flags = X509KeyStorageFlags.EphemeralKeySet | X509KeyStorageFlags.Exportable;
    private static string Password(SecureString value) {
        if (value == null || value.Length < 16 || value.Length > 1024) throw new InvalidOperationException("Use a backup passphrase of 16 to 1024 characters.");
        IntPtr pointer = Marshal.SecureStringToGlobalAllocUnicode(value);
        try {
            string result = Marshal.PtrToStringUni(pointer);
            if (result.IndexOf('\0') >= 0) throw new InvalidOperationException("Invalid backup passphrase.");
            return result;
        } finally { Marshal.ZeroFreeGlobalAllocUnicode(pointer); }
    }
    private static byte[] Read(string path) {
        var info = new FileInfo(path);
        if (!info.Exists || info.Length < 1 || info.Length > 1024 * 1024 || (info.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new InvalidOperationException("Missing or invalid signing input.");
        return File.ReadAllBytes(path);
    }
    private static X509Certificate2 Load(byte[] data, string password) {
        var limits = new Pkcs12LoaderLimits {
            MaxKeys = 1, MaxCertificates = 1, MacIterationLimit = 1000000,
            IndividualKdfIterationLimit = 1000000, TotalKdfIterationLimit = 3000000,
            PreserveCertificateAlias = true
        };
        var cert = X509CertificateLoader.LoadPkcs12(data, password, Flags, limits);
        if (!cert.HasPrivateKey) { cert.Dispose(); throw new InvalidOperationException("Signing private key missing."); }
        return cert;
    }
    private static void ImportPatch(RSA patch, byte[] encrypted, string password) {
        // Bound the KDF before handing a possibly damaged backup to the crypto API.
        var document = new AsnReader(encrypted, AsnEncodingRules.DER);
        var sequence = document.ReadSequence(); var algorithm = sequence.ReadSequence();
        if (algorithm.ReadObjectIdentifier() != "1.2.840.113549.1.5.13") throw new InvalidOperationException("Expected PBES2.");
        var parameters = algorithm.ReadSequence(); var kdf = parameters.ReadSequence();
        if (kdf.ReadObjectIdentifier() != "1.2.840.113549.1.5.12") throw new InvalidOperationException("Expected PBKDF2.");
        var kdfParameters = kdf.ReadSequence(); byte[] salt = kdfParameters.ReadOctetString();
        if (salt.Length < 16 || salt.Length > 64 || kdfParameters.ReadInteger() != 600000) throw new InvalidOperationException("Invalid backup KDF limits.");
        if (kdfParameters.HasData && kdfParameters.PeekTag().HasSameClassAndValue(Asn1Tag.Integer)) {
            if (kdfParameters.ReadInteger() != 32) throw new InvalidOperationException("Invalid backup key length.");
        }
        var prf = kdfParameters.ReadSequence();
        if (prf.ReadObjectIdentifier() != "1.2.840.113549.2.9") throw new InvalidOperationException("Expected HMAC SHA-256.");
        if (prf.HasData) prf.ReadNull(); prf.ThrowIfNotEmpty(); kdfParameters.ThrowIfNotEmpty(); kdf.ThrowIfNotEmpty();
        var cipher = parameters.ReadSequence();
        if (cipher.ReadObjectIdentifier() != "2.16.840.1.101.3.4.1.42" || cipher.ReadOctetString().Length != 16) throw new InvalidOperationException("Expected AES-256-CBC.");
        cipher.ThrowIfNotEmpty(); parameters.ThrowIfNotEmpty(); algorithm.ThrowIfNotEmpty();
        sequence.ReadOctetString(); sequence.ThrowIfNotEmpty(); document.ThrowIfNotEmpty();
        patch.ImportEncryptedPkcs8PrivateKey(password, encrypted, out int used);
        if (used != encrypted.Length) throw new InvalidOperationException("Unexpected encrypted key data.");
    }
    private static void Check(X509Certificate2 android, RSA patch, string certificatePath, string publicKeyPath) {
        using var expectedCert = X509Certificate2.CreateFromPem(File.ReadAllText(certificatePath));
        if (!CryptographicOperations.FixedTimeEquals(android.RawData, expectedCert.RawData))
            throw new InvalidOperationException("Android signing identity mismatch.");
        using var expectedPatch = RSA.Create(); expectedPatch.ImportFromPem(File.ReadAllText(publicKeyPath));
        byte[] nonce = RandomNumberGenerator.GetBytes(32);
        using var androidKey = android.GetRSAPrivateKey();
        using var androidPublic = expectedCert.GetRSAPublicKey();
        if (androidKey == null || androidKey.KeySize < 3072 || patch.KeySize < 4096 ||
            !androidPublic.VerifyData(nonce, androidKey.SignData(nonce, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1) ||
            !expectedPatch.VerifyData(nonce, patch.SignData(nonce, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1))
            throw new InvalidOperationException("Signing key verification failed.");
    }
    private static void Create(string path, byte[] data) {
        using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        stream.Write(data); stream.Flush(true);
    }
    private static void Alias(Pkcs12SafeBag bag, byte[] identifier) {
        var name = new AsnWriter(AsnEncodingRules.DER); name.WriteCharacterString(UniversalTagNumber.BMPString, "exvpn");
        var id = new AsnWriter(AsnEncodingRules.DER); id.WriteOctetString(identifier);
        bag.Attributes.Add(new CryptographicAttributeObject(new Oid("1.2.840.113549.1.9.20"), new AsnEncodedDataCollection(new AsnEncodedData(new Oid("1.2.840.113549.1.9.20"), name.Encode()))));
        bag.Attributes.Add(new CryptographicAttributeObject(new Oid("1.2.840.113549.1.9.21"), new AsnEncodedDataCollection(new AsnEncodedData(new Oid("1.2.840.113549.1.9.21"), id.Encode()))));
    }
    private static byte[] ExportAndroid(X509Certificate2 certificate, string password) {
        var certificates = new Pkcs12SafeContents(); var keys = new Pkcs12SafeContents();
        using var rsa = certificate.GetRSAPrivateKey();
        byte[] identifier = SHA256.HashData(certificate.RawData);
        Alias(certificates.AddCertificate(certificate), identifier);
        Alias(keys.AddShroudedKey(rsa, password, Pbe), identifier);
        var builder = new Pkcs12Builder();
        builder.AddSafeContentsEncrypted(certificates, password, Pbe);
        builder.AddSafeContentsUnencrypted(keys); // The key itself is a shrouded (encrypted) key bag.
        builder.SealWithMac(password, HashAlgorithmName.SHA256, 600000);
        return builder.Encode();
    }
    public static void Export(string source, string destination, string certificatePath, string publicKeyPath, SecureString password) {
        byte[] passwordBytes = null, patchBytes = null;
        try {
            passwordBytes = ProtectedData.Unprotect(Read(Path.Combine(source, "android", "store-password.dpapi")), null, DataProtectionScope.CurrentUser);
            patchBytes = ProtectedData.Unprotect(Read(Path.Combine(source, "shorebird", "beta-private.dpapi")), null, DataProtectionScope.CurrentUser);
            using var android = Load(Read(Path.Combine(source, "android", "release.p12")), System.Text.Encoding.UTF8.GetString(passwordBytes));
            using var patch = RSA.Create(); patch.ImportPkcs8PrivateKey(patchBytes, out int used);
            if (used != patchBytes.Length) throw new InvalidOperationException("Unexpected private key data.");
            Check(android, patch, certificatePath, publicKeyPath);
            string passphrase = Password(password);
            // keytool and Android Gradle expect the established alias.
            Create(Path.Combine(destination, "android-release.p12"), ExportAndroid(android, passphrase));
            Create(Path.Combine(destination, "shorebird-beta.pk8"), patch.ExportEncryptedPkcs8PrivateKey(passphrase, Pbe));
            Verify(destination, certificatePath, publicKeyPath, password);
        } finally {
            if (passwordBytes != null) CryptographicOperations.ZeroMemory(passwordBytes);
            if (patchBytes != null) CryptographicOperations.ZeroMemory(patchBytes);
        }
    }
    public static void Verify(string backup, string certificatePath, string publicKeyPath, SecureString password) {
        string passphrase = Password(password);
        using var android = Load(Read(Path.Combine(backup, "android-release.p12")), passphrase);
        if (android.FriendlyName != "exvpn") throw new InvalidOperationException("Android key alias mismatch.");
        using var patch = RSA.Create();
        byte[] encrypted = Read(Path.Combine(backup, "shorebird-beta.pk8"));
        ImportPatch(patch, encrypted, passphrase);
        Check(android, patch, certificatePath, publicKeyPath);
    }
    public static void Restore(string backup, string destination, string certificatePath, string publicKeyPath, SecureString password) {
        string passphrase = Password(password);
        // Verify and restore the same snapshots, even if a backup is being copied
        // or synchronized concurrently after the wrapper's preliminary check.
        byte[] androidBytes = Read(Path.Combine(backup, "android-release.p12"));
        byte[] encryptedPatch = Read(Path.Combine(backup, "shorebird-beta.pk8"));
        using var android = Load(androidBytes, passphrase);
        if (android.FriendlyName != "exvpn") throw new InvalidOperationException("Android key alias mismatch.");
        using var patch = RSA.Create(); ImportPatch(patch, encryptedPatch, passphrase);
        Check(android, patch, certificatePath, publicKeyPath);
        byte[] passwordBytes = System.Text.Encoding.UTF8.GetBytes(passphrase), patchBytes = patch.ExportPkcs8PrivateKey();
        try {
            Directory.CreateDirectory(Path.Combine(destination, "android"));
            Directory.CreateDirectory(Path.Combine(destination, "shorebird"));
            Create(Path.Combine(destination, "android", "release.p12"), androidBytes);
            Create(Path.Combine(destination, "android", "store-password.dpapi"), ProtectedData.Protect(passwordBytes, null, DataProtectionScope.CurrentUser));
            Create(Path.Combine(destination, "shorebird", "beta-private.dpapi"), ProtectedData.Protect(patchBytes, null, DataProtectionScope.CurrentUser));
        } finally { CryptographicOperations.ZeroMemory(passwordBytes); CryptographicOperations.ZeroMemory(patchBytes); }
    }
}
