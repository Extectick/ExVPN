//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"math/bits"
	"net"
	"net/netip"
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"github.com/xtls/xray-core/app/proxyman"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/transport/internet"
	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
	"google.golang.org/protobuf/proto"
)

// A single dialer is installed before the first core starts. A new core owns a
// new lease, never a new global Xray controller. Retired transport callbacks
// cannot acquire the next core's interface or sockets.
var outboundRuntime = newOutboundManager()
var installOutboundDialer sync.Once

type outboundRoute struct {
	index  uint32
	luid   uint64
	source netip.Addr
}

type outboundSnapshot struct{ ipv4, ipv6 outboundRoute }
type outboundLeaseKey struct{}

type outboundManager struct {
	current   atomic.Pointer[outboundLease]
	watchOnce sync.Once
	watchErr  error
	watchers  []winipcfg.ChangeCallback
	inspect   func(outboundRoute) error
	set       func(windows.Handle, int, int, int) error
	dial      func(context.Context, *net.Dialer, string, string) (net.Conn, error)
	listen    func(context.Context, *net.ListenConfig, string, string) (net.PacketConn, error)
}

func newOutboundManager() *outboundManager {
	return &outboundManager{
		inspect: inspectOutboundRoute,
		set:     windows.SetsockoptInt,
		dial: func(ctx context.Context, d *net.Dialer, network, address string) (net.Conn, error) {
			return d.DialContext(ctx, network, address)
		},
		listen: func(ctx context.Context, l *net.ListenConfig, network, address string) (net.PacketConn, error) {
			return l.ListenPacket(ctx, network, address)
		},
	}
}

type outboundLease struct {
	manager         *outboundManager
	token           string // Runtime-only identity; never persisted or logged.
	ctx             context.Context
	cancel          context.CancelFunc
	snapshot        atomic.Pointer[outboundSnapshot]
	mu              sync.Mutex
	retired         bool
	sockets         map[io.Closer]struct{}
	inflight        sync.WaitGroup
	once            sync.Once
	closeErr        error
	underlayChanged atomic.Bool
	endpointName    string
	endpointIPs     []netip.Addr
	nextEndpoint    atomic.Uint64
}

func prepareOutboundLease(ctx context.Context, resolution *endpointResolution) (context.Context, *outboundLease, error) {
	if ctx.Err() != nil {
		return nil, nil, Code("cancelled")
	}
	if err := outboundRuntime.watchRoutes(); err != nil {
		return nil, nil, err
	}
	var snapshot outboundSnapshot
	var err4, err6 error
	snapshot.ipv4, err4 = selectOutboundRoute(netip.MustParseAddr("1.1.1.1"))
	snapshot.ipv6, err6 = selectOutboundRoute(netip.MustParseAddr("2606:4700:4700::1111"))
	// A missing address family has no fallback. An unsafe configured interface
	// is different: never silently ignore its weak-host/forwarding policy.
	if err4 == Code("outbound_interface_unsafe") || err6 == Code("outbound_interface_unsafe") {
		return nil, nil, Code("outbound_interface_unsafe")
	}
	if err4 != nil && err6 != nil {
		return nil, nil, Code("outbound_route_unavailable")
	}
	lease, err := outboundRuntime.newLease(ctx, snapshot, resolution)
	if err != nil {
		return nil, nil, err
	}
	installOutboundDialer.Do(func() { internet.UseAlternativeSystemDialer(outboundRuntime) })
	return context.WithValue(lease.ctx, outboundLeaseKey{}, lease), lease, nil
}

