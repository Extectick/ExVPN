// SPDX-License-Identifier: Apache-2.0
package androidcore

import (
	"encoding/json"
	"testing"

	exvpn "github.com/Extectick/ExVPN/native/core"
	"github.com/xtls/xray-core/infra/conf"
)

func sample() exvpn.Profile {
	return exvpn.Profile{ID: "synthetic", Name: "Sample", Protocol: "vless", Server: "vpn.example.invalid", Port: 443,
		UUID: "00000000-0000-4000-8000-000000000001", Transport: exvpn.Transport{Type: "tcp"}, TLS: exvpn.TLS{Enabled: true}}
}

func TestAndroidConfigurationKeepsDNSBeforeUIDAndNeverDefaultDirect(t *testing.T) {
	b, err := BuildConfig(sample(), "192.0.2.1", []int{10001})
	if err != nil {
		t.Fatal(err)
	}
	var c map[string]any
	if json.Unmarshal(b, &c) != nil {
		t.Fatal("json")
	}
	out := c["outbounds"].([]any)
	if out[0].(map[string]any)["protocol"] != "blackhole" {
		t.Fatal("default permits escape")
	}
	if out[len(out)-1].(map[string]any)["settings"].(map[string]any)["domainStrategy"] != "ForceIP" {
		t.Fatal("direct exemption must not fall back to the platform resolver")
	}
	rules := c["routing"].(map[string]any)["rules"].([]any)
	if rules[2].(map[string]any)["outboundTag"] != "dns-out" || rules[3].(map[string]any)["outboundTag"] != "direct-excluded" {
		t.Fatal("DNS must precede exclusions")
	}
	last := rules[len(rules)-1].(map[string]any)
	if last["outboundTag"] != "proxy" {
		t.Fatal("unknown owner bypass")
	}
	tls := out[1].(map[string]any)["streamSettings"].(map[string]any)["tlsSettings"].(map[string]any)
	if tls["serverName"] != "vpn.example.invalid" || tls["allowInsecure"] != false {
		t.Fatal("bootstrap changed certificate identity")
	}
	var compiled conf.Config
	if json.Unmarshal(b, &compiled) != nil {
		t.Fatal("decode")
	}
	if _, err := compiled.Build(); err != nil {
		t.Fatalf("pinned core rejects schema: %v", err)
	}
}

func TestUntrustedPolicyAndEndpointRejected(t *testing.T) {
	for _, tc := range []struct {
		ip   string
		uids []int
	}{{"example.invalid", nil}, {"192.0.2.1", []int{0}}, {"192.0.2.1", []int{-1}}} {
		if _, err := BuildConfig(sample(), tc.ip, tc.uids); err == nil {
			t.Fatal("invalid policy accepted")
		}
	}
}

func TestNoExemptionsCreatesNoDirectOutbound(t *testing.T) {
	b, err := BuildConfig(sample(), "2001:db8::1", nil)
	if err != nil {
		t.Fatal(err)
	}
	var c map[string]any
	_ = json.Unmarshal(b, &c)
	for _, o := range c["outbounds"].([]any) {
		if o.(map[string]any)["protocol"] == "freedom" {
			t.Fatal("unrequested direct")
		}
	}
}
