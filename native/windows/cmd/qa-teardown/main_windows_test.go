//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package main

import (
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
)

func validConfig() config {
	return config{RunID: "11111111-1111-4111-8111-111111111111", ForbiddenHost: "HOST", HelperSHA256: strings.Repeat("a", 64), ServiceSHA256: strings.Repeat("b", 64), ServiceCommand: `"C:\Program Files\ExVPN Service\exvpn-service.exe" -test`, Address: "192.0.2.1:32100", PayloadHex: strings.Repeat("c", 64)}
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