func (m *outboundManager) newLease(ctx context.Context, snapshot outboundSnapshot, resolution *endpointResolution) (*outboundLease, error) {
	if ctx.Err() != nil {
		return nil, Code("cancelled")
	}
	var name string
	var addresses []netip.Addr
	if resolution != nil {
		var err error
		name, err = endpointName(resolution.name)
		if err != nil || name != resolution.name || len(resolution.addresses) == 0 || len(resolution.addresses) > maxBootstrapAddresses {
			return nil, Code("bootstrap_mapping_invalid")
		}
		seen := make(map[netip.Addr]bool, len(resolution.addresses))
		for _, address := range resolution.addresses {
			address = address.Unmap()
			if !usableEndpointAddress(address) || seen[address] {
				return nil, Code("bootstrap_mapping_invalid")
			}
			seen[address] = true
			addresses = append(addresses, address)
		}
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return nil, Code("entropy_failed")
	}
	leaseCtx, cancel := context.WithCancel(ctx)
	l := &outboundLease{manager: m, token: hex.EncodeToString(secret), ctx: leaseCtx, cancel: cancel, sockets: make(map[io.Closer]struct{}), endpointName: name, endpointIPs: addresses}
	l.snapshot.Store(&snapshot)
	if !m.current.CompareAndSwap(nil, l) {
		cancel()
		return nil, Code("outbound_lease_busy")
	}
	return l, nil
}

// BindConfig stamps only the locally compiled protobuf. gRPC reconstructs its
// context and drops arbitrary values, but retains the stream's socket settings.
// Interface is an opaque capability here, not an OS interface name. TypedMessage
// decoding copies pointers, so pointer identity cannot safely identify a core.
func (l *outboundLease) BindConfig(cfg *core.Config) error {
	if cfg == nil || !l.live() {
		return Code("outbound_lease_retired")
	}
	bound := make([]*serial.TypedMessage, len(cfg.Outbound))
	for index, outbound := range cfg.Outbound {
		if outbound == nil || outbound.SenderSettings == nil {
			return Code("outbound_socket_rejected")
		}
		message, err := outbound.SenderSettings.GetInstance()
		sender, ok := message.(*proxyman.SenderConfig)
		if err != nil || !ok || sender.Via != nil || sender.ViaCidr != "" || sender.TargetStrategy != internet.DomainStrategy_AS_IS {
			return Code("outbound_socket_rejected")
		}
		if sender.StreamSettings == nil {
			sender.StreamSettings = &internet.StreamConfig{}
		}
		if !ownedSocketOptions(sender.StreamSettings.SocketSettings, "") {
			return Code("outbound_socket_rejected")
		}
		if sender.StreamSettings.SocketSettings == nil {
			sender.StreamSettings.SocketSettings = &internet.SocketConfig{}
		}
		sender.StreamSettings.SocketSettings.Interface = l.token
		bound[index] = serial.ToTypedMessage(sender)
	}
	for index := range cfg.Outbound {
		cfg.Outbound[index].SenderSettings = bound[index]
	}
	return nil
}

func ownedSocketOptions(options *internet.SocketConfig, token string) bool {
	if options == nil {
		return token == ""
	}
	if options.Interface != token || options.DomainStrategy != internet.DomainStrategy_AS_IS {
		return false
	}
	// Allow the pinned compiler's default Happy Eyeballs configuration. AS_IS
	// keeps upstream DNS/racing disabled; only this lease maps the endpoint.
	defaults := &internet.HappyEyeballsConfig{Interleave: 1, MaxConcurrentTry: 4}
	if options.HappyEyeballs != nil && !proto.Equal(options.HappyEyeballs, defaults) {
		return false
	}
	copy := proto.Clone(options).(*internet.SocketConfig)
	copy.Interface, copy.DomainStrategy, copy.HappyEyeballs = "", internet.DomainStrategy_AS_IS, nil
	// Includes unknown protobuf fields: a new dependency option requires review.
	return proto.Equal(copy, &internet.SocketConfig{})
}

func (l *outboundLease) live() bool {
	return l != nil && l.ctx.Err() == nil && l.snapshot.Load() != nil && l.manager.current.Load() == l
}

