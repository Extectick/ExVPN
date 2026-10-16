//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/netip"
	"reflect"
	"testing"

	exvpn "github.com/Extectick/ExVPN/native/core"
	"github.com/xtls/xray-core/core"
)

func TestBootstrapLeaseClosesBeforePublishingResult(t *testing.T) {
	for _, mode := range []string{"ok", "already_cancelled", "permit_failed", "cancelled_after_permit", "lookup_failed", "cancelled_during_lookup", "close_failed"} {
		t.Run(mode, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			var events []string
			if mode == "already_cancelled" {
				cancel()
			}
			result, err := resolveWithBootstrapLease(ctx, func() error {
				events = append(events, "permit")
				if mode == "permit_failed" {
					return Code("fault")
				}
				if mode == "cancelled_after_permit" {
					cancel()
				}
				return nil
			}, func() error {
				events = append(events, "close")
				if mode == "close_failed" {
					return Code("fault")
				}
				return nil
			}, func(context.Context) (endpointResolution, error) {
				events = append(events, "lookup")
				if mode == "lookup_failed" {
					return endpointResolution{}, Code("fault")
				}
				if mode == "cancelled_during_lookup" {
					cancel()
				}
				return endpointResolution{name: "vpn.example", addresses: []netip.Addr{netip.MustParseAddr("198.51.100.1")}}, nil
			})
			want := []string{"permit", "lookup", "close"}
			if mode == "already_cancelled" {
				want = nil
			}
			if mode == "permit_failed" {
				want = []string{"permit"}
			}
			if mode == "cancelled_after_permit" {
				want = []string{"permit", "close"}
			}
			if !reflect.DeepEqual(events, want) {
				t.Fatalf("Lifetime order %v, expected %v", events, want)
			}
			if mode == "ok" {
				if err != nil || len(result.addresses) != 1 {
					t.Fatal("Valid result lost")
				}
			} else if err == nil || len(result.addresses) != 0 {
				t.Fatal("Result escaped failed/cancelled lease")
			}
		})
	}
}

func TestBootstrapTransportHasNoProxyOrOnlineTrustFallback(t *testing.T) {
	client, closeConnections, err := newBootstrapClient(bootstrapRoute{index: 1, luid: 1, source: netip.MustParseAddr("192.0.2.1")})
	if err != nil {
		t.Fatal(err)
	}
	defer closeConnections()
	tr := client.Transport.(*http.Transport)
	if tr.Proxy != nil || tr.TLSClientConfig == nil || tr.TLSClientConfig.RootCAs == nil || tr.TLSClientConfig.InsecureSkipVerify || tr.TLSClientConfig.ServerName != bootstrapTLSName || !tr.DisableKeepAlives || !tr.DisableCompression || client.CheckRedirect(nil, nil) == nil {
		t.Fatal("Unsafe bootstrap HTTP policy")
	}
	for _, address := range []string{"attacker.invalid:443", "cloudflare-dns.com:80", "127.0.0.1:443", "1.1.1.1:443"} {
		if _, err := tr.DialContext(context.Background(), "tcp", address); err != Code("bootstrap_socket_rejected") {
			t.Fatal("Unexpected bootstrap dial allowed")
		}
	}
}

func TestResolvedTunnelKeepsHostnameAndTransportIdentity(t *testing.T) {
	for _, variant := range []string{"tcp", "ws", "xhttp", "grpc", "reality", "vmess", "trojan", "shadowsocks", "hysteria2"} {
		t.Run(variant, func(t *testing.T) {
			profile := syntheticProfile()
			profile.Server = "VPN.Example."
			profile.TLS.ServerName = "tls.example"
			switch variant {
			case "ws", "xhttp":
				profile.Transport = exvpn.Transport{Type: variant, Host: "http.example", Path: "/fixture"}
			case "grpc":
				profile.Transport = exvpn.Transport{Type: "grpc", ServiceName: "fixture"}
			case "reality":
				profile.TLS.Reality = &exvpn.Reality{PublicKey: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32)), ShortID: "ab12"}
			case "vmess":
				profile.Protocol = "vmess"
			case "trojan", "shadowsocks", "hysteria2":
				profile.Protocol = variant
				profile.UUID = ""
				profile.Password = "synthetic-fixture"
				if variant == "shadowsocks" {
					profile.Cipher = "aes-128-gcm"
				}
				if variant == "hysteria2" {
					profile.Transport.Type = "hysteria"
				}
			}
			resolution := endpointResolution{name: "vpn.example", addresses: []netip.Addr{netip.MustParseAddr("198.51.100.10"), netip.MustParseAddr("2001:db8::10")}, ttl: 30}
			opts := exvpn.ProbeOptions{Port: 10808, Username: "fixture", Password: "fixture"}
			encoded, err := buildTunnelConfig(profile, nil, opts, &resolution)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = core.LoadConfig("json", bytes.NewReader(encoded)); err != nil {
				t.Fatal("Pinned core rejected resolved configuration")
			}
			original, err := exvpn.BuildProbeConfig(profile, opts)
			if err != nil {
				t.Fatal(err)
			}
			var got, want map[string]any
			_ = json.Unmarshal(encoded, &got)
			_ = json.Unmarshal(original, &want)
			actualProxy := got["outbounds"].([]any)[1].(map[string]any)
			expectedProxy := want["outbounds"].([]any)[1].(map[string]any)
			stream := actualProxy["streamSettings"].(map[string]any)
			if stream["sockopt"].(map[string]any)["domainStrategy"] != "AsIs" {
				t.Fatal("Upstream DNS resolution can run before the lease check")
			}
			delete(stream, "sockopt")
			if !reflect.DeepEqual(actualProxy, expectedProxy) {
				t.Fatal("Endpoint name, TLS identity or transport host changed")
			}
			dns := got["dns"].(map[string]any)
			hosts := dns["hosts"].(map[string]any)
			if dns["useSystemHosts"] != false || len(hosts) != 1 || len(hosts["full:vpn.example"].([]any)) != 2 || dns["disableFallback"] != true {
				t.Fatal("Unsafe mapping or DNS fallback")
			}
		})
	}
}

func TestResolvedTunnelRejectsMissingOrMismatchedBootstrap(t *testing.T) {
	profile := syntheticProfile()
	profile.Server = "vpn.example"
	opts := exvpn.ProbeOptions{Port: 10808, Username: "fixture", Password: "fixture"}
	for _, resolution := range []*endpointResolution{nil, {name: "other.example", addresses: []netip.Addr{netip.MustParseAddr("198.51.100.4")}}, {name: "vpn.example"}, {name: "vpn.example", addresses: []netip.Addr{netip.MustParseAddr("127.0.0.1")}}} {
		if _, err := buildTunnelConfig(profile, nil, opts, resolution); err == nil {
			t.Fatal("Untrusted/missing endpoint mapping accepted")
		}
	}
	if err := validateTunnelProfile(profile, nil); err != nil {
		t.Fatal("Validation incorrectly requires network resolution")
	}
	profile.Protocol = "invalid"
	if _, err := WindowsTunnelFactory(nil)(context.Background(), profile, nil); err == nil {
		t.Fatal("Invalid profile reached bootstrap")
	}
}
