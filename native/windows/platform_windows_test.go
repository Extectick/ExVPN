//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"os"
	"strings"
	"testing"
	"time"
	"unsafe"

	exvpn "github.com/Extectick/ExVPN/native/core"
	"github.com/Microsoft/go-winio"
	"github.com/xtls/xray-core/app/proxyman"
	appstats "github.com/xtls/xray-core/app/stats"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/transport/internet"
	"golang.org/x/sys/windows"
)

func TestWFPWin64ABILayout(t *testing.T) {
	// Expected x64 offsets/sizes from the Windows SDK's C definitions.
	for name, v := range map[string][2]uintptr{
		"value": {unsafe.Sizeof(wfpValue{}), 16}, "blob": {unsafe.Sizeof(wfpBlob{}), 16},
		"session": {unsafe.Sizeof(wfpSession{}), 72}, "sublayer": {unsafe.Sizeof(wfpSublayer{}), 72},
		"condition": {unsafe.Sizeof(wfpCondition{}), 40}, "filter": {unsafe.Sizeof(wfpFilter{}), 200},
		"conditions_offset": {unsafe.Offsetof(wfpFilter{}.Conditions), 120},
		"action_offset":     {unsafe.Offsetof(wfpFilter{}.Action), 128}, "context_offset": {unsafe.Offsetof(wfpFilter{}.Context), 152},
	} {
		if v[0] != v[1] {
			t.Errorf("%s got %d want %d", name, v[0], v[1])
		}
	}
	keys := map[windows.GUID]bool{}
	for i := 0; i < 16; i++ {
		k := guardKey(i)
		if keys[k] {
			t.Fatal("duplicate owned key")
		}
		keys[k] = true
	}
}
func TestTunnelConfigUsesPinnedCoreAndOwnsPolicy(t *testing.T) {
	b, e := BuildTunnelConfig(syntheticProfile(), []string{"C:/Apps/example.exe"}, exvpn.ProbeOptions{Port: 10808, Username: "test", Password: "fixture"})
	if e != nil {
		t.Fatal(e)
	}
	compiled, e := core.LoadConfig("json", bytes.NewReader(b))
	if e != nil {
		t.Fatal("actual pinned core rejected generated config")
	}
	for _, outbound := range compiled.Outbound {
		if outbound.Tag != "direct-excluded" {
			continue
		}
		sender, err := outbound.SenderSettings.GetInstance()
		if err != nil {
			t.Fatal(err)
		}
		if sender.(*proxyman.SenderConfig).StreamSettings.SocketSettings.DomainStrategy != internet.DomainStrategy_FORCE_IP {
			t.Fatal("excluded traffic permits system resolver fallback")
		}
	}
	var c map[string]any
	if json.Unmarshal(b, &c) != nil {
		t.Fatal("config not JSON")
	}
	in := c["inbounds"].([]any)
	if len(in) != 2 {
		t.Fatal("listener count")
	}
	settings := in[1].(map[string]any)["settings"].(map[string]any)
	for _, rawDNS := range settings["dns"].([]any) {
		dns, err := netip.ParseAddr(rawDNS.(string))
		if err != nil {
			t.Fatal("invalid tunnel DNS address")
		}
		captured := false
		for _, rawGateway := range settings["gateway"].([]any) {
			gateway, err := netip.ParsePrefix(rawGateway.(string))
			if err != nil {
				t.Fatal("invalid tunnel prefix")
			}
			if dns == gateway.Addr() {
				t.Fatal("DNS points to Windows' own adapter address and bypasses TUN delivery")
			}
			captured = captured || gateway.Contains(dns)
		}
		if !captured {
			t.Fatal("DNS must be a separate peer inside the captured TUN subnet")
		}
	}
	if len(settings["autoSystemRoutingTable"].([]any)) != 4 {
		t.Fatal("missing IPv4/IPv6 routes")
	}
	if len(settings["autoSystemWfpBlockLeak"].([]any)) != 0 {
		t.Fatal("relied on dynamic upstream guard")
	}
	rules := c["routing"].(map[string]any)["rules"].([]any)
	if rules[1].(map[string]any)["outboundTag"] != "dns-out" || rules[2].(map[string]any)["outboundTag"] != applicationPolicyTag {
		t.Fatal("DNS must precede exceptions")
	}
	for _, rule := range rules {
		if _, unsafe := rule.(map[string]any)["process"]; unsafe {
			t.Fatal("used ambiguous upstream process matcher")
		}
	}
	if c["outbounds"].([]any)[0].(map[string]any)["protocol"] != "blackhole" {
		t.Fatal("unsafe default")
	}
	p := syntheticProfile()
	p.Server = "example.com"
	if _, e = BuildTunnelConfig(p, nil, exvpn.ProbeOptions{Port: 10808, Username: "test", Password: "fixture"}); e != Code("server_ip_required") {
		t.Fatal("unprotected bootstrap DNS allowed")
	}
}
func TestActualXrayCountersAreReadWithoutCreatingOrResetting(t *testing.T) {
	manager, err := appstats.NewManager(context.Background(), &appstats.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = readTraffic(manager); err != Code("statistics_unavailable") {
		t.Fatal("absent counters invented zero measurements")
	}
	up, _ := manager.RegisterCounter("inbound>>>vpn>>>traffic>>>uplink")
	if _, err = readTraffic(manager); err != Code("statistics_unavailable") {
		t.Fatal("partial counters accepted")
	}
	down, _ := manager.RegisterCounter("inbound>>>vpn>>>traffic>>>downlink")
	up.Add(4096)
	down.Add(8192)
	for range 2 {
		traffic, err := readTraffic(manager)
		if err != nil || traffic.UploadBytes != 4096 || traffic.DownloadBytes != 8192 {
			t.Fatal("incorrect or destructive counter read")
		}
	}
	down.Set(-1)
	if _, err = readTraffic(manager); err != Code("statistics_unavailable") {
		t.Fatal("counter overflow accepted")
	}
}
func TestPipeACLDoesNotGrantCreateInstance(t *testing.T) {
	s, e := PipeSecurity("S-1-5-21-100-200-300-1001")
	if e != nil {
		t.Fatal(e)
	}
	if _, e = windows.SecurityDescriptorFromString(s); e != nil {
		t.Fatal("invalid SDDL")
	}
	if !strings.Contains(s, "0x12019b") || strings.Contains(s, ";;;WD") || strings.Contains(s, ";;;BA") {
		t.Fatal("overbroad ACL")
	}
	for _, bad := range []string{"WD", "S-1-1-0", "S-1-5-18", "S-1-5-21-1-2-3-1001)(A;;GA;;;WD)"} {
		if _, e = PipeSecurity(bad); e == nil {
			t.Fatal("accepted bad owner")
		}
	}
}
func TestRealNamedPipeRoundtripAndExecutableRejection(t *testing.T) {
	u, e := windows.GetCurrentProcessToken().GetTokenUser()
	if e != nil {
		t.Fatal(e)
	}
	sid := u.User.Sid.String()
	if !strings.HasPrefix(sid, "S-1-5-21-") {
		t.Skip("test requires ordinary local account")
	}
	exe, e := os.Executable()
	if e != nil {
		t.Fatal(e)
	}
	c, e := NewController(&fakeGuard{}, nil, nil, false)
	if e != nil {
		t.Fatal(e)
	}
	for _, allowed := range []bool{true, false} {
		t.Run(fmt.Sprint(allowed), func(t *testing.T) {
			identity := ClientIdentity{SID: sid, Executable: exe}
			if !allowed {
				identity.Executable = os.Getenv("SystemRoot") + `\System32\notepad.exe`
			}
			name := fmt.Sprintf(`\\.\pipe\ExVPN.Test.%d.%d`, os.Getpid(), time.Now().UnixNano())
			// The production ACL's server owner is LocalSystem. Unit tests run
			// unelevated, so use a test-only owner ACE while exercising the real
			// Windows pipe, client token/path validation and protocol below.
			identity.Executable, e = canonicalExecutable(identity.Executable)
			if e != nil {
				t.Fatal(e)
			}
			listener, e := winio.ListenPipe(name, &winio.PipeConfig{SecurityDescriptor: "D:P(A;;GA;;;" + sid + ")"})
			if e != nil {
				t.Fatal(e)
			}
			s := &PipeServer{listener: listener, identity: identity, controller: c, connections: map[net.Conn]struct{}{}}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			defer s.Close()
			done := make(chan error, 1)
			go func() { done <- s.Serve(ctx) }()
			timeout := time.Second
			conn, e := winio.DialPipeAccess(context.Background(), name, 0x12019b)
			if e != nil {
				t.Fatal(e)
			}
			defer conn.Close()
			_ = conn.SetDeadline(time.Now().Add(timeout))
			if e = WriteFrame(conn, Request{Version: 1, ID: "test", Command: "status"}); e != nil && !allowed {
				return
			}
			if e != nil {
				t.Fatal(e)
			}
			b, e := ReadFrame(conn)
			if !allowed {
				if e == nil {
					t.Fatal("unexpected executable accepted")
				}
				return
			}
			if e != nil {
				t.Fatal(e)
			}
			var r Response
			if json.Unmarshal(b, &r) != nil || !r.OK || r.Status.State != "disconnected" {
				t.Fatal("invalid status response")
			}
		})
	}
}