// A failed server probe alone must not interrupt confirmed direct exclusions.
// Rebuild is needed only when the captured physical underlay changed. The
// notifications retain even a down/up transition between health samples.
func (l *outboundLease) RecoveryRequired() bool {
	if !l.live() {
		return true
	}
	if l.underlayChanged.Load() {
		return true
	}
	snapshot := l.snapshot.Load()
	if snapshot == nil {
		return true
	}
	for _, route := range []outboundRoute{snapshot.ipv4, snapshot.ipv6} {
		if route.index != 0 && l.manager.inspect(route) != nil {
			l.underlayChanged.Store(true)
			return true
		}
	}
	return false
}

func (m *outboundManager) watchRoutes() error {
	m.watchOnce.Do(func() {
		iface, err := winipcfg.RegisterInterfaceChangeCallback(m.interfaceChanged)
		if err == nil {
			m.watchers = append(m.watchers, iface)
		}
		if err == nil {
			var address *winipcfg.UnicastAddressChangeCallback
			address, err = winipcfg.RegisterUnicastAddressChangeCallback(m.addressChanged)
			if err == nil {
				m.watchers = append(m.watchers, address)
			}
		}
		if err == nil {
			var route *winipcfg.RouteChangeCallback
			route, err = winipcfg.RegisterRouteChangeCallback(m.routeChanged)
			if err == nil {
				m.watchers = append(m.watchers, route)
			}
		}
		if err != nil {
			// Initialization has no live core. Successful registrations are
			// retained if unregister fails; this manager never starts a lease.
			for _, watcher := range m.watchers {
				_ = watcher.Unregister()
			}
			m.watchErr = Code("outbound_watcher_unavailable")
		}
	})
	return m.watchErr
}

func (m *outboundManager) interfaceChanged(kind winipcfg.MibNotificationType, row *winipcfg.MibIPInterfaceRow) {
	l := m.current.Load()
	if row == nil || kind == winipcfg.MibInitialNotification || l == nil {
		return
	}
	snapshot := l.snapshot.Load()
	if snapshot == nil {
		return
	}
	for _, route := range []outboundRoute{snapshot.ipv4, snapshot.ipv6} {
		if route.luid != 0 && uint64(row.InterfaceLUID) == route.luid && ((row.Family == windows.AF_INET) == route.source.Is4()) {
			// Notifications may contain only identity fields, so do not infer
			// Connected=true from an incomplete row or erase a quick down/up.
			l.underlayChanged.Store(true)
			return
		}
	}
}

func (m *outboundManager) addressChanged(kind winipcfg.MibNotificationType, row *winipcfg.MibUnicastIPAddressRow) {
	l := m.current.Load()
	if row == nil || kind == winipcfg.MibInitialNotification || l == nil {
		return
	}
	snapshot := l.snapshot.Load()
	if snapshot == nil {
		return
	}
	for _, route := range []outboundRoute{snapshot.ipv4, snapshot.ipv6} {
		address := row.Address.Addr().Unmap()
		if route.luid != 0 && uint64(row.InterfaceLUID) == route.luid && (address == route.source || (kind == winipcfg.MibAddInstance && address.IsGlobalUnicast() && address.Is4() == route.source.Is4())) {
			l.underlayChanged.Store(true)
			return
		}
	}
}

func (m *outboundManager) routeChanged(kind winipcfg.MibNotificationType, row *winipcfg.MibIPforwardRow2) {
	l := m.current.Load()
	if row == nil || kind == winipcfg.MibInitialNotification || l == nil || l.snapshot.Load() == nil {
		return
	}
	// ExVPN owns /1 capture routes, never a physical /0. A changed /0 can
	// select another physical NIC even when the former NIC remains present.
	if !row.Loopback && row.InterfaceLUID != 0 && row.DestinationPrefix.PrefixLength == 0 {
		l.underlayChanged.Store(true)
	}
}

func (l *outboundLease) begin() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.retired || !l.live() {
		return false
	}
	l.inflight.Add(1)
	return true
}

