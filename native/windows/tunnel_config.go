// SPDX-License-Identifier: Apache-2.0
package service

import (
	"encoding/json"
	"net/netip"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

const TunnelName = "ExVPN-Tunnel"
const applicationPolicyTag = "application-policy"

type object = map[string]any

// BuildTunnelConfig projects an already validated profile through the shared
// compiler, replacing only application-owned inbounds and policy. It never
// accepts provider DNS, routes, listeners or arbitrary Xray configuration.
func BuildTunnelConfig(p exvpn.Profile, exclusions []string, probe exvpn.ProbeOptions) ([]byte, error) {
	if _, err := netip.ParseAddr(p.Server); err != nil {
		return nil, Code("server_ip_required")
	}
	b, err := exvpn.BuildProbeConfig(p, probe)
	if err != nil {
		return nil, err
	}
	var c object
	if json.Unmarshal(b, &c) != nil {
		return nil, Code("config_rejected")
	}
	rules, err := (exvpn.RoutingPolicy{WindowsExecutablePaths: exclusions}).Rules("vpn")
	if err != nil {
		return nil, Code("exclusions_rejected")
	}
	if len(exclusions) > 0 {
		// Keep the shared path validator and DNS precedence, but never use the
		// pinned Windows process matcher: it ignores the remote TCP endpoint
		// and chooses the first ambiguous UDP row. The native adapter checks
		// ownership before delegating to direct-excluded or proxy instead.
		rules[2] = object{"type": "field", "inboundTag": []string{"vpn"}, "network": "tcp,udp", "outboundTag": applicationPolicyTag}
	}
	probeRules, _ := (exvpn.RoutingPolicy{}).Rules("probe")
	rules = append(rules, probeRules...)
	c["routing"] = object{"domainStrategy": "AsIs", "rules": rules}
	c["stats"] = object{}
	c["policy"] = object{"system": object{"statsInboundUplink": true, "statsInboundDownlink": true}}
	c["inbounds"] = append(c["inbounds"].([]any), object{
		"tag": "vpn", "protocol": "tun", "settings": object{
			"name": TunnelName, "desc": "ExVPN", "mtu": 1500,
			"gateway":                []string{"172.31.255.1/30", "fd71:6578:7670::1/126"},
			"dns":                    []string{"172.31.255.1", "fd71:6578:7670::1"},
			"autoSystemRoutingTable": []string{"0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"},
			"autoOutboundsInterface": "auto",
			// Separate ExVPN WFP guard owns leak/crash protection. Upstream's
			// optional dynamic guard must not be mistaken for persistence.
			"autoSystemWfpBlockLeak": []string{},
		},
	})
	if len(exclusions) > 0 {
		c["outbounds"] = append(c["outbounds"].([]any), object{"tag": "direct-excluded", "protocol": "freedom", "settings": object{"domainStrategy": "ForceIP"}})
	}
	return json.Marshal(c)
}
