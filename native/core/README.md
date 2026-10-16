# ExVPN core prototype

This is the E1 **loopback transport prototype**, not a system VPN. It cannot
enable TUN, change routes or DNS, install a Windows service, or activate a kill
switch. Keep E1 open until the system protection tests pass on both target OSes.

## Build and verify

From the repository root in PowerShell:

```powershell
./scripts/core/test.ps1
./scripts/core/build.ps1
./artifacts/core/exvpn-core.exe version
./artifacts/core/exvpn-core.exe validate -profile -
./artifacts/core/exvpn-core.exe probe -profile - -timeout 20s
```

`-profile -` reads normalized profile JSON from stdin. Keep real profiles in
memory or an ignored, access-controlled local file. Never put keys in command
arguments, version control, CI output, task descriptions or screenshots. The
CLI emits fixed error codes, status, elapsed time and core version only. It
does not return the response body or the underlying network error. A successful
probe is a real verified HTTPS GET over authenticated loopback SOCKS and Xray,
not proof of a system tunnel, DNS isolation, kill switch or application routing.
The destination defaults to Google's standard connectivity endpoint and can be
changed with `-target` to another HTTPS endpoint. Redirects are not followed.

## Native boundary

`DecodeProfile` rejects unknown fields, duplicate keys, null values, oversized
documents and wrong JSON types. `Profile.Validate` constrains endpoints,
credentials, transports and TLS settings. No arbitrary provider configuration
can introduce inbounds, log files, routes, outbound fallbacks or update sources.
`Compile` invokes the actual pinned Xray config builder without starting it.
`StartProbe` / `Runtime.Close` manage a randomly authenticated loopback SOCKS
listener. The listener binds an ephemeral port; a bind race fails explicitly.

Profile JSON is shared with the Dart domain package:

```json
{
  "id": "documentation-only",
  "name": "Synthetic example",
  "protocol": "vless",
  "server": "192.0.2.1",
  "port": 443,
  "uuid": "12345678-1234-4234-8234-123456789abc",
  "transport": {"type": "tcp"},
  "tls": {"enabled": true, "serverName": "example.com"}
}
```

Protocols: `vless`, `vmess`, `trojan`, `shadowsocks`, `hysteria2`.
Transports: `tcp`, `ws`, `grpc`, `xhttp`, `hysteria`. Optional transport fields
are `path` and `host` for WS/XHTTP, `serviceName` for gRPC and `mode` for XHTTP.
TLS supports `serverName`, `fingerprint`, `alpn`, and VLESS `reality` with
`publicKey`, `shortId`, `spiderX`. Optional top-level fields are `password`,
`cipher`, `flow` and `uuid`. VMess is AEAD only (legacy alterId is unsupported).
Advanced XHTTP `extra`, Hysteria obfuscation and port hopping are unsupported
and must be surfaced by importers, never silently removed.

`RoutingPolicy.Rules` is a policy compiler only. It gives DNS priority over
exceptions, accepts exact Windows executable paths or already-resolved Android
UIDs, and leaves unknown traffic on the proxy. It never enables a direct route
by itself. This compiler is not evidence that process lookup works on a device.
The probe does not use exclusions and has no freedom/direct outbound.

## Verified and still pending

On Windows x64, Go 1.27.2, 2026-10-16:

- All supported protocol and transport configurations compile using pinned Xray.
- Local Xray VLESS TCP/WS/gRPC/XHTTP, VMess and Shadowsocks servers carry a
  verified HTTPS response through the SOCKS/Xray client; listeners close cleanly.
- Local Trojan/TLS, Hysteria2 over QUIC, and VLESS/REALITY (standard and
  `xtls-rprx-vision`) servers also carry verified HTTPS. The tests add only the
  fixture certificate to an in-memory client trust pool; production TLS and the
  OS certificate store are unchanged. Wrong TLS hostnames and a wrong REALITY
  server key fail without reaching the HTTPS destination.
- An unreachable proxy does not reach an independently listening HTTPS target.
- Invalid types, duplicate fields, raw provider controls, unsafe process
  patterns, missing TLS and malformed keys are rejected.
- `go test ./... -count=1` and `go vet ./...` pass, including the additional
  fixtures in `runtime_secure_test.go`. This is local protocol evidence, not
  provider endpoint coverage or proof of application UDP datagram forwarding.

The separate [Android adapter](../android/README.md) has JNI builds and emulator
TUN smoke evidence; the [Windows service](../windows/README.md) has its own
system integration and acceptance requirements. Still required for E1: complete
native lifecycle and OS socket protection acceptance, real provider protocol
matrix, both-platform system TUN, persistent Windows WFP, application exceptions,
DNS/IPv6 leak checks, crash/reboot and sleep/resume tests. A hostname in the VPN server endpoint may need bootstrap
resolution; the probe uses the host resolver for that endpoint and does not
claim bootstrap DNS isolation. Destination DNS is delegated to the remote proxy;
Xray-internal DNS is configured through the proxy with fallback disabled.

See [SOURCE_AUDIT.md](SOURCE_AUDIT.md) for pinned-source capability evidence and
licensing requirements. Source files in this directory authored for ExVPN use
Apache-2.0; Xray and other dependencies retain their own licenses.
