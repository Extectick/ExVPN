// SPDX-License-Identifier: Apache-2.0
package service

import (
	"encoding/json"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

func buildTunnelConfigWithPolicies(p exvpn.Profile, application ApplicationRoutingPolicy, site exvpn.SiteRoutingPolicy, probe exvpn.ProbeOptions, resolution *endpointResolution) ([]byte, error) {
	if _, err := exvpn.NewSiteMatcher(site); err != nil {
		return nil, Code("site_routing_rejected")
	}
	b, err := buildTunnelConfigWithRouting(p, application, probe, resolution)
	if err != nil || !site.Active() {
		return b, err
	}
	var config object
	if json.Unmarshal(b, &config) != nil {
		return nil, Code("config_rejected")
	}
	// Keep the existing DNS and TCP-only UDP gates ahead of this owned route.
	// No domain/IP rule is allowed to authorize a direct outbound by itself.
	routing := config["routing"].(map[string]any)
	for _, raw := range routing["rules"].([]any) {
		rule := raw.(map[string]any)
		inbound, ok := rule["inboundTag"].([]any)
		if !ok || len(inbound) != 1 || inbound[0] != "vpn" || rule["network"] != "tcp,udp" {
			continue
		}
		if rule["outboundTag"] == "proxy" || rule["outboundTag"] == applicationPolicyTag {
			rule["outboundTag"] = applicationPolicyTag
		}
	}
	for _, raw := range config["inbounds"].([]any) {
		inbound := raw.(map[string]any)
		if inbound["tag"] == "vpn" {
			// Classification only: the original numeric destination stays intact
			// for ownership verification and the underlay-bound direct dialer.
			inbound["sniffing"] = object{
				"enabled": true, "destOverride": []string{"http", "tls", "quic"}, "routeOnly": true,
			}
		}
	}
	outs := config["outbounds"].([]any)
	hasDirect := false
	for _, raw := range outs {
		if raw.(map[string]any)["tag"] == "direct-excluded" {
			hasDirect = true
		}
	}
	if !hasDirect {
		config["outbounds"] = append(outs, object{"tag": "direct-excluded", "protocol": "freedom", "settings": object{"domainStrategy": "AsIs"}})
	}
	return json.Marshal(config)
}