func (l *outboundLease) track(socket io.Closer) bool {
	l.mu.Lock()
	if !l.retired && l.live() {
		l.sockets[socket] = struct{}{}
		l.mu.Unlock()
		return true
	}
	l.mu.Unlock()
	// A socket may finish creation after cancellation; it must be closed before
	// the in-flight dial completes and before the next lease can be published.
	if err := socket.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
		l.mu.Lock()
		l.closeErr = Code("outbound_close_failed")
		l.sockets[socket] = struct{}{}
		l.mu.Unlock()
	}
	return false
}

func (l *outboundLease) forget(socket io.Closer, err error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if err == nil || errors.Is(err, net.ErrClosed) {
		delete(l.sockets, socket)
	} else {
		l.closeErr = Code("outbound_close_failed")
	}
}

func (l *outboundLease) Close() error {
	if l == nil {
		return nil
	}
	l.once.Do(func() {
		l.mu.Lock()
		l.retired = true
		l.snapshot.Store(nil)
		l.cancel()
		l.mu.Unlock()
		l.inflight.Wait()
		l.mu.Lock()
		sockets := make([]io.Closer, 0, len(l.sockets))
		for socket := range l.sockets {
			sockets = append(sockets, socket)
		}
		l.mu.Unlock()
		for _, socket := range sockets {
			_ = socket.Close() // The wrapper records and retains every close error.
		}
		l.mu.Lock()
		if l.closeErr == nil && len(l.sockets) == 0 {
			l.manager.current.CompareAndSwap(l, nil)
		} else {
			l.closeErr = Code("outbound_close_failed")
		}
		l.mu.Unlock()
	})
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.closeErr
}

func (*outboundManager) DestIpAddress() xnet.IP { return nil }

