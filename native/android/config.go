// SPDX-License-Identifier: Apache-2.0
package androidcore

import (
	"encoding/json"
	"net"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

// BuildConfig accepts only a normalized profile and locally resolved policy.
// Endpoint bootstrap is the only resolution permitted on the underlying network.
func BuildConfig(p exvpn.Profile, endpointIP string, uids []int) ([]byte, error) {
	if net.ParseIP(endpointIP) == nil {
		return nil, exvpn.CodeError("endpoint_invalid_ip")
	}
	if err := p.Validate(); err != nil {
		return nil, err
	}
	if p.TLS.Enabled && p.TLS.ServerName == "" {
		p.TLS.ServerName = p.Server
	}
	p.Server = endpointIP
	data, err := exvpn.BuildProbeConfig(p, exvpn.ProbeOptions{Port: 10808, Username: "unused", Password: "unused"})
	if err != nil {
		return nil, err
	}
	var config map[string]any
	if json.Unmarshal(data, &config) != nil {
		return nil, exvpn.CodeError("config_invalid")
	}
	rules, err := (exvpn.RoutingPolicy{AndroidUIDs: uids}).Rules("vpn")
	if err != nil {
		return nil, err
	}
	rules = append([]map[string]any{{"type": "field", "inboundTag": []string{"healthcheck"}, "outboundTag": "proxy"}}, rules...)
	config["routing"] = map[string]any{"domainStrategy": "AsIs", "rules": rules}
	config["inbounds"] = []any{map[string]any{"tag": "vpn", "protocol": "tun", "settings": map[string]any{
		"name": "ExVPN", "mtu": 1500, "autoOutboundsInterface": "",
	}}}
	outbounds := config["outbounds"].([]any)
	if len(uids) != 0 {
		outbounds = append(outbounds, map[string]any{
			"tag": "direct-excluded", "protocol": "freedom", "settings": map[string]any{"domainStrategy": "ForceIP"},
		})
	}
	config["outbounds"] = outbounds
	config["stats"] = map[string]any{}
	config["policy"] = map[string]any{"system": map[string]any{"statsInboundUplink": true, "statsInboundDownlink": true}}
	return json.Marshal(config)
}
