// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"encoding/json"
	"strings"
	"testing"
)

func masqueProfile() Profile {
	return Profile{ID: "synthetic-masque", Name: "Synthetic MASQUE", Protocol: "masque", Server: "127.0.0.1", Port: 443,
		Username: "synthetic-user", Password: "synthetic:password", Transport: Transport{Type: "masque"}, TLS: TLS{Enabled: true, ServerName: "127.0.0.1"}}
}

func TestMasqueCompilesWithStrictTLSAndLocallyOwnedPolicy(t *testing.T) {
	p := masqueProfile()
	if _, err := Compile(p); err != nil {
		t.Fatal(err)
	}
	if p.TCPOnly() {
		t.Fatal("MASQUE must support protected UDP")
	}
	b, err := BuildProbeConfig(p, ProbeOptions{Port: 10808, Username: "local", Password: "local"})
	if err != nil {
		t.Fatal(err)
	}
	var cfg object
	if json.Unmarshal(b, &cfg) != nil {
		t.Fatal("invalid fixture output")
	}
	out := cfg["outbounds"].([]any)[1].(map[string]any)
	stream := out["streamSettings"].(map[string]any)
	tls := stream["tlsSettings"].(map[string]any)
	if stream["network"] != "masque" || stream["security"] != "tls" || tls["allowInsecure"] != false || tls["serverName"] != p.TLS.ServerName {
		t.Fatal("MASQUE changed peer authentication")
	}
	masque := stream["masqueSettings"].(map[string]any)
	if len(masque) != 2 || masque["user"] != p.Username || masque["pass"] != p.Password {
		t.Fatal("MASQUE transport authentication is not normalized")
	}
	settings := out["settings"].(map[string]any)
	dns := settings["remoteDNS"].([]any)
	if len(settings) != 3 || len(dns) != 2 || dns[0] != "1.1.1.1" || dns[1] != "1.0.0.1" {
		t.Fatal("remote DNS is not fixed local policy")
	}
}

func TestMasqueRejectsInsecureOrUnrepresentedOptions(t *testing.T) {
	for _, change := range []struct {
		name string
		edit func(*Profile)
	}{
		{"missing-user", func(p *Profile) { p.Username = "" }},
		{"invalid-basic-user", func(p *Profile) { p.Username = "one:two" }},
		{"username-control", func(p *Profile) { p.Username = "user\r\nheader" }},
		{"oversized-user", func(p *Profile) { p.Username = strings.Repeat("a", 256) }},
		{"missing-password", func(p *Profile) { p.Password = "" }},
		{"oversized-password", func(p *Profile) { p.Password = strings.Repeat("p", 256) }},
		{"password-control", func(p *Profile) { p.Password = "pass\nheader" }},
		{"missing-tls", func(p *Profile) { p.TLS = TLS{} }},
		{"missing-identity", func(p *Profile) { p.TLS.ServerName = "" }},
		{"fingerprint", func(p *Profile) { p.TLS.Fingerprint = "chrome" }},
		{"http2", func(p *Profile) { p.TLS.ALPN = []string{"h2"} }},
		{"mixed-alpn", func(p *Profile) { p.TLS.ALPN = []string{"h3", "h2"} }},
		{"wrong-transport", func(p *Profile) { p.Transport.Type = "tcp" }},
		{"path", func(p *Profile) { p.Transport.Path = "/masque" }},
		{"host", func(p *Profile) { p.Transport.Host = "other.example" }},
		{"keepalive", func(p *Profile) { n := 10; p.Transport.TCPKeepAliveIdle = &n }},
	} {
		t.Run(change.name, func(t *testing.T) {
			p := masqueProfile()
			change.edit(&p)
			if p.Validate() == nil {
				t.Fatal("unsafe MASQUE profile was accepted")
			}
		})
	}
	p := masqueProfile()
	p.TLS.ALPN = []string{"h3"}
	if p.Validate() != nil {
		t.Fatal("explicit QUIC ALPN rejected")
	}
	p.Protocol = "vless"
	if p.Validate() == nil {
		t.Fatal("MASQUE transport accepted for another protocol")
	}
}
