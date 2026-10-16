# ExVPN Windows native service — E1/E5 work in progress

**Not a verified VPN release.** This module builds the real privileged service,
TUN runtime and Windows Filtering Platform guard. Ordinary unit checks never
install a service/driver or change routes, DNS or firewall settings. Separate
authorized system tests run only in a disposable Sandbox; the development host
has no ExVPN service or TUN. Keep E1-007–010 and E5 open.

## What is implemented

- `exvpn-service.exe` runs only under Service Control Manager as LocalSystem.
  The Flutter process remains unelevated. Ordinary interactive execution cannot
  start the privileged tunnel.
- Local byte-mode named pipe `\\.\pipe\ExVPN.Control.v1`, ACL restricted to
  LocalSystem and one installer-bound user SID. The user receives data access
  without `FILE_CREATE_PIPE_INSTANCE`; go-winio rejects remote clients. Each
  request checks the client's process token SID **and** exact canonical UI path.
- IPC uses a four-byte little-endian length prefix, at most 1 MiB + 8192 bytes,
  strict version 1 JSON and one request per connection. Duplicate keys, nulls,
  unknown fields, oversized/nested input and arbitrary provider config fail.
  At most eight simultaneous pipe clients; read/write deadlines are bounded.
- Commands: `status`, `stats`, `validate`, `connect`, `disconnect`, `probe`,
  `getExclusions`, `setExclusions`. Profiles go through the shared strict core
  decoder. Exclusions are existing canonical absolute `.exe` paths, at most
  128; changing an active policy requires disconnect/reconnect. The service
  retains effective exclusions across UI restarts. If its own process restarts
  with an armed guard and no recoverable policy, it reports
  `exclusions_unavailable`, never an invented empty list.
- Xray's pinned TUN inbound config captures IPv4/IPv6, assigns adapter-specific
  DNS, prioritizes DNS above exact executable exclusions, then sends remaining
  traffic through the chosen proxy. The first/default outbound is blackhole.
  Only the service constructs listeners/routes/DNS/policy. Hostname endpoints
  use a bounded DoH bootstrap after persistent protection is armed, before TUN
  starts. Temporary WFP permits match this executable, SYSTEM, the fixed peer,
  TCP/443 and the selected physical interface. TLS uses a pinned offline root
  bundle. Exact static hosts and ForceIP retain the original SNI/Host/authority.
  [Bootstrap implementation and evidence](../../docs/WINDOWS_DNS_BOOTSTRAP.md)
  distinguish the passing WFP/DoH smoke from pending end-to-end hostname tests.
  Direct exclusions use `ForceIP`; failed core DNS resolution cannot fall back
  to the Windows resolver for a domain target.
- Windows exceptions use ExVPN's `application-policy` outbound adapter, installed
  through the pinned core's public handler API before core start. TCP checks the
  full local/remote tuple; UDP requires one confirmed PID across specific and
  wildcard binds, including possible IPv6 dual-stack binds. Process creation
  time and exact executable path are checked against repeated bounded Windows
  owner-table snapshots. Unknown, inaccessible or ambiguous ownership uses the
  proxy. Active direct UDP flows recheck each datagram in both directions and
  stop permanently on an owner/PID-lifetime change. Per-packet DNS/domain targets
  cannot bypass the DNS route. The unguarded direct handler is removed from the
  routable handler map. No fork or patch of Xray is required. See
  [owner validation evidence](OWNER_VALIDATION.md).
- A separate ExVPN-owned **persistent** WFP latch blocks outbound and inbound
  IPv4/IPv6. Temporary higher-weight permits require the TUN's local and next-
  hop/arrival interface, or the service executable **and LocalSystem identity**.
  Loopback stays permitted. Service death should remove dynamic permits while
  persistent blocks remain. This is implemented intent; crash/packet capture
  validation is still mandatory, including interactions with other WFP vendors.
