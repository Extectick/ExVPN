// SPDX-License-Identifier: Apache-2.0
package androidcore

import (
	"context"
	"net/netip"
	"sync/atomic"

	exvpn "github.com/Extectick/ExVPN/native/core"
	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/buf"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/outbound"
	"github.com/xtls/xray-core/transport"
)

type UIDResolver func(network string, local, remote netip.AddrPort) (int, error)

type applicationPolicy struct {
	outbound.Handler
	fallback outbound.Handler
	mode     string
	selected map[int]bool
	resolve  UIDResolver
}

func InstallApplicationRouting(instance *core.Instance, mode string, uids []int, resolve UIDResolver) error {
	if _, err := (exvpn.RoutingPolicy{AndroidUIDs: uids, Mode: mode}).Rules("vpn"); err != nil {
		return err
	}
	if mode == exvpn.RoutingDisabled || (mode == exvpn.RoutingExclude && len(uids) == 0) {
		return nil
	}
	manager, ok := instance.GetFeature(outbound.ManagerType()).(outbound.Manager)
	if !ok || resolve == nil {
		return exvpn.CodeError("owner_policy_unavailable")
	}
	direct, proxy := manager.GetHandler("direct-excluded"), manager.GetHandler("proxy")
	if direct == nil || proxy == nil || manager.GetDefaultHandler() == direct || manager.GetHandler(exvpn.ApplicationPolicyTag) != nil {
		return exvpn.CodeError("owner_policy_unavailable")
	}
	selected := map[int]bool{}
	for _, uid := range uids {
		selected[uid] = true
	}
	if manager.RemoveHandler(context.Background(), direct.Tag()) != nil {
		return exvpn.CodeError("owner_policy_unavailable")
	}
	policy := &applicationPolicy{Handler: direct, fallback: proxy, mode: mode, selected: selected, resolve: resolve}
	if manager.AddHandler(context.Background(), policy) != nil {
		_ = direct.Close()
		return exvpn.CodeError("owner_policy_unavailable")
	}
	return nil
}

func (*applicationPolicy) Tag() string { return exvpn.ApplicationPolicyTag }

func routingEndpoint(d xnet.Destination) (netip.AddrPort, bool) {
	if d.Address == nil || !d.Address.Family().IsIP() || d.Port == 0 {
		return netip.AddrPort{}, false
	}
	address, ok := netip.AddrFromSlice(d.Address.IP())
	if !ok || address.IsUnspecified() || address.Zone() != "" {
		return netip.AddrPort{}, false
	}
	return netip.AddrPortFrom(address.Unmap(), uint16(d.Port)), true
}

func routingFlow(ctx context.Context) (string, netip.AddrPort, netip.AddrPort, bool) {
	in := session.InboundFromContext(ctx)
	outs := session.OutboundsFromContext(ctx)
	if in == nil || in.Tag != "vpn" || in.Name != "tun" || len(outs) == 0 || outs[len(outs)-1] == nil {
		return "", netip.AddrPort{}, netip.AddrPort{}, false
	}
	local, ok := routingEndpoint(in.Source)
	if !ok {
		return "", local, netip.AddrPort{}, false
	}
	out := outs[len(outs)-1]
	target := out.OriginalTarget
	if target.Address == nil {
		target = out.Target
	}
	remote, ok := routingEndpoint(target)
	if !ok || local.Addr().Is4() != remote.Addr().Is4() || in.Source.Network != target.Network {
		return "", local, remote, false
	}
	if out.Target.Address != nil {
		actual, valid := routingEndpoint(out.Target)
		if !valid || actual != remote || out.Target.Network != target.Network {
			return "", local, remote, false
		}
	}
	network := ""
	if target.Network == xnet.Network_TCP {
		network = "tcp"
	} else if target.Network == xnet.Network_UDP {
		network = "udp"
	}
	return network, local, remote, network != ""
}

func (p *applicationPolicy) Dispatch(ctx context.Context, link *transport.Link) {
	handler := p.fallback
	network, local, remote, valid := routingFlow(ctx)
	if valid && remote.Port() != 53 {
		uid, err := p.resolve(network, local, remote)
		direct := p.selected[uid]
		if p.mode == exvpn.RoutingInclude {
			direct = !direct
		}
		if p.mode == exvpn.RoutingDisabled {
			direct = false
		}
		if err == nil && uid >= 10000 && direct {
			handler = p.Handler
			if network == "udp" {
				check := &datagramUIDCheck{local: local, remote: remote, uid: uid, resolve: p.resolve}
				link = &transport.Link{Reader: &uidCheckedReader{Reader: link.Reader, check: check}, Writer: &uidCheckedWriter{Writer: link.Writer, check: check}}
			}
		}
	}
	outs := session.OutboundsFromContext(ctx)
	if len(outs) > 0 && outs[len(outs)-1] != nil {
		outs[len(outs)-1].Tag = handler.Tag()
	}
	handler.Dispatch(ctx, link)
}

type datagramUIDCheck struct {
	local, remote netip.AddrPort
	uid           int
	resolve       UIDResolver
	revoked       atomic.Bool
}

func (c *datagramUIDCheck) validate(data buf.MultiBuffer) bool {
	if c.revoked.Load() {
		return false
	}
	for _, packet := range data {
		if packet == nil {
			c.revoked.Store(true)
			return false
		}
		remote := c.remote
		if packet.UDP != nil {
			var ok bool
			remote, ok = routingEndpoint(*packet.UDP)
			if !ok || packet.UDP.Network != xnet.Network_UDP {
				c.revoked.Store(true)
				return false
			}
		}
		if remote.Port() == 53 {
			c.revoked.Store(true)
			return false
		}
		uid, err := c.resolve("udp", c.local, remote)
		if err != nil || uid != c.uid {
			c.revoked.Store(true)
			return false
		}
	}
	return !c.revoked.Load()
}

type uidCheckedReader struct {
	buf.Reader
	check *datagramUIDCheck
}

func (r *uidCheckedReader) ReadMultiBuffer() (buf.MultiBuffer, error) {
	data, err := r.Reader.ReadMultiBuffer()
	if !r.check.validate(data) {
		buf.ReleaseMulti(data)
		return nil, exvpn.CodeError("owner_changed")
	}
	return data, err
}
func (r *uidCheckedReader) Close() error { return common.Close(r.Reader) }
func (r *uidCheckedReader) Interrupt()   { _ = common.Interrupt(r.Reader) }

type uidCheckedWriter struct {
	buf.Writer
	check *datagramUIDCheck
}

func (w *uidCheckedWriter) WriteMultiBuffer(data buf.MultiBuffer) error {
	if !w.check.validate(data) {
		buf.ReleaseMulti(data)
		return exvpn.CodeError("owner_changed")
	}
	return w.Writer.WriteMultiBuffer(data)
}
func (w *uidCheckedWriter) Close() error { return common.Close(w.Writer) }
func (w *uidCheckedWriter) Interrupt()   { _ = common.Interrupt(w.Writer) }
