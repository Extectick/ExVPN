# Android protocol QA server

Local fixture for the API36 emulator. This command is not included in the app or
release packaging. It binds only IPv4 loopback, uses the pinned Xray module, and
does not change host routes, firewall, DNS or certificate stores.

```powershell
. ./scripts/bootstrap/enter-environment.ps1
Push-Location native/android
go build -ldflags='-checklinkname=0' -o ../../.tools/artifacts/qa-protocol-server.exe ./cmd/qa-server
Pop-Location
./.tools/artifacts/qa-protocol-server.exe -output-dir .private/android-protocol-matrix
```

The output directory must have a `.private` path component. Each run creates new
random credentials and free ports for VLESS TCP, VLESS REALITY, VLESS Vision,
VLESS XHTTP, XHTTP REALITY, VMess and Shadowsocks. Import `subscription.b64` using
the app's Text dialog. Do not print, commit or capture the populated form. The
URI host is Android Emulator's host-loopback gateway; this bundle is not intended
for physical devices. Stop with Ctrl+C and discard the stale test subscription.

REALITY's camouflage server is an ephemeral local TLS1.3 HTTP/2 endpoint. Its
certificate is never trusted globally. REALITY peers authenticate using their
generated key; destination HTTPS still uses normal Android trust/hostname checks.
Trojan/Hysteria2 are deliberately absent: this fixture does not disable transport
certificate validation to make a device test pass.

Only fixture names and aggregate inbound bytes are printed. Independent protected
UID HTTPS probes and server counter increments provide evidence; simply starting
the server or importing all seven profiles does not prove runtime connectivity.
See `docs/ANDROID_VALIDATION.md` for tested APK hashes and limits.

Configuration sources: pinned local `native/core/runtime_test.go` and
`runtime_secure_test.go`, plus the official [REALITY documentation](https://github.com/XTLS/Xray-docs-next/blob/main/docs/en/config/transports/reality.md).