- Guard arm precedes TUN start. A verified HTTPS response through authenticated
  loopback SOCKS and the active Xray outbound precedes `connected`. Health probes
  every 15 seconds move to `reconnecting` on failure without direct fallback.
  This proves a transport only after actually run; it does not by itself prove
  OS TUN traversal or absence of leaks.
- Failed startup/probe retains the guard. Explicit disconnect first revokes
  dynamic permits, then closes the core, then deletes only ExVPN-owned persistent
  keys. A failed core close never clears the latch. SCM stop/shutdown deliberately
  leaves the latch. `recover-guard` is an explicit administrator/installer action
  and requires the service to be stopped.

## Flutter Windows boundary

`apps/exvpn/windows/runner/vpn_bridge.*` connects the shared methods
`exvpn/vpn` and events `exvpn/vpn_state` / `exvpn/vpn_stats` to this service.
Bounded pipe work and JSON parsing run on a worker; results return to the Flutter
platform thread. Before transmitting a profile the UI checks the server PID
against SCM, its LocalSystem account and the expected Program Files executable.
Closing the UI does not disconnect the service.

One UI writer is enforced across sessions with `Global\\ExVPN.UI.v1.<user SID>`.
The mutex ACL grants only that user and SYSTEM access; failure to acquire it
does not open subscription storage. A second launch restores the existing
window when it is on this desktop. An abandoned owner can be recovered.

The shared methods include `connect`, `disconnect`, `getStatus`, `getExclusions`,
`setExclusions`, `listApplications`, `probe`, `coreVersion` and
`openSystemProtectionSettings`. The application list currently consists of
queryable **running** executables. Windows has no Android lockdown settings page,
so that method returns a stable unsupported error. Traffic counters read Xray's
actual TUN inbound upload/download counters without resetting them, including
captured excluded-app traffic; the loopback health probe is not included. The
service returns `statistics_unavailable` while counters are absent or a lifetime
change is underway, never invented zero measurements. `processCrashProtection`
remains false while system acceptance is unverified. Absent/unreachable service
produces a stable error state. The service is not installed during this
development check. The native Flutter host has compiled and launched
successfully; see evidence below.

The service `status` response already includes `coreVersion`. The Flutter host's
`coreVersion` method currently returns the bundled `26.10.10` pin without a pipe
request; it does not confirm the installed service's version. Reading the actual
service identity through authenticated status IPC is a separate pending change,
described in the [bootstrap/version notes](../../docs/WINDOWS_DNS_BOOTSTRAP.md).

## Build and non-networking checks

From the repository root, Go 1.27.2:

```powershell
./scripts/windows/test.ps1
./scripts/windows/build.ps1
./scripts/windows/prepare-wintun.ps1
./artifacts/windows/exvpn-service.exe version
```

Verified **2026-10-16** in the working tree (commit pending):

- `go mod verify`, `go vet ./...`: passed.
- 27 Go test entry points passed (including one child-process socket helper),
  covering failed-probe latch retention, stop
  ordering, cancellation, stale completion rejection, failed-cleanup retention,
  service-owned exclusion state and unknown recovery state, strict IPC framing,
  actual pinned Xray config compilation and expected Win64 ABI layouts,
  non-destructive real Xray counter reads and no statistics after disconnect.
- Two real unprivileged child processes sharing one UDP loopback endpoint
  reproduced the pinned upstream lookup ambiguity; the ExVPN resolver rejected
  the ambiguous owner. Two real TCP processes sharing one local endpoint but
  connecting to different loopback destinations were correctly distinguished.
  Regression tests also cover wildcard binds, PID reuse, revoked UDP flows,
  exact-path matching, malformed tables and DNS precedence. No external packets
  or privileged network changes are needed for these tests.
- A real temporary named-pipe roundtrip passed; the same user running the wrong
  executable was rejected. Tests use an unprivileged test-only server owner ACL;
  production LocalSystem/user ACL behavior still requires the SCM integration
  test. Tests do **not** call WFP mutators or start a system TUN.
- `artifacts/windows/exvpn-service.exe` built for Windows x64; `version` reports
  core 26.10.10 / `701af60772cda123492f86e383e1fdba066614a9` and
  `systemVerified:false`.
