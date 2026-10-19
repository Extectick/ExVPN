// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"encoding/base64"
	"encoding/json"
	"testing"
)

func additionalProfile(protocol string) Profile {
	p := Profile{ID: "synthetic", Name: "Synthetic", Protocol: protocol, Server: "198.51.100.8", Port: 443, Transport: Transport{Type: "tcp"}}
	if protocol == "wireguard" {
		key := base64.StdEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef"))
		p.WireGuard = &WireGuardOptions{PrivateKey: key, PublicKey: key, Addresses: []string{"10.7.0.2/32", "fd00:7::2/128"}, MTU: 1420, Reserved: []int{1, 2, 3}}
	}
	return p
}

func TestAdditionalProtocolsCompileWithPinnedCore(t *testing.T) {
	for _, protocol := range []string{"socks5", "http", "wireguard"} {
		t.Run(protocol, func(t *testing.T) {
			p := additionalProfile(protocol)
			if protocol != "wireguard" {
				p.Username = "synthetic-user"
				p.Password = "synthetic-password"
				p.TLS = TLS{Enabled: true, ServerName: "vpn.example"}
			}
			if _, err := Compile(p); err != nil {
				t.Fatalf("compile: %v", err)
			}
			b, err := BuildProbeConfig(p, ProbeOptions{Port: 10808, Username: "local", Password: "local"})
			if err != nil {
				t.Fatal(err)
			}
			var c object
			if json.Unmarshal(b, &c) != nil {
				t.Fatal("json")
			}
			out := c["outbounds"].([]any)[1].(map[string]any)
			s := out["settings"].(map[string]any)
			if protocol == "wireguard" {
				if s["noKernelTun"] != true {
					t.Fatal("kernel TUN requested")
				}
				peers := s["peers"].([]any)
				if len(peers) != 1 {
					t.Fatal("peer count")
				}
				allowed := peers[0].(map[string]any)["allowedIPs"].([]any)
				if len(allowed) != 2 || allowed[0] != "0.0.0.0/0" || allowed[1] != "::/0" {
					t.Fatal("provider routes")
				}
			} else {
				rule := c["routing"].(map[string]any)["rules"].([]any)[0].(map[string]any)
				if rule["network"] != "udp" || rule["outboundTag"] != "blocked" {
					t.Fatal("UDP not blocked")
				}
			}
		})
	}
}

func TestAdditionalProtocolValidationRejectsUnsafeOptions(t *testing.T) {
	for _, mutate := range []func(*Profile){
		func(p *Profile) { p.WireGuard.PrivateKey = "bad" },
		func(p *Profile) { p.WireGuard.MTU = 9000 },
		func(p *Profile) { p.WireGuard.Addresses = []string{"0.0.0.0/0"} },
		func(p *Profile) { p.WireGuard.Reserved = []int{256, 0, 0} },
		func(p *Profile) { p.TLS.Enabled = true },
	} {
		p := additionalProfile("wireguard")
		mutate(&p)
		if p.Validate() == nil {
			t.Fatal("unsafe WireGuard accepted")
		}
	}
	p := additionalProfile("http")
	p.Password = "orphan"
	if p.Validate() == nil {
		t.Fatal("orphan credential")
	}
	p = additionalProfile("socks5")
	p.Transport.Type = "ws"
	if p.Validate() == nil {
		t.Fatal("unsupported transport")
	}
}
