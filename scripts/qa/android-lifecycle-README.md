# Android lifecycle QA helpers

`android-lifecycle-tools.ps1` is an inert, dot-sourced ADB helper for the disposable
emulator. It adds no production hook and never selects, connects, installs or
disconnects a VPN automatically. The run owner explicitly performs those actions.

```powershell
. ./scripts/bootstrap/enter-environment.ps1
. ./scripts/qa/android-lifecycle-tools.ps1
Initialize-AndroidLifecycleQa -Serial emulator-5564 -OutputDirectory "$PWD/.private/android-lifecycle-build11"
$tree = Read-AndroidLifecycleUi -Step before
$node = Find-AndroidLifecycleLabel $tree 'Подключить VPN'
# After validating the selected synthetic profile and the immutable APK:
Invoke-AndroidLifecycleTap $node -Step connect
$probe = Invoke-AndroidLifecycleProbe -Mode health -Step connected-health
```

Read a fresh tree for each tap. Coordinates come from that node's actual bounds;
ambiguous labels and non-ExVPN packages are rejected. Raw UI, stdout and stderr
are stored only in the run's `.private` directory. Do not print the tree, private
profile labels, subscription input or device logs. ADB calls have a 30-second
default deadline and a 60-second maximum. The output parser allows only fixed
probe fields and error codes, rejects duplicates and requires the complete
instrumentation result. Process completion alone never means network success.

Run the independent `ru.exvpn.netprobe` instrumentation sequentially. Do not run
its text-input helper at the same time. Require `success=true`, actual
`vpnTransport=true`, and the expected separate UID for a connected result. Keep
the same explicit IP probe mode for baseline, connected and restored states.

For native transport retirement, perform at least three ordinary connect → HTTPS
→ disconnect cycles for each synthetic gRPC/XHTTP profile, without killing the
app between cycles. Save per-cycle state, fixture inbound counters and socket
drain evidence. Verify no residual VPN service/transport, original direct egress,
and unchanged OS settings at the end. Remove only the exact ADB reverse mappings
and terminate only the fixture process created by this run. Runtime probes and
server-side socket counts cannot reveal internal Android Go cache object counts;
the separate upstream/core lifecycle tests establish that boundary.

`test-android-lifecycle-tools.ps1` uses synthetic strings/XML only. It does not
invoke ADB, change a network, load credentials or build an app.
