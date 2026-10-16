# Android JNI and VPN service

Status 2026-10-16: JNI/APK builds and focused emulator traffic checks passed,
**not an accepted VPN release**. E1 remains open until Android traffic, DNS, IPv6, UID exclusions,
network changes and crash/lockdown behavior are verified on a physical device.

## Components

- `config.go`: builds a local TUN configuration from the strict existing native
  profile decoder/compiler. Provider inbounds/routing/logging are never accepted.
- `dialer.go`: aborts TCP/UDP socket creation if Android `protect()` or binding to
  the selected underlying network fails. Unknown DNS names never reach the OS
  resolver through this dialer.
- `bridge/main.go`, `bridge/jni.c`: Go `c-shared` JNI adapter; UTF-8 profile bytes,
  bounded inputs, explicit service-reference and TUN-descriptor ownership.
- `apps/exvpn/android/.../ExVpnService.kt`: foreground service, TUN, socket/owner
  callbacks, lifecycle and actual HTTPS health checks.
- `MainActivity.kt`: permission request and Flutter channel interface. Closing
  the activity does not stop the service.
- `VpnPersistence.kt`: native resume request and package policy encrypted with
  Android Keystore AES-256-GCM and committed with `AtomicFile` in `noBackupFilesDir`.

The adapter embeds the existing pinned Xray `26.10.10` commit
`701af60772cda123492f86e383e1fdba066614a9`. It does not link libXray: direct Xray APIs
are used because the default Xray dialer logs and ignores a protection-controller
error. ExVPN's alternative dialer propagates that failure before network use.

## Security behavior

The Android service owns the original TUN descriptor; native code duplicates it
for Xray and closes that duplicate on stop. The TUN covers IPv4 and IPv6 with
default routes. No `addDisallowedApplication`, `allowBypass` or direct fallback
is used. An unavailable core/server keeps the established TUN open. If TUN setup
itself fails, the state is `error`, with no claim that traffic is blocked.

Only the selected VPN endpoint hostname is bootstrapped through the selected
underlying Android `Network`. Its resolved IP replaces the dial address while the
original TLS identity remains intact. `DnsResolver` queries have an eight-second
bound and are cancelled immediately on disconnect; numeric addresses skip DNS.
**This endpoint bootstrap DNS is outside
the VPN**; it is necessary before the tunnel transport exists. Application DNS
goes to Xray's DNS outbound, then to HTTPS DNS through the proxy; no direct DNS
fallback is configured. Direct exclusions use `ForceIP`, so a failed Xray DNS
lookup cannot fall back to a platform UDP resolver. Unknown owners use the proxy,
not the direct outbound.

Exclusions are local package names resolved to current UIDs. A shared UID is only
accepted when all packages sharing it are explicitly selected. The owner callback
rechecks package membership before granting direct routing. Installed apps are
listed through launchable activities only, without `QUERY_ALL_PACKAGES`.

`connected` is emitted only after certificate-verified HTTPS through Xray to the
fixed health endpoint `https://www.gstatic.com/generate_204` returns 204. This
checks the tunnel transport but does not replace the separate end-to-end TUN,
external-IP and leak tests. Health failure reports `blocked`; checks retry every
20 seconds while the core is running. A network change restarts the core while
keeping the TUN. Health-target availability is a dependency and may produce a
false-negative status if that target is blocked by the provider.

`processCrashProtection` reflects actual `isAlwaysOn && isLockdownEnabled` from
Android. Without system lockdown, process death can remove the OS VPN. Settings
remain user-controlled. Sticky/Always-on service restart can restore the last
validated, explicitly requested profile and policy from encrypted native storage.
Missing credentials create a blocking TUN with `profile_required`; corrupt or
unavailable storage reports `native_storage_unavailable` without replacing it
with plaintext or silently resetting the policy. Resume is accepted only after
the normal profile and current package-owner validation. This implementation
still requires the process-death/reboot/lockdown acceptance checks below.

No profiles go into Intent extras, notifications or logs; notification text is
generic. Flutter's subscription store and native resume store have separate
purposes. Explicit disconnect stops the core, verifies removal of the native
resume record, then closes the TUN. If durable removal fails, an ordinary stop
keeps the non-forwarding TUN and reports the storage error. Explicit policy edits
while disconnected clear an older resume record before saving the new policy,
so a later service restart cannot restore stale exclusions. OS lockdown may
still prevent network access after successful disconnect; the app cannot disable
that system setting. Permission revocation does not claim that a revoked TUN
continues to block traffic.

## Flutter channel contract

Method channel: `exvpn/vpn`. State events: `exvpn/vpn_state`. Statistics events:
`exvpn/vpn_stats`. All errors use fixed codes and generic messages.

