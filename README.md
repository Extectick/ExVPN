# ExVPN disposable QA data feed

This data-only branch is a public Android API36 QA fixture, not a production release.
The disposable signing key must never be added to production builds. Only a
deliberately configured QA APK trusts this key. Default builds leave delivery disabled.

Channel: beta. App compatibility: 0.1.0+1 only.
Current manifest: revision 2, rollbackOf 1, restoring the application's bundled
connection-help text. This is a higher signed revision; replay of revision 1 is
not an accepted rollback mechanism. The two content-addressed files are immutable.

The package contains plain display text only, no executable code, VPN profiles,
subscriptions, private signing material or user data. The public key is an operator
reference; it does not grant automatic trust to clients.

After QA, stop the test app and remove only its verified app-private
signed-data-v1/beta directory before returning to a default keyless build.
This prevents the QA revision floor from contaminating a later beta trust domain.