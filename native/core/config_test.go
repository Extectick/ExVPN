// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"encoding/base64"
	"encoding/json"
	"testing"

	xrayTLS "github.com/xtls/xray-core/transport/internet/tls"
)

func TestRealityEdgeCompatibilityPreservesPeerAuthentication(t *testing.T) {
	p := fixture("vless")
	p.TLS.Fingerprint = "edge"
	p.TLS.Reality = &Reality{
		PublicKey: base64.RawURLEncoding.EncodeToString(append([]byte{1}, make([]byte, 31)...)),
		ShortID:   "0123456789abcdef", SpiderX: "/",
	}
	settings := outbound(p)["streamSettings"].(object)["realitySettings"].(object)
	if settings["fingerprint"] != "chrome" || settings["serverName"] != p.TLS.ServerName ||
		settings["publicKey"] != p.TLS.Reality.PublicKey || settings["shortId"] != p.TLS.Reality.ShortID ||
		settings["spiderX"] != p.TLS.Reality.SpiderX || p.TLS.Fingerprint != "edge" || len(settings) != 5 {
		t.Fatal("Edge compatibility changed the profile or peer authentication")
	}
	p.TLS.Reality = nil
	tls := outbound(p)["streamSettings"].(object)["tlsSettings"].(object)
	if tls["fingerprint"] != "edge" || tls["allowInsecure"] != false {
		t.Fatal("REALITY-specific compatibility changed ordinary TLS")
	}
}

func TestQQFingerprintUsesPinnedCoreWithoutDisablingVerification(t *testing.T) {
	p := fixture("vless")
	p.TLS.Fingerprint = "qq"
	if xrayTLS.GetFingerprint("qq") == nil {
		t.Fatal("pinned core does not implement QQ")
	}
	if _, err := Compile(p); err != nil {
		t.Fatal(err)
	}
	settings := outbound(p)["streamSettings"].(map[string]any)["tlsSettings"].(map[string]any)
	if settings["fingerprint"] != "qq" || settings["allowInsecure"] != false || settings["serverName"] != p.TLS.ServerName {
		t.Fatal("fingerprint changed peer authentication")
	}
	p.TLS.Fingerprint = "qq-unknown"
	if _, err := Compile(p); err == nil {
		t.Fatal("unknown fingerprint silently accepted")
	}
}

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
