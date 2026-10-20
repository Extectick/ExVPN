//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"context"
	exvpn "github.com/Extectick/ExVPN/native/core"
	"net/netip"
	"sync/atomic"

	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/buf"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/outbound"
	"github.com/xtls/xray-core/transport"
)

// Own the existing direct handler's lifecycle through the public outbound API.
// The proxy remains separately owned by the manager. No upstream source patch,
// process-name matcher, API listener or provider-controlled policy is involved.
type applicationPolicy struct {
	outbound.Handler
	fallback   outbound.Handler
	allowed    map[string]bool
	resolve    ownerResolver
	mode       string
	siteMode   string
	site       *exvpn.SiteMatcher
	siteActive bool
}

func installApplicationPolicy(instance *core.Instance, exclusions []string) error {
	return installApplicationRouting(instance, legacyApplicationRouting(exclusions))
}

func installApplicationRouting(instance *core.Instance, routing ApplicationRoutingPolicy) error {
	return installApplicationPolicies(instance, routing, exvpn.DefaultSiteRoutingState().Policy)
}

func installApplicationPolicies(instance *core.Instance, routing ApplicationRoutingPolicy, site exvpn.SiteRoutingPolicy) error {
	if routing.validate() != nil {
		return Code("application_routing_rejected")
	}
	matcher, err := exvpn.NewSiteMatcher(site)
	if err != nil {
		return Code("site_routing_rejected")
	}
	appActive := routing.Mode == exvpn.RoutingInclude || (routing.Mode == exvpn.RoutingExclude && len(routing.Applications) > 0)
	if !appActive && !site.Active() {
		return nil
	}
	manager, ok := instance.GetFeature(outbound.ManagerType()).(outbound.Manager)
	if !ok {
		return Code("owner_policy_unavailable")
	}
	direct, proxy := manager.GetHandler("direct-excluded"), manager.GetHandler("proxy")
	if direct == nil || proxy == nil || manager.GetDefaultHandler() == direct || manager.GetHandler(applicationPolicyTag) != nil {
		return Code("owner_policy_unavailable")
	}
	allowed := make(map[string]bool, len(routing.Applications))
	for _, path := range routing.Applications {
		allowed[applicationPathKey(path)] = true
	}
	if manager.RemoveHandler(context.Background(), direct.Tag()) != nil {
		return Code("owner_policy_unavailable")
	}
	policy := &applicationPolicy{Handler: direct, fallback: proxy, allowed: allowed, resolve: resolveProcessOwner, mode: routing.Mode, siteMode: site.Mode, site: matcher, siteActive: site.Active()}
	if manager.AddHandler(context.Background(), policy) != nil {
		_ = direct.Close()
		return Code("owner_policy_unavailable")
	}
	return nil
}

func (p *applicationPolicy) Tag() string { return applicationPolicyTag }

func endpoint(destination xnet.Destination) (netip.AddrPort, bool) {
	if destination.Address == nil || !destination.Address.Family().IsIP() || destination.Port == 0 {
		return netip.AddrPort{}, false
	}
	address, ok := netip.AddrFromSlice(destination.Address.IP())
	if !ok {
		return netip.AddrPort{}, false
	}
	return netip.AddrPortFrom(address.Unmap(), uint16(destination.Port)), true
}

func contextFlow(ctx context.Context) (flowTuple, bool) {
	in := session.InboundFromContext(ctx)
	outs := session.OutboundsFromContext(ctx)
	if in == nil || in.Tag != "vpn" || in.Name != "tun" || len(outs) == 0 || outs[len(outs)-1] == nil {
		return flowTuple{}, false
	}
	local, ok := endpoint(in.Source)
	if !ok {
		return flowTuple{}, false
	}
	target := outs[len(outs)-1].OriginalTarget
	if target.Address == nil {
		target = outs[len(outs)-1].Target
	}
	remote, ok := endpoint(target)
	if !ok || in.Source.Network != target.Network {
		return flowTuple{}, false
	}
	if actual := outs[len(outs)-1].Target; actual.Address != nil {
		current, valid := endpoint(actual)
		if !valid || current != remote || actual.Network != target.Network {
			return flowTuple{}, false
		}
	}
	flow := flowTuple{local: local, remote: remote}
	switch target.Network {
	case xnet.Network_TCP:
		flow.network = "tcp"
	case xnet.Network_UDP:
		flow.network = "udp"
	default:
		return flowTuple{}, false
	}
	return flow, flow.valid()
}

