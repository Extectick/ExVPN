// SPDX-License-Identifier: Apache-2.0
package androidcore

import (
	"encoding/base64"
	"encoding/json"
	exvpn "github.com/Extectick/ExVPN/native/core"
	"testing"
)

func TestAdditionalProtocolsPreserveDNSAndBlockUnsupportedUDP(t *testing.T) {
	for _, protocol := range []string{"socks5", "http", "wireguard"} {
		p := exvpn.Profile{Protocol: protocol, Server: "vpn.example", Port: 443, Transport: exvpn.Transport{Type: "tcp"}}
		if protocol == "wireguard" {
			key := base64.StdEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef"))
			p.WireGuard = &exvpn.WireGuardOptions{PrivateKey: key, PublicKey: key, Addresses: []string{"10.7.0.2/32"}, MTU: 1420}
		}
		for _, mode := range []string{exvpn.RoutingDisabled, exvpn.RoutingExclude, exvpn.RoutingInclude} {
			b, err := BuildConfigWithRouting(p, "198.51.100.8", mode, []int{10001})
			if err != nil {
				t.Fatal(err)
			}
			var c map[string]any
			if json.Unmarshal(b, &c) != nil {
				t.Fatal("config")
			}
			rules := c["routing"].(map[string]any)["rules"].([]any)
			if rules[2].(map[string]any)["outboundTag"] != "dns-out" {
				t.Fatal("DNS lost precedence")
			}
			if protocol != "wireguard" && rules[3].(map[string]any)["outboundTag"] != "blocked" {
				t.Fatal("proxy UDP not blocked before application dispatcher")
			}
			if protocol == "wireguard" {
				o := c["outbounds"].([]any)[1].(map[string]any)
				settings := o["settings"].(map[string]any)
				if settings["noKernelTun"] != true || settings["peers"].([]any)[0].(map[string]any)["endpoint"] != "198.51.100.8:443" {
					t.Fatal("untrusted WireGuard endpoint or kernel TUN")
				}
			}
		}
	}
}
