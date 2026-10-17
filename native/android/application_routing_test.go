// SPDX-License-Identifier: Apache-2.0
package androidcore

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/netip"
	"strings"
	"testing"

	exvpn "github.com/Extectick/ExVPN/native/core"
	"github.com/xtls/xray-core/common/buf"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/outbound"
	"github.com/xtls/xray-core/transport"
)

type routingOutbound struct {
	tag   string
	calls int
	link  *transport.Link
}

func (h *routingOutbound) Tag() string                                      { return h.tag }
func (*routingOutbound) Start() error                                       { return nil }
func (*routingOutbound) Close() error                                       { return nil }
func (*routingOutbound) SenderSettings() *serial.TypedMessage               { return nil }
func (*routingOutbound) ProxySettings() *serial.TypedMessage                { return nil }
func (h *routingOutbound) Dispatch(_ context.Context, link *transport.Link) { h.calls++; h.link = link }

func routingContext(network xnet.Network) context.Context {
	ctx := session.ContextWithInbound(context.Background(), &session.Inbound{Tag: "vpn", Name: "tun", Source: xnet.Destination{Network: network, Address: xnet.ParseAddress("192.0.2.2"), Port: 50000}})
	return session.ContextWithOutbounds(ctx, []*session.Outbound{{OriginalTarget: xnet.Destination{Network: network, Address: xnet.ParseAddress("198.51.100.1"), Port: 443}}})
}

func TestApplicationRoutingAllModesRequireConfirmedUIDForDirect(t *testing.T) {
	for _, mode := range []string{exvpn.RoutingDisabled, exvpn.RoutingExclude, exvpn.RoutingInclude} {
		for _, uid := range []int{10001, 10002, 999, -1} {
			for _, failure := range []bool{false, true} {
				direct, proxy := &routingOutbound{tag: "direct-excluded"}, &routingOutbound{tag: "proxy"}
				p := &applicationPolicy{Handler: direct, fallback: proxy, mode: mode, selected: map[int]bool{10001: true}, resolve: func(network string, local, remote netip.AddrPort) (int, error) {
					if network != "tcp" || local.Port() != 50000 || remote.Port() != 443 {
						t.Fatal("lost exact socket tuple")
					}
					if failure {
						return 0, exvpn.CodeError("owner_unknown")
					}
					return uid, nil
				}}
				p.Dispatch(routingContext(xnet.Network_TCP), &transport.Link{})
				want := !failure && uid >= 10000 && ((mode == exvpn.RoutingExclude && uid == 10001) || (mode == exvpn.RoutingInclude && uid != 10001))
				if (direct.calls == 1) != want || direct.calls+proxy.calls != 1 {
					t.Fatalf("wrong mode=%s UID=%d failure=%v decision", mode, uid, failure)
				}
				p.Dispatch(context.Background(), &transport.Link{})
				if proxy.calls == 0 {
					t.Fatal("missing TUN metadata granted direct")
				}
			}
		}
	}
}

func TestModernRoutingConfigsHaveNoUnownedDirectOrInvertedProcessRule(t *testing.T) {
	for _, mode := range []string{exvpn.RoutingDisabled, exvpn.RoutingExclude, exvpn.RoutingInclude} {
		for _, uids := range [][]int{nil, {10001}} {
			encoded, err := BuildConfigWithRouting(sample(), "192.0.2.1", mode, uids)
			if err != nil {
				t.Fatal(err)
			}
			var cfg map[string]any
			_ = json.Unmarshal(encoded, &cfg)
			rules := cfg["routing"].(map[string]any)["rules"].([]any)
			if rules[0].(map[string]any)["outboundTag"] != "proxy" || rules[1].(map[string]any)["outboundTag"] != "proxy" || rules[2].(map[string]any)["outboundTag"] != "dns-out" {
				t.Fatal("health/internal/application DNS priority lost")
			}
			if strings.Contains(string(encoded), `"outboundTag":"direct-excluded"`) || strings.Contains(string(encoded), `"process"`) {
				t.Fatal("unsafe direct rule")
			}
			if cfg["outbounds"].([]any)[0].(map[string]any)["tag"] != "blocked" {
				t.Fatal("unsafe default")
			}
			compiled, err := core.LoadConfig("json", bytes.NewReader(encoded))
			if err != nil {
				t.Fatal("pinned config rejected", err)
			}
			instance, err := core.New(compiled)
			if err != nil {
				t.Fatal("handler construction failed", err)
			}
			resolver := func(string, netip.AddrPort, netip.AddrPort) (int, error) { return 10001, nil }
			if err := InstallApplicationRouting(instance, mode, uids, resolver); err != nil {
				t.Fatal(err)
			}
			manager := instance.GetFeature(outbound.ManagerType()).(outbound.Manager)
			active := mode == exvpn.RoutingInclude || (mode == exvpn.RoutingExclude && len(uids) > 0)
			if manager.GetHandler("direct-excluded") != nil || (manager.GetHandler(exvpn.ApplicationPolicyTag) != nil) != active {
				t.Fatal("unguarded direct handler or missing owned policy")
			}
			_ = instance.Close()
		}
	}
}

