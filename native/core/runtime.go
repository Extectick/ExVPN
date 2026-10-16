// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"sync"
	"time"

	_ "github.com/xtls/xray-core/app/dispatcher"
	_ "github.com/xtls/xray-core/app/dns"
	_ "github.com/xtls/xray-core/app/log"
	_ "github.com/xtls/xray-core/app/proxyman/inbound"
	_ "github.com/xtls/xray-core/app/proxyman/outbound"
	_ "github.com/xtls/xray-core/app/router"
	"github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/json"
	_ "github.com/xtls/xray-core/proxy/blackhole"
	_ "github.com/xtls/xray-core/proxy/dns"
	_ "github.com/xtls/xray-core/proxy/hysteria"
	_ "github.com/xtls/xray-core/proxy/shadowsocks"
	_ "github.com/xtls/xray-core/proxy/shadowsocks_2022"
	_ "github.com/xtls/xray-core/proxy/socks"
	_ "github.com/xtls/xray-core/proxy/trojan"
	_ "github.com/xtls/xray-core/proxy/vless/outbound"
	_ "github.com/xtls/xray-core/proxy/vmess/outbound"
	_ "github.com/xtls/xray-core/transport/internet/grpc"
	_ "github.com/xtls/xray-core/transport/internet/hysteria"
	_ "github.com/xtls/xray-core/transport/internet/reality"
	_ "github.com/xtls/xray-core/transport/internet/splithttp"
	_ "github.com/xtls/xray-core/transport/internet/tagged/taggedimpl"
	_ "github.com/xtls/xray-core/transport/internet/tcp"
	_ "github.com/xtls/xray-core/transport/internet/tls"
	_ "github.com/xtls/xray-core/transport/internet/udp"
	_ "github.com/xtls/xray-core/transport/internet/websocket"
	"golang.org/x/net/proxy"
)

type Runtime struct {
	instance  *core.Instance
	dialer    proxy.ContextDialer
	closeOnce sync.Once
}

// StartProbe binds loopback on a free ephemeral port with a random password.
// Binding failure is terminal; it never silently uses another server or direct.
func StartProbe(p Profile) (*Runtime, error) {
	if err := p.Validate(); err != nil {
		return nil, err
	}
	l, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		return nil, CodeError("probe_bind_failed")
	}
	port := l.Addr().(*net.TCPAddr).Port
	_ = l.Close()
	secret := make([]byte, 32)
	if _, e = rand.Read(secret); e != nil {
		return nil, CodeError("probe_entropy_failed")
	}
	password := hex.EncodeToString(secret)
	b, e := BuildProbeConfig(p, ProbeOptions{Port: port, Username: "exvpn", Password: password})
	if e != nil {
		return nil, e
	}
	config, e := core.LoadConfig("json", bytes.NewReader(b))
	if e != nil {
		return nil, CodeError("core_config_rejected")
	}
	instance, e := core.New(config)
	if e != nil {
		return nil, CodeError("core_start_failed")
	}
	if e = instance.Start(); e != nil {
		_ = instance.Close()
		return nil, CodeError("core_start_failed")
	}
	d, e := proxy.SOCKS5("tcp", "127.0.0.1:"+strconv.Itoa(port), &proxy.Auth{User: "exvpn", Password: password}, &net.Dialer{Timeout: 10 * time.Second})
	if e != nil {
		_ = instance.Close()
		return nil, CodeError("probe_dialer_failed")
	}
	cd, ok := d.(proxy.ContextDialer)
	if !ok {
		_ = instance.Close()
		return nil, CodeError("probe_dialer_failed")
	}
	return &Runtime{instance: instance, dialer: cd}, nil
}

func (r *Runtime) Close() { r.closeOnce.Do(func() { _ = r.instance.Close() }) }

type ProbeResult struct {
	OK          bool   `json:"ok"`
	Code        string `json:"code"`
	CoreVersion string `json:"coreVersion"`
	HTTPStatus  int    `json:"httpStatus,omitempty"`
	ElapsedMS   int64  `json:"elapsedMs"`
}

// Probe performs a real HTTPS request through SOCKS; DNS for the destination is
// passed to Xray/the remote server. No environment proxies, redirects, response
// bodies, headers, IP addresses or underlying errors are exposed.
func (r *Runtime) Probe(ctx context.Context, target string) ProbeResult {
	start := time.Now()
	result := ProbeResult{CoreVersion: CoreVersion, Code: "probe_invalid_target"}
	u, e := url.Parse(target)
	if e != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Fragment != "" {
		return result
	}
	transport := &http.Transport{DialContext: r.dialer.DialContext, TLSHandshakeTimeout: 10 * time.Second, ResponseHeaderTimeout: 15 * time.Second, DisableKeepAlives: true}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	req, e := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if e != nil {
		return result
	}
	resp, e := client.Do(req)
	result.ElapsedMS = time.Since(start).Milliseconds()
	if e != nil {
		result.Code = "probe_connection_failed"
		return result
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	result.HTTPStatus = resp.StatusCode
	result.OK = resp.StatusCode >= 200 && resp.StatusCode < 400
	result.Code = "probe_http_failed"
	if result.OK {
		result.Code = "probe_ok"
	}
	return result
}
