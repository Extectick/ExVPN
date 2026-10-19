//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"sync"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/stats"
	_ "github.com/xtls/xray-core/proxy/http"
)

type xraySystemProxy struct {
	instance *core.Instance
	lease    *outboundLease
	port     int
	once     sync.Once
	closeErr error
}

func (p *xraySystemProxy) LUID() uint64         { return 0 }
func (p *xraySystemProxy) SystemProxyPort() int { return p.port }
func (p *xraySystemProxy) RecoveryRequired() bool {
	return p.lease == nil || p.lease.RecoveryRequired()
}
func (p *xraySystemProxy) Close() error {
	p.once.Do(func() {
		if p.lease != nil && p.lease.Close() != nil {
			p.closeErr = Code("outbound_close_failed")
		}
		if p.instance != nil && p.instance.Close() != nil && p.closeErr == nil {
			p.closeErr = Code("core_stop_failed")
		}
	})
	return p.closeErr
}
func (p *xraySystemProxy) Statistics() (Traffic, error) {
	manager, ok := p.instance.GetFeature(stats.ManagerType()).(stats.Manager)
	if !ok {
		return Traffic{}, Code("statistics_unavailable")
	}
	return readTrafficTag(manager, systemProxyInbound)
}
func (p *xraySystemProxy) Verify(ctx context.Context) error {
	roots, err := offlineNativeRoots()
	if err != nil {
		return Code("probe_failed")
	}
	return verifySystemProxy(ctx, p.port, "https://www.gstatic.com/generate_204", roots)
}
func verifySystemProxy(ctx context.Context, port int, target string, roots *x509.CertPool) error {
	endpoint := &url.URL{Scheme: "http", Host: net.JoinHostPort("127.0.0.1", strconv.Itoa(port))}
	transport := &http.Transport{Proxy: http.ProxyURL(endpoint), TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}, TLSHandshakeTimeout: 10 * time.Second, ResponseHeaderTimeout: 10 * time.Second, DisableKeepAlives: true}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return Code("probe_failed")
	}
	response, err := client.Do(request)
	if err != nil {
		return Code("probe_failed")
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
	if response.StatusCode != http.StatusNoContent {
		return Code("probe_http_failed")
	}
	return nil
}

// Resolution is for the selected transport endpoint only. It does not change
// Windows DNS, proxy settings or routes, and is never used for HTTP targets.
func resolveProxyEndpoint(ctx context.Context, profile exvpn.Profile) (*endpointResolution, error) {
	if _, err := netip.ParseAddr(profile.Server); err == nil {
		return nil, nil
	}
	name, err := endpointName(profile.Server)
	if err != nil {
		return nil, err
	}
	bounded, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	addresses, err := net.DefaultResolver.LookupNetIP(bounded, "ip", name)
	if err != nil {
		return nil, Code("proxy_endpoint_unavailable")
	}
	resolution := &endpointResolution{name: name}
	seen := map[netip.Addr]bool{}
	for _, address := range addresses {
		address = address.Unmap()
		if usableEndpointAddress(address) && !seen[address] && len(resolution.addresses) < maxBootstrapAddresses {
			seen[address] = true
			resolution.addresses = append(resolution.addresses, address)
		}
	}
	if len(resolution.addresses) == 0 {
		return nil, Code("proxy_endpoint_unavailable")
	}
	return resolution, nil
}

func WindowsProxyFactory() TunnelFactory {
	return func(ctx context.Context, profile exvpn.Profile, exclusions []string) (Tunnel, error) {
		if exclusions != nil {
			return nil, Code("proxy_exclusions_unsupported")
		}
		if err := validateTunnelProfile(profile, nil); err != nil {
			return nil, err
		}
		resolution, err := resolveProxyEndpoint(ctx, profile)
		if err != nil {
			return nil, err
		}
		return startSystemProxy(ctx, profile, resolution, prepareOutboundLease)
	}
}

type proxyLeasePreparer func(context.Context, *endpointResolution) (context.Context, *outboundLease, error)

func startSystemProxy(ctx context.Context, profile exvpn.Profile, resolution *endpointResolution, prepare proxyLeasePreparer) (Tunnel, error) {
	if ctx.Err() != nil {
		return nil, Code("cancelled")
	}
	reservation, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, Code("proxy_bind_failed")
	}
	port := reservation.Addr().(*net.TCPAddr).Port
	_ = reservation.Close()
	compiledProfile := profile
	if profile.Protocol == "wireguard" && resolution != nil && len(resolution.addresses) > 0 {
		compiledProfile.Server = resolution.addresses[0].Unmap().String()
	}
	encoded, err := BuildSystemProxyConfig(compiledProfile, port)
	if err != nil {
		return nil, Code("config_rejected")
	}
	config, err := core.LoadConfig("json", bytes.NewReader(encoded))
	if err != nil {
		return nil, Code("config_rejected")
	}
	coreContext, lease, err := prepare(ctx, resolution)
	if err != nil {
		return nil, err
	}
	proxy := &xraySystemProxy{lease: lease, port: port}
	if err := lease.BindConfig(config); err != nil {
		return proxy, err
	}
	instance, err := core.NewWithContext(coreContext, config)
	if err != nil {
		return proxy, Code("core_start_failed")
	}
	proxy.instance = instance
	if err := instance.Start(); err != nil {
		return proxy, Code("core_start_failed")
	}
	if ctx.Err() != nil {
		return proxy, Code("cancelled")
	}
	return proxy, nil
}
