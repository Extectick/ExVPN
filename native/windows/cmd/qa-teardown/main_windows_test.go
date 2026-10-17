//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"testing/iotest"
	"time"

	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
)

func validConfig() config {
	return config{RunID: "11111111-1111-4111-8111-111111111111", ForbiddenHost: "HOST", HelperSHA256: strings.Repeat("a", 64), ServiceSHA256: strings.Repeat("b", 64), ServiceCommand: `"C:\Program Files\ExVPN Service\exvpn-service.exe" -test`, Address: "192.0.2.1:32100", PayloadHex: strings.Repeat("c", 64)}
}

func TestWireFramesKeepBoundariesAndIdentity(t *testing.T) {
	c := validConfig()
	var b bytes.Buffer
	for _, action := range []string{"positive", "close-intent", "close-ready", "result-request"} {
		if err := writeFrame(&b, message(c, "B", action)); err != nil {
			t.Fatal(err)
		}
	}
	r := iotest.OneByteReader(&b)
	for _, action := range []string{"positive", "close-intent", "close-ready", "result-request"} {
		if _, err := expectFrame(r, c, "B", action); err != nil {
			t.Fatal(err)
		}
	}
	if b.Len() != 0 {
		t.Fatal("unread framed payload")
	}
	for name, edit := range map[string]func(*wireMessage){
		"version":       func(m *wireMessage) { m.Version = 2 },
		"action":        func(m *wireMessage) { m.Action = "result-request" },
		"run":           func(m *wireMessage) { m.RunID = "22222222-2222-4222-8222-222222222222" },
		"case":          func(m *wireMessage) { m.Case = "C" },
		"helper":        func(m *wireMessage) { m.HelperSHA256 = strings.Repeat("d", 64) },
		"nonce":         func(m *wireMessage) { m.Nonce = strings.Repeat("e", 64) },
		"result-in-ack": func(m *wireMessage) { m.Result = &peerResult{} },
	} {
		t.Run(name, func(t *testing.T) {
			m := message(c, "B", "positive")
			edit(&m)
			if validateMessage(m, c, "B", "positive") == nil {
				t.Fatal("unbound/stale frame accepted")
			}
		})
	}
}

func TestWireRejectsMalformedBoundedFrames(t *testing.T) {
	frame := func(payload string) []byte {
		b := make([]byte, 4+len(payload))
		binary.BigEndian.PutUint32(b, uint32(len(payload)))
		copy(b[4:], payload)
		return b
	}
	oversize := make([]byte, 4)
	binary.BigEndian.PutUint32(oversize, wireLimit+1)
	for name, b := range map[string][]byte{
		"missing-header": nil, "short-header": {0, 0}, "empty": {0, 0, 0, 0}, "oversize": oversize,
		"short-payload": {0, 0, 0, 2, '{'}, "unknown-field": frame(`{"unknown":1}`),
		"wrong-type": frame(`{"version":"one"}`), "trailing-json": frame(`{} {}`), "damaged-json": frame(`{`),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := readFrame(bytes.NewReader(b)); err == nil {
				t.Fatal("bad frame accepted")
			}
		})
	}
	if err := writeFrame(zeroWriter{}, message(validConfig(), "A", "positive")); err == nil {
		t.Fatal("zero progress write accepted")
	}
	if err := writeFrame(failedWriter{}, message(validConfig(), "A", "positive")); err == nil {
		t.Fatal("failed write accepted")
	}
}

type zeroWriter struct{}

func (zeroWriter) Write([]byte) (int, error) { return 0, nil }

type failedWriter struct{}

