// SPDX-License-Identifier: Apache-2.0
package service

import (
	"encoding/json"
	"net/netip"
	"testing"

	exvpn "github.com/Extectick/ExVPN/native/core"
	"github.com/xtls/xray-core/transport/internet"
)

func TestKeepAliveSurvivesOwnedEndpointBootstrap(t *testing.T) {
	p := syntheticProfile()
	p.Server = "vpn.example"
	idle, interval := 60, 20
	p.Transport.TCPKeepAliveIdle, p.Transport.TCPKeepAliveInterval = &idle, &interval
	resolution := endpointResolution{name: p.Server, addresses: []netip.Addr{netip.MustParseAddr("192.0.2.9")}, ttl: 30}
	tunnel, err := buildTunnelConfig(p, nil, exvpn.ProbeOptions{Port: 10808, Username: "test", Password: "test"}, &resolution)
	if err != nil {
		t.Fatal(err)
	}
	proxy, err := BuildSystemProxyConfig(p, 10808)
	if err != nil {
		t.Fatal(err)
	}
	for _, wire := range [][]byte{tunnel, proxy} {
		var decoded map[string]any
		if json.Unmarshal(wire, &decoded) != nil {
			t.Fatal("invalid generated config")
		}
		outbound := decoded["outbounds"].([]any)[1].(map[string]any)
		socket := outbound["streamSettings"].(map[string]any)["sockopt"].(map[string]any)
		if len(socket) != 3 || socket["domainStrategy"] != "AsIs" || socket["tcpKeepAliveIdle"] != float64(60) || socket["tcpKeepAliveInterval"] != float64(20) {
			t.Fatal("bootstrap changed remote liveness or privileged resolver policy")
		}
	}
}

func TestOwnedSocketKeepAliveDoesNotRelaxLease(t *testing.T) {
	valid := &internet.SocketConfig{TcpKeepAliveIdle: 60, TcpKeepAliveInterval: 20}
	if !ownedSocketOptions(valid, "") {
		t.Fatal("safe keepalive rejected")
	}
	for _, invalid := range []*internet.SocketConfig{
		{TcpKeepAliveIdle: -1}, {TcpKeepAliveInterval: 86401},
		{TcpKeepAliveIdle: 60, Interface: "external"}, {TcpKeepAliveIdle: 60, Mark: 1},
		{TcpKeepAliveIdle: 60, DomainStrategy: internet.DomainStrategy_USE_IP},
		{TcpKeepAliveIdle: 60, DialerProxy: "direct"},
	} {
		if ownedSocketOptions(invalid, "") {
			t.Fatal("liveness allowed socket policy bypass")
		}
	}
}
