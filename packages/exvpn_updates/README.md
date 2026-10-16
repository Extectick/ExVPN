# exvpn_updates

Pure Dart (`dart:io`) verifier and stager for signed, bounded ExVPN data updates.
No production endpoint/key, publishing service, app timer, executable update or
VPN command is included. See [the protocol and limitations](../../docs/DATA_UPDATES.md).

The trusted application constructs `TrustedUpdatePolicy` from its own HTTPS
endpoints, Ed25519 public keys and exact resource allowlist. Never derive this
policy or a custom transport from a subscription.

```dart
final client = DataUpdateClient(
  policy: trustedApplicationPolicy,
  context: UpdateContext(
    appVersion: installedVersion,
    build: installedBuild,
    channel: UpdateChannel.stable,
  ),
  store: DirectoryUpdateStore(privateApplicationDirectory),
  validateResource: validateKnownResourceSchema,
);

final previous = await client.recover();
final staged = await client.stage();
// The host must always activate or cancel the returned stage.
if (hostCanApplyDataNow) {
  final active = await client.activate(staged);
  final bytes = await active.read(knownAllowlistedPath);
  // Pass bytes only to the trusted data consumer, never an interpreter.
} else {
  await client.cancel(staged);
}
```

`stage()` does not change the active revision. It downloads changed files only,
then validates the full snapshot. `activate()` revalidates and publishes a new
commit marker by same-filesystem rename. Failed downloads/writes preserve the
previous version. Recovery validates signatures and resources again. Rollback
must be published with a higher signed revision. Errors contain safe codes only.

Use **one writer isolate per private store**. Separate clients in that isolate
and separate processes fail `busy` immediately when a stage owns the lease.
POSIX process-level advisory locks do not synchronize Dart isolates. Always
activate/cancel each stage. The OS releases the file lock after process death.

Validation (Dart 3.13.5, Windows): `dart analyze`, `dart test` — 24 passing tests,
including real localhost TLS, signature tamper, interrupted transfer, ENOSPC,
recovery, replay/path denial and concurrent writers. Hardware power-loss,
Android filesystem and production delivery remain integration acceptance work.

Runtime: `crypto 3.0.7` and `cryptography 2.9.0`. Test-only RSA certificate helper:
`pointycastle 4.0.0`. Exact versions and hashes are in `pubspec.lock`; license
texts are in `third_party`. Own source: Apache-2.0.

An offline authoring CLI with 7 additional tests is described in
[tool/README.md](tool/README.md). It accepts an existing private seed file and
writes a new signed data directory; it never creates production keys or publishes.