func (failedWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

func TestResultCannotClaimLateOrActivePeerSuccess(t *testing.T) {
	c := validConfig()
	base := peerResult{RunID: c.RunID, Case: "C", Positive: true, Passed: true, ReadEnd: "eof", EOF: true, ElapsedMS: 1, FinalStates: []uint32{}}
	m := message(c, "C", "result")
	m.Result = &base
	if validateMessage(m, c, "C", "result") != nil {
		t.Fatal("valid result rejected")
	}
	for name, edit := range map[string]func(*peerResult){
		"deadline": func(r *peerResult) { r.ElapsedMS = 10000 }, "late": func(r *peerResult) { r.ElapsedMS = 11000 },
		"established": func(r *peerResult) { r.FinalStates = []uint32{5} }, "close-wait": func(r *peerResult) { r.FinalStates = []uint32{8} },
		"no-eof": func(r *peerResult) { r.ReadEnd = "pending" }, "wrong-run": func(r *peerResult) { r.RunID = "other" },
		"wrong-case": func(r *peerResult) { r.Case = "A" }, "no-positive": func(r *peerResult) { r.Positive = false },
	} {
		t.Run(name, func(t *testing.T) {
			p := base
			edit(&p)
			m.Result = &p
			if validateMessage(m, c, "C", "result") == nil {
				t.Fatal("false success accepted")
			}
		})
	}
}

func TestGateDeadlineCannotMoveWithLateAckOrResult(t *testing.T) {
	start := time.Unix(1, 0)
	for name, tc := range map[string]struct {
		initial time.Duration
		states  []uint32
		end     string
		pass    bool
	}{
		"eof-empty": {time.Millisecond, nil, "eof", true}, "reset-time-wait": {time.Millisecond, []uint32{11}, "reset", true},
		"empty-without-eof": {0, nil, "", false}, "eof-established": {0, []uint32{5}, "eof", false},
		"eof-close-wait": {0, []uint32{8}, "eof", false}, "exact-deadline": {gate, nil, "eof", false},
		"late-ready-ack": {gate + time.Second, nil, "eof", false}, "late-result-cannot-reset": {2 * gate, nil, "eof", false},
	} {
		t.Run(name, func(t *testing.T) {
			elapsed := tc.initial
			done := make(chan string, 1)
			if tc.end != "" {
				done <- tc.end
			}
			result, err := observePeerGate(start, func() time.Time { return start.Add(elapsed) }, func() ([]uint32, error) { return tc.states, nil }, func() { elapsed += time.Second }, done)
			if err != nil || result.Passed != tc.pass || result.GateStarted != start.UTC() {
				t.Fatalf("gate result: %+v %v", result, err)
			}
			if !tc.pass && result.ElapsedMS < gate.Milliseconds() {
				t.Fatal("failure used a new deadline")
			}
		})
	}
	_, err := observePeerGate(start, func() time.Time { return start.Add(-time.Second) }, func() ([]uint32, error) { return nil, nil }, func() { t.Fatal("pause") }, make(chan string))
	if err == nil {
		t.Fatal("backwards clock accepted")
	}
	_, err = observePeerGate(start, func() time.Time { return start }, func() ([]uint32, error) { return nil, errors.New("table failed") }, func() { t.Fatal("pause") }, make(chan string))
	if err == nil {
		t.Fatal("missing TCP state treated as success")
	}
	// A table call begun just before expiry can return after expiry. The EOF
	// and empty table still cannot be reported as a timely PASS.
	elapsed := gate - time.Millisecond
	done := make(chan string, 1)
	done <- "eof"
	late, err := observePeerGate(start, func() time.Time { return start.Add(elapsed) }, func() ([]uint32, error) {
		elapsed += 2 * time.Millisecond
		return nil, nil
	}, func() { t.Fatal("expired sample must finish") }, done)
	if err != nil || late.Passed || late.ElapsedMS != 10001 {
		t.Fatal("late table completion became a PASS")
	}
}

func TestControlTupleCannotCountAsRetainedDataPeer(t *testing.T) {
	local := netip.MustParseAddrPort("192.0.2.1:40000")
	data := netip.MustParseAddrPort("192.0.2.2:50000")
	control := netip.MustParseAddrPort("192.0.2.2:50001")
	rows := []tcpRow{{local: local, remote: control, pid: 42, state: 5}}
	if len(matchingTCPStates(rows, local, data, 0)) != 0 {
		t.Fatal("control counted as data")
	}
	rows = append(rows, tcpRow{local: local, remote: data, pid: 0, state: 11})
	if got := matchingTCPStates(rows, local, data, 0); !reflect.DeepEqual(got, []uint32{11}) {
		t.Fatal("all-owner data snapshot lost TIME_WAIT")
	}
	if len(matchingTCPStates(rows, local, data, 42)) != 0 {
		t.Fatal("specific owner accepted PID0")
	}
}

func TestConfigBoundaries(t *testing.T) {
	if validateConfig(validConfig()) != nil {
		t.Fatal("fixture rejected")
	}
	for name, edit := range map[string]func(*config){
		"zero-run": func(c *config) { c.RunID = "00000000-0000-0000-0000-000000000000" }, "path-run": func(c *config) { c.RunID = "../x" }, "missing-host": func(c *config) { c.ForbiddenHost = "" }, "helper-hash": func(c *config) { c.HelperSHA256 = "no" }, "service-hash": func(c *config) { c.ServiceSHA256 = "no" }, "payload": func(c *config) { c.PayloadHex = "secret" }, "foreign-service": func(c *config) { c.ServiceCommand = "other.exe" }, "wildcard": func(c *config) { c.Address = "0.0.0.0:12345" }, "loopback": func(c *config) { c.Address = "127.0.0.1:12345" }, "hostname": func(c *config) { c.Address = "example.invalid:12345" }, "ipv6": func(c *config) { c.Address = "[2001:db8::1]:12345" }, "reserved-port": func(c *config) { c.Address = "192.0.2.1:80" }, "multicast": func(c *config) { c.Address = "224.0.0.1:12345" },
	} {
		t.Run(name, func(t *testing.T) {
			c := validConfig()
			edit(&c)
			if validateConfig(c) == nil {
				t.Fatal("invalid config accepted")
			}
		})
	}
}

func TestAbsentLUIDFailsClosed(t *testing.T) {
	rows := []winipcfg.MibIfRow2{{InterfaceLUID: 123}}
	if absentProof(rows, nil, windows.ERROR_FILE_NOT_FOUND) != nil {
		t.Fatal("positive absence rejected")
	}
	for name, entry := range map[string]struct {
		rows []winipcfg.MibIfRow2
		row  *winipcfg.MibIfRow2
		err  error
	}{"empty": {nil, nil, windows.ERROR_FILE_NOT_FOUND}, "present": {append(rows, winipcfg.MibIfRow2{InterfaceLUID: winipcfg.LUID(absentLUID)}), nil, windows.ERROR_FILE_NOT_FOUND}, "lookup-returned": {rows, &winipcfg.MibIfRow2{}, nil}, "access-denied": {rows, nil, windows.ERROR_ACCESS_DENIED}, "invalid": {rows, nil, windows.ERROR_INVALID_PARAMETER}, "undocumented-not-found": {rows, nil, windows.ERROR_NOT_FOUND}} {
		t.Run(name, func(t *testing.T) {
			if absentProof(entry.rows, entry.row, entry.err) == nil {
				t.Fatal("uncertain absence accepted")
			}
		})
	}
}

type fakeGuard struct {
	calls        *[]string
	suspendError error
}

func (g fakeGuard) Suspend() error { *g.calls = append(*g.calls, "Suspend"); return g.suspendError }
func (g fakeGuard) Disarm() error  { *g.calls = append(*g.calls, "Disarm"); return nil }
func TestCloseOrders(t *testing.T) {
	for mode, want := range map[string][]string{"A": {"Close", "Wait"}, "B": {"Close", "Wait", "Suspend", "Disarm"}, "C": {"Suspend", "Close", "Disarm", "Wait"}} {
		t.Run(mode, func(t *testing.T) {
			calls := []string{}
			g := fakeGuard{calls: &calls}
			err := closeInOrder(mode, g, func() error { calls = append(calls, "Close"); return nil }, func() error { calls = append(calls, "Wait"); return nil })
			if err != nil || !reflect.DeepEqual(calls, want) {
				t.Fatalf("wrong sequence: %v %v", calls, err)
			}
		})
	}
	calls := []string{}
	err := closeInOrder("C", fakeGuard{&calls, errors.New("fail")}, func() error { t.Fatal("close after failed suspend"); return nil }, func() error { t.Fatal("wait after failed suspend"); return nil })
	if err == nil {
		t.Fatal("failure lost")
	}
	calls = nil
	err = closeInOrder("B", fakeGuard{calls: &calls}, func() error { return nil }, func() error { return errors.New("peer failed") })
	if err == nil || !reflect.DeepEqual(calls, []string{"Suspend", "Disarm"}) {
		t.Fatal("B failure did not cleanup")
	}
}

func TestOwnershipRejectsForeignFilters(t *testing.T) {
	owned := map[string]uint64{"0": 10, "1": 11, "2": 12, "3": 13, "4": 14, "5": 15, "6": 16, "7": 17}
	if !ownedFilterSet(map[string]uint64{"0": 10}, owned) {
		t.Fatal("owned subset rejected")
	}
	for _, current := range []map[string]uint64{nil, {"0": 18}, {"8": 10}, {"0": 0}} {
		if ownedFilterSet(current, owned) {
			t.Fatal("foreign/uncertain ownership accepted")
		}
	}
	if ownedFilterSet(map[string]uint64{"0": 10}, map[string]uint64{"0": 10}) {
		t.Fatal("incomplete original ownership")
	}
}

func TestTCPDecoderRejectsTruncationAndKeepsState(t *testing.T) {
	b := make([]byte, 28)
	binary.LittleEndian.PutUint32(b, 1)
	binary.LittleEndian.PutUint32(b[4:], 5)
	copy(b[8:12], []byte{192, 0, 2, 1})
	binary.BigEndian.PutUint16(b[12:14], 12345)
	copy(b[16:20], []byte{192, 0, 2, 2})
	binary.BigEndian.PutUint16(b[20:22], 23456)
	binary.LittleEndian.PutUint32(b[24:], 42)
	rows, err := decodeTCP(b)
	if err != nil || len(rows) != 1 || rows[0].state != 5 || rows[0].pid != 42 || rows[0].local.String() != "192.0.2.1:12345" || rows[0].remote.String() != "192.0.2.2:23456" {
		t.Fatal("table decoding")
	}
	for _, bad := range [][]byte{nil, b[:3], b[:27], {255, 255, 255, 255}} {
		if _, err = decodeTCP(bad); err == nil {
			t.Fatal("truncated table accepted")
		}
	}
}

func TestCheckpointIsAtomicAndCannotOverwrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "checkpoint.json")
	if err := writeJSON(path, map[string]string{"case": "A"}); err != nil {
		t.Fatal(err)
	}
	if err := writeJSON(path, map[string]string{"case": "B"}); err == nil {
		t.Fatal("overwrote historical checkpoint")
	}
	var got struct {
		Case string `json:"case"`
	}
	if err := waitJSON(path, &got, time.Second); err != nil || got.Case != "A" {
		t.Fatal("checkpoint changed")
	}
	for _, bad := range []string{`{"case":"A","extra":true}`, `{"case":"A"} {}`, `{"case":`} {
		if err := os.WriteFile(path, []byte(bad), 0600); err != nil {
			t.Fatal(err)
		}
		if readJSON(path, &got) == nil {
			t.Fatal("malformed/unknown/trailing JSON accepted")
		}
	}
}

