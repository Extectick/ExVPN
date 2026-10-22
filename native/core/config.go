// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"encoding/json"
	"regexp"
	"strconv"
	"strings"

	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf"
)

const CoreVersion = "26.10.10-exvpn.6"
const CoreCommit = "701af60772cda123492f86e383e1fdba066614a9"
const LibXrayCommit = "4e1f7843e6cddb750ac7abc23ef36800820a8098"

type object = map[string]any

// Exclusions are privileged local policy, never accepted from a subscription.
// Android entries are resolved UIDs, not untrusted provider strings.
type RoutingPolicy struct {
	WindowsExecutablePaths []string
	AndroidUIDs            []int
	Mode                   string
}

const RoutingDisabled = "disabled"
const RoutingExclude = "exclude"
const RoutingInclude = "include"
const ApplicationPolicyTag = "application-policy"

func RoutingMode(mode string, selected bool) (string, error) {
	if mode == "" {
		if selected {
			return RoutingExclude, nil
		}
		return RoutingDisabled, nil
	}
	if mode != RoutingDisabled && mode != RoutingExclude && mode != RoutingInclude {
		return "", CodeError("policy_invalid_mode")
	}
	return mode, nil
}

var windowsPath = regexp.MustCompile(`^[A-Za-z]:/[^:*?"<>|]+\.exe$`)

func (p RoutingPolicy) Rules(inbound string) ([]object, error) {
	mode, err := RoutingMode(p.Mode, len(p.WindowsExecutablePaths)+len(p.AndroidUIDs) != 0)
	if err != nil {
		return nil, err
	}
	if inbound != "probe" && inbound != "vpn" {
		return nil, CodeError("policy_invalid_inbound")
	}
	if len(p.WindowsExecutablePaths) != 0 && len(p.AndroidUIDs) != 0 {
		return nil, CodeError("policy_mixed_platforms")
	}
	processes := []string{}
	for _, path := range p.WindowsExecutablePaths {
		if !windowsPath.MatchString(path) || !clean(path, 1024) || strings.Contains(path, "/../") || strings.Contains(path, "/./") {
			return nil, CodeError("policy_invalid_executable")
		}
		processes = append(processes, path)
	}
	for _, uid := range p.AndroidUIDs {
		if uid < 10000 {
			return nil, CodeError("policy_invalid_uid")
		}
		processes = append(processes, strconv.Itoa(uid))
	}
	// Internal DNS and application DNS precede exclusions; no DNS direct fallback.
	rules := []object{
		{"type": "field", "inboundTag": []string{"dns-query"}, "outboundTag": "proxy"},
		{"type": "field", "inboundTag": []string{inbound}, "port": "53", "outboundTag": "dns-out"},
	}
	if mode == RoutingInclude {
		// Inversion of an upstream process matcher would also invert unknown
		// ownership. Only a platform's owned dispatcher may grant direct access.
		rules = append(rules, object{"type": "field", "inboundTag": []string{inbound}, "network": "tcp,udp", "outboundTag": ApplicationPolicyTag})
	} else if mode == RoutingExclude && len(processes) > 0 {
		rules = append(rules, object{"type": "field", "inboundTag": []string{inbound}, "process": processes, "outboundTag": "direct-excluded"})
	}
	rules = append(rules, object{"type": "field", "inboundTag": []string{inbound}, "network": "tcp,udp", "outboundTag": "proxy"})
	return rules, nil
}

type ProbeOptions struct {
	Port     int
	Username string
	Password string
}

// BuildProbeConfig produces only an authenticated loopback SOCKS listener.
// It cannot create a TUN, change system settings or install firewall rules.
func BuildProbeConfig(p Profile, opts ProbeOptions) ([]byte, error) {
	if e := p.Validate(); e != nil {
		return nil, e
	}
	if opts.Port < 1 || opts.Port > 65535 || opts.Username == "" || opts.Password == "" {
		return nil, CodeError("probe_invalid_listener")
	}
	rules, _ := (RoutingPolicy{}).Rules("probe")
	if p.TCPOnly() {
		rules = append([]object{{"type": "field", "inboundTag": []string{"probe"}, "network": "udp", "outboundTag": "blocked"}}, rules...)
	}
	c := object{
		"log":      object{"loglevel": "none", "access": "none", "error": "none", "dnsLog": false},
		"dns":      object{"tag": "dns-query", "servers": []string{"https://1.1.1.1/dns-query"}, "disableFallback": true, "queryStrategy": "UseIP"},
		"inbounds": []object{{"tag": "probe", "listen": "127.0.0.1", "port": opts.Port, "protocol": "socks", "settings": object{"auth": "password", "accounts": []object{{"user": opts.Username, "pass": opts.Password}}, "udp": false}}},
		// Blackhole is the default even if a future inbound accidentally lacks a rule.
		"outbounds": []object{{"tag": "blocked", "protocol": "blackhole"}, outbound(p), {"tag": "dns-out", "protocol": "dns"}},
		"routing":   object{"domainStrategy": "AsIs", "rules": rules},
	}
	return json.Marshal(c)
}

// Compile validates using the exact pinned core. It deliberately does not start
// any core object, open files referenced by config, or mutate host networking.
func Compile(p Profile) (*core.Config, error) {
	b, e := BuildProbeConfig(p, ProbeOptions{Port: 10808, Username: "compile-only", Password: "compile-only"})
	if e != nil {
		return nil, e
	}
	var c conf.Config
	if json.Unmarshal(b, &c) != nil {
		return nil, CodeError("core_config_invalid")
	}
	v, e := c.Build()
	if e != nil {
		return nil, CodeError("core_config_rejected")
	}
	return v, nil
}

