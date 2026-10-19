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
	return buildTunnelConfig(p, exclusions, probe, nil)
}

// Validation has no resolver, route, listener or WFP side effects. A hostname
// is allowed here; it still cannot start a tunnel without a trusted resolution.
func validateTunnelProfile(p exvpn.Profile, exclusions []string) error {
	if _, err := exvpn.Compile(p); err != nil {
		return Code("profile_rejected")
	}
	if _, err := (exvpn.RoutingPolicy{WindowsExecutablePaths: exclusions}).Rules("vpn"); err != nil {
		return Code("exclusions_rejected")
	}
	return nil
}

func buildTunnelConfig(p exvpn.Profile, exclusions []string, probe exvpn.ProbeOptions, resolution *endpointResolution) ([]byte, error) {
	return buildTunnelConfigWithRouting(p, legacyApplicationRouting(exclusions), probe, resolution)
}

func buildTunnelConfigWithRouting(p exvpn.Profile, policy ApplicationRoutingPolicy, probe exvpn.ProbeOptions, resolution *endpointResolution) ([]byte, error) {
	if policy.validate() != nil {
		return nil, Code("application_routing_rejected")
	}
	exclusions := policy.effective()
	_, literalErr := netip.ParseAddr(p.Server)
	if literalErr != nil {
		name, err := endpointName(p.Server)
		if err != nil || resolution == nil || resolution.name != name || len(resolution.addresses) == 0 || len(resolution.addresses) > maxBootstrapAddresses {
			return nil, Code("server_ip_required")
		}
		for _, address := range resolution.addresses {
			if !usableEndpointAddress(address) {
				return nil, Code("bootstrap_address_rejected")
			}
		}
	} else if resolution != nil {
		return nil, Code("bootstrap_mapping_invalid")
	}
	b, err := exvpn.BuildProbeConfig(p, probe)
	if err != nil {
		return nil, err
	}
	var c object
	if json.Unmarshal(b, &c) != nil {
		return nil, Code("config_rejected")
	}
	if resolution != nil {
		addresses := make([]string, len(resolution.addresses))
		for i, address := range resolution.addresses {
			addresses[i] = address.Unmap().String()
		}
		dns := c["dns"].(map[string]any)
		dns["hosts"] = object{"full:" + resolution.name: addresses}
		dns["useSystemHosts"] = false
		for _, raw := range c["outbounds"].([]any) {
			out := raw.(map[string]any)
			if out["tag"] == "proxy" {
				// The ExVPN dialer validates the generation token before using
				// this already bootstrapped name. Upstream ForceIP resolves via
				// a global DNS client before reaching that lifetime check.
				stream := out["streamSettings"].(map[string]any)
				socket, _ := stream["sockopt"].(map[string]any)
				if socket == nil {
					socket = object{}
				}
				socket["domainStrategy"] = "AsIs"
				stream["sockopt"] = socket
			}
		}
	}
	rules, err := (exvpn.RoutingPolicy{WindowsExecutablePaths: exclusions, Mode: policy.Mode}).Rules("vpn")
	if err != nil {
		return nil, Code("exclusions_rejected")
	}
	if policy.Mode == exvpn.RoutingInclude || (policy.Mode == exvpn.RoutingExclude && len(exclusions) > 0) {
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
			"gateway": []string{"172.31.255.1/30", "fd71:6578:7670::1/126"},
			// Windows consumes packets addressed to its own adapter IP locally.
			// Use a distinct peer in each captured subnet so DNS reaches Xray.
			"dns":                    []string{"172.31.255.2", "fd71:6578:7670::2"},
			"autoSystemRoutingTable": []string{"0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"},
			// The process-lifetime ExVPN dialer binds every TCP/UDP socket to
			// this core generation's validated underlay lease. Upstream's
			// per-Start global hooks are not used for repeated reconnects.
			// Separate ExVPN WFP guard owns leak/crash protection. Upstream's
			// optional dynamic guard must not be mistaken for persistence.
			"autoSystemWfpBlockLeak": []string{},
		},
	})
	if policy.Mode == exvpn.RoutingInclude || (policy.Mode == exvpn.RoutingExclude && len(exclusions) > 0) {
		// Ownership checks accept numeric TUN tuples only, including every UDP
		// datagram. Never invoke upstream's global resolver for a direct flow.
		c["outbounds"] = append(c["outbounds"].([]any), object{"tag": "direct-excluded", "protocol": "freedom", "settings": object{"domainStrategy": "AsIs"}})
	}
	return json.Marshal(c)
}
