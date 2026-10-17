# Public signing identities

These files contain public verification material only:

- `android-release-cert.pem`: the Android release signer certificate.
- `shorebird-beta-public.pem`: the RSA key embedded in the controlled beta base
  for strict Shorebird patch verification.

Private keys and the Android keystore password stay in `.private/signing` with
restricted Windows ACLs and current-user DPAPI protection. Never commit them.
The one-time provisioner refuses to replace an existing identity. A portable,
protected backup and a tested recovery procedure are required before stable
distribution; DPAPI files alone are not such a backup.

The beta patch key is separate from APK signing, Windows Authenticode and data
OTA Ed25519 keys. Rotating an embedded patch trust key requires a reviewed full
application release. Earlier Android debug APKs use a different signer.
