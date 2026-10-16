//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"context"
	"errors"
	"io"
	"math/bits"
	"net"
	"net/netip"
	"sync"
	"syscall"
	"testing"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
	"github.com/xtls/xray-core/app/proxyman"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/transport/internet"
	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
	"google.golang.org/protobuf/proto"
)

type outboundRawFixture struct{ err error }

func (r outboundRawFixture) Control(f func(uintptr)) error {
	if r.err != nil {
		return r.err
	}
	f(17)
	return nil
}
func (outboundRawFixture) Read(func(uintptr) bool) error  { return nil }
func (outboundRawFixture) Write(func(uintptr) bool) error { return nil }

type outboundSocketFixture struct {
	mu       sync.Mutex
	closed   bool
	closeErr error
	writes   int
}

func (s *outboundSocketFixture) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closed = true
	return s.closeErr
}
func (s *outboundSocketFixture) isClosed() bool           { s.mu.Lock(); defer s.mu.Unlock(); return s.closed }
func (s *outboundSocketFixture) Read([]byte) (int, error) { return 0, io.EOF }
func (s *outboundSocketFixture) Write(data []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return 0, net.ErrClosed
	}
	s.writes++
	return len(data), nil
}
func (*outboundSocketFixture) LocalAddr() net.Addr {
	return &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1}
}
func (*outboundSocketFixture) RemoteAddr() net.Addr {
	return &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 2}
}
func (*outboundSocketFixture) SetDeadline(time.Time) error      { return nil }
func (*outboundSocketFixture) SetReadDeadline(time.Time) error  { return nil }
func (*outboundSocketFixture) SetWriteDeadline(time.Time) error { return nil }
func (s *outboundSocketFixture) ReadFrom(b []byte) (int, net.Addr, error) {
	n, err := s.Read(b)
	return n, s.RemoteAddr(), err
}
func (s *outboundSocketFixture) WriteTo(b []byte, _ net.Addr) (int, error) { return s.Write(b) }

func outboundFixture(t *testing.T) (*outboundManager, *outboundLease, context.Context, *internet.SocketConfig) {
	return outboundFixtureWithResolution(t, nil)
}

func outboundFixtureWithResolution(t *testing.T, resolution *endpointResolution) (*outboundManager, *outboundLease, context.Context, *internet.SocketConfig) {
	t.Helper()
	m := newOutboundManager()
	m.inspect = func(route outboundRoute) error {
		if route.index == 0 || route.luid == 0 || !route.source.IsGlobalUnicast() {
			return Code("unavailable")
		}
		return nil
	}
	m.set = func(windows.Handle, int, int, int) error { return nil }
	snapshot := outboundSnapshot{
		ipv4: outboundRoute{index: 7, luid: 70, source: netip.MustParseAddr("192.0.2.8")},
		ipv6: outboundRoute{index: 9, luid: 90, source: netip.MustParseAddr("2001:db8::8")},
	}
	l, err := m.newLease(context.Background(), snapshot, resolution)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l.Close() })
	return m, l, context.WithValue(l.ctx, outboundLeaseKey{}, l), &internet.SocketConfig{Interface: l.token}
}

