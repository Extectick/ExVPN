# Pinned Xray transport lifecycle patch

ExVPN's modified Xray module is **`v1.260327.1-exvpn.6`**, based on upstream
`v1.260327.1-0.20261010092107-701af60772cd`, commit
`701af60772cda123492f86e383e1fdba066614a9`. It is not an official Xray release.
The upstream source and license are retained. Original and modified covered
files, including the patch's new files, remain **MPL-2.0**. ExVPN's separate
build helpers remain Apache-2.0.

## Scope

The upstream gRPC and XHTTP caches keep stream configurations after a core
instance closes. Repeated reconnects can retain transports and background work.
The patch gives each parsed stream configuration an explicit lifetime and
retires it from the outbound handler's `Close`:

- gRPC removes only its owner's cache entries, closes `ClientConn` outside the
  cache lock, cancels background dials, and joins already-started callbacks.
- XHTTP retires the owner's mux clients, HTTP/1.1, HTTP/2 and HTTP/3 resources,
  active requests and raw upload sockets. Derived download settings share the
  same lifetime. A completed owner cannot re-enter the cache.
- An independent live instance keeps its own connections. Concurrent repeated
  close calls join the same cleanup and preserve errors.
- TUN owns a cancellable inbound context and its UDP workers. Normal Close and
  partial startup failure cancel that context before retiring and joining UDP
  sessions; late packets cannot create new sessions. Init/Start/Close are
  serialized and concurrent callers retain cleanup errors. Memory-only tests
  exercise actual gVisor packets and the DNS proxy without a system TUN.
- Windows Wintun sessions reject new I/O during retirement, wake pending event
  waits, and join admitted receive/release/send/wait operations before `End`.
  Receive buffers are released after gVisor's existing copy, so a retained
  packet cannot call Wintun after session teardown. A failed wake or five-second
  drain timeout preserves native handles and returns a stable cleanup error.
  Synthetic session tests include retained packets, blocked operations,
  concurrent Read/Write/Close, and real cancellation events without a TUN.
- TLS and QUIC sniffers publish a routing domain only after checking the complete
  ClientHello extension list. An ECH extension, including GREASE and either
  extension order, leaves the domain unknown. Malformed trailing extensions and
  duplicate or empty SNI cannot authorize domain-based direct routing. The
  original numeric destination and TLS validation are unchanged. Regression
  fixtures cover ordinary TLS and encrypted QUIC Initial packets without a
  network; they do not claim successful cryptographic ECH negotiation.

The Windows lifetime defect was reproduced deterministically as a release after
`End` on the previous source. This does not establish the cause of the separate
Windows +16 service exit, whose process crash evidence is still incomplete.

The optional upstream browser dialer is not enabled by ExVPN. Its external
browser process is outside this patch's teardown contract. The patch does not
replace Windows socket-generation isolation, persistent WFP policy or Android's
system lockdown, and is not evidence of full VPN acceptance.

## Reconstruct and inspect

`xray-lifecycle.lock.json` pins the upstream archive SHA-256 and Go checksums,
the exact UTF-8/LF patch bytes, and the modified module's expected Go checksums.
The version is immutable: changing the patch requires a new ExVPN module
version and corresponding application native build.

From the repository in PowerShell 7:

```powershell
./scripts/core/prepare-xray-patch.ps1
. ./scripts/bootstrap/enter-environment.ps1
./scripts/qa/test-xray-lifecycle.ps1
./scripts/qa/test-xray-lifecycle.ps1 -Race -Count 5
```

Preparation verifies the original ZIP, validates paths, applies the patch in a
dedicated temporary Git repository, verifies the resulting module `h1`, and
publishes a local immutable `file://` Go proxy. Existing module caches and the
upstream source are not edited. Every native `go.mod` pins the custom version;
there is no external `replace`. `GONOSUMDB` excludes only the custom module from
the public checksum service; the committed `go.sum` remains authoritative.
Environment changes are process-local. Offline callers require the verified
upstream archive in the local cache and do not gain a network fallback.

The ordinary lifecycle suite uses synthetic loopback connections. `-Race`
additionally uses the pinned portable w64devkit compiler from `.tools/`; it is
used for tests only and is not shipped in the VPN application.

## Distribution

The notice collector reads the actual native binary's embedded module version
and checksum. A release bundle contains the exact linked module ZIP under
`sources/xray-core.zip`, this patch and lock, and `XRAY-EXVPN-NOTICE.txt`.
The artifact audit compares the bundled source's Go checksum to the binary and
checks the patch provenance. A successful source check does not remove signing,
device-testing or full license-inventory release gates.
