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
`trace4` (the same numeric HTTPS trace endpoint; validates exactly one canonical
IPv4 `ip=` line and emits only `publicIpSha256`), and `dns` (example.com).
`trace4` is an explicit separate mode, never an automatic fallback from `ip4`.
Use the same mode for direct baseline, tunneled egress and restored baseline.
The numeric request can test direct UID exclusions while
the proxy is stopped, independently of the shared tunnel DNS policy.
HTTPS uses the platform certificate and
hostname checks; there are no trust overrides, redirects, credentials, custom
sockets, underlying-network binding, or VPN bypass. Requests have an 18-second
total deadline, eight-second connect/read limits and a 32 KiB body limit. Only
HTTP status, elapsed time, byte counters, a body hash, DNS answer counts and actual
VPN transport state are returned. IP response bodies are never printed or saved.
`success`/`error` in the result is authoritative; instrumentation's process exit
alone does not mean the request passed. Every invocation is a new app process.

The trace parser has a fast, network-free host JVM check with synthetic fixtures:
`./scripts/qa/android-https-probe/test.ps1`. It rejects missing/duplicate IP fields,
IPv6, invalid octets, ambiguous leading zeros, control characters and oversized
responses. It never prints the trace or the parsed address.

Run a direct baseline, then both packages while the tunnel is active. Use the
synthetic local Xray server's counters and a controlled server-stop failure to
prove traffic actually depends on the tunnel. Equal public IP hashes are expected
when the test server shares the emulator host's egress and do not establish proxy
bypass or successful tunnelling by themselves. Successful DNS resolution does not
prove absence of DNS leaks; packet-level leak checks remain a separate gate.
Removing the helper APKs after QA does not affect ExVPN data.

## Uncached DNS capture check

`dnsNonce` issues one ordinary `InetAddress.getAllByName` lookup for a fixed
`exvpn-<nonce>.example.com` name. Its `nonce` argument must be exactly 32 lowercase
hexadecimal characters; no arbitrary domain, resolver, socket or TLS policy is
accepted. Generate a new nonce for every phase in a private driver and keep the
nonce, phase input and raw capture under `.private/`. The result contains only
`dnsQueryAttempted`, `dnsQuerySha256`, answer counts and `dnsOutcome` (`answers` or
`no_answer`). `no_answer` alone does not distinguish NXDOMAIN from blocked DNS and
does not prove protection. The host JVM fixtures also cover this input contract.

The offline companion `../android-dns-capture/test.ps1` checks synthetic classic
PCAP fixtures using the existing pinned Go module graph. Its CLI takes `-pcap`
and `-phases` paths inside `.private/`, with at most eight disjoint phase windows,
90 seconds per phase and 32 MiB per capture. It hashes the same immutable bytes it
parses and emits only counts, timestamps and digests. `PARSED` describes parser
completion, never a leak-test PASS. Truncation, fragments, TCP DNS requiring stream
reassembly, uncertain clocks and unknown input fail as `INDETERMINATE`.

A runtime check must separately confirm an uncached direct DNS query and its
response in the capture, actual independent-UID HTTPS egress and VPN state, then
repeat a fresh direct DNS control after explicit disconnect. A TCP port 53 SYN
control proves capture visibility of TCP 53, not DNS payload decoding. Classic
emulator PCAP supplies no drop counter; report that limitation and the tested
address families. An IPv4-only emulator with an ADB reverse fixture does not
establish physical-device, IPv6 or all DNS-transport protection.

## Fast focused text input

The protected QA APK also registers
`ru.exvpn.netprobe/ru.exvpn.netprobe.TextInputProbe`. It uses Android's
`Instrumentation.getUiAutomation()` and `AccessibilityNodeInfo.ACTION_SET_TEXT`
to paste a large subscription in one action instead of thousands of ADB key
events. It adds no hook to the production APK and does not submit the dialog.

First open ExVPN's Add subscription dialog and focus the intended editable field
using the current UI hierarchy. The helper requires the active window and the
single focused editable node to belong to **`ru.exvpn.exvpn`**. Missing/ambiguous
focus, another application, password fields and unavailable actions are rejected.
On connecting accessibility, Flutter may publish its focused text node after the
first window root. The helper polls fresh bounded snapshots for up to two seconds;
wrong-package or ambiguous-focus snapshots are rejected immediately.
The input is strict UTF-8, nonempty, at most **512 KiB**, with no NUL or other
control bytes except tab/newline/carriage return.

```powershell
# InputPath must point to an existing local file inside this repo's .private/.
# Its bytes may be a Base64 subscription, URI list, URL or synthetic QA text.
./scripts/qa/android-https-probe/set-text.ps1 -Serial emulator-5564 -InputPath "$PWD/.private/qa-input.txt"
```

The wrapper sends bytes through **ADB stdin** into the QA APK's own fixed
`files/qa-text-input.txt` using `run-as`; no private text appears in process
arguments, tool output, clipboard, a shell script or shared `/sdcard`. Then it
invokes instrumentation with only `-e payloadFile qa-text-input.txt`. The helper
accepts that exact filename, refuses symlinks and deletes it in `finally`; the
wrapper also cleans up that exact file if instrumentation cannot complete.

Only `status`, `inputLength` (UTF-8 byte count), `inputSha256`, `appliedSha256` and
`actionAccepted` are emitted. `verified` and exit 0 require the text read back
from the same accessibility node to have the exact length and SHA-256 of the
staged input. `accepted_unverified` means the action was accepted but equality
was not established (for example truncated accessibility text); it returns
nonzero. The UI tree, actual input and raw ADB errors are never printed.

Host JVM fixtures cover UTF-8 malformed sequences, control characters, empty
input, exact/over-limit input, a streaming size-limit bypass and a known SHA-256
vector. Run `test.ps1`; on-device focus/paste/readback remains a separate check.
Do not invoke multiple instrumentation components for the same QA package at once.

Build uses installed API 36 / build-tools 36.0.0 and an existing Android debug
keystore. It accepts no licenses and creates no release credentials. Source APIs:
[Instrumentation](https://developer.android.com/reference/android/app/Instrumentation),
[AccessibilityNodeInfo](https://developer.android.com/reference/android/view/accessibility/AccessibilityNodeInfo),
[HttpsURLConnection](https://developer.android.com/reference/javax/net/ssl/HttpsURLConnection),
[D8](https://developer.android.com/tools/d8).
