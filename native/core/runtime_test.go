// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/proxy/freedom"
	_ "github.com/xtls/xray-core/proxy/vless/inbound"
	_ "github.com/xtls/xray-core/proxy/vmess/inbound"
)

func freePort(t *testing.T) int {
	t.Helper()
	l, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

// All traffic remains on loopback. This verifies actual core protocol handling
// and HTTPS transport, rather than only JSON generation or a TCP ping.
func TestLoopbackProtocolsCarryVerifiedHTTPSAndStop(t *testing.T) {
	for _, entry := range []struct{ protocol, transport string }{
		{"vless", "tcp"}, {"vless", "ws"}, {"vless", "grpc"}, {"vless", "xhttp"}, {"vmess", "tcp"}, {"shadowsocks", "tcp"},
	} {
		t.Run(entry.protocol+"/"+entry.transport, func(t *testing.T) {
			p := fixture(entry.protocol)
			p.Transport.Type = entry.transport
			if entry.transport == "ws" || entry.transport == "xhttp" {
				p.Transport.Path = "/exvpn-local-test"
			}
			if entry.transport == "grpc" {
				p.Transport.ServiceName = "exvpn-local-test"
			}
			loopbackHTTPS(t, p)
		})
	}
}

func loopbackHTTPS(t *testing.T, p Profile) {
	t.Helper()
	target := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(w, "exvpn-local-proof") }))
	defer target.Close()
	p.Server = "127.0.0.1"
	p.Port = freePort(t)
	p.TLS = TLS{}
	// Xray blocks proxy inbound access to private destinations by default. The
	// fixture server explicitly allows loopback for this local test only.
	settings := object{"clients": []object{{"id": p.UUID}}, "decryption": "none"}
	if p.Protocol == "shadowsocks" {
		settings = object{"method": p.Cipher, "password": p.Password}
	}
	serverConfig := object{"log": object{"loglevel": "none", "access": "none", "error": "none"}, "inbounds": []object{{"listen": "127.0.0.1", "port": p.Port, "protocol": p.Protocol, "settings": settings, "streamSettings": outbound(p)["streamSettings"]}}, "outbounds": []object{{"protocol": "freedom", "settings": object{"finalRules": []object{{"action": "allow", "ip": []string{"127.0.0.1"}}}}}}}
	b, _ := json.Marshal(serverConfig)
	server, e := core.StartInstance("json", b)
	if e != nil {
		t.Fatal("local server could not start")
	}
	defer server.Close()
	r, e := StartProbe(p)
	if e != nil {
		t.Fatal(e)
	}
	defer r.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, e := r.dialer.DialContext(ctx, "tcp", strings.TrimPrefix(target.URL, "https://"))
	if e != nil {
		t.Fatal("SOCKS/protocol connection failed")
	}
	defer conn.Close()
	roots := x509.NewCertPool()
	roots.AddCert(target.Certificate())
	tlsConn := tls.Client(conn, &tls.Config{RootCAs: roots, ServerName: "127.0.0.1", MinVersion: tls.VersionTLS12})
	if e = tlsConn.HandshakeContext(ctx); e != nil {
		t.Fatalf("verified TLS handshake failed: %v", e)
	}
	_, e = fmt.Fprintf(tlsConn, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
	if e != nil {
		t.Fatal("HTTPS write failed")
	}
	response, e := http.ReadResponse(bufio.NewReader(tlsConn), nil)
	if e != nil {
		t.Fatal("HTTPS read failed")
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	if string(body) != "exvpn-local-proof" {
		t.Fatal("unexpected HTTPS content")
	}
	r.Close()
	r.Close()
	if _, e = r.dialer.DialContext(ctx, "tcp", strings.TrimPrefix(target.URL, "https://")); e == nil {
		t.Fatal("listener still active after stop")
	}
}

func TestUnreachableProxyNeverReachesDirectTarget(t *testing.T) {
	var hits atomic.Int32
	target := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { hits.Add(1); w.WriteHeader(204) }))
	defer target.Close()
	p := fixture("vless")
	p.Server = "127.0.0.1"
	p.Port = freePort(t)
	p.TLS = TLS{}
	r, e := StartProbe(p)
	if e != nil {
		t.Fatal(e)
	}
	defer r.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	result := r.Probe(ctx, target.URL)
	if result.OK || result.Code != "probe_connection_failed" || hits.Load() != 0 {
		t.Fatal("failed proxy did not stay closed")
	}
}

func TestProbeRequiresHTTPSWithoutURLCredentials(t *testing.T) {
	r := &Runtime{}
	for _, target := range []string{"http://example.com", "https://user:secret@example.com", "file:///private", "https://example.com/#secret"} {
		if result := r.Probe(context.Background(), target); result.Code != "probe_invalid_target" || result.OK {
			t.Error("unsafe probe target accepted")
		}
	}
}