func (m *outboundManager) Dial(ctx context.Context, source xnet.Address, destination xnet.Destination, options *internet.SocketConfig) (net.Conn, error) {
	l := m.current.Load()
	contextLease, hasContextLease := ctx.Value(outboundLeaseKey{}).(*outboundLease)
	if l == nil || !l.live() || (hasContextLease && contextLease != l) || options == nil || !ownedSocketOptions(options, l.token) {
		return nil, Code("outbound_lease_retired")
	}
	if ctx.Err() != nil || !l.begin() {
		return nil, Code("outbound_lease_retired")
	}
	defer l.inflight.Done()
	if source != nil && (source.Family().IsDomain() || !net.IP(source.IP()).IsUnspecified()) {
		return nil, Code("outbound_socket_rejected")
	}
	if destination.Address == nil || destination.Port == 0 || (destination.Network != xnet.Network_TCP && destination.Network != xnet.Network_UDP) {
		return nil, Code("outbound_socket_rejected")
	}
	snapshot := l.snapshot.Load()
	if snapshot == nil {
		return nil, Code("outbound_lease_retired")
	}
	if destination.Address.Family().IsDomain() {
		// Token/context validation must precede any name handling. The only
		// permitted name is the selected endpoint resolved by our protected
		// bootstrap. Never call Xray's global DNS client or the OS resolver.
		address, err := l.endpointAddress(destination.Address.Domain(), snapshot)
		if err != nil {
			return nil, err
		}
		// Destination is a value copy. TLS/HTTP/gRPC still retain their original
		// domain for SNI, Host and authority outside this system-socket layer.
		destination.Address = xnet.IPAddress(address.AsSlice())
	}
	address, ok := netip.AddrFromSlice(destination.Address.IP())
	address = address.Unmap()
	if !ok || (!address.IsGlobalUnicast() && !address.IsLoopback()) {
		return nil, Code("outbound_socket_rejected")
	}
	route := snapshot.ipv6
	network := destination.Network.SystemString() + "6"
	if address.Is4() {
		route = snapshot.ipv4
		network = destination.Network.SystemString() + "4"
	}
	if !address.IsLoopback() && m.inspect(route) != nil {
		return nil, Code("outbound_route_unavailable")
	}
	dialCtx, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(l.ctx, cancel)
	defer func() { stop(); cancel() }()
	control := func(actualNetwork, _ string, raw syscall.RawConn) error {
		if actualNetwork != network || !l.live() || dialCtx.Err() != nil {
			return Code("outbound_socket_rejected")
		}
		if address.IsLoopback() {
			return nil
		}
		if m.inspect(route) != nil {
			return Code("outbound_route_unavailable")
		}
		level, value := windows.IPPROTO_IPV6, int(route.index)
		if address.Is4() {
			level, value = windows.IPPROTO_IP, int(bits.ReverseBytes32(route.index))
		}
		var optionErr error
		if raw.Control(func(socket uintptr) {
			optionErr = m.set(windows.Handle(socket), level, 31 /* IP[V6]_UNICAST_IF */, value)
		}) != nil || optionErr != nil {
			return Code("outbound_socket_failed")
		}
		if !l.live() || dialCtx.Err() != nil {
			return Code("outbound_lease_retired")
		}
		return nil
	}
	if destination.Network == xnet.Network_UDP {
		bind := "[::]:0"
		if address.Is4() {
			bind = "0.0.0.0:0"
		}
		if address.IsLoopback() {
			bind = net.JoinHostPort(address.String(), "0")
		} else {
			bind = net.JoinHostPort(route.source.String(), "0")
		}
		packet, err := m.listen(dialCtx, &net.ListenConfig{Control: control}, network, bind)
		if err != nil {
			return nil, Code("outbound_socket_failed")
		}
		tracked := &outboundPacket{PacketConn: packet, lease: l, ipv4: address.Is4(), loopback: address.IsLoopback()}
		if !l.track(tracked) {
			return nil, Code("outbound_lease_retired")
		}
		return &xnet.PacketConnWrapper{PacketConn: tracked, Dest: &net.UDPAddr{IP: net.IP(address.AsSlice()), Port: int(destination.Port)}}, nil
	}
	dialer := &net.Dialer{Timeout: 15 * time.Second, Control: control, KeepAliveConfig: net.KeepAliveConfig{Enable: true, Idle: 45 * time.Second, Interval: 45 * time.Second, Count: -1}}
	if !address.IsLoopback() {
		dialer.LocalAddr = &net.TCPAddr{IP: net.IP(route.source.AsSlice())}
	}
	conn, err := m.dial(dialCtx, dialer, network, destination.NetAddr())
	if err != nil {
		return nil, Code("outbound_socket_failed")
	}
	tracked := &outboundConn{Conn: conn, lease: l}
	if !l.track(tracked) {
		return nil, Code("outbound_lease_retired")
	}
	return tracked, nil
}

func (l *outboundLease) endpointAddress(domain string, snapshot *outboundSnapshot) (netip.Addr, error) {
	name, err := endpointName(domain)
	if err != nil || name != l.endpointName || len(l.endpointIPs) == 0 {
		return netip.Addr{}, Code("outbound_socket_rejected")
	}
	start := int((l.nextEndpoint.Add(1) - 1) % uint64(len(l.endpointIPs)))
	for offset := range l.endpointIPs {
		address := l.endpointIPs[(start+offset)%len(l.endpointIPs)]
		route := snapshot.ipv6
		if address.Is4() {
			route = snapshot.ipv4
		}
		if route.index != 0 && route.source.IsValid() {
			return address, nil
		}
	}
	return netip.Addr{}, Code("outbound_route_unavailable")
}

type outboundConn struct {
	net.Conn
	lease *outboundLease
	once  sync.Once
	err   error
}

func (c *outboundConn) Close() error {
	c.once.Do(func() { c.err = c.Conn.Close(); c.lease.forget(c, c.err) })
	return c.err
}