- Official Wintun 0.14.1 archive/DLL SHA-256 and Authenticode `Valid` verified.
  Driver not installed. Pin: `scripts/windows/wintun.lock.json`.
- `flutter build windows --debug --no-pub`: passed with Visual Studio Community
  18, MSVC 14.51.36231, ATL and Windows SDK 10.0.26100.0. Runner C++/WinRT uses
  C++20 and `/utf-8`. Artifact: `apps/exvpn/build/windows/x64/runner/Debug/exvpn.exe`.
- The actual Windows UI launched and displayed the truthful `service_unavailable`
  state with an empty subscription list. A second executable process exited 0;
  the original PID/window remained the only UI instance. Cross-session behavior
  still needs a Terminal Services test. Screenshot:
  [Windows native empty state](../../design/qa/windows-native/2026-10-16-service-unavailable.png).
- All Windows PowerShell scripts parsed. `stage-client.ps1 -CheckOnly` validated
  the complete 26-file debug bundle without copying/installing it.
- `flutter build windows --release --no-pub` also passed. The ICO exports the
  existing approved squirrel mask at native Windows icon sizes; the actual release
  window was checked with the new title-bar icon:
  [release squirrel](../../design/qa/windows-native/2026-10-16-release-squirrel.jpg).
- NSIS 3.13 compiled the full unsigned development installer offline, including
  service, release UI and the generated component notices/source inventory. Windows
  PowerShell 5.1 manifest/cleanup/rollback-path tests and payload inspection passed.
  Thirteen replacement/uninstall/recovery scenarios also passed with real filesystem/Windows
  sharing locks and mocked SCM/ACL/registration. Partial previous-file deletion
  restores missing verified files. Uninstall backs up before SCM/file deletion
  and restores after a locked second DLL or registration-removal failure;
  unknown/modified/locked replacement survivors
  retain backup and produce an explicit incomplete-recovery error.
  [Installer and guest QA instructions](INSTALLER.md) distinguish these build
  checks from the still-open installation/network acceptance.

## Controlled integration / recovery

The preferred complete test package is now the [NSIS installer](INSTALLER.md).
Its administrator-only custom service control 128 explicitly disconnects before
stopping for package maintenance. Ordinary SCM stop/shutdown still preserves the
guard. The standalone scripts below remain useful for a separately reviewed
development setup; an unmanaged script-based installation is not silently adopted
by NSIS.

Package maintenance serializes all users through a separate machine-wide global
mutex before reading installed state. SYSTEM/Admin owner and exact ACL are checked
before a nonblocking acquisition; a precreated untrusted mutex fails closed. The
per-user UI mutex is retained. Mock cross-owner/hijack tests pass; elevated Windows
object behavior remains part of guest acceptance.

`scripts/windows/stage-client.ps1 -SourceExecutable <built exvpn.exe>` prepares
a fresh protected `Program Files/ExVPN` UI bundle. `-CheckOnly` performs a
non-elevated, read-only preflight. Actual staging requires administrator rights,
rejects reparse points and records each installed file's hash. Both directories
and files are owned by Administrators and writable only by Administrators/SYSTEM.

`scripts/windows/install-service.ps1` accepts only that protected installed UI
path, verifies the whole bundle's ownership/write ACLs, and prepares a separate
protected Program Files service directory and an automatic service dependent on
BFE. It does not start it. A user-writable development executable is refused.
Without the explicit `-EnableNetworkTesting` switch, connect requests fail with
`system_testing_required`. The installer-bound client executable path must match
the actual Flutter binary. Do not run this on a working host as a unit test.

Before the first system run use a disposable Windows 10/11 VM or a controlled
machine with local console, snapshot/backup and a pre-staged recovery executable.
Prepare evidence for:

1. Actual HTTPS through TUN, external IPs for normal and excluded applications,
   IPv4/IPv6 and UDP; unknown process does not take direct route.
2. DNS with empty caches, multihomed Windows resolver behavior and failure of the
   proxy/DNS. Never relax protection merely to make a test pass.
