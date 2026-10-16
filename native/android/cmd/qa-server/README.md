# Local protocol QA server

Local fixture for Android emulators and Windows Sandbox. This command is not
included in the app or release packaging. It uses the pinned Xray module and
does not change host routes, firewall, DNS or certificate stores. By default it
binds IPv4 loopback and advertises the Android emulator alias `10.0.2.2`.

```powershell
. ./scripts/bootstrap/enter-environment.ps1
Push-Location native/android
go build -ldflags='-checklinkname=0' -o ../../.tools/artifacts/qa-protocol-server.exe ./cmd/qa-server
Pop-Location
./.tools/artifacts/qa-protocol-server.exe -output-dir .private/android-protocol-matrix
```

The output directory must have a `.private` path component. Each run creates new
random credentials and free ports for VLESS TCP, VLESS REALITY, VLESS Vision,
VLESS XHTTP, XHTTP REALITY, VLESS gRPC h2c, VMess and Shadowsocks. Import `subscription.b64` using
the app's Text dialog. Do not print, commit or capture the populated form. The
URI host is Android Emulator's host-loopback gateway; this bundle is not intended
for physical devices. Stop with Ctrl+C and discard the stale test subscription.

For Windows Sandbox, explicitly pass `-listen-address <host-vEthernet-IPv4>` and
the identical `-client-address`. The address must belong to a local interface;
wildcards, multicast, IPv6 and mismatched client addresses are rejected. Map only
the run's private fixture directory read-only into the disposable guest. This
makes the fixture reachable on that virtual interface, without opening a listener
on every host interface. Stop the owned fixture process after QA. Guest and host
may share an external IP; this topology alone cannot prove different egress IPs.

REALITY's camouflage server is an ephemeral local TLS1.3 HTTP/2 endpoint. Its
certificate is never trusted globally. REALITY peers authenticate using their
generated key; destination HTTPS still uses normal Android trust/hostname checks.
Trojan/Hysteria2 are deliberately absent: this fixture does not disable transport
certificate validation to make a device test pass.

Only fixture names and aggregate inbound bytes are printed. Independent protected
UID HTTPS probes and server counter increments provide evidence; simply starting
the server or importing all eight profiles does not prove runtime connectivity.
See `docs/ANDROID_VALIDATION.md` for tested APK hashes and limits.

The gRPC fixture uses cleartext HTTP/2 only on this explicit QA listener; it does
not add a trust exception to ExVPN. For emulator-only lifecycle checks, pass
`-client-address 127.0.0.1` and use an exact `adb reverse tcp:<port> tcp:<port>` for
each chosen fixture port. Remove those exact mappings after the run. Repeated
ordinary app connect/disconnect plus independent HTTPS and fixture-side TCP peer
drain are runtime checks; they do not expose internal client cache object counts.

Configuration sources: pinned local `native/core/runtime_test.go` and
`runtime_secure_test.go`, plus the official [REALITY documentation](https://github.com/XTLS/Xray-docs-next/blob/main/docs/en/config/transports/reality.md).
