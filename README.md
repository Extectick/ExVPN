# ExVPN disposable QA data feed

This data-only branch is a public Android API36 QA fixture, not a production release.
The signing key is disposable and must never be added to production builds.
Only a deliberately configured QA APK trusts this key. The default app has data
delivery disabled and does not read this feed.

Channel: beta. App compatibility: 0.1.0+1 only.
Current manifest: revision 1, QA connection-help text.
Two immutable content-addressed resources are present to permit a later separately
published higher signed revision returning the bundled help text. The revision 2
manifest has NOT been published by this commit.

The package contains plain display text only, no executable code, VPN profiles,
subscriptions, private signing material or user data. The public key is an operator
reference; it does not grant automatic trust to clients.

Validation uses ExVPN's production Ed25519 verifier, SHA-256 checks and HTTPS
transport. No TLS bypass, redirect-following or production key is involved.

After QA, stop the test app and remove only its verified app-private
signed-data-v1/beta directory before returning to a default keyless build.
This prevents the QA revision floor from contaminating a later beta trust domain.