func TestOutboundEndpointMappingIsCopiedAndOnlyUsedAfterLeaseGate(t *testing.T) {
	resolution := &endpointResolution{name: "server.invalid", addresses: []netip.Addr{netip.MustParseAddr("198.51.100.5")}}
	m, first, ctx, options := outboundFixtureWithResolution(t, resolution)
	resolution.name = "mutated.invalid"
	resolution.addresses[0] = netip.MustParseAddr("198.51.100.99")
	var dials int
	m.dial = func(_ context.Context, d *net.Dialer, network, address string) (net.Conn, error) {
		dials++
		if address != "198.51.100.5:443" || network != "tcp4" {
			t.Fatal("immutable bootstrap mapping was not used")
		}
		return &outboundSocketFixture{}, d.Control(network, address, outboundRawFixture{})
	}
	dest := xnet.TCPDestination(xnet.DomainAddress("SERVER.invalid."), 443)
	conn, err := m.Dial(ctx, nil, dest, options)
	if err != nil {
		t.Fatal(err)
	}
	_ = conn.Close()
	if !dest.Address.Family().IsDomain() || dest.Address.Domain() != "SERVER.invalid." {
		t.Fatal("logical TLS/HTTP destination was changed")
	}
	for _, domain := range []string{"other.invalid", "a.server.invalid", "server.invalid.evil", "server.invalid..", "server.invalid:443"} {
		if conn, err := m.Dial(ctx, nil, xnet.TCPDestination(xnet.DomainAddress(domain), 443), options); err == nil || conn != nil {
			t.Fatal("non-bootstrap domain accepted")
		}
	}
	snapshot := *first.snapshot.Load()
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	second, err := m.newLease(context.Background(), snapshot, &endpointResolution{name: "server.invalid", addresses: []netip.Addr{netip.MustParseAddr("198.51.100.6")}})
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	if conn, err := m.Dial(context.Background(), nil, dest, options); err == nil || conn != nil {
		t.Fatal("retired callback used the replacement mapping")
	}
	if second.nextEndpoint.Load() != 0 || dials != 1 {
		t.Fatal("retired request reached endpoint selection or socket creation")
	}
}

func TestOutboundEndpointMappingUsesOnlyAvailableAddressFamilies(t *testing.T) {
	for _, family := range []string{"ipv4", "ipv6", "both", "neither"} {
		t.Run(family, func(t *testing.T) {
			resolution := &endpointResolution{name: "server.invalid", addresses: []netip.Addr{netip.MustParseAddr("198.51.100.5"), netip.MustParseAddr("2001:db8::5")}}
			m, lease, ctx, options := outboundFixtureWithResolution(t, resolution)
			snapshot := *lease.snapshot.Load()
			if family == "ipv6" || family == "neither" {
				snapshot.ipv4 = outboundRoute{}
			}
			if family == "ipv4" || family == "neither" {
				snapshot.ipv6 = outboundRoute{}
			}
			lease.snapshot.Store(&snapshot)
			seen := map[string]int{}
			m.dial = func(_ context.Context, d *net.Dialer, network, address string) (net.Conn, error) {
				seen[network]++
				return &outboundSocketFixture{}, d.Control(network, address, outboundRawFixture{})
			}
			for range 4 {
				conn, err := m.Dial(ctx, nil, xnet.TCPDestination(xnet.DomainAddress("server.invalid"), 443), options)
				if family == "neither" {
					if err != Code("outbound_route_unavailable") || conn != nil {
						t.Fatal("missing physical route did not fail closed")
					}
				} else if err != nil {
					t.Fatal(err)
				} else {
					_ = conn.Close()
				}
			}
			if (family == "ipv4" && (seen["tcp4"] != 4 || seen["tcp6"] != 0)) || (family == "ipv6" && (seen["tcp6"] != 4 || seen["tcp4"] != 0)) || (family == "both" && (seen["tcp4"] != 2 || seen["tcp6"] != 2)) || (family == "neither" && len(seen) != 0) {
				t.Fatal("address selection escaped the captured family snapshot")
			}
		})
	}
}