func TestServerLayoutMatchesGuestReadOnlyMapping(t *testing.T) {
	root := `V:\project\.private\windows-lifecycle-results\11111111-1111-4111-8111-111111111111`
	input := `V:\project\.private\teardown-inputs\11111111-1111-4111-8111-111111111111`
	got, err := serverReportRoot(root, filepath.Join(input, "payload", "marker.json"))
	if err != nil || got != filepath.Join(input, "server") {
		t.Fatal("read-only input layout rejected")
	}
	for name, bad := range map[string][2]string{
		"writable-results-alias": {root, filepath.Join(root, "input", "payload", "marker.json")},
		"wrong-file":             {root, filepath.Join(input, "payload", "other.json")},
		"wrong-input-base":       {root, filepath.Join(input, "foreign", "payload", "marker.json")},
		"different-run":          {root, strings.Replace(filepath.Join(input, "payload", "marker.json"), "4111", "4112", 1)},
		"different-private-root": {root, strings.Replace(filepath.Join(input, "payload", "marker.json"), `V:\project`, `V:\other`, 1)},
		"different-result-base":  {strings.Replace(root, "windows-lifecycle-results", "other-results", 1), filepath.Join(input, "payload", "marker.json")},
		"non-private":            {strings.Replace(root, ".private", "public", 1), strings.Replace(filepath.Join(input, "payload", "marker.json"), ".private", "public", 1)},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := serverReportRoot(bad[0], bad[1]); err == nil {
				t.Fatal("unexpected/writable layout accepted")
			}
		})
	}
}

func TestGuestInputIsUniqueAndRejectsEscape(t *testing.T) {
	first, err := guestInputRoot("11111111-1111-4111-8111-111111111111")
	if err != nil || first != `C:\ExVPN-Teardown-Input-11111111-1111-4111-8111-111111111111` {
		t.Fatal("immutable guest input path mismatch")
	}
	second, err := guestInputRoot("22222222-2222-4222-8222-222222222222")
	if err != nil || first == second {
		t.Fatal("second run would rebind existing input")
	}
	for _, run := range []string{"", `..\payload`, "00000000-0000-0000-0000-000000000000"} {
		if _, err := guestInputRoot(run); err == nil {
			t.Fatal("invalid run accepted")
		}
	}
}