type outboundPacket struct {
	net.PacketConn
	lease          *outboundLease
	ipv4, loopback bool
	once           sync.Once
	err            error
}

func (p *outboundPacket) Close() error {
	p.once.Do(func() { p.err = p.PacketConn.Close(); p.lease.forget(p, p.err) })
	return p.err
}

func (p *outboundPacket) WriteTo(data []byte, destination net.Addr) (int, error) {
	address, ok := destination.(*net.UDPAddr)
	if !ok || address == nil || address.Port <= 0 || address.Port > 65535 || address.Zone != "" || !p.lease.live() {
		return 0, Code("outbound_socket_rejected")
	}
	ip, ok := netip.AddrFromSlice(address.IP)
	ip = ip.Unmap()
	if !ok || ip.Is4() != p.ipv4 || ip.IsLoopback() != p.loopback || (!ip.IsGlobalUnicast() && !ip.IsLoopback()) {
		return 0, Code("outbound_socket_rejected")
	}
	return p.PacketConn.WriteTo(data, destination)
}

// Route lookup and inspection only read OS state. No DNS, route, firewall or
// weak-host/forwarding mutation is performed here.
func selectOutboundRoute(destination netip.Addr) (outboundRoute, error) {
	var target, source winipcfg.RawSockaddrInet
	var row winipcfg.MibIPforwardRow2
	if target.SetAddr(destination) != nil {
		return outboundRoute{}, Code("outbound_route_unavailable")
	}
	result, _, _ := getBootstrapRoute.Call(0, 0, 0, uintptr(unsafe.Pointer(&target)), 0, uintptr(unsafe.Pointer(&row)), uintptr(unsafe.Pointer(&source)))
	runtime.KeepAlive(target)
	if uint32(result) != 0 || row.Loopback || source.Addr().Is4() != destination.Is4() {
		return outboundRoute{}, Code("outbound_route_unavailable")
	}
	route := outboundRoute{index: row.InterfaceIndex, luid: uint64(row.InterfaceLUID), source: source.Addr()}
	if err := inspectOutboundRoute(route); err != nil {
		return outboundRoute{}, err
	}
	return route, nil
}

func inspectOutboundRoute(route outboundRoute) error {
	if route.index == 0 || route.index >= 1<<24 || route.luid == 0 || !route.source.IsGlobalUnicast() || route.source.Is4In6() || route.source.Zone() != "" {
		return Code("outbound_route_unavailable")
	}
	iface, err := net.InterfaceByIndex(int(route.index))
	if err != nil || iface.Name == TunnelName || iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
		return Code("outbound_route_unavailable")
	}
	luid, err := winipcfg.LUIDFromIndex(route.index)
	if err != nil || uint64(luid) != route.luid {
		return Code("outbound_route_unavailable")
	}
	family := winipcfg.AddressFamily(windows.AF_INET6)
	if route.source.Is4() {
		family = windows.AF_INET
	}
	row, err := luid.IPInterface(family)
	if err != nil {
		return Code("outbound_route_unavailable")
	}
	if err := validateOutboundInterface(route, row); err != nil {
		return err
	}
	// A DHCP/source-address change must not bind a stale or reassigned address.
	if _, err := luid.IPAddress(route.source); err != nil {
		return Code("outbound_route_unavailable")
	}
	return nil
}

func validateOutboundInterface(route outboundRoute, row *winipcfg.MibIPInterfaceRow) error {
	family := winipcfg.AddressFamily(windows.AF_INET6)
	if route.source.Is4() {
		family = windows.AF_INET
	}
	if row == nil || !row.Connected || row.InterfaceIndex != route.index || uint64(row.InterfaceLUID) != route.luid || row.Family != family {
		return Code("outbound_route_unavailable")
	}
	if row.WeakHostSend || row.ForwardingEnabled {
		return Code("outbound_interface_unsafe")
	}
	return nil
}
