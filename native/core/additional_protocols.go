// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"encoding/base64"
	"net"
	"net/netip"
	"strconv"
)

// WireGuardOptions is one remote peer, never host networking policy.
type WireGuardOptions struct {
	PrivateKey   string   `json:"privateKey"`
	PublicKey    string   `json:"publicKey"`
	PreSharedKey string   `json:"preSharedKey,omitempty"`
	Addresses    []string `json:"addresses"`
	MTU          int      `json:"mtu"`
	KeepAlive    int      `json:"keepAlive,omitempty"`
	Reserved     []int    `json:"reserved,omitempty"`
}

func (p Profile) TCPOnly() bool { return p.Protocol == "socks5" || p.Protocol == "http" }

func (p Profile) validateAdditional() error {
	bad := CodeError("profile_invalid_additional_protocol")
	if (p.WireGuard != nil) != (p.Protocol == "wireguard") {
		return bad
	}
	if p.Username != "" && !p.TCPOnly() {
		return bad
	}
	if (p.TCPOnly() || p.Protocol == "wireguard") && (p.Transport.Type != "tcp" || p.Transport.Path != "" || p.Transport.Host != "" || p.Transport.ServiceName != "" || p.Transport.Mode != "" || p.Transport.TCPKeepAliveIdle != nil || p.Transport.TCPKeepAliveInterval != nil || p.Transport.TCPSudoku != nil || p.Transport.WSEarlyDataHeaderName != "") {
		return bad
	}
	if p.TCPOnly() {
		if p.Transport.Type != "tcp" || p.Transport.Path != "" || p.Transport.Host != "" || p.Transport.ServiceName != "" || p.Transport.Mode != "" || p.Transport.TCPKeepAliveIdle != nil || p.Transport.TCPKeepAliveInterval != nil || p.Transport.TCPSudoku != nil || p.TLS.Reality != nil || (p.Username == "") != (p.Password == "") || !clean(p.Username, 255) || len(p.Password) > 255 {
			return bad
		}
	}
	if w := p.WireGuard; w != nil {
		key := func(s string) bool {
			b, e := base64.StdEncoding.DecodeString(s)
			if e != nil || len(b) != 32 {
				return false
			}
			for _, v := range b {
				if v != 0 {
					return true
				}
			}
			return false
		}
		if !key(w.PrivateKey) || !key(w.PublicKey) || (w.PreSharedKey != "" && !key(w.PreSharedKey)) || w.MTU < 1280 || w.MTU > 1420 || w.KeepAlive < 0 || w.KeepAlive > 120 || len(w.Addresses) < 1 || len(w.Addresses) > 2 || (len(w.Reserved) != 0 && len(w.Reserved) != 3) || p.Transport.Type != "tcp" || p.TLS.Enabled || p.Password != "" || p.Username != "" {
			return bad
		}
		seen := map[string]bool{}
		for _, a := range w.Addresses {
			prefix, e := netip.ParsePrefix(a)
			if e != nil || prefix.Bits() < 1 || prefix.Addr().IsUnspecified() || prefix.Addr().IsMulticast() || seen[a] {
				return bad
			}
			seen[a] = true
		}
		for _, v := range w.Reserved {
			if v < 0 || v > 255 {
				return bad
			}
		}
	}
	return nil
}

func additionalOutbound(p Profile) (string, object) {
	if p.TCPOnly() {
		protocol := p.Protocol
		if protocol == "socks5" {
			protocol = "socks"
		}
		server := object{"address": p.Server, "port": p.Port}
		if p.Username != "" {
			server["users"] = []object{{"user": p.Username, "pass": p.Password}}
		}
		return protocol, object{"servers": []object{server}}
	}
	w := p.WireGuard
	peer := object{"endpoint": net.JoinHostPort(p.Server, strconv.Itoa(p.Port)), "publicKey": w.PublicKey, "allowedIPs": []string{"0.0.0.0/0", "::/0"}}
	if w.PreSharedKey != "" {
		peer["preSharedKey"] = w.PreSharedKey
	}
	if w.KeepAlive != 0 {
		peer["keepAlive"] = w.KeepAlive
	}
	settings := object{"secretKey": w.PrivateKey, "address": w.Addresses, "peers": []object{peer}, "mtu": w.MTU, "noKernelTun": true}
	if len(w.Reserved) != 0 {
		settings["reserved"] = w.Reserved
	}
	return "wireguard", settings
}