| Method | Arguments | Result |
|---|---|---|
| `connect` | `{profile: normalized profile map}` | `null` after permission/request acceptance; observe state events |
| `disconnect` | none | `null`; observe final `disconnected` |
| `getStatus` | none | status map |
| `getExclusions` | none | Current native package exclusions as `[String]` |
| `coreVersion` | none | `26.10.10` |
| `listApplications` | none | `[{id, displayName, sharedIdentityGroup?}]` |
| `setExclusions` | `{applications: [package name]}` | `null`; active service rejects with `reconnect_required` |
| `probe` | `{profile: normalized profile map}` | `{reachable, latencyMs?, errorCode?}`; only current active profile is supported |
| `openSystemProtectionSettings` | none | Opens Android VPN settings |

Status: `{phase, processCrashProtection, activeProfileId?, connectedAt?, errorCode?}`.
`connectedAt` is epoch milliseconds. Traffic: `{uploadBytes, downloadBytes}` from
the Xray TUN counters. Missing counters emit `statistics_unavailable` on the
statistics stream instead of inventing zero measurements. State does not include
secrets or provider addresses.

## Build and checks

```powershell
. ./scripts/bootstrap/enter-environment.ps1
Push-Location native/android
go test ./...
go vet ./...
Pop-Location
./native/android/build.ps1
```

Native builds use pinned Go 1.27.2, NDK 27.1.12297006, API 30 and 16 KiB ELF page
alignment. Both arm64-v8a and x86_64 libraries are written under ignored
`.tools/artifacts/android-jni`; Gradle packages those and rejects missing libraries.
Flutter/plugin APK packaging uses NDK 28.2.13676358; the Go JNI build retains its
separate pin above. The APK libraries were compared with native build outputs
after the packaging toolchain's normal symbol stripping.
The Xray-pinned Android `-checklinkname=0` linker setting is inherited from the
existing native CLI build; changes to Go/anet require fresh device validation.

Verified locally: configuration compiles with the pinned core; default blackhole,
DNS-before-exclusion ordering, invalid UID/IP rejection, absent unrequested direct
outbound, protect-failure abort for TCP/UDP, approved socket success, and refusal
to send unresolved domains to the host resolver. Six Go tests and `go vet` pass.
Both JNI ABIs compile, expose expected JNI symbols and pass the script's ELF
alignment checks. A focused API36 x86_64 emulator run verified real HTTPS from a
separate UID through TUN, IPv4/IPv6 endpoint availability, and DNS availability.
During a controlled synthetic VLESS server outage, the protected UID failed
numeric HTTPS while the selected excluded UID succeeded through the same TUN.
The UI reported blocked and recovered automatically after server restoration;
background UI and Wi-Fi/cellular transitions retained working HTTPS after recovery.
Exact APK hash, observations and limitations are in the local
[`artifacts/android-runtime/REPORT.md`](../../artifacts/android-runtime/REPORT.md).
That report identifies the tested build; later native persistence changes require
a new APK and their own focused lifecycle replay. No real provider key was used.

## Sources and remaining validation

- [Android VPN lifecycle and lockdown](https://developer.android.com/develop/connectivity/vpn)
- [Android connection-owner UID API](https://developer.android.com/reference/android/net/ConnectivityManager#getConnectionOwnerUid(int,%20java.net.InetSocketAddress,%20java.net.InetSocketAddress))
- [Cancellable network-specific DNS](https://developer.android.com/reference/android/net/DnsResolver)
- [Foreground service system exemption](https://developer.android.com/develop/background-work/services/fgs/service-types#system-exempted)
- [Pinned Android TUN](https://github.com/XTLS/Xray-core/blob/701af60772cda123492f86e383e1fdba066614a9/proxy/tun/tun_android.go)
- [Pinned system dialer](https://github.com/XTLS/Xray-core/blob/701af60772cda123492f86e383e1fdba066614a9/transport/internet/system_dialer.go)

Pending: physical Android 11+ permission/foreground lifecycle, real provider and
Android per-protocol matrix, IPv4/IPv6/DNS packet capture with cold caches,
unknown/shared UID edge cases, sleep/resume/reboot and native process-crash
lockdown tests. The local core's verified Trojan, Hy2 and REALITY HTTPS fixtures
do not by themselves prove those protocols through Android TUN. Encrypted native
recovery, explicit-stop cleanup and corrupted-store failure require focused
runtime verification on the updated APK. JNI compilation or an emulator
screenshot alone must not close E1/E4 acceptance.
Use synthetic profiles first and keep any real inputs under `.private/`.