func TestDirectUIDUDPRevokesOnUnknownChangedOwnerAndDNS(t *testing.T) {
	for _, change := range []string{"uid", "unknown", "dns", "domain"} {
		uid := 10002
		failed := false
		check := &datagramUIDCheck{local: netip.MustParseAddrPort("192.0.2.2:50000"), remote: netip.MustParseAddrPort("198.51.100.1:443"), uid: uid, resolve: func(string, netip.AddrPort, netip.AddrPort) (int, error) {
			if failed {
				return 0, exvpn.CodeError("owner_unknown")
			}
			return uid, nil
		}}
		first := buf.MultiBuffer{buf.FromBytes([]byte("fixture"))}
		if !check.validate(first) {
			t.Fatal("known owner refused")
		}
		buf.ReleaseMulti(first)
		packet := buf.FromBytes([]byte("must remain protected"))
		switch change {
		case "uid":
			uid++
		case "unknown":
			failed = true
		case "dns":
			destination := xnet.UDPDestination(xnet.ParseAddress("198.51.100.1"), 53)
			packet.UDP = &destination
		case "domain":
			destination := xnet.UDPDestination(xnet.DomainAddress("example.invalid"), 443)
			packet.UDP = &destination
		}
		data := buf.MultiBuffer{packet}
		if check.validate(data) {
			t.Fatal("unsafe UDP accepted")
		}
		buf.ReleaseMulti(data)
		uid = 10002
		failed = false
		data = buf.MultiBuffer{buf.FromBytes([]byte("late reply"))}
		if check.validate(data) {
			t.Fatal("revoked association resumed")
		}
		buf.ReleaseMulti(data)
	}
}

type routingSocketOutbound struct {
	routingOutbound
	address string
	failure error
}

func (h *routingSocketOutbound) Dispatch(_ context.Context, _ *transport.Link) {
	connection, err := net.Dial("tcp", h.address)
	if err != nil {
		h.failure = err
		return
	}
	defer connection.Close()
	_, h.failure = io.WriteString(connection, h.tag)
}

func TestApplicationRoutingLoopbackDispatchAllModes(t *testing.T) {
	for _, mode := range []string{exvpn.RoutingDisabled, exvpn.RoutingExclude, exvpn.RoutingInclude} {
		for _, uid := range []int{10001, 10002, -1} {
			listener, err := net.Listen("tcp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			result := make(chan string, 1)
			go func() {
				connection, err := listener.Accept()
				if err != nil {
					result <- "failed"
					return
				}
				defer connection.Close()
				data, _ := io.ReadAll(connection)
				result <- string(data)
			}()
			direct := &routingSocketOutbound{routingOutbound: routingOutbound{tag: "direct"}, address: listener.Addr().String()}
			proxy := &routingSocketOutbound{routingOutbound: routingOutbound{tag: "vpn"}, address: listener.Addr().String()}
			policy := &applicationPolicy{Handler: direct, fallback: proxy, mode: mode, selected: map[int]bool{10001: true}, resolve: func(string, netip.AddrPort, netip.AddrPort) (int, error) {
				if uid < 0 {
					return 0, exvpn.CodeError("owner_unknown")
				}
				return uid, nil
			}}
			policy.Dispatch(routingContext(xnet.Network_TCP), &transport.Link{})
			if direct.failure != nil || proxy.failure != nil {
				t.Fatal("loopback dispatch failed")
			}
			want := "vpn"
			if uid >= 10000 && ((mode == exvpn.RoutingExclude && uid == 10001) || (mode == exvpn.RoutingInclude && uid != 10001)) {
				want = "direct"
			}
			if actual := <-result; actual != want {
				t.Fatal("wrong loopback destination", mode, uid, actual)
			}
			listener.Close()
		}
	}
}
