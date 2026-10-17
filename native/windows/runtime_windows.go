//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"io"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
	_ "github.com/xtls/xray-core/app/policy"
	_ "github.com/xtls/xray-core/app/stats"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/stats"
	_ "github.com/xtls/xray-core/proxy/freedom"
	_ "github.com/xtls/xray-core/proxy/tun"
	"golang.org/x/net/proxy"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
)

type xrayTunnel struct {
	instance *core.Instance
	lease    *outboundLease
	luid     uint64
	dialer   proxy.ContextDialer
	once     sync.Once
	closeErr error
}

func (t *xrayTunnel) LUID() uint64 { return t.luid }
func (t *xrayTunnel) RecoveryRequired() bool {
	return t.lease == nil || t.lease.RecoveryRequired()
}
func (t *xrayTunnel) Statistics() (Traffic, error) {
	manager, ok := t.instance.GetFeature(stats.ManagerType()).(stats.Manager)
	if !ok {
		return Traffic{}, Code("statistics_unavailable")
	}
	return readTraffic(manager)
}
func readTraffic(manager stats.Manager) (Traffic, error) {
	return readTrafficTag(manager, "vpn")
}
func readTrafficTag(manager stats.Manager, tag string) (Traffic, error) {
	upload := manager.GetCounter("inbound>>>" + tag + ">>>traffic>>>uplink")
	download := manager.GetCounter("inbound>>>" + tag + ">>>traffic>>>downlink")
	if upload == nil || download == nil {
		return Traffic{}, Code("statistics_unavailable")
	}
	traffic := Traffic{UploadBytes: upload.Value(), DownloadBytes: download.Value()}
	if traffic.UploadBytes < 0 || traffic.DownloadBytes < 0 {
		return Traffic{}, Code("statistics_unavailable")
	}
	return traffic, nil
}
func (t *xrayTunnel) Close() error {
	t.once.Do(func() {
		// Retire the generation and close its sockets before the core's Close;
		// upstream transports can otherwise leave asynchronous dialers alive.
		if t.lease != nil && t.lease.Close() != nil {
			t.closeErr = Code("outbound_close_failed")
		}
		if t.instance != nil && t.instance.Close() != nil && t.closeErr == nil {
			t.closeErr = Code("core_stop_failed")
		}
	})
	return t.closeErr
}
func (t *xrayTunnel) Verify(ctx context.Context) error {
	roots, err := offlineNativeRoots()
	if err != nil {
		return Code("probe_failed")
	}
	tr := &http.Transport{DialContext: t.dialer.DialContext, TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}, TLSHandshakeTimeout: 10 * time.Second, ResponseHeaderTimeout: 10 * time.Second, DisableKeepAlives: true}
	defer tr.CloseIdleConnections()
	c := http.Client{Transport: tr, Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	r, e := http.NewRequestWithContext(ctx, http.MethodGet, "https://www.gstatic.com/generate_204", nil)
	if e != nil {
		return Code("probe_failed")
	}
	resp, e := c.Do(r)
	if e != nil {
		return Code("probe_failed")
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	if resp.StatusCode != http.StatusNoContent {
		return Code("probe_http_failed")
	}
	return nil
}
func StartTunnel(ctx context.Context, p exvpn.Profile, exclusions []string) (Tunnel, error) {
	return startTunnelResolved(ctx, p, exclusions, nil)
}

func startTunnelResolved(ctx context.Context, p exvpn.Profile, exclusions []string, resolution *endpointResolution) (Tunnel, error) {
	if ctx.Err() != nil {
		return nil, Code("cancelled")
	}
	// Do not adopt a pre-existing adapter: Xray's cleanup flushes its routes,
	// addresses and DNS. Recovery of an abandoned ExVPN adapter is a separate
	// controlled operation, never ownership inferred merely from its name.
	if _, e := net.InterfaceByName(TunnelName); e == nil {
		return nil, Code("adapter_already_exists")
	}
	l, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		return nil, Code("probe_bind_failed")
	}
	port := l.Addr().(*net.TCPAddr).Port
	_ = l.Close()
	secret := make([]byte, 32)
	if _, e = rand.Read(secret); e != nil {
		return nil, Code("entropy_failed")
	}
	password := hex.EncodeToString(secret)
	b, e := buildTunnelConfig(p, exclusions, exvpn.ProbeOptions{Port: port, Username: "exvpn", Password: password}, resolution)
	if e != nil {
		return nil, e
	}
	cfg, e := core.LoadConfig("json", bytes.NewReader(b))
	if e != nil {
		return nil, Code("config_rejected")
	}
	coreContext, lease, e := prepareOutboundLease(ctx, resolution)
	if e != nil {
		return nil, e
	}
	if e = lease.BindConfig(cfg); e != nil {
		if lease.Close() != nil {
			return &xrayTunnel{lease: lease}, Code("outbound_close_failed")
		}
		return nil, e
	}
	i, e := core.NewWithContext(coreContext, cfg)
	if e != nil {
		if lease.Close() != nil {
			return &xrayTunnel{lease: lease}, Code("outbound_close_failed")
		}
		return nil, Code("core_start_failed")
	}
	if e = installApplicationPolicy(i, exclusions); e != nil {
		return &xrayTunnel{instance: i, lease: lease}, e
	}
	if e = i.Start(); e != nil {
		return &xrayTunnel{instance: i, lease: lease}, Code("core_start_failed")
	}
	fail := func() (Tunnel, error) { return &xrayTunnel{instance: i, lease: lease}, Code("tunnel_setup_failed") }
	if ctx.Err() != nil {
		return fail()
	}
	iface, e := net.InterfaceByName(TunnelName)
	if e != nil {
		return fail()
	}
	luid, e := winipcfg.LUIDFromIndex(uint32(iface.Index))
	if e != nil {
		return fail()
	}
	d, e := proxy.SOCKS5("tcp", "127.0.0.1:"+strconv.Itoa(port), &proxy.Auth{User: "exvpn", Password: password}, &net.Dialer{Timeout: 10 * time.Second})
	if e != nil {
		return fail()
	}
	cd, ok := d.(proxy.ContextDialer)
	if !ok {
		return fail()
	}
	return &xrayTunnel{instance: i, lease: lease, luid: uint64(luid), dialer: cd}, nil
}
