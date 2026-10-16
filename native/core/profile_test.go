// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func fixture(protocol string) Profile {
	p := Profile{ID: "synthetic", Name: "Documentation fixture", Protocol: protocol, Server: "192.0.2.1", Port: 443, Transport: Transport{Type: "tcp"}, TLS: TLS{Enabled: true, ServerName: "example.com"}}
	switch protocol {
	case "vless", "vmess":
		p.UUID = "12345678-1234-4234-8234-123456789abc"
	case "trojan", "hysteria2":
		p.Password = "synthetic-test-password"
	case "shadowsocks":
		p.Password = "synthetic-test-password"
		p.Cipher = "aes-256-gcm"
		p.TLS = TLS{}
	}
	if protocol == "hysteria2" {
		p.Transport.Type = "hysteria"
	}
	return p
}

func TestSupportedProfilesCompileAgainstPinnedCore(t *testing.T) {
	for _, protocol := range []string{"vless", "vmess", "trojan", "shadowsocks", "hysteria2"} {
		t.Run(protocol, func(t *testing.T) {
			if _, err := Compile(fixture(protocol)); err != nil {
				t.Fatal(err)
			}
		})
	}
	for _, transport := range []string{"tcp", "ws", "grpc", "xhttp"} {
		t.Run("vless/"+transport, func(t *testing.T) {
			p := fixture("vless")
			p.Transport.Type = transport
			if transport == "ws" || transport == "xhttp" {
				p.Transport.Path = "/vpn"
				p.Transport.Host = "example.com"
			}
			if transport == "grpc" {
				p.Transport.ServiceName = "vpn"
			}
			if _, err := Compile(p); err != nil {
				t.Fatal(err)
			}
		})
	}
	p := fixture("vless")
	p.Flow = "xtls-rprx-vision"
	p.TLS.Reality = &Reality{PublicKey: "XBXsHxq4cT8BWHzJm8GGpXWjZy1AMVZlQdBz3sXLfFo", ShortID: "0123456789abcdef"}
	if _, err := Compile(p); err != nil {
		t.Fatal(err)
	}
}

func TestDecodeRejectsMalformedAndProviderControl(t *testing.T) {
	b, _ := json.Marshal(fixture("vless"))
	base := string(b)
	cases := []string{
		strings.Replace(base, `"port":443`, `"port":"443"`, 1),
		strings.Replace(base, `"port":443`, `"port":0`, 1),
		strings.Replace(base, `"port":443`, `"port":65536`, 1),
		strings.Replace(base, `"port":443`, `"port":443,"port":8443`, 1),
		strings.Replace(base, `"port":443`, `"port":443,"PORT":8443`, 1),
		strings.Replace(base, `"type":"tcp"`, `"type":"tcp","sockopt":{"mark":1}`, 1),
		strings.Replace(base, `"enabled":true`, `"enabled":true,"allowInsecure":true`, 1),
		strings.Replace(base, `"enabled":true`, `"enabled":null`, 1),
		strings.Replace(base, `"enabled":true,`, ``, 1),
		strings.TrimSuffix(base, "}") + `,"inbounds":[]}`,
		base + ` {}`,
		`null`,
		strings.Repeat(" ", MaxProfileBytes+1),
		strings.Repeat("[", 33) + "1" + strings.Repeat("]", 33),
	}
	for i, raw := range cases {
		if _, err := DecodeProfile(strings.NewReader(raw)); err == nil {
			t.Errorf("case %d accepted", i)
		}
	}
	if _, err := DecodeProfile(bytes.NewReader(b)); err != nil {
		t.Fatal(err)
	}
}

func TestProtocolRestrictions(t *testing.T) {
	cases := []func(*Profile){
		func(p *Profile) { p.UUID = "SECRET-private-invalid-uuid" },
		func(p *Profile) { p.TLS.Reality = &Reality{PublicKey: "SECRET-private-invalid-key"} },
		func(p *Profile) { p.Transport.Type = "quic" },
		func(p *Profile) { p.Transport.Mode = "invalid-mode" },
		func(p *Profile) { p.Transport.Host = "bad\r\nHeader: value" },
		func(p *Profile) { p.Flow = "xtls-rprx-vision"; p.Transport.Type = "ws" },
		func(p *Profile) { p.Server = "https://example.com/private-key" },
	}
	for _, change := range cases {
		p := fixture("vless")
		change(&p)
		err := p.Validate()
		if err == nil {
			t.Error("accepted invalid profile")
		} else if strings.Contains(err.Error(), "SECRET") {
			t.Error("secret escaped validation")
		}
	}
	h := fixture("hysteria2")
	h.TLS.Enabled = false
	if h.Validate() == nil {
		t.Error("unencrypted hysteria accepted")
	}
	s := fixture("shadowsocks")
	s.Cipher = "none"
	if s.Validate() == nil {
		t.Error("unencrypted SS accepted")
	}
}
