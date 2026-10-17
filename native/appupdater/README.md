# Windows application update helper

`exvpn-updater.exe` is a separate standard-library-only Go 1.27.2 executable.
It is packaged next to the ordinary-user `exvpn.exe`. It does not implement a
VPN service command and never disconnects, kills, or elevates the UI.

`scripts/windows/build-app-updater.ps1` pins the package version/build and all
trust material from `config/updates/windows-beta.json` through six linker
variables: `appVersion`, `appBuild`, `updateChannel`, `manifestFeed`,
`manifestKeyID`, `manifestPublicKey`. Empty or invalid pins disable full updates.
There are no external Go dependencies and consequently no `go.sum`.

## External protocol

Start the installed executable directly, with no shell:

```text
exvpn-updater.exe check --json
exvpn-updater.exe download --json
exvpn-updater.exe handoff --json
exvpn-updater.exe restart-ui --json
```

Write exactly one JSON line to stdin and close stdin. The maximum is 16 KiB.
`check` takes `{"protocol":1}`. `download` additionally takes
`"version":"0.1.0+22"`; `handoff` takes that version and `"parentPid":123`.
`restart-ui` takes only `protocol` and `parentPid`. There are no caller-selected
URLs, trust keys, channels, executable paths, installer arguments, or current
version overrides. Unknown fields, duplicate fields, and wrong field types fail.

Stdout is JSON Lines, without raw OS errors, URLs, paths, or request echoes:

```json
{"type":"progress","received":1048576,"total":12345678}
{"type":"result","status":"available","version":"0.1.0+22","sizeBytes":12345678}
```

The one terminal status is `upToDate`, `available`, `ready`, `accepted`, or
`error`. Errors have a fixed `errorCode`; the allowlist is in `protocol.go`.
A missing feed (HTTP 404) is `upToDate`. A fully authenticated current/older
package is also `upToDate` for a check and clears its availability cache;
download/handoff still reject its identity. `previous_install_failed` is a consumed
local receipt for a failed/cancelled installer or a package that did not become
the expected build. The UI may show this specific failure on startup.
Downloaded byte progress does not assert successful verification or installation.

## Signed full-release manifest

The envelope is at most 32 KiB and contains only:

```json
{"schema":1,"keyId":"exvpn-full-update-beta-1","payload":"STANDARD_BASE64","signature":"STANDARD_BASE64"}
```

Ed25519 verifies the exact bytes
`UTF8("ExVPN/windows-update/v1\u0000") || base64decode(payload)` before JSON is
interpreted. The payload is at most 16 KiB and contains only:

```json
{
  "schema": 1,
  "appId": "exvpn",
  "platform": "windows-x64",
  "channel": "beta",
  "version": "0.1.0",
  "build": 22,
  "publishedAt": "2026-10-18T00:00:00Z",
  "expiresAt": "2026-10-25T00:00:00Z",
  "asset": {
    "url": "https://github.com/Extectick/ExVPN/releases/download/v0.1.0-beta.22/ExVPN-0.1.0+22-windows-x64.exe",
    "sizeBytes": 12345678,
    "sha256": "64_lowercase_hex_digits"
  }
}
```

Version is the package's numeric `major.minor.patch`; beta/stable is separate.
The build must strictly increase, up to 2147483647; SemVer cannot decrease.
Both timestamps must be UTC `Z`, publication cannot be in the future, expiry
must remain in the future, and signed lifetime cannot exceed 30 days.
The installer is between 1 byte and 512 MiB. The example digest is a placeholder,
not a usable manifest. No manifest permits arbitrary provider configuration.

The initial feed and installer URL must use the exact project release path on
`github.com/Extectick/ExVPN/releases/download/<tag>/<filename>`. HTTPS uses normal
certificate validation, minimum TLS 1.2, bounded timeouts, at most four redirects,
no transparent compression, and no partial 206 response. Redirects permit only:

- The same exact project release-download path on `github.com`.
- `api.github.com/repos/Extectick/ExVPN/releases/assets/<positive integer>`.
- `release-assets.githubusercontent.com`, `objects.githubusercontent.com`, and
  `github-releases.githubusercontent.com`, restricted to GitHub's
  `/github-production-release-asset/` or `/github-production-release-asset-...`
  release delivery paths. Temporary GitHub query signatures are permitted here.

No certificate bypass, other host, plaintext URL, user info, custom port,
fragment, encoded path escape, or fallback source is accepted.

## Staging and handoff

The cache is the real current user's Known Folder LocalAppData path plus
`ExVPN/update-cache`; an environment override, remote/mapped volume, or reparse
component is rejected. Windows can inherit MSIX filesystem virtualization from
a packaged launcher while reporting no current package identity. In that case
only the OS-opened fixed `ExVPN` directory may resolve to
`LocalAppData/Packages/<PFN>/LocalCache/Local/ExVPN`: the owner/DACL are checked,
every physical ancestor is retained without reparses, and the physical directory
must have the same volume/file ID as the original held logical directory. When
the OS reports a current package family it must match exactly. All later cache
operations use the physical path and demand exact final-path matches.
Unpackaged operation retains its original path. Directories and files have private protected DACLs for
that user, SYSTEM, and Administrators. Existing DACLs/owners are inspected.
Actual installer bytes are streamed, counted, SHA-256 checked, flushed, and
renamed before a verified envelope commits readiness. Readiness is rechecked
on every use. All ancestors are retained without delete sharing; installer files
must be regular single-link files and are opened without write/delete sharing.
Cross-session per-user mutexes serialize cache writers and handoffs.

`handoff` is accepted only from the fixed Program Files installation. It checks
the exact UI image, current-user SID, ordinary token, session and process creation
timestamp, then retains its process handle. It copies the installed helper to a
unique private staging directory, hashes the copy, and starts that same helper
as a detached ordinary-user child. The child repeats source/copy checks and
rechecks the signed manifest and actual locked installer bytes before a two-phase
pipe handshake. A caller must save/quiesce state and exit the UI gracefully only
after `accepted`. The child waits at most 120 seconds for that exact process and
60 seconds for the cross-session UI writer mutex; it never kills either owner.

All handles in Program Files are released before installation. The staged
installer's locked read handle remains held through UAC and process completion.
Only that verified installer is elevated with fixed
`/S /APP_UPDATE=1 /OWNER_SID=<actual current SID>` arguments. Its atomic idle
maintenance gate must reject active VPN/guard/proxy state and block new sessions
through service stop. Older services without that gate refuse automatic updates.
The installer preserves the installed network-testing policy. The detached helper
relaunches the fixed installed UI with its ordinary user token after success,
UAC cancellation, or installer failure. A local receipt is committed before launch.

`restart-ui` uses the same process-identity/writer-mutex handoff without launching
an installer or changing the service, for a prepared signed Dart patch.

## Verification boundaries

Run `../../.tools/go/bin/go.exe test -count=1 ./...` and `go vet ./...` here.
Tests use synthetic manifests, mock HTTP/local TLS, temporary owned files, and
ephemeral mutexes. They cover exact-byte/domain signatures, schema failures,
version/expiry/host bounds, actual byte counts/hash, TLS refusal, locked files and
parent directories, hardlinks, owner PID reuse, writer exclusion, and receipts.

These tests do not run UAC, NSIS, install a package, stop a service, change VPN,
DNS, routes or WFP, publish a release, or prove a real signed full-update cycle.
Physical/installed runtime acceptance, UI visibility after UAC failure, complete
rollback/protection continuity and production feed publication remain E6 gates.
The helper currently restarts a cancelled download from zero; abandoned private
`.part` files and old staged helpers may remain after a forced process exit.