func TestOutboundRejectsInvalidBootstrapMappingBeforePublishingLease(t *testing.T) {
	for _, kind := range []string{"empty_name", "noncanonical", "empty_addresses", "too_many", "loopback", "linklocal", "multicast", "duplicate", "tun"} {
		t.Run(kind, func(t *testing.T) {
			resolution := &endpointResolution{name: "server.invalid", addresses: []netip.Addr{netip.MustParseAddr("198.51.100.5")}}
			switch kind {
			case "empty_name":
				resolution.name = ""
			case "noncanonical":
				resolution.name = "SERVER.invalid."
			case "empty_addresses":
				resolution.addresses = nil
			case "too_many":
				resolution.addresses = make([]netip.Addr, maxBootstrapAddresses+1)
			case "loopback":
				resolution.addresses[0] = netip.MustParseAddr("127.0.0.1")
			case "linklocal":
				resolution.addresses[0] = netip.MustParseAddr("fe80::1")
			case "multicast":
				resolution.addresses[0] = netip.MustParseAddr("224.0.0.1")
			case "duplicate":
				resolution.addresses = append(resolution.addresses, resolution.addresses[0])
			case "tun":
				resolution.addresses[0] = netip.MustParseAddr("172.31.255.2")
			}
			manager := newOutboundManager()
			lease, err := manager.newLease(context.Background(), outboundSnapshot{}, resolution)
			if lease != nil || err != Code("bootstrap_mapping_invalid") || manager.current.Load() != nil {
				t.Fatal("invalid map published a current lease")
			}
		})
	}
}

func TestOutboundSocketBindingAllFamiliesAndNetworks(t *testing.T) {
	for _, network := range []xnet.Network{xnet.Network_TCP, xnet.Network_UDP} {
		for _, address := range []string{"198.51.100.5", "2001:db8::5"} {
			t.Run(network.String()+"/"+address, func(t *testing.T) {
				m, l, ctx, options := outboundFixture(t)
				physical := &outboundSocketFixture{}
				var gotLevel, gotOption, gotValue, controls int
				m.set = func(_ windows.Handle, level, option, value int) error {
					gotLevel, gotOption, gotValue = level, option, value
					controls++
					return nil
				}
				m.dial = func(_ context.Context, d *net.Dialer, network, destination string) (net.Conn, error) {
					if err := d.Control(network, destination, outboundRawFixture{}); err != nil {
						return nil, err
					}
					if d.LocalAddr == nil {
						t.Error("TCP source was not bound")
					}
					return physical, nil
				}
				m.listen = func(_ context.Context, lc *net.ListenConfig, network, bind string) (net.PacketConn, error) {
					if err := lc.Control(network, bind, outboundRawFixture{}); err != nil {
						return nil, err
					}
					if bind == "0.0.0.0:0" || bind == "[::]:0" {
						t.Error("UDP source was not bound")
					}
					return physical, nil
				}
				dest := xnet.Destination{Network: network, Address: xnet.ParseAddress(address), Port: 443}
				conn, err := m.Dial(ctx, nil, dest, options)
				if err != nil {
					t.Fatal(err)
				}
				wantLevel, wantValue := windows.IPPROTO_IPV6, 9
				if dest.Address.Family().IsIPv4() {
					wantLevel, wantValue = windows.IPPROTO_IP, int(bits.ReverseBytes32(7))
				}
				if controls != 1 || gotLevel != wantLevel || gotOption != 31 || gotValue != wantValue {
					t.Fatal("incorrect IP_UNICAST_IF contract")
				}
				if network == xnet.Network_UDP {
					if _, ok := conn.(*xnet.PacketConnWrapper); !ok {
						t.Fatal("Hysteria2 packet wrapper contract lost")
					}
				}
				if err := l.Close(); err != nil || !physical.isClosed() || m.current.Load() != nil {
					t.Fatal("lease did not close owned socket")
				}
			})
		}
	}
}

