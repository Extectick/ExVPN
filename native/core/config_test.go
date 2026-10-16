// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"encoding/json"
	"testing"
)

func TestProbeNeverAddsDirectOrSystemTunnel(t *testing.T) {
	b, e := BuildProbeConfig(fixture("vless"), ProbeOptions{Port: 10808, Username: "user", Password: "test"})
	if e != nil {
		t.Fatal(e)
	}
	var c map[string]any
	if json.Unmarshal(b, &c) != nil {
		t.Fatal("json")
	}
	in := c["inbounds"].([]any)[0].(map[string]any)
	if in["protocol"] != "socks" || in["listen"] != "127.0.0.1" {
		t.Fatal("not loopback SOCKS")
	}
	if in["settings"].(map[string]any)["auth"] != "password" {
		t.Fatal("unauthenticated listener")
	}
	outs := c["outbounds"].([]any)
	if outs[0].(map[string]any)["protocol"] != "blackhole" {
		t.Fatal("default not blocked")
	}
	for _, v := range outs {
		if v.(map[string]any)["protocol"] == "freedom" {
			t.Fatal("direct fallback")
		}
	}
	dns := c["dns"].(map[string]any)
	if dns["disableFallback"] != true {
		t.Fatal("DNS fallback enabled")
	}
}

func TestRoutingDNSPrecedesOnlyExactTrustedExclusions(t *testing.T) {
	p := RoutingPolicy{WindowsExecutablePaths: []string{"C:/Program Files/Example/browser.exe"}}
	rules, e := p.Rules("vpn")
	if e != nil {
		t.Fatal(e)
	}
	if len(rules) != 4 || rules[0]["outboundTag"] != "proxy" || rules[1]["outboundTag"] != "dns-out" || rules[2]["outboundTag"] != "direct-excluded" || rules[3]["outboundTag"] != "proxy" {
		t.Fatal("policy priority changed")
	}
	for _, path := range []string{"browser", "C:/Program Files/Example/", "C:/x/../browser.exe", "C:/x/*.exe", "relative.exe"} {
		if _, e := (RoutingPolicy{WindowsExecutablePaths: []string{path}}).Rules("vpn"); e == nil {
			t.Fatal("unsafe process pattern accepted")
		}
	}
	if _, e := (RoutingPolicy{AndroidUIDs: []int{-1}}).Rules("vpn"); e == nil {
		t.Fatal("unknown UID matched")
	}
	if _, e := (RoutingPolicy{AndroidUIDs: []int{10001}}).Rules("vpn"); e != nil {
		t.Fatal(e)
	}
}

func TestHysteriaAuthenticationIsTransportConfiguration(t *testing.T) {
	p := fixture("hysteria2")
	o := outbound(p)
	if o["protocol"] != "hysteria" {
		t.Fatal("wrong Xray protocol")
	}
	s := o["streamSettings"].(map[string]any)
	if s["network"] != "hysteria" || s["security"] != "tls" || s["hysteriaSettings"].(map[string]any)["auth"] != p.Password {
		t.Fatal("Hysteria transport credentials missing")
	}
}
