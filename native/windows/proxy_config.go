// SPDX-License-Identifier: Apache-2.0
package service

import (
	"encoding/json"
	exvpn "github.com/Extectick/ExVPN/native/core"
)

const systemProxyInbound = "system-proxy"

// Only a validated profile is projected. There is no TUN, direct outbound,
// application exclusion, DNS listener, WFP or system route in this config.
func BuildSystemProxyConfig(p exvpn.Profile, port int) ([]byte, error) {
	b, err := exvpn.BuildProbeConfig(p, exvpn.ProbeOptions{Port: port, Username: "unused", Password: "unused"})
	if err != nil {
		return nil, err
	}
	var config object
	if json.Unmarshal(b, &config) != nil {
		return nil, Code("config_rejected")
	}
	config["inbounds"] = []object{{"tag": systemProxyInbound, "listen": "127.0.0.1", "port": port, "protocol": "http", "settings": object{"allowTransparent": false}}}
	config["routing"] = object{"domainStrategy": "AsIs", "rules": []object{
		{"type": "field", "inboundTag": []string{"dns-query"}, "outboundTag": "proxy"},
		{"type": "field", "inboundTag": []string{systemProxyInbound}, "network": "tcp", "outboundTag": "proxy"},
	}}
	// The generation lease resolves only the endpoint; HTTP/CONNECT targets are
	// passed as domains to the selected remote protocol without local DNS.
	for _, raw := range config["outbounds"].([]any) {
		out := raw.(map[string]any)
		if out["tag"] == "proxy" {
			out["streamSettings"].(map[string]any)["sockopt"] = object{"domainStrategy": "AsIs"}
		}
	}
	config["stats"] = object{}
	config["policy"] = object{"system": object{"statsInboundUplink": true, "statsInboundDownlink": true}}
	return json.Marshal(config)
}
