// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"regexp"
	"strings"
)

const MaxProfileBytes = 1 << 20

// CodeError contains no provider values, credentials, addresses or raw errors.
type CodeError string

func (e CodeError) Error() string { return string(e) }

type Profile struct {
	ID             string    `json:"id"`
	Name           string    `json:"name"`
	Protocol       string    `json:"protocol"`
	Server         string    `json:"server"`
	Port           int       `json:"port"`
	UUID           string    `json:"uuid,omitempty"`
	Password       string    `json:"password,omitempty"`
	Cipher         string    `json:"cipher,omitempty"`
	Flow           string    `json:"flow,omitempty"`
	Encryption     string    `json:"encryption,omitempty"`
	PacketEncoding string    `json:"packetEncoding,omitempty"`
	Transport      Transport `json:"transport"`
	TLS            TLS       `json:"tls"`
}

type Transport struct {
	Type                  string  `json:"type"`
	Path                  string  `json:"path,omitempty"`
	Host                  string  `json:"host,omitempty"`
	ServiceName           string  `json:"serviceName,omitempty"`
	Mode                  string  `json:"mode,omitempty"`
	TCPSudoku             *Sudoku `json:"tcpSudoku,omitempty"`
	TCPKeepAliveIdle      *int    `json:"tcpKeepAliveIdle,omitempty"`
	TCPKeepAliveInterval  *int    `json:"tcpKeepAliveInterval,omitempty"`
	WSEarlyDataHeaderName string  `json:"wsEarlyDataHeaderName,omitempty"`
}

type TLS struct {
	Enabled     bool     `json:"enabled"`
	ServerName  string   `json:"serverName,omitempty"`
	Fingerprint string   `json:"fingerprint,omitempty"`
	ALPN        []string `json:"alpn,omitempty"`
	Reality     *Reality `json:"reality,omitempty"`
}

type Reality struct {
	PublicKey string `json:"publicKey"`
	ShortID   string `json:"shortId"`
	SpiderX   string `json:"spiderX,omitempty"`
}