3. Forced core/service death, SCM stop, UI death/restart, network switch,
   sleep/resume and reboot. Check packets while filters remain after process exit.
4. Other user SID, unexpected client executable, remote pipe and first-instance
   attacks; regular users cannot replace the service/DLL or create a pipe server.
5. Explicit disconnect, failed start/stop, recovery, upgrade and uninstall remove
   only owned resources and retain unrelated routes/DNS/firewall state.

`uninstall-service.ps1` stops the service, refuses cleanup if an abandoned TUN
adapter remains, recovers only owned WFP keys, then removes only known files.
It does not perform blanket firewall resets or delete unknown adapters.
After the service is removed and the UI closed, `remove-client.ps1` verifies the
installed manifest and removes only unchanged known bundle files. Unknown or
modified files abort preflight; encrypted per-user subscriptions are retained.
These scripts are prepared and syntax checked, not elevated/install tested.

### Remaining release blockers

- Controlled WFP/TUN/leak/crash tests above; production guard capability remains
  unverified. Link-local DHCP/IPv6 discovery handling needs that validation.
- Hostname bootstrap end-to-end/expiry/network-change tests, crash ownership journal/adapter recovery,
  durable encrypted service policy and robust route/DNS restore after abrupt death.
  Existing `ExVPN-Tunnel` adapters are currently refused rather than adopted.
- Real end-to-end IPC with a signed installed UI/service; measured live traffic
  statistics and full installed-app picker. Owner snapshots are not an atomic
  kernel flow-attestation mechanism: stress tests for rapid socket/PID reuse and
  UDP performance remain part of the controlled system acceptance.
- NSIS clean install/upgrade/failed upgrade/rollback/uninstall runtime acceptance
  in the disposable guest, binary signing and complete release SBOM. The compiled
  package includes notices and exact covered sources, but is unsigned and remains
  a controlled development artifact.

## Pinned libraries and primary references

- Shared `../core` pins Xray; no changes to its upstream covered source.
- `github.com/Microsoft/go-winio v0.6.2`, MIT, notice in `licenses/`.
- `golang.org/x/sys v0.48.0`, BSD-3-Clause, notice in `licenses/`.
- `golang.zx2c4.com/wireguard/windows v1.1.1`, MIT, notice in `licenses/`;
  winipcfg only. All transitive versions/checksums are in go.mod/go.sum.
- Wintun signed 0.14.1 DLL: official **prebuilt binary license**, not GPL source
  license; preserve its supplied license. Only its permitted API is used; the
  DLL is not modified. No binary was published in this work.
- C++/WinRT JSON comes from the Windows SDK; no vendored JSON dependency added.

Sources: [WFP object lifetimes](https://learn.microsoft.com/en-us/windows/win32/fwp/object-management),
[FWPM_FILTER0](https://learn.microsoft.com/en-us/windows/win32/api/fwpmtypes/ns-fwpmtypes-fwpm_filter0),
[filter deletion by key](https://learn.microsoft.com/en-us/windows/win32/api/fwpmu/nf-fwpmu-fwpmfilterdeletebykey0),
[named-pipe access rights](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights),
[go-winio pinned pipe implementation](https://github.com/microsoft/go-winio/blob/v0.6.2/pipe.go),
[Windows SCM Go API](https://pkg.go.dev/golang.org/x/sys/windows/svc),
[official Wintun download and hash](https://www.wintun.net/),
[TCP owner tables](https://learn.microsoft.com/en-us/windows/win32/api/iphlpapi/nf-iphlpapi-getextendedtcptable),
[TCP tuple fields](https://learn.microsoft.com/en-us/windows/win32/api/tcpmib/ns-tcpmib-mib_tcprow_owner_pid),
[UDP owner limitations](https://learn.microsoft.com/en-us/windows/win32/api/udpmib/ns-udpmib-mib_udprow_owner_pid),
[global kernel namespaces](https://learn.microsoft.com/en-us/windows/win32/termserv/kernel-object-namespaces).
