# Android separate-UID network probe

QA-only helper, never shipped inside ExVPN. It creates two tiny debug APKs with
distinct UIDs (`ru.exvpn.netprobe` and `ru.exvpn.netprobe.excluded`) so protected and
excluded traffic can be compared without browser automation or host route changes.
The launcher entries exist only so the packages appear in the exclusion picker.

```powershell
./scripts/qa/android-https-probe/build.ps1
adb -s emulator-5562 install -r -t artifacts/android-network-probe/protected-debug.apk
adb -s emulator-5562 install -r -t artifacts/android-network-probe/excluded-debug.apk
adb -s emulator-5562 shell am instrument -w -e mode health ru.exvpn.netprobe/ru.exvpn.netprobe.HttpsProbe
```

Modes are a fixed allowlist: `health` (gstatic 204), `ip4` (api.ipify.org), `ip6`
(api6.ipify.org), `numeric` (Cloudflare 1.1.1.1 HTTPS trace, certificate-verified),
and `dns` (example.com). The numeric request can test direct UID exclusions while
the proxy is stopped, independently of the shared tunnel DNS policy.
HTTPS uses the platform certificate and
hostname checks; there are no trust overrides, redirects, credentials, custom
sockets, underlying-network binding, or VPN bypass. Requests have an 18-second
total deadline, eight-second connect/read limits and a 32 KiB body limit. Only
HTTP status, elapsed time, byte counters, a body hash, DNS answer counts and actual
VPN transport state are returned. IP response bodies are never printed or saved.
`success`/`error` in the result is authoritative; instrumentation's process exit
alone does not mean the request passed. Every invocation is a new app process.

Run a direct baseline, then both packages while the tunnel is active. Use the
synthetic local Xray server's counters and a controlled server-stop failure to
prove traffic actually depends on the tunnel. Equal public IP hashes are expected
when the test server shares the emulator host's egress and do not establish proxy
bypass or successful tunnelling by themselves. Successful DNS resolution does not
prove absence of DNS leaks; packet-level leak checks remain a separate gate.
Removing the helper APKs after QA does not affect ExVPN data.

Build uses installed API 36 / build-tools 36.0.0 and an existing Android debug
keystore. It accepts no licenses and creates no release credentials. Source APIs:
[Instrumentation](https://developer.android.com/reference/android/app/Instrumentation),
[HttpsURLConnection](https://developer.android.com/reference/javax/net/ssl/HttpsURLConnection),
[D8](https://developer.android.com/tools/d8).
