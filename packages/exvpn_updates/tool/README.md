# Offline data release authoring

Run from `packages/exvpn_updates` with the pinned Dart SDK after `dart pub get`:

```powershell
dart run tool/build_data_update.dart --resources V:/release-input/resources --metadata V:/release-input/metadata.json --seed-file V:/release-secrets/.private/signing.seed --output V:/release-output/revision-3
```

Paths above are placeholders for operator-owned local files. The tool does **not**
create a production key, publish files, call a network service or modify the app's
trust configuration. `--help` prints the command syntax. No secret is accepted as
an inline argument or environment value. Success prints only `package_written`;
failure prints `authoring_failed:<fixed-code>` and exits 1. Paths, seed, resource
contents and underlying exceptions never appear in tool logs.

Inputs:

- An existing resource directory containing **only** `help/connection-ru.json`.
  This is validated using the application's exact pure Dart `parseConnectionHelp`
  source: maximum 8192 bytes, plain body 1–1500 characters, schema format 1, no
  duplicate/extra fields or control characters. The CLI is repository-local and
  intentionally imports that source rather than maintaining a second schema.
- An existing metadata file, maximum 4096 bytes, with the flat schema below.
  Duplicate/unknown keys, nested structures and wrong types are rejected.
- An absolute path to an **existing 32-byte binary Ed25519 seed** below a directory
  named `.private`. Base64/PEM text is not the seed-file format. The seed must be
  separate from the resource tree/metadata and not inside the output. Keep that
  private directory outside the publishable tree and restrict its OS permissions;
  a directory name alone is not an ACL or a secure vault. `.private` is Git-ignored
  in ExVPN. The tool refuses symlinks in all input/output-parent path components.
- An output name of 1–80 ASCII letters/digits/underscore/hyphen, beginning with a
  letter/digit, in an **existing trusted parent directory**. Output must not exist
  (even as an empty directory or symlink) or overlap the resource/seed tree.

Metadata example (public information only):

```json
{
  "keyId": "release-key-1",
  "revision": 3,
  "channel": "stable",
  "minVersion": "0.1.0",
  "maxVersionExclusive": "0.2.0",
  "minBuild": 1,
  "maxBuild": 10
}
```

`rollbackOf` is optional and must reference a smaller positive revision. Every
release, including rollback, needs a revision higher than every previously
published revision for that channel. This offline tool validates the number and
format, but cannot discover a remote release history. The operator owns that ledger.

Output contains exactly:

```text
manifest.json           signed envelope, exact UTF-8 manifest bytes inside Base64
files/<sha256>          unchanged validated resource bytes
public-key.json         keyId and Base64 Ed25519 PUBLIC key only
```

The envelope is signed and then verified with the production `ManifestVerifier`
before any output is written. SHA-256 and byte size are computed from the resource.
Known raw/Base64/hex representations of the supplied seed are refused in all output
payloads. The source seed file is never modified or copied. The local read buffer
is cleared in `finally`; Dart/library-managed copies may remain until GC, so this
is not a claim of hardened key memory or HSM protection.

Prepared output is written/flushed in a fresh sibling staging directory, then
renamed to the new target. An exclusively created `.NAME.authoring-lock` reservation
prevents cooperating CLI processes from taking the same output. Ordinary failures
remove only exact files created by the invocation. Process crash can leave a
reservation/staging directory; inspect it before manually removing it. The tool
does not automatically erase unknown leftovers. A same-user process modifying the
trusted parent concurrently is outside this guarantee; there is no directory fsync
or hardware power-loss durability claim.

Publishable paths are `manifest.json` and `files/`; `public-key.json` is a public
operator reference for independently configuring the app's compile-time trust.
It does **not** make a client trust a new key automatically. No real endpoint or
production key is supplied by this repository.

Validation: 7 authoring tests on Windows cover the complete production-client
round trip, output/reservation no-overwrite, malformed inputs, private-key
containment, symlink rejection and subprocess stdout/stderr. The fixture uses
test-only seeds in temporary `.private` directories; no production key is created.
