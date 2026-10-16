//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"math/bits"
	"net"
	"net/http"
	"net/netip"
	"runtime"
	"syscall"
	"time"
	"unsafe"

	exvpn "github.com/Extectick/ExVPN/native/core"
	xrayTLS "github.com/xtls/xray-core/transport/internet/tls"
	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
)

type bootstrapRoute struct {
	index  uint32
	luid   uint64
	source netip.Addr
}

var getBootstrapRoute = windows.NewLazySystemDLL("iphlpapi.dll").NewProc("GetBestRoute2")

func selectBootstrapRoute() (bootstrapRoute, error) {
	var target, source winipcfg.RawSockaddrInet
	var route winipcfg.MibIPforwardRow2
	if target.SetAddr(bootstrapResolverIP) != nil {
		return bootstrapRoute{}, Code("bootstrap_route_unavailable")
	}
	result, _, _ := getBootstrapRoute.Call(0, 0, 0, uintptr(unsafe.Pointer(&target)), 0, uintptr(unsafe.Pointer(&route)), uintptr(unsafe.Pointer(&source)))
	runtime.KeepAlive(target)
	if uint32(result) != 0 || route.Loopback || route.InterfaceIndex == 0 || route.InterfaceLUID == 0 || !source.Addr().Is4() || !source.Addr().IsGlobalUnicast() {
		return bootstrapRoute{}, Code("bootstrap_route_unavailable")
	}
	iface, err := net.InterfaceByIndex(int(route.InterfaceIndex))
	if err != nil || iface.Name == TunnelName || iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
		return bootstrapRoute{}, Code("bootstrap_route_unavailable")
	}
	luid, err := winipcfg.LUIDFromIndex(route.InterfaceIndex)
	if err != nil || luid != route.InterfaceLUID {
		return bootstrapRoute{}, Code("bootstrap_route_unavailable")
	}
	return bootstrapRoute{route.InterfaceIndex, uint64(luid), source.Addr()}, nil
}

func offlineNativeRoots() (*x509.CertPool, error) {
	// Pinned Xray builds a non-system pool from its pinned Go root bundle when
	// UseSystemCa is false. Copy only that pool; do not install OS trust or use
	// Windows' online CertGetCertificateChain/AIA verifier for these requests.
	roots := (&xrayTLS.Config{UseSystemCa: false}).GetTLSConfig().RootCAs
	if roots == nil {
		return nil, Code("bootstrap_trust_unavailable")
	}
	return roots.Clone(), nil
}

func newBootstrapClient(route bootstrapRoute) (*http.Client, func(), error) {
	roots, err := offlineNativeRoots()
	if err != nil {
		return nil, nil, err
	}
	dialer := net.Dialer{Timeout: 5 * time.Second, LocalAddr: &net.TCPAddr{IP: net.IP(route.source.AsSlice())}, Control: func(network, _ string, raw syscall.RawConn) error {
		if network != "tcp4" {
			return Code("bootstrap_socket_rejected")
		}
		var optionErr error
		if err := raw.Control(func(socket uintptr) {
			optionErr = windows.SetsockoptInt(windows.Handle(socket), windows.IPPROTO_IP, 31 /* IP_UNICAST_IF */, int(bits.ReverseBytes32(route.index)))
		}); err != nil {
			return err
		}
		return optionErr
	}}
	transport := &http.Transport{
		Proxy: nil, TLSClientConfig: &tls.Config{RootCAs: roots, ServerName: bootstrapTLSName, MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout: 5 * time.Second, ResponseHeaderTimeout: 5 * time.Second, MaxResponseHeaderBytes: 16384,
		DisableKeepAlives: true, DisableCompression: true, ForceAttemptHTTP2: true,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			if network != "tcp" || address != bootstrapTLSName+":443" {
				return nil, Code("bootstrap_socket_rejected")
			}
			return dialer.DialContext(ctx, "tcp4", net.JoinHostPort(bootstrapResolverIP.String(), "443"))
		},
	}
	client := &http.Client{Transport: transport, Timeout: 12 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return Code("bootstrap_redirect_rejected") }}
	return client, transport.CloseIdleConnections, nil
}

func resolveWithBootstrapLease(ctx context.Context, begin, end func() error, lookup func(context.Context) (endpointResolution, error)) (result endpointResolution, err error) {
	if ctx.Err() != nil {
		return result, Code("cancelled")
	}
	if begin() != nil {
		return result, Code("bootstrap_permit_failed")
	}
	defer func() {
		if end() != nil {
			result = endpointResolution{}
			err = Code("bootstrap_close_failed")
		}
	}()
	if ctx.Err() != nil {
		return result, Code("cancelled")
	}
	result, err = lookup(ctx)
	if ctx.Err() != nil {
		return endpointResolution{}, Code("cancelled")
	}
	return result, err
}

func resolveWindowsEndpoint(ctx context.Context, guard *WindowsGuard, name string) (endpointResolution, error) {
	if _, err := endpointName(name); err != nil {
		return endpointResolution{}, err
	}
	route, err := selectBootstrapRoute()
	if err != nil {
		return endpointResolution{}, err
	}
	client, closeConnections, err := newBootstrapClient(route)
	if err != nil {
		return endpointResolution{}, err
	}
	return resolveWithBootstrapLease(ctx, func() error { return guard.beginBootstrap(route.luid) }, guard.endBootstrap, func(ctx context.Context) (endpointResolution, error) {
		defer closeConnections()
		return resolveEndpointHTTPS(ctx, client, bootstrapURL, name)
	})
}

// Host and isolated integration tests use this same factory. The controller
// arms persistent protection before invoking it. Only its own endpoint is
// resolved; the original server name, TLS SNI and transport Host are retained.
func WindowsTunnelFactory(guard *WindowsGuard) TunnelFactory {
	return func(ctx context.Context, profile exvpn.Profile, exclusions []string) (Tunnel, error) {
		if err := validateTunnelProfile(profile, exclusions); err != nil {
			return nil, err
		}
		var resolution *endpointResolution
		if _, err := netip.ParseAddr(profile.Server); err != nil {
			resolved, err := resolveWindowsEndpoint(ctx, guard, profile.Server)
			if err != nil {
				return nil, err
			}
			resolution = &resolved
		}
		return startTunnelResolved(ctx, profile, exclusions, resolution)
	}
}
