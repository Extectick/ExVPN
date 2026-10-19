// SPDX-License-Identifier: Apache-2.0
package service

import (
	"encoding/base64"
	"encoding/json"
	exvpn "github.com/Extectick/ExVPN/native/core"
	"net/netip"
	"testing"
)

func TestAdditionalProtocolsUseTrustedEndpointAndPreserveDNSOrder(t *testing.T) {
	for _, protocol := range []string{"socks5", "http", "wireguard"} {
		p := exvpn.Profile{Protocol: protocol, Server: "vpn.example", Port: 443, Transport: exvpn.Transport{Type: "tcp"}}
		if protocol == "wireguard" {
			key := base64.StdEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef"))
			p.WireGuard = &exvpn.WireGuardOptions{PrivateKey: key, PublicKey: key, Addresses: []string{"10.7.0.2/32"}, MTU: 1420}
		}
		resolution := &endpointResolution{name: "vpn.example", addresses: []netip.Addr{netip.MustParseAddr("198.51.100.8")}, ttl: 60}
		for _, mode := range []string{exvpn.RoutingDisabled, exvpn.RoutingExclude, exvpn.RoutingInclude} {
			b, err := buildTunnelConfigWithRouting(p, ApplicationRoutingPolicy{Mode: mode, Applications: []string{"C:/Apps/Synthetic.exe"}}, exvpn.ProbeOptions{Port: 10808, Username: "local", Password: "local"}, resolution)
			if err != nil {
				t.Fatal(err)
			}
			var c map[string]any
			if json.Unmarshal(b, &c) != nil {
				t.Fatal("config")
			}
			rules := c["routing"].(map[string]any)["rules"].([]any)
			if rules[1].(map[string]any)["outboundTag"] != "dns-out" {
				t.Fatal("DNS lost precedence")
			}
			if protocol != "wireguard" && rules[2].(map[string]any)["outboundTag"] != "blocked" {
				t.Fatal("proxy UDP not blocked")
			}
			if protocol == "wireguard" {
				settings := c["outbounds"].([]any)[1].(map[string]any)["settings"].(map[string]any)
				if settings["noKernelTun"] != true || settings["peers"].([]any)[0].(map[string]any)["endpoint"] != "198.51.100.8:443" {
					t.Fatal("untrusted endpoint or kernel TUN")
				}
			}
		}
	}
}
