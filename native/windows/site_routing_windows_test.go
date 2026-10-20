//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"encoding/json"
	"testing"

	exvpn "github.com/Extectick/ExVPN/native/core"
	"github.com/xtls/xray-core/common/buf"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/transport"
)

func TestSiteRoutingCompiledConfigKeepsDNSAndOriginalTargets(t *testing.T) {
	for _, mode := range []string{exvpn.RoutingExclude, exvpn.RoutingInclude} {
		policy := exvpn.SiteRoutingPolicy{Mode: mode, Rules: []string{"example.com", "198.51.100.0/24"}}
		b, err := buildTunnelConfigWithPolicies(syntheticProfile(), legacyApplicationRouting(nil), policy, exvpn.ProbeOptions{Port: 10808, Username: "fixture", Password: "fixture"}, nil)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := core.LoadConfig("json", bytes.NewReader(b)); err != nil {
			t.Fatal("pinned core rejected site config")
		}
		var config map[string]any
		if json.Unmarshal(b, &config) != nil {
			t.Fatal("invalid config")
		}
		rules := config["routing"].(map[string]any)["rules"].([]any)
		if rules[0].(map[string]any)["outboundTag"] != "proxy" || rules[1].(map[string]any)["outboundTag"] != "dns-out" {
			t.Fatal("site policy weakened DNS precedence")
		}
		if rules[2].(map[string]any)["outboundTag"] != applicationPolicyTag {
			t.Fatal("site policy bypassed owned dispatcher")
		}
		for _, raw := range rules {
			rule := raw.(map[string]any)
			if rule["outboundTag"] == "direct-excluded" {
				t.Fatal("direct routing rule bypasses owner check")
			}
		}
		for _, raw := range config["inbounds"].([]any) {
			in := raw.(map[string]any)
			if in["tag"] != "vpn" {
				continue
			}
			sniff, ok := in["sniffing"].(map[string]any)
			if !ok || sniff["routeOnly"] != true || sniff["enabled"] != true {
				t.Fatal("site sniffing rewrites numeric target")
			}
		}
	}
}

func TestSiteRoutingDirectStillRequiresKnownOwnerAndKeepsIncludePrivate(t *testing.T) {
	for _, test := range []struct {
		name, mode, domain, appMode string
		failed, appSelected, direct bool
	}{
		{"excluded domain", exvpn.RoutingExclude, "www.example.com", exvpn.RoutingDisabled, false, false, true},
		{"unknown owner", exvpn.RoutingExclude, "www.example.com", exvpn.RoutingDisabled, true, false, false},
		{"unmatched exclusion", exvpn.RoutingExclude, "other.example", exvpn.RoutingDisabled, false, false, false},
		{"included domain", exvpn.RoutingInclude, "example.com", exvpn.RoutingDisabled, false, false, false},
		{"known unmatched include", exvpn.RoutingInclude, "other.example", exvpn.RoutingDisabled, false, false, true},
		{"unknown domain include", exvpn.RoutingInclude, "", exvpn.RoutingDisabled, false, false, false},
		{"app include wins over site direct", exvpn.RoutingExclude, "example.com", exvpn.RoutingInclude, false, true, false},
		{"site include wins over app direct", exvpn.RoutingInclude, "example.com", exvpn.RoutingExclude, false, true, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			matcher, err := exvpn.NewSiteMatcher(exvpn.SiteRoutingPolicy{Mode: test.mode, Rules: []string{"example.com"}})
			if err != nil {
				t.Fatal(err)
			}
			direct, proxy := &countingOutbound{tag: "direct-excluded"}, &countingOutbound{tag: "proxy"}
			allowed := map[string]bool{}
			if test.appSelected {
				allowed["c:/apps/selected.exe"] = true
			}
			p := &applicationPolicy{Handler: direct, fallback: proxy, mode: test.appMode, allowed: allowed, site: matcher, siteMode: test.mode, siteActive: true, resolve: func(flowTuple) (processOwner, error) {
				if test.failed {
					return processOwner{}, Code("owner_unavailable")
				}
				return processOwner{pid: 101, created: 123, path: "C:/Apps/Selected.exe"}, nil
			}}
			ctx := policyContext(xnet.Network_TCP)
			if test.domain != "" {
				session.OutboundsFromContext(ctx)[0].RouteTarget = xnet.TCPDestination(xnet.DomainAddress(test.domain), 443)
			}
			p.Dispatch(ctx, &transport.Link{})
			if (direct.calls == 1) != test.direct || direct.calls+proxy.calls != 1 {
				t.Fatal("incorrect protected site routing decision")
			}
			if out := session.OutboundsFromContext(ctx)[0]; out.OriginalTarget.Address.String() != "198.51.100.1" {
				t.Fatal("sniffed name changed the original owner tuple")
			}
		})
	}
}

func TestSiteRoutingUDPBlocksChangedDestinationEvenForSameOwner(t *testing.T) {
	owner := processOwner{pid: 101, created: 123, path: "c:/apps/selected.exe"}
	for _, destination := range []xnet.Destination{
		xnet.UDPDestination(xnet.ParseAddress("198.51.100.2"), 443),
		xnet.UDPDestination(xnet.ParseAddress("198.51.100.1"), 444),
	} {
		check := &datagramOwnerCheck{flow: fixtureFlow("udp"), owner: owner, strictRemote: true, resolve: func(flowTuple) (processOwner, error) { return owner, nil }}
		valid := buf.MultiBuffer{buf.FromBytes([]byte("fixture"))}
		if !check.validate(valid) {
			t.Fatal("original destination refused")
		}
		buf.ReleaseMulti(valid)
		packet := buf.FromBytes([]byte("fixture"))
		packet.UDP = &destination
		packets := buf.MultiBuffer{packet}
		if check.validate(packets) {
			t.Fatal("same-owner UDP bypassed site policy by changing target")
		}
		buf.ReleaseMulti(packets)
		valid = buf.MultiBuffer{buf.FromBytes([]byte("fixture"))}
		if check.validate(valid) {
			t.Fatal("revoked UDP flow became usable again")
		}
		buf.ReleaseMulti(valid)
	}
}

func TestSiteRoutingCannotBypassTCPOnlyUDPBlock(t *testing.T) {
	profile := syntheticProfile()
	profile.Protocol, profile.UUID = "http", ""
	policy := exvpn.SiteRoutingPolicy{Mode: exvpn.RoutingExclude, Rules: []string{"198.51.100.0/24"}}
	b, err := buildTunnelConfigWithPolicies(profile, legacyApplicationRouting(nil), policy, exvpn.ProbeOptions{Port: 10808, Username: "fixture", Password: "fixture"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	var config map[string]any
	if json.Unmarshal(b, &config) != nil {
		t.Fatal("invalid config")
	}
	rules := config["routing"].(map[string]any)["rules"].([]any)
	if rules[1].(map[string]any)["outboundTag"] != "dns-out" || rules[2].(map[string]any)["network"] != "udp" || rules[2].(map[string]any)["outboundTag"] != "blocked" {
		t.Fatal("site direct rule weakened TCP-only DNS/UDP gates")
	}
}
