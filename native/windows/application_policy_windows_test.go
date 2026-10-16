//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"context"
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

type countingOutbound struct {
	tag   string
	calls int
	link  *transport.Link
}

func (h *countingOutbound) Tag() string                        { return h.tag }
func (*countingOutbound) Start() error                         { return nil }
func (*countingOutbound) Close() error                         { return nil }
func (*countingOutbound) SenderSettings() *serial.TypedMessage { return nil }
func (*countingOutbound) ProxySettings() *serial.TypedMessage  { return nil }
func (h *countingOutbound) Dispatch(_ context.Context, link *transport.Link) {
	h.calls++
	h.link = link
}

func policyContext(network xnet.Network) context.Context {
	ctx := session.ContextWithInbound(context.Background(), &session.Inbound{Name: "tun", Tag: "vpn", Source: xnet.Destination{Network: network, Address: xnet.ParseAddress("192.0.2.2"), Port: 50000}})
	return session.ContextWithOutbounds(ctx, []*session.Outbound{{OriginalTarget: xnet.Destination{Network: network, Address: xnet.ParseAddress("198.51.100.1"), Port: 443}}})
}

func TestApplicationPolicyUnknownOrWrongPathUsesProxy(t *testing.T) {
	for _, test := range []struct {
		name, path string
		failure    bool
		direct     bool
	}{
		{"exact", "C:\\Apps\\Allowed.exe", false, true},
		{"case", "c:/apps/allowed.EXE", false, true},
		{"basename", "C:/Other/allowed.exe", false, false},
		{"folder", "C:/Apps/allowed.exe.extra", false, false},
		{"unknown", "C:/Apps/allowed.exe", true, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			direct, proxy := &countingOutbound{tag: "direct-excluded"}, &countingOutbound{tag: "proxy"}
			p := &applicationPolicy{Handler: direct, fallback: proxy, allowed: map[string]bool{"c:/apps/allowed.exe": true}, resolve: func(flow flowTuple) (processOwner, error) {
				if flow != fixtureFlow("tcp") {
					t.Fatal("lost original complete tuple")
				}
				if test.failure {
					return processOwner{}, Code("owner_unavailable")
				}
				return processOwner{pid: 101, created: 123, path: test.path}, nil
			}}
			ctx := policyContext(xnet.Network_TCP)
			p.Dispatch(ctx, &transport.Link{})
			if (direct.calls == 1) != test.direct || direct.calls+proxy.calls != 1 {
				t.Fatal("incorrect exception decision")
			}
			p.Dispatch(context.Background(), &transport.Link{})
			if proxy.calls == 0 {
				t.Fatal("non-TUN metadata granted direct access")
			}
		})
	}
}

type packetReader struct{ next buf.MultiBuffer }

func (r *packetReader) ReadMultiBuffer() (buf.MultiBuffer, error) {
	next := r.next
	r.next = nil
	return next, nil
}

type packetWriter struct{ writes int }

func (w *packetWriter) WriteMultiBuffer(data buf.MultiBuffer) error {
	w.writes++
	buf.ReleaseMulti(data)
	return nil
}

func TestUDPDirectFlowRevokesOnOwnerChangeAndPIDReuse(t *testing.T) {
	for _, change := range []string{"pid", "creation", "path", "ambiguous"} {
		t.Run(change, func(t *testing.T) {
			original := processOwner{pid: 101, created: 123, path: "c:/apps/allowed.exe"}
			current := original
			failed := false
			check := &datagramOwnerCheck{flow: fixtureFlow("udp"), owner: original, resolve: func(flow flowTuple) (processOwner, error) {
				if !flow.valid() {
					return processOwner{}, Code("owner_unavailable")
				}
				if failed {
					return processOwner{}, Code("owner_unavailable")
				}
				return current, nil
			}}
			input := &packetReader{next: buf.MultiBuffer{buf.FromBytes([]byte("fixture"))}}
			reader := &ownerCheckedReader{Reader: input, check: check}
			data, err := reader.ReadMultiBuffer()
			if err != nil || len(data) != 1 {
				t.Fatal("known UDP owner was blocked")
			}
			buf.ReleaseMulti(data)
			switch change {
			case "pid":
				current.pid++
			case "creation":
				current.created++
			case "path":
				current.path = "c:/other.exe"
			case "ambiguous":
				failed = true
			}
			input.next = buf.MultiBuffer{buf.FromBytes([]byte("must not escape"))}
			if data, err = reader.ReadMultiBuffer(); err != Code("owner_changed") || len(data) != 0 {
				t.Fatal("old direct flow inherited by another owner")
			}
			current = original
			failed = false
			output := &packetWriter{}
			writer := &ownerCheckedWriter{Writer: output, check: check}
			if writer.WriteMultiBuffer(buf.MultiBuffer{buf.FromBytes([]byte("reply"))}) != Code("owner_changed") || output.writes != 0 {
				t.Fatal("revoked flow resumed or delivered a late reply")
			}
		})
	}
}

func TestApplicationAdapterInstalledBeforeCoreStartWithoutDirectRoute(t *testing.T) {
	encoded, err := BuildTunnelConfig(syntheticProfile(), []string{"C:/Apps/allowed.exe"}, exvpn.ProbeOptions{Port: 10808, Username: "fixture", Password: "fixture"})
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := core.LoadConfig("json", bytes.NewReader(encoded))
	if err != nil {
		t.Fatal(err)
	}
	// New creates handlers; never Start: no listeners, adapters, routes or WFP.
	instance, err := core.New(cfg)
	if err != nil {
		t.Fatal("pinned core handler construction failed")
	}
	defer instance.Close()
	if installApplicationPolicy(instance, []string{"C:/Apps/allowed.exe"}) != nil {
		t.Fatal("adapter installation failed")
	}
	manager := instance.GetFeature(outbound.ManagerType()).(outbound.Manager)
	if manager.GetHandler("direct-excluded") != nil {
		t.Fatal("unguarded direct handler remains routable")
	}
	if _, ok := manager.GetHandler(applicationPolicyTag).(*applicationPolicy); !ok {
		t.Fatal("missing adapter")
	}
	if manager.GetDefaultHandler().Tag() != "blocked" {
		t.Fatal("unsafe default route")
	}
}

func TestUDPDirectFlowCannotChangeDestinationToDNSOrDomain(t *testing.T) {
	for _, destination := range []xnet.Destination{
		xnet.UDPDestination(xnet.ParseAddress("198.51.100.1"), 53),
		xnet.UDPDestination(xnet.DomainAddress("example.invalid"), 443),
	} {
		owner := processOwner{pid: 101, created: 123, path: "c:/apps/allowed.exe"}
		check := &datagramOwnerCheck{flow: fixtureFlow("udp"), owner: owner, resolve: func(flowTuple) (processOwner, error) { return owner, nil }}
		packet := buf.FromBytes([]byte("fixture"))
		packet.UDP = &destination
		input := &packetReader{next: buf.MultiBuffer{packet}}
		reader := &ownerCheckedReader{Reader: input, check: check}
		if data, err := reader.ReadMultiBuffer(); len(data) != 0 || err != Code("owner_changed") {
			t.Fatal("direct UDP bypassed DNS policy")
		}
	}
}
