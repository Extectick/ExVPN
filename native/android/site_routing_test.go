// SPDX-License-Identifier: Apache-2.0
package androidcore

import (
	"bytes"
	"encoding/json"
	"net/netip"
	"strings"
	"testing"

	exvpn "github.com/Extectick/ExVPN/native/core"
	"github.com/xtls/xray-core/common/buf"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/outbound"
	"github.com/xtls/xray-core/transport"
)

func TestSiteRoutingConfigsKeepDNSAndOnlyUseOwnedDispatcher(t *testing.T) {
	for _, mode := range []string{exvpn.RoutingDisabled, exvpn.RoutingExclude, exvpn.RoutingInclude} {
		sites := exvpn.SiteRoutingPolicy{Mode: mode, Rules: []string{"example.com", "198.51.100.0/24"}}
		data, err := BuildConfigWithSiteRouting(sample(), "192.0.2.1", exvpn.RoutingDisabled, nil, sites)
		if err != nil {
			t.Fatal(err)
		}
		var cfg map[string]any
		_ = json.Unmarshal(data, &cfg)
		rules := cfg["routing"].(map[string]any)["rules"].([]any)
		if rules[0].(map[string]any)["outboundTag"] != "proxy" || rules[1].(map[string]any)["outboundTag"] != "proxy" || rules[2].(map[string]any)["outboundTag"] != "dns-out" {
			t.Fatal("health/internal/application DNS precedence changed")
		}
		if strings.Contains(string(data), `"outboundTag":"direct-excluded"`) {
			t.Fatal("unowned direct rule")
		}
		inbound := cfg["inbounds"].([]any)[0].(map[string]any)
		if mode == exvpn.RoutingDisabled {
			if inbound["sniffing"] != nil {
				t.Fatal("disabled policy changed sniffing")
			}
		} else {
			if inbound["sniffing"].(map[string]any)["routeOnly"] != true {
				t.Fatal("routing must not rewrite destination")
			}
			if rules[3].(map[string]any)["outboundTag"] != exvpn.ApplicationPolicyTag {
				t.Fatal("missing owned dispatcher")
			}
		}
		compiled, err := core.LoadConfig("json", bytes.NewReader(data))
		if err != nil {
			t.Fatal("pinned config rejected", err)
		}
		instance, err := core.New(compiled)
		if err != nil {
			t.Fatal(err)
		}
		resolver := func(string, netip.AddrPort, netip.AddrPort) (int, error) { return 10001, nil }
		if err := InstallSiteApplicationRouting(instance, exvpn.RoutingDisabled, nil, sites, resolver); err != nil {
			t.Fatal(err)
		}
		manager := instance.GetFeature(outbound.ManagerType()).(outbound.Manager)
		if manager.GetHandler("direct-excluded") != nil || (manager.GetHandler(exvpn.ApplicationPolicyTag) != nil) != sites.Active() {
			t.Fatal("direct handler not owned")
		}
		_ = instance.Close()
	}
}

func TestSiteRoutingDispatchRequiresOwnerAndUnknownDomainsRemainProtected(t *testing.T) {
	cases := []struct {
		name, appMode, siteMode, domain string
		rules                           []string
		uid                             int
		fail, selected, direct          bool
	}{
		{"exclude numeric", "disabled", "exclude", "", []string{"198.51.100.0/24"}, 10001, false, false, true},
		{"exclude domain", "disabled", "exclude", "sub.example.com", []string{"example.com"}, 10001, false, false, true},
		{"include selected", "disabled", "include", "example.com", []string{"example.com"}, 10001, false, false, false},
		{"include unselected", "disabled", "include", "other.example.net", []string{"example.com"}, 10001, false, false, true},
		{"include unknown", "exclude", "include", "", []string{"example.com"}, 10001, false, true, false},
		{"explicit application include wins", "include", "exclude", "example.com", []string{"example.com"}, 10001, false, true, false},
		{"unknown UID", "disabled", "exclude", "example.com", []string{"example.com"}, -1, false, false, false},
		{"failed owner", "disabled", "exclude", "example.com", []string{"example.com"}, 10001, true, false, false},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			matcher, err := exvpn.NewSiteMatcher(exvpn.SiteRoutingPolicy{Mode: test.siteMode, Rules: test.rules})
			if err != nil {
				t.Fatal(err)
			}
			direct, proxy := &routingOutbound{tag: "direct-excluded"}, &routingOutbound{tag: "proxy"}
			policy := &applicationPolicy{Handler: direct, fallback: proxy, mode: test.appMode, sites: matcher,
				selected: map[int]bool{test.uid: test.selected}, resolve: func(string, netip.AddrPort, netip.AddrPort) (int, error) {
					if test.fail {
						return 0, exvpn.CodeError("owner_unknown")
					}
					return test.uid, nil
				}}
			ctx := routingContext(xnet.Network_TCP)
			if test.domain != "" {
				session.OutboundsFromContext(ctx)[0].RouteTarget = xnet.TCPDestination(xnet.DomainAddress(test.domain), 443)
			}
			policy.Dispatch(ctx, &transport.Link{})
			if (direct.calls == 1) != test.direct || direct.calls+proxy.calls != 1 {
				t.Fatal("wrong decision")
			}
		})
	}
}

func TestSiteRoutingUDPDirectCannotReuseSniffForAnotherRemote(t *testing.T) {
	for _, destination := range []string{"198.51.100.2:443", "198.51.100.1:444"} {
		check := &datagramUIDCheck{local: netip.MustParseAddrPort("192.0.2.2:50000"), remote: netip.MustParseAddrPort("198.51.100.1:443"), uid: 10001,
			fixedRemote: true, resolve: func(string, netip.AddrPort, netip.AddrPort) (int, error) { return 10001, nil }}
		first := buf.MultiBuffer{buf.FromBytes([]byte("fixture"))}
		if !check.validate(first) {
			t.Fatal("initial owner/destination rejected")
		}
		buf.ReleaseMulti(first)
		address := netip.MustParseAddrPort(destination)
		packet := buf.FromBytes([]byte("must stay protected"))
		target := xnet.UDPDestination(xnet.ParseAddress(address.Addr().String()), xnet.Port(address.Port()))
		packet.UDP = &target
		data := buf.MultiBuffer{packet}
		if check.validate(data) {
			t.Fatal("UDP destination change bypassed policy")
		}
		buf.ReleaseMulti(data)
		late := buf.MultiBuffer{buf.FromBytes([]byte("old destination reply"))}
		if check.validate(late) {
			t.Fatal("revoked association resumed")
		}
		buf.ReleaseMulti(late)
	}
}