func TestOutboundBindingErrorsNeverFallBack(t *testing.T) {
	for _, failure := range []string{"route", "unsafe", "raw", "option", "network", "retire"} {
		for _, network := range []xnet.Network{xnet.Network_TCP, xnet.Network_UDP} {
			t.Run(failure+"/"+network.String(), func(t *testing.T) {
				m, l, ctx, options := outboundFixture(t)
				if failure == "route" {
					m.inspect = func(outboundRoute) error { return Code("no_route") }
				}
				if failure == "unsafe" {
					m.inspect = func(outboundRoute) error { return Code("outbound_interface_unsafe") }
				}
				if failure == "option" {
					m.set = func(windows.Handle, int, int, int) error { return errors.New("sensitive OS detail") }
				}
				success := false
				control := func(fn func(string, string, syscall.RawConn) error, network, address string) error {
					raw := outboundRawFixture{}
					if failure == "raw" {
						raw.err = errors.New("sensitive raw error")
					}
					if failure == "network" {
						network = "udp6"
					}
					if failure == "retire" {
						l.cancel()
					}
					if err := fn(network, address, raw); err != nil {
						return err
					}
					success = true
					return nil
				}
				m.dial = func(_ context.Context, d *net.Dialer, network, address string) (net.Conn, error) {
					return nil, control(d.Control, network, address)
				}
				m.listen = func(_ context.Context, lc *net.ListenConfig, network, address string) (net.PacketConn, error) {
					return nil, control(lc.Control, network, address)
				}
				conn, err := m.Dial(ctx, nil, xnet.Destination{Network: network, Address: xnet.ParseAddress("198.51.100.9"), Port: 443}, options)
				if conn != nil || err == nil || success {
					t.Fatal("binding failure reached unprotected socket")
				}
				if _, ok := err.(Code); !ok {
					t.Fatal("raw error was exposed")
				}
			})
		}
	}
}

func TestOutboundRejectsUntrustedRequestsBeforeSocketCreation(t *testing.T) {
	for _, variant := range []string{"missing_token", "unknown_token", "foreign_context", "domain", "zero_port", "multicast", "unspecified", "unknown_network", "source", "custom_option", "unknown_option", "missing_ipv6"} {
		t.Run(variant, func(t *testing.T) {
			m, l, ctx, options := outboundFixture(t)
			dest := xnet.TCPDestination(xnet.ParseAddress("198.51.100.5"), 443)
			var source xnet.Address
			switch variant {
			case "missing_token":
				options = nil
			case "unknown_token":
				options.Interface = "other"
			case "foreign_context":
				ctx = context.WithValue(ctx, outboundLeaseKey{}, &outboundLease{})
			case "domain":
				dest.Address = xnet.DomainAddress("never-resolve.invalid")
			case "zero_port":
				dest.Port = 0
			case "multicast":
				dest.Address = xnet.ParseAddress("224.0.0.1")
			case "unspecified":
				dest.Address = xnet.ParseAddress("0.0.0.0")
			case "unknown_network":
				dest.Network = xnet.Network_Unknown
			case "source":
				source = xnet.ParseAddress("192.0.2.99")
			case "custom_option":
				options.Mark = 5
			case "unknown_option":
				options.ProtoReflect().SetUnknown([]byte{0xa0, 0x06, 0x01})
			case "missing_ipv6":
				dest.Address = xnet.ParseAddress("2001:db8::5")
				l.snapshot.Store(&outboundSnapshot{ipv4: l.snapshot.Load().ipv4})
			}
			m.dial = func(context.Context, *net.Dialer, string, string) (net.Conn, error) {
				t.Fatal("created socket for rejected request")
				return nil, nil
			}
			if conn, err := m.Dial(ctx, source, dest, options); conn != nil || err == nil {
				t.Fatal("untrusted request accepted")
			}
		})
	}
}

