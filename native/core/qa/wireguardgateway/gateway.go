// SPDX-License-Identifier: Apache-2.0
// Package wireguardgateway is an authenticated userspace gateway for explicit
// isolated QA only. It is not linked into the production service or UI.
package wireguardgateway

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net"
	"sync"

	exvpn "github.com/Extectick/ExVPN/native/core"
	"github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/proxy/freedom"
)

type Options struct {
	Port              int
	PhysicalInterface string
}

type Gateway struct {
	mu       sync.Mutex
	instance *core.Instance
	config   []byte
	profile  exvpn.Profile
	closed   bool
}

// Start binds only loopback, generates one fresh peer with a preshared key and
// forwards its public TCP/UDP destinations without changing host networking.
func Start(options Options) (*Gateway, error) {
	if options.Port < 0 || options.Port > 65535 {
		return nil, exvpn.CodeError("qa_wireguard_arguments_invalid")
	}
	if options.PhysicalInterface != "" {
		adapter, err := net.InterfaceByName(options.PhysicalInterface)
		if err != nil || adapter.Name != options.PhysicalInterface || adapter.Flags&net.FlagUp == 0 || adapter.Flags&net.FlagLoopback != 0 {
			return nil, exvpn.CodeError("qa_wireguard_physical_interface_invalid")
		}
	}
	server, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, exvpn.CodeError("qa_wireguard_entropy_failed")
	}
	client, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, exvpn.CodeError("qa_wireguard_entropy_failed")
	}
	var preshared [32]byte
	if _, err := rand.Read(preshared[:]); err != nil {
		return nil, exvpn.CodeError("qa_wireguard_entropy_failed")
	}
	if options.Port == 0 {
		listener, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
		if err != nil {
			return nil, exvpn.CodeError("qa_wireguard_bind_failed")
		}
		options.Port = listener.LocalAddr().(*net.UDPAddr).Port
		_ = listener.Close()
	}
	encode := base64.StdEncoding.EncodeToString
	outbound := map[string]any{"protocol": "freedom", "settings": map[string]any{}}
	if options.PhysicalInterface != "" {
		// The explicit guest egress binding prevents its gateway from feeding
		// forwarded test traffic back into the TUN under examination.
		outbound["streamSettings"] = map[string]any{"sockopt": map[string]any{"interface": options.PhysicalInterface}}
	}
	config := map[string]any{
		"log": map[string]any{"loglevel": "none", "access": "none", "error": "none", "dnsLog": false},
		"inbounds": []any{map[string]any{
			"listen": "127.0.0.1", "port": options.Port, "protocol": "wireguard", "tag": "synthetic-wireguard",
			"settings": map[string]any{
				"secretKey": encode(server.Bytes()), "address": []string{"10.7.0.1/24", "fd00:7::1/64"}, "mtu": 1420, "noKernelTun": true,
				"peers": []any{map[string]any{"publicKey": encode(client.PublicKey().Bytes()), "preSharedKey": encode(preshared[:]), "allowedIPs": []string{"10.7.0.2/32", "fd00:7::2/128"}}},
			},
		}},
		// Xray's default freedom rules retain the private-destination block.
		"outbounds": []any{outbound},
	}
	encoded, err := json.Marshal(config)
	if err != nil {
		return nil, exvpn.CodeError("qa_wireguard_config_failed")
	}
	p := exvpn.Profile{ID: "qa-wireguard", Name: "Synthetic WireGuard QA", Protocol: "wireguard", Server: "127.0.0.1", Port: options.Port, Transport: exvpn.Transport{Type: "tcp"}, WireGuard: &exvpn.WireGuardOptions{PrivateKey: encode(client.Bytes()), PublicKey: encode(server.PublicKey().Bytes()), PreSharedKey: encode(preshared[:]), Addresses: []string{"10.7.0.2/32", "fd00:7::2/128"}, MTU: 1420, KeepAlive: 15}}
	if p.Validate() != nil {
		return nil, exvpn.CodeError("qa_wireguard_profile_failed")
	}
	g := &Gateway{config: encoded, profile: p}
	if err := g.SetOnline(true); err != nil {
		return nil, err
	}
	return g, nil
}

// Profile contains ephemeral secrets. Serialize it only to private QA inputs.
func (g *Gateway) Profile() exvpn.Profile {
	p := g.profile
	options := *p.WireGuard
	options.Addresses = append([]string(nil), options.Addresses...)
	options.Reserved = append([]int(nil), options.Reserved...)
	p.WireGuard = &options
	return p
}

func (g *Gateway) Online() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.instance != nil
}

// SetOnline closes/recreates only the owned instance with its original keys and
// port. It never edits routes, DNS, firewall or another WireGuard process.
func (g *Gateway) SetOnline(online bool) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.closed {
		return exvpn.CodeError("qa_wireguard_closed")
	}
	if !online && g.instance != nil {
		_ = g.instance.Close()
		g.instance = nil
	} else if online && g.instance == nil {
		instance, err := core.StartInstance("json", g.config)
		if err != nil {
			return exvpn.CodeError("qa_wireguard_start_failed")
		}
		g.instance = instance
	}
	return nil
}

func (g *Gateway) Close() error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.instance != nil {
		_ = g.instance.Close()
		g.instance = nil
	}
	g.closed = true
	return nil
}