func outbound(p Profile) object {
	stream := object{"network": p.Transport.Type, "security": "none"}
	// Only remote transport liveness knobs cross the provider boundary. Bind,
	// interface, DNS strategy, mark and dialer chains remain platform policy.
	if p.Transport.TCPKeepAliveIdle != nil || p.Transport.TCPKeepAliveInterval != nil {
		socket := object{}
		if p.Transport.TCPKeepAliveIdle != nil {
			socket["tcpKeepAliveIdle"] = *p.Transport.TCPKeepAliveIdle
		}
		if p.Transport.TCPKeepAliveInterval != nil {
			socket["tcpKeepAliveInterval"] = *p.Transport.TCPKeepAliveInterval
		}
		stream["sockopt"] = socket
	}
	if p.TLS.Enabled {
		stream["security"] = "tls"
		tls := object{"serverName": p.TLS.ServerName, "allowInsecure": false}
		if len(p.TLS.ALPN) > 0 {
			tls["alpn"] = p.TLS.ALPN
		} else if p.Protocol == "http" {
			// HTTPS CONNECT defaults to HTTP/1.1. Advertising implicit h2 to
			// HTTP/1.1-only proxy servers makes a valid TLS session unusable.
			tls["alpn"] = []string{"http/1.1"}
		}
		if p.TLS.Fingerprint != "" {
			tls["fingerprint"] = p.TLS.Fingerprint
		}
		stream["tlsSettings"] = tls
	}
	if r := p.TLS.Reality; r != nil {
		delete(stream, "tlsSettings")
		stream["security"] = "reality"
		fingerprint := p.TLS.Fingerprint
		if fingerprint == "" {
			fingerprint = "chrome"
		}
		// The pinned uTLS Edge_Auto is the obsolete Edge 85 hello and fails
		// REALITY handshakes. Use the pinned modern Chromium hello for this
		// browser alias only; peer keys, SNI and REALITY verification stay intact.
		// This is deterministic compatibility, never a retry without protection.
		if fingerprint == "edge" {
			fingerprint = "chrome"
		}
		stream["realitySettings"] = object{"serverName": p.TLS.ServerName, "fingerprint": fingerprint, "publicKey": r.PublicKey, "shortId": r.ShortID, "spiderX": r.SpiderX}
	}
	switch p.Transport.Type {
	case "ws":
		stream["wsSettings"] = object{"path": p.Transport.Path, "host": p.Transport.Host}
	case "grpc":
		stream["grpcSettings"] = object{"serviceName": p.Transport.ServiceName}
	case "xhttp":
		mode := p.Transport.Mode
		if mode == "" {
			mode = "auto"
		}
		stream["xhttpSettings"] = object{"path": p.Transport.Path, "host": p.Transport.Host, "mode": mode}
	case "hysteria":
		stream["hysteriaSettings"] = object{"version": 2, "auth": p.Password}
	case "masque":
		// Authentication uses the pinned CONNECT-IP transport's Basic header.
		// Path, remote resolver policy, WARP, headers and socket options are local.
		stream["masqueSettings"] = object{"user": p.Username, "pass": p.Password}
	}
	var settings object
	if s := p.Transport.TCPSudoku; s != nil {
		stream["finalmask"] = object{"tcp": []object{{"type": "sudoku", "settings": s}}}
	}
	if q := p.Transport.QuicParams; q != nil {
		stream["finalmask"] = object{"quicParams": q}
	}
	protocol := p.Protocol
	switch protocol {
	case "vless":
		encryption := p.Encryption
		if encryption == "" {
			encryption = "none"
		}
		settings = object{"vnext": []object{{"address": p.Server, "port": p.Port, "users": []object{{"id": p.UUID, "encryption": encryption, "flow": p.Flow}}}}}
	case "vmess":
		cipher := p.Cipher
		if cipher == "" {
			cipher = "auto"
		}
		settings = object{"vnext": []object{{"address": p.Server, "port": p.Port, "users": []object{{"id": p.UUID, "security": cipher, "alterId": 0}}}}}
	case "trojan":
		settings = object{"servers": []object{{"address": p.Server, "port": p.Port, "password": p.Password}}}
	case "shadowsocks":
		settings = object{"servers": []object{{"address": p.Server, "port": p.Port, "password": p.Password, "method": p.Cipher}}}
	case "hysteria2":
		protocol = "hysteria"
		settings = object{"version": 2, "address": p.Server, "port": p.Port}
	case "masque":
		settings = object{"address": p.Server, "port": p.Port, "remoteDNS": []string{"1.1.1.1", "1.0.0.1"}}
	case "socks5", "http", "wireguard":
		protocol, settings = additionalOutbound(p)
	}
	result := object{"tag": "proxy", "protocol": protocol, "settings": settings, "streamSettings": stream}
	if p.PacketEncoding == "xudp" {
		// Xray's typed mux sender implements XUDP. Disable TCP mux separately;
		// a raw packetEncoding field would be ignored by this pinned core.
		result["mux"] = object{"enabled": true, "concurrency": -1, "xudpConcurrency": 8, "xudpProxyUDP443": "allow"}
	}
	// Sec-WebSocket-Protocol is already the pinned WS dialer's only early-data
	// header. The accepted marker does not create arbitrary request headers.
	return result
}
