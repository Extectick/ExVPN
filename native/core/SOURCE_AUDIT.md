# Core source review — 2026-10-16

The source and licenses were read before building dependencies. No upstream
code or license was modified. Source clones under `.cache` are research-only.

| Component | Exact revision | Status |
|---|---|---|
| Xray-core | tag `v26.10.10`, commit `701af60772cda123492f86e383e1fdba066614a9` | Embedded and compiled by this module |
| Go module | `v1.260327.1-0.20261010092107-701af60772cd` | Checksums in go.sum; no floating latest |
| libXray | `4e1f7843e6cddb750ac7abc23ef36800820a8098` | Source-reviewed candidate, not linked or Android-built |
| Go | module minimum `1.27.1`; verified toolchain `1.27.2` | Windows x64 |

The candidate libXray `go.mod` references the same Xray commit. Its wrapper
offers Android protect-socket and process-finder callbacks. Native integration
still requires a reproducible Android build and device validation; source
compatibility alone does not close that gate.

## Findings relevant to the security gate

- Xray implements a TUN inbound. On Android `XRAY_TUN_FD` supplies the native FD;
  the app must establish and own VpnService and socket protection. No automatic
  route manipulation here can replace the OS integration.
- Android `RegisterAndroidProcessFinder` exists; libXray adapts an app-supplied
  connection owner UID to the process rule string. ExVPN must resolve package
  identities locally and reject unknown UIDs, never use provider-supplied rules.
- **Windows Xray TUN WFP is dynamic.** The source explicitly says filters are
  removed when the process dies. Therefore `autoSystemWfpBlockLeak` cannot meet
  ExVPN's persistent crash kill-switch requirement. A separate persistent WFP
  policy owned by the ExVPN service and safe installer recovery is mandatory.
- Hysteria2 uses outbound protocol `hysteria`, outbound settings `version:2`,
  transport `network:hysteria`, transport settings `version:2,auth`, and TLS.
- Xray's freedom outbound blocks proxy-server access to private targets by
  default. The local HTTPS integration test has an explicit loopback-only allow
  rule in its synthetic test server, never in production probe configuration.

## Pinned primary sources

- [Xray go.mod](https://github.com/XTLS/Xray-core/blob/701af60772cda123492f86e383e1fdba066614a9/go.mod)
- [Xray TUN Windows WFP lifecycle](https://github.com/XTLS/Xray-core/blob/701af60772cda123492f86e383e1fdba066614a9/proxy/tun/tun_windows_wfp.go#L197-L198)
- [Xray Android TUN](https://github.com/XTLS/Xray-core/blob/701af60772cda123492f86e383e1fdba066614a9/proxy/tun/tun_android.go)
- [Xray Android process hook](https://github.com/XTLS/Xray-core/blob/701af60772cda123492f86e383e1fdba066614a9/common/net/find_process_android.go)
- [libXray dependency pin](https://github.com/XTLS/libXray/blob/4e1f7843e6cddb750ac7abc23ef36800820a8098/go.mod)
- [libXray Android controller](https://github.com/XTLS/libXray/blob/4e1f7843e6cddb750ac7abc23ef36800820a8098/controller/controller_android.go)
- [Xray Hysteria configuration](https://github.com/XTLS/Xray-core/blob/701af60772cda123492f86e383e1fdba066614a9/infra/conf/hysteria.go)
- [Xray freedom defaults](https://github.com/XTLS/Xray-core/blob/701af60772cda123492f86e383e1fdba066614a9/proxy/freedom/freedom.go)

## Distribution notices

Xray-core is MPL-2.0. Preserve the included license, notices and access to the
exact corresponding source when distributing a binary; distribute modifications
to covered files under MPL-2.0. ExVPN's separate own files remain Apache-2.0.
The reviewed libXray candidate is MIT; its full notice is included even though
it is not yet linked. Dependency inventories and all transitive licenses must
be completed before any public binary release. This prototype is not a release
with completed third-party compliance packaging.