// DecodeProfile is the only provider-facing native JSON entry point. Inbounds,
// routing, files, sockets, log paths and update sources cannot cross this boundary.
func DecodeProfile(r io.Reader) (Profile, error) {
	b, err := io.ReadAll(io.LimitReader(r, MaxProfileBytes+1))
	if err != nil || len(b) > MaxProfileBytes {
		return Profile{}, CodeError("profile_read_failed")
	}
	if err := uniqueJSON(b); err != nil {
		return Profile{}, CodeError("profile_invalid_json")
	}
	var envelope map[string]json.RawMessage
	if json.Unmarshal(b, &envelope) != nil {
		return Profile{}, CodeError("profile_invalid_schema")
	}
	if !onlyKeys(envelope, "id", "name", "protocol", "server", "port", "uuid", "password", "cipher", "flow", "encryption", "packetEncoding", "transport", "tls") {
		return Profile{}, CodeError("profile_invalid_schema")
	}
	for _, key := range []string{"protocol", "server", "port", "transport", "tls"} {
		if _, ok := envelope[key]; !ok {
			return Profile{}, CodeError("profile_invalid_schema")
		}
	}
	var tlsFields map[string]json.RawMessage
	if json.Unmarshal(envelope["tls"], &tlsFields) != nil {
		return Profile{}, CodeError("profile_invalid_schema")
	}
	if !onlyKeys(tlsFields, "enabled", "serverName", "fingerprint", "alpn", "reality") {
		return Profile{}, CodeError("profile_invalid_schema")
	}
	var transportFields map[string]json.RawMessage
	if json.Unmarshal(envelope["transport"], &transportFields) != nil || !onlyKeys(transportFields, "type", "path", "host", "serviceName", "mode", "tcpSudoku", "tcpKeepAliveIdle", "tcpKeepAliveInterval", "wsEarlyDataHeaderName") {
		return Profile{}, CodeError("profile_invalid_schema")
	}
	if raw, ok := transportFields["tcpSudoku"]; ok {
		var sudokuFields map[string]json.RawMessage
		if json.Unmarshal(raw, &sudokuFields) != nil || !onlyKeys(sudokuFields, "password", "ascii", "customTables", "paddingMin", "paddingMax") {
			return Profile{}, CodeError("profile_invalid_schema")
		}
	}
	if raw, ok := tlsFields["reality"]; ok {
		var realityFields map[string]json.RawMessage
		if json.Unmarshal(raw, &realityFields) != nil || !onlyKeys(realityFields, "publicKey", "shortId", "spiderX") {
			return Profile{}, CodeError("profile_invalid_schema")
		}
	}
	if _, ok := tlsFields["enabled"]; !ok {
		return Profile{}, CodeError("profile_invalid_schema")
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	var p Profile
	if err := d.Decode(&p); err != nil {
		return Profile{}, CodeError("profile_invalid_schema")
	}
	if err := p.Validate(); err != nil {
		return Profile{}, err
	}
	return p, nil
}

func onlyKeys(fields map[string]json.RawMessage, allowed ...string) bool {
	for key := range fields {
		if !oneOf(key, allowed...) {
			return false
		}
	}
	return true
}

// Reject duplicate object keys and trailing values rather than accept ambiguous
// input interpreted differently by Dart and the native service.
func uniqueJSON(b []byte) error {
	d := json.NewDecoder(bytes.NewReader(b))
	var walk func() error
	depth := 0
	walk = func() error {
		depth++
		defer func() { depth-- }()
		if depth > 32 {
			return errors.New("too deeply nested")
		}
		t, err := d.Token()
		if err != nil {
			return err
		}
		if t == nil {
			return errors.New("null fields are not supported")
		}
		if delim, ok := t.(json.Delim); ok {
			switch delim {
			case '{':
				seen := map[string]bool{}
				for d.More() {
					k, e := d.Token()
					if e != nil {
						return e
					}
					key, ok := k.(string)
					if !ok || seen[key] {
						return errors.New("duplicate")
					}
					seen[key] = true
					if e = walk(); e != nil {
						return e
					}
				}
			case '[':
				for d.More() {
					if e := walk(); e != nil {
						return e
					}
				}
			default:
				return errors.New("delimiter")
			}
			_, err = d.Token()
			return err
		}
		return nil
	}
	if err := walk(); err != nil {
		return err
	}
	if _, err := d.Token(); err != io.EOF {
		return errors.New("trailing")
	}
	return nil
}

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
var dnsPattern = regexp.MustCompile(`^(?i:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(?:\.(?i:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?))*\.?$`)

func validHost(s string) bool {
	return len(s) <= 253 && s != "" && (net.ParseIP(s) != nil || dnsPattern.MatchString(s))
}
func clean(s string, max int) bool { return len(s) <= max && !strings.ContainsAny(s, "\x00\r\n") }
func oneOf(s string, values ...string) bool {
	for _, v := range values {
		if s == v {
			return true
		}
	}
	return false
}

func (p Profile) Validate() error {
	bad := func(code string) error { return CodeError("profile_" + code) }
	if !validHost(p.Server) || p.Port < 1 || p.Port > 65535 {
		return bad("invalid_endpoint")
	}
	if ip := net.ParseIP(p.Server); ip != nil && ip.IsUnspecified() {
		return bad("invalid_endpoint")
	}
	if !clean(p.ID, 128) || !clean(p.Name, 256) || !clean(p.Password, 4096) {
		return bad("invalid_text")
	}
	if !oneOf(p.Protocol, "vless", "vmess", "trojan", "shadowsocks", "hysteria2") {
		return bad("unsupported_protocol")
	}
	if oneOf(p.Protocol, "vless", "vmess") && !uuidPattern.MatchString(p.UUID) {
		return bad("invalid_uuid")
	}
	if oneOf(p.Protocol, "trojan", "shadowsocks", "hysteria2") && p.Password == "" {
		return bad("missing_password")
	}
	if p.Flow != "" && (p.Protocol != "vless" || p.Flow != "xtls-rprx-vision") {
		return bad("unsupported_flow")
	}
	if p.Encryption != "" && (p.Protocol != "vless" || !validVlessEncryption(p.Encryption)) {
		return bad("invalid_encryption")
	}
	if p.PacketEncoding != "" && (p.Protocol != "vless" || p.PacketEncoding != "xudp") {
		return bad("unsupported_packet_encoding")
	}
	for _, seconds := range []*int{p.Transport.TCPKeepAliveIdle, p.Transport.TCPKeepAliveInterval} {
		if seconds != nil && (*seconds < 1 || *seconds > 86400 || p.Transport.Type == "hysteria") {
			return bad("invalid_keepalive")
		}
	}
	if p.Transport.WSEarlyDataHeaderName != "" && (p.Transport.Type != "ws" || p.Transport.WSEarlyDataHeaderName != "Sec-WebSocket-Protocol") {
		return bad("unsupported_ws_early_data_header")
	}
	if s := p.Transport.TCPSudoku; s != nil && (p.Protocol != "vless" || p.Transport.Type != "tcp" || (!p.TLS.Enabled && p.Encryption == "") || !s.valid()) {
		return bad("invalid_sudoku")
	}
	if p.UUID != "" && !oneOf(p.Protocol, "vless", "vmess") {
		return bad("unexpected_uuid")
	}
	if p.Password != "" && !oneOf(p.Protocol, "trojan", "shadowsocks", "hysteria2") {
		return bad("unexpected_password")
	}
	if p.Cipher != "" && !oneOf(p.Protocol, "shadowsocks", "vmess") {
		return bad("unexpected_cipher")
	}
	if p.Protocol == "shadowsocks" && !oneOf(p.Cipher, "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305") {
		return bad("unsupported_cipher")
	}
	if p.Protocol == "shadowsocks" && strings.HasPrefix(p.Cipher, "2022-") {
		keySize := 32
		if p.Cipher == "2022-blake3-aes-128-gcm" {
			keySize = 16
		}
		for _, part := range strings.Split(p.Password, ":") {
			key, e := base64.StdEncoding.DecodeString(part)
			if e != nil || len(key) != keySize {
				return bad("invalid_shadowsocks_key")
			}
		}
	}
	if p.Protocol == "vmess" && !oneOf(p.Cipher, "", "auto", "aes-128-gcm", "chacha20-poly1305") {
		return bad("unsupported_cipher")
	}
	if !oneOf(p.Transport.Type, "tcp", "ws", "grpc", "xhttp", "hysteria") {
		return bad("unsupported_transport")
	}
	if (p.Protocol == "hysteria2") != (p.Transport.Type == "hysteria") {
		return bad("invalid_transport")
	}
	if p.Protocol == "hysteria2" && (!p.TLS.Enabled || p.TLS.Reality != nil) {
		return bad("tls_required")
	}
	if p.Protocol == "trojan" && !p.TLS.Enabled {
		return bad("tls_required")
	}
	if p.Transport.Path != "" && (!strings.HasPrefix(p.Transport.Path, "/") || !clean(p.Transport.Path, 4096)) {
		return bad("invalid_path")
	}
	if p.Transport.Host != "" && !validHost(p.Transport.Host) {
		return bad("invalid_host")
	}
	if !clean(p.Transport.ServiceName, 256) {
		return bad("invalid_service")
	}
	if (p.Transport.Path != "" || p.Transport.Host != "") && !oneOf(p.Transport.Type, "ws", "xhttp") {
		return bad("unexpected_http_transport_fields")
	}
	if p.Transport.ServiceName != "" && p.Transport.Type != "grpc" {
		return bad("unexpected_grpc_service")
	}
	if p.Transport.Mode != "" && (p.Transport.Type != "xhttp" || !oneOf(p.Transport.Mode, "auto", "packet-up", "stream-up", "stream-one")) {
		return bad("invalid_mode")
	}
	if p.Flow != "" && (p.Transport.Type != "tcp" || (!p.TLS.Enabled && p.Encryption == "")) {
		return bad("invalid_flow_transport")
	}
	if p.TLS.ServerName != "" && !validHost(p.TLS.ServerName) {
		return bad("invalid_server_name")
	}
	if !p.TLS.Enabled && (p.TLS.ServerName != "" || p.TLS.Fingerprint != "" || len(p.TLS.ALPN) != 0 || p.TLS.Reality != nil) {
		return bad("unexpected_tls_fields")
	}
	if !oneOf(p.TLS.Fingerprint, "", "chrome", "firefox", "safari", "ios", "android", "edge", "qq", "random", "randomized") {
		return bad("unsupported_fingerprint")
	}
	if len(p.TLS.ALPN) > 8 {
		return bad("invalid_alpn")
	}
	for _, a := range p.TLS.ALPN {
		if a == "" || !clean(a, 255) {
			return bad("invalid_alpn")
		}
	}
	if r := p.TLS.Reality; r != nil {
		if !p.TLS.Enabled || p.Protocol != "vless" || !oneOf(p.Transport.Type, "tcp", "xhttp", "grpc") {
			return bad("invalid_reality")
		}
		key, e := base64.RawURLEncoding.DecodeString(r.PublicKey)
		if e != nil || len(key) != 32 {
			return bad("invalid_reality_key")
		}
		sid, e := hex.DecodeString(r.ShortID)
		if e != nil || len(sid) > 8 {
			return bad("invalid_reality_short_id")
		}
		if !clean(r.SpiderX, 1024) || (r.SpiderX != "" && !strings.HasPrefix(r.SpiderX, "/")) {
			return bad("invalid_reality_spider")
		}
	}
	return nil
}
