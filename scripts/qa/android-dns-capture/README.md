# Offline DNS capture analysis

This tool reads a bounded classic Ethernet PCAP from `.private/` using the
repository's pinned Go graph. It never starts a capture, opens a socket, changes
network settings or emits query names, raw endpoints or packet payloads.

Run the in-memory IPv4/IPv6, UDP/TCP and malformed-input fixtures:

```powershell
pwsh -NoProfile -File scripts/qa/android-dns-capture/test.ps1
```

The driver supplies a private JSON file with ordered, non-overlapping `phases`
(inclusive start/end, maximum 8 phases of 90 seconds). Each phase has a distinct
synthetic 32-character lowercase hex `nonce`. A nonce observed outside its phase
returns `INDETERMINATE`; a delayed packet must not silently change attribution.

Protection must also be checked across the gaps between these probe phases.
Supply optional `protectedIntervals` from independently recorded VPN-state and
action markers, rather than inferring them from phase names:

```json
{
  "phases": [
    {"id":"connected","nonce":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","startUnixMs":1700000000000,"endUnixMs":1700000001000},
    {"id":"fault","nonce":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","startUnixMs":1700000002000,"endUnixMs":1700000003000}
  ],
  "protectedIntervals": [
    {"id":"vpn","startUnixMs":1700000000000,"endExclusiveUnixMs":1700000003001}
  ]
}
```

Intervals use **[start, end)**, have unique bounded IDs, are ordered and do not
overlap. Adjacent intervals are permitted without double-counting the boundary.
There may be at most 8 intervals, each at most 360 seconds. Phase and interval
boundaries intentionally differ; existing phase-only inputs remain compatible.

The report includes every UDP/TCP port 53 packet in each interval, including
traffic in phase gaps and DNS unrelated to the synthetic nonce. TCP SYN counts
are capture visibility controls, not DNS payload proof. `captureBoundsCoverInterval`
is true only after complete parsing when the first and last capture timestamps
enclose the entire interval. It does not prove zero packet drops or correct
VPN-state markers. An omitted interval supplies no continuous-window evidence.

`PARSED` and exit code 0 mean only successful parsing. A caller must separately
check positive DNS controls, continuous interval counts and bounds, actual VPN
state, independent traffic and cleanup. Neither this tool nor hostname matching
can attribute a packet to an Android UID. A failed or incomplete parse always
remains `INDETERMINATE`, even if its partial counts are zero. Classic PCAP has no
drop counter; segmented TCP DNS and fragmented IP require reassembly and are
deliberately rejected. Keep original capture and reports immutable when adding a
later analysis.