func TestOutboundTokenSurvivesContextLossButNotRetirement(t *testing.T) {
	m, first, oldContext, oldOptions := outboundFixture(t)
	m.dial = func(context.Context, *net.Dialer, string, string) (net.Conn, error) {
		return &outboundSocketFixture{}, nil
	}
	dest := xnet.TCPDestination(xnet.LocalHostIP, 443)
	if conn, err := m.Dial(context.Background(), nil, dest, proto.Clone(oldOptions).(*internet.SocketConfig)); err != nil {
		t.Fatal("trusted decoded options lost gRPC identity")
	} else {
		_ = conn.Close()
	}
	snapshot := *first.snapshot.Load()
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	second, err := m.newLease(context.Background(), snapshot, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	for _, ctx := range []context.Context{context.Background(), oldContext} {
		if conn, err := m.Dial(ctx, nil, dest, oldOptions); conn != nil || err == nil {
			t.Fatal("retired transport adopted fresh lease")
		}
	}
	if conn, err := m.Dial(oldContext, nil, dest, &internet.SocketConfig{Interface: second.token}); conn != nil || err == nil {
		t.Fatal("context/token conflict accepted")
	}
}

func TestOutboundCloseWaitsForAndClosesLateDial(t *testing.T) {
	m, l, ctx, options := outboundFixture(t)
	entered := make(chan struct{})
	socket := &outboundSocketFixture{}
	m.dial = func(ctx context.Context, _ *net.Dialer, _ string, _ string) (net.Conn, error) {
		close(entered)
		<-ctx.Done()
		return socket, nil
	}
	result := make(chan error, 1)
	go func() { _, err := m.Dial(ctx, nil, xnet.TCPDestination(xnet.LocalHostIP, 443), options); result <- err }()
	<-entered
	closed := make(chan error, 1)
	go func() { closed <- l.Close() }()
	select {
	case err := <-closed:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("retirement did not cancel pending dial")
	}
	if <-result == nil || !socket.isClosed() || m.current.Load() != nil {
		t.Fatal("late success escaped retirement")
	}
}

func TestOutboundCloseFailureRetainsOwnerAndPreventsNewLease(t *testing.T) {
	m, l, ctx, options := outboundFixture(t)
	snapshot := *l.snapshot.Load()
	m.dial = func(context.Context, *net.Dialer, string, string) (net.Conn, error) {
		return &outboundSocketFixture{closeErr: errors.New("private socket detail")}, nil
	}
	if _, err := m.Dial(ctx, nil, xnet.TCPDestination(xnet.LocalHostIP, 443), options); err != nil {
		t.Fatal(err)
	}
	if l.Close() != Code("outbound_close_failed") || m.current.Load() != l || l.live() {
		t.Fatal("uncertain close owner was forgotten")
	}
	if next, err := m.newLease(context.Background(), snapshot, nil); next != nil || err != Code("outbound_lease_busy") {
		t.Fatal("new lease started after close failure")
	}
}

func TestOutboundLoopbackUDPDoesNotPermitUnboundInternetWrites(t *testing.T) {
	m, l, ctx, options := outboundFixture(t)
	socket := &outboundSocketFixture{}
	m.set = func(windows.Handle, int, int, int) error {
		t.Fatal("loopback socket bound to physical NIC")
		return nil
	}
	m.listen = func(_ context.Context, lc *net.ListenConfig, network, address string) (net.PacketConn, error) {
		return socket, lc.Control(network, address, outboundRawFixture{})
	}
	conn, err := m.Dial(ctx, nil, xnet.UDPDestination(xnet.LocalHostIP, 443), options)
	if err != nil {
		t.Fatal(err)
	}
	packet := conn.(*xnet.PacketConnWrapper).PacketConn
	if _, err := packet.WriteTo([]byte("x"), &net.UDPAddr{IP: net.ParseIP("198.51.100.2"), Port: 443}); err == nil {
		t.Fatal("unbound loopback socket escaped to physical interface")
	}
	if _, err := conn.Write([]byte("x")); err != nil {
		t.Fatal("loopback probe failed")
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Write([]byte("x")); err == nil {
		t.Fatal("retired UDP socket accepted writes")
	}
}

func TestOutboundBindConfigStrictAndAtomic(t *testing.T) {
	_, l, _, _ := outboundFixture(t)
	good := &proxyman.SenderConfig{StreamSettings: &internet.StreamConfig{SocketSettings: &internet.SocketConfig{HappyEyeballs: &internet.HappyEyeballsConfig{Interleave: 1, MaxConcurrentTry: 4}}}}
	bad := proto.Clone(good).(*proxyman.SenderConfig)
	bad.StreamSettings.SocketSettings.Interface = "untrusted"
	cfg := &core.Config{Outbound: []*core.OutboundHandlerConfig{{SenderSettings: serial.ToTypedMessage(good)}, {SenderSettings: serial.ToTypedMessage(bad)}}}
	before := proto.Clone(cfg)
	if err := l.BindConfig(cfg); err == nil || !proto.Equal(before, cfg) {
		t.Fatal("partial config mutation or untrusted interface accepted")
	}
	cfg.Outbound = cfg.Outbound[:1]
	if err := l.BindConfig(cfg); err != nil {
		t.Fatal(err)
	}
	decoded, err := cfg.Outbound[0].SenderSettings.GetInstance()
	if err != nil {
		t.Fatal(err)
	}
	options := decoded.(*proxyman.SenderConfig).StreamSettings.SocketSettings
	if !ownedSocketOptions(options, l.token) || options.DomainStrategy != internet.DomainStrategy_AS_IS {
		t.Fatal("compiled owner options did not survive protobuf copy")
	}
}

func TestOutboundBindConfigRejectsResolutionBeforeTheLeaseGate(t *testing.T) {
	_, lease, _, _ := outboundFixture(t)
	for _, kind := range []string{"sender_force_ip", "socket_force_ip", "socket_use_ip", "dialer_proxy", "address_port"} {
		t.Run(kind, func(t *testing.T) {
			sender := &proxyman.SenderConfig{StreamSettings: &internet.StreamConfig{SocketSettings: &internet.SocketConfig{}}}
			switch kind {
			case "sender_force_ip":
				sender.TargetStrategy = internet.DomainStrategy_FORCE_IP
			case "socket_force_ip":
				sender.StreamSettings.SocketSettings.DomainStrategy = internet.DomainStrategy_FORCE_IP
			case "socket_use_ip":
				sender.StreamSettings.SocketSettings.DomainStrategy = internet.DomainStrategy_USE_IP
			case "dialer_proxy":
				sender.StreamSettings.SocketSettings.DialerProxy = "untrusted"
			case "address_port":
				sender.StreamSettings.SocketSettings.AddressPortStrategy = internet.AddressPortStrategy(1)
			}
			cfg := &core.Config{Outbound: []*core.OutboundHandlerConfig{{SenderSettings: serial.ToTypedMessage(sender)}}}
			before := proto.Clone(cfg)
			if err := lease.BindConfig(cfg); err != Code("outbound_socket_rejected") || !proto.Equal(cfg, before) {
				t.Fatal("pre-gate resolver or redirect was accepted")
			}
		})
	}
}

func TestOutboundBindEveryCompiledProtocolAndTransport(t *testing.T) {
	for _, variant := range []string{"tcp", "ws", "grpc", "xhttp", "vmess", "trojan", "shadowsocks", "hysteria2"} {
		t.Run(variant, func(t *testing.T) {
			_, l, _, _ := outboundFixture(t)
			profile := syntheticProfile()
			switch variant {
			case "tcp", "ws", "grpc", "xhttp":
				profile.Transport.Type = variant
				if variant == "grpc" {
					profile.Transport.ServiceName = "fixture"
				}
			case "vmess":
				profile.Protocol = variant
			default:
				profile.Protocol, profile.UUID, profile.Password = variant, "", "synthetic-password"
				if variant == "shadowsocks" {
					profile.Cipher = "aes-128-gcm"
					profile.TLS = exvpn.TLS{}
				}
				if variant == "hysteria2" {
					profile.Transport.Type = "hysteria"
				}
			}
			data, err := BuildTunnelConfig(profile, []string{"C:/Program Files/Fixture/app.exe"}, exvpn.ProbeOptions{Port: 10800, Username: "test", Password: "synthetic"})
			if err != nil {
				t.Fatal(err)
			}
			cfg, err := core.LoadConfig("json", bytes.NewReader(data))
			if err != nil {
				t.Fatal("compiled config rejected")
			}
			if err := l.BindConfig(cfg); err != nil {
				t.Fatal(err)
			}
			for _, outbound := range cfg.Outbound {
				message, err := outbound.SenderSettings.GetInstance()
				if err != nil || !ownedSocketOptions(message.(*proxyman.SenderConfig).StreamSettings.SocketSettings, l.token) {
					t.Fatal("outbound lacks exact lease")
				}
			}
		})
	}
}

func TestOutboundInterfaceSafety(t *testing.T) {
	route := outboundRoute{index: 7, luid: 70, source: netip.MustParseAddr("192.0.2.5")}
	valid := winipcfg.MibIPInterfaceRow{Family: windows.AF_INET, InterfaceIndex: 7, InterfaceLUID: 70, Connected: true}
	if err := validateOutboundInterface(route, &valid); err != nil {
		t.Fatal(err)
	}
	for _, kind := range []string{"weak_host", "forwarding", "offline", "index", "luid", "family"} {
		row := valid
		switch kind {
		case "weak_host":
			row.WeakHostSend = true
		case "forwarding":
			row.ForwardingEnabled = true
		case "offline":
			row.Connected = false
		case "index":
			row.InterfaceIndex++
		case "luid":
			row.InterfaceLUID++
		case "family":
			row.Family = windows.AF_UNSPEC
		}
		if validateOutboundInterface(route, &row) == nil {
			t.Fatalf("unsafe %s accepted", kind)
		}
	}
}

func TestOutboundRecoveryTracksUnderlayNotServerFailures(t *testing.T) {
	for _, kind := range []string{"healthy", "other_nic", "initial", "own_tun_route", "interface", "address", "new_address", "default_route", "source_gone"} {
		t.Run(kind, func(t *testing.T) {
			m, l, _, _ := outboundFixture(t)
			want := false
			switch kind {
			case "healthy":
			case "other_nic":
				m.interfaceChanged(winipcfg.MibDeleteInstance, &winipcfg.MibIPInterfaceRow{Family: windows.AF_INET, InterfaceLUID: 999})
			case "initial":
				m.interfaceChanged(winipcfg.MibInitialNotification, &winipcfg.MibIPInterfaceRow{Family: windows.AF_INET, InterfaceLUID: 70})
			case "own_tun_route":
				m.routeChanged(winipcfg.MibAddInstance, &winipcfg.MibIPforwardRow2{InterfaceLUID: 100, DestinationPrefix: winipcfg.IPAddressPrefix{PrefixLength: 1}})
			case "interface":
				m.interfaceChanged(winipcfg.MibDeleteInstance, &winipcfg.MibIPInterfaceRow{Family: windows.AF_INET, InterfaceLUID: 70})
				m.interfaceChanged(winipcfg.MibAddInstance, &winipcfg.MibIPInterfaceRow{Family: windows.AF_INET, InterfaceLUID: 70, Connected: true})
				want = true
			case "address":
				row := &winipcfg.MibUnicastIPAddressRow{InterfaceLUID: 70}
				_ = row.Address.SetAddr(netip.MustParseAddr("192.0.2.8"))
				m.addressChanged(winipcfg.MibDeleteInstance, row)
				want = true
			case "new_address":
				row := &winipcfg.MibUnicastIPAddressRow{InterfaceLUID: 70}
				_ = row.Address.SetAddr(netip.MustParseAddr("192.0.2.9"))
				m.addressChanged(winipcfg.MibAddInstance, row)
				want = true
			case "default_route":
				m.routeChanged(winipcfg.MibAddInstance, &winipcfg.MibIPforwardRow2{InterfaceLUID: 200})
				want = true
			case "source_gone":
				m.inspect = func(outboundRoute) error { return Code("outbound_route_unavailable") }
				want = true
			}
			if l.RecoveryRequired() != want {
				t.Fatal("incorrect underlay decision")
			}
			if want {
				m.inspect = func(outboundRoute) error { return nil }
				if !l.RecoveryRequired() {
					t.Fatal("underlay loss was forgotten before rebuild")
				}
			}
		})
	}
}