func (p *applicationPolicy) Dispatch(ctx context.Context, link *transport.Link) {
	handler := p.fallback
	flow, valid := contextFlow(ctx)
	if valid {
		owner, err := p.resolve(flow)
		selected := p.allowed[applicationOwnerKey(owner.path)]
		siteMode := p.siteMode
		if siteMode == "" {
			siteMode = exvpn.RoutingDisabled
		}
		domain := exvpn.SiteDomainFromContext(ctx)
		siteMatched, siteKnown := false, true
		if p.site != nil {
			siteMatched = p.site.Match(flow.remote.Addr(), domain)
			siteKnown = !p.site.HasDomains() || domain != ""
		}
		appMode := p.mode
		if appMode == "" {
			appMode = exvpn.RoutingExclude
		}
		direct := exvpn.RouteDirectForPolicies(appMode, selected, siteMode, siteMatched, siteKnown)
		if err == nil && owner.pid > 4 && owner.created != 0 && owner.path != "" && flow.remote.Port() != 53 && direct {
			handler = p.Handler
			if flow.network == "udp" {
				check := &datagramOwnerCheck{flow: flow, owner: owner, resolve: p.resolve, strictRemote: p.siteActive}
				link = &transport.Link{Reader: &ownerCheckedReader{Reader: link.Reader, check: check}, Writer: &ownerCheckedWriter{Writer: link.Writer, check: check}}
			}
		}
	}
	outs := session.OutboundsFromContext(ctx)
	if len(outs) > 0 && outs[len(outs)-1] != nil {
		outs[len(outs)-1].Tag = handler.Tag()
	}
	handler.Dispatch(ctx, link)
}

// UDP associations can outlive the owning process or a socket bind. Recheck the
// PID, creation time and exact path for every datagram batch in both directions.
// Once ownership changes, stop this direct flow; never migrate it to a new PID.
type datagramOwnerCheck struct {
	flow         flowTuple
	owner        processOwner
	resolve      ownerResolver
	revoked      atomic.Bool
	strictRemote bool
}

func (c *datagramOwnerCheck) validate(multi buf.MultiBuffer) bool {
	if c.revoked.Load() {
		return false
	}
	for _, packet := range multi {
		flow := c.flow
		if packet == nil {
			c.revoked.Store(true)
			return false
		}
		if packet.UDP != nil {
			remote, ok := endpoint(*packet.UDP)
			if !ok || packet.UDP.Network != xnet.Network_UDP {
				c.revoked.Store(true)
				return false
			}
			flow.remote = remote
		}
		if c.strictRemote && flow.remote != c.flow.remote {
			c.revoked.Store(true)
			return false
		}
		// An existing UDP association must not bypass the higher-priority DNS
		// route by changing its per-packet destination after initial dispatch.
		if flow.remote.Port() == 53 {
			c.revoked.Store(true)
			return false
		}
		owner, err := c.resolve(flow)
		if err != nil || owner != c.owner {
			c.revoked.Store(true)
			return false
		}
	}
	return !c.revoked.Load()
}

type ownerCheckedReader struct {
	buf.Reader
	check *datagramOwnerCheck
}

func (r *ownerCheckedReader) ReadMultiBuffer() (buf.MultiBuffer, error) {
	data, err := r.Reader.ReadMultiBuffer()
	if !r.check.validate(data) {
		buf.ReleaseMulti(data)
		return nil, Code("owner_changed")
	}
	return data, err
}
func (r *ownerCheckedReader) Close() error { return common.Close(r.Reader) }
func (r *ownerCheckedReader) Interrupt()   { _ = common.Interrupt(r.Reader) }

type ownerCheckedWriter struct {
	buf.Writer
	check *datagramOwnerCheck
}

func (w *ownerCheckedWriter) WriteMultiBuffer(data buf.MultiBuffer) error {
	if !w.check.validate(data) {
		buf.ReleaseMulti(data)
		return Code("owner_changed")
	}
	return w.Writer.WriteMultiBuffer(data)
}
func (w *ownerCheckedWriter) Close() error { return common.Close(w.Writer) }
func (w *ownerCheckedWriter) Interrupt()   { _ = common.Interrupt(w.Writer) }
