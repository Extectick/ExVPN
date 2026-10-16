# Windows exception ownership — 2026-10-16

Working tree; commit pending. This is native resolver/adapter evidence, not a
claim that the full Windows VPN or WFP crash protection has passed E1.

## Pinned dependency finding

Xray `26.10.10`, commit `701af60772cda123492f86e383e1fdba066614a9`,
`common/net/find_process_windows.go`: `FindProcess` accepts the remote endpoint
but its table search uses only the local address/port and returns the first PID.
TCP rows with different remote endpoints can share a local endpoint. UDP owner
tables do not contain a remote endpoint, and Windows permits overlapping binds.
Choosing the first row is insufficient evidence for an application exception.

The deterministic regression suite first models two distinct PIDs with the same
local endpoint. The real-process tests then reproduce the condition on loopback:

- `TestRealTwoProcessUDPReuseRejectsAmbiguousOwner`: two child processes bind the
  same IPv4 UDP address/port with `SO_REUSEADDR`. The pinned upstream call reports
  one PID; ExVPN reports `owner_unavailable` and therefore uses the proxy.
- `TestRealTwoProcessTCPReuseMatchesRemoteTuple`: two child processes bind the
  same local TCP endpoint and connect to two different loopback listeners.
  ExVPN identifies each correct PID using the complete tuple.

Only loopback sockets and read-only IP Helper/process queries are used. No
external server, credentials, route, DNS, adapter, WFP or service installation is
involved. Child sockets/processes close when each test finishes.

## ExVPN adapter

- `owner_table.go`: bounded explicit decoding of documented IPv4/IPv6 owner
  table structures; full TCP tuple; unique UDP owner, including wildcard binds.
- `owner_windows.go`: bounded Win32 table calls; repeated snapshots; open
  process handle, creation/exit time and full image path. No owner cache or TTL
  grants an exception after ownership becomes unknown.
- `application_policy_windows.go`: public Xray `outbound.Handler` wrapper owns
  the direct handler's lifecycle. The manager retains only the guarded policy
  tag; DNS routing precedes it. Unknown/unlisted owner delegates to proxy.
- Direct UDP flows check PID, creation time and path for every datagram in both
  directions. A change permanently revokes that flow. A new association can
  receive a new routing decision. Per-packet DNS and domain targets are blocked
  on an existing direct association.

The implementation is original Apache-2.0 ExVPN code using published Windows
APIs and the pinned Xray handler interface. It does not copy, vendor or patch the
upstream owner searcher; existing dependency notices continue to apply.

## Checks and limits

`scripts/windows/test.ps1` passed: checksums, 27 Go test entry points (including
the child helper), and `go vet`. `scripts/windows/build.ps1` produced the x64
service. Tests additionally verify malformed/oversized tables, exact path versus
basename, same-PID repeated binds, scoped/unknown identity rejection, UDP owner
change/PID lifetime change, and adapter installation before core start.

Windows owner tables are snapshots, not an atomic kernel callout. Stress testing
rapid bind/PID reuse under real TUN traffic remains required. The conservative
resolver may temporarily proxy an excluded app when tables are unavailable,
IPv6 scope is unproven, or another process shares a UDP endpoint. It never picks
an arbitrary owner to preserve an exception. Per-datagram queries prioritize
correctness in this prototype; CPU/throughput must be measured before release.

Still open: separate external IP proof for ordinary/excluded applications,
IPv4/IPv6/DNS packet captures, service/core crash, persistent WFP behavior,
network changes and cleanup on a controlled Windows machine/VM.

Primary references:
[GetExtendedTcpTable](https://learn.microsoft.com/en-us/windows/win32/api/iphlpapi/nf-iphlpapi-getextendedtcptable),
[IPv4 TCP row](https://learn.microsoft.com/en-us/windows/win32/api/tcpmib/ns-tcpmib-mib_tcprow_owner_pid),
[IPv6 TCP row](https://learn.microsoft.com/en-us/windows/win32/api/tcpmib/ns-tcpmib-mib_tcp6row_owner_pid),
[UDP row](https://learn.microsoft.com/en-us/windows/win32/api/udpmib/ns-udpmib-mib_udprow_owner_pid),
[pinned upstream owner implementation](https://github.com/XTLS/Xray-core/blob/701af60772cda123492f86e383e1fdba066614a9/common/net/find_process_windows.go).
