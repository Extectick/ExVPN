// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"bufio"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/xtls/xray-core/core"
	"golang.org/x/net/proxy"
)

// Trust is injected into a test-only core configuration, never a production
// profile or system certificate store. Both transport TLS and destination HTTPS
// still verify the certificate and hostname.
func TestLoopbackTLSProtocolsCarryVerifiedHTTPS(t *testing.T) {
	for _, protocol := range []string{"trojan", "hysteria2"} {
		t.Run(protocol, func(t *testing.T) {
			var hits atomic.Int32
			target := localHTTPSTarget(t, &hits, false)
			p := fixture(protocol)
			p.Server, p.Port = "127.0.0.1", freePort(t)
			p.TLS = TLS{Enabled: true, ServerName: "127.0.0.1"}
			if protocol == "hysteria2" {
				p.Port = freeUDPPort(t)
				p.TLS.ALPN = []string{"h3"}
			}
			stream := outbound(p)["streamSettings"].(object)
			stream["tlsSettings"].(object)["certificates"] = []object{testServerCertificate(t, target)}
			settings := object{"clients": []object{{"password": p.Password}}}
			serverProtocol := protocol
			if protocol == "hysteria2" {
				serverProtocol = "hysteria"
				settings = object{"version": 2, "users": []object{{"auth": p.Password}}}
			}
			startLocalProtocolServer(t, p.Port, serverProtocol, settings, stream)
			r := startProbeWithTestRoots(t, p, target.Certificate())
			if err := requestLocalHTTPS(r, target); err != nil {
				t.Fatalf("verified HTTPS over %s failed: %v", protocol, err)
			}
			if hits.Load() != 1 {
				t.Fatal("HTTPS request did not reach the independent destination")
			}
			assertProbeStops(t, r, target)

			// A trusted certificate with the wrong server name must still fail.
			// This also prevents a test helper from masking an insecure transport.
			p.TLS.ServerName = "wrong.exvpn.test"
			bad := startProbeWithTestRoots(t, p, target.Certificate())
			if requestLocalHTTPS(bad, target) == nil || hits.Load() != 1 {
				t.Fatal("transport accepted a mismatched TLS server identity")
			}
		})
	}
}

func TestLoopbackVLESSRealityCarriesVerifiedHTTPS(t *testing.T) {
	for _, flow := range []string{"", "xtls-rprx-vision"} {
		name := flow
		if name == "" {
			name = "standard"
		}
		t.Run(name, func(t *testing.T) { loopbackRealityHTTPS(t, flow) })
	}
}

func loopbackRealityHTTPS(t *testing.T, flow string) {
	t.Helper()
	var hits atomic.Int32
	target := localHTTPSTarget(t, &hits, true)
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	p := fixture("vless")
	p.Flow = flow
	p.Server, p.Port = "127.0.0.1", freePort(t)
	p.TLS = TLS{Enabled: true, ServerName: "example.com", Reality: &Reality{
		PublicKey: base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes()),
		ShortID:   "0123456789abcdef", SpiderX: "/",
	}}
	stream := object{"network": "tcp", "security": "reality", "realitySettings": object{
		"target": strings.TrimPrefix(target.URL, "https://"), "serverNames": []string{p.TLS.ServerName},
		"privateKey": base64.RawURLEncoding.EncodeToString(key.Bytes()), "shortIds": []string{p.TLS.Reality.ShortID},
	}}
	startLocalProtocolServer(t, p.Port, "vless", object{"clients": []object{{"id": p.UUID, "flow": flow}}, "decryption": "none"}, stream)
	r, err := StartProbe(p)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(r.Close)
	if err = requestLocalHTTPS(r, target); err != nil {
		t.Fatalf("verified HTTPS over REALITY failed: %v", err)
	}
	if hits.Load() != 1 {
		t.Fatal("REALITY did not carry the independent HTTPS request")
	}
	assertProbeStops(t, r, target)

	wrongKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	p.TLS.Reality.PublicKey = base64.RawURLEncoding.EncodeToString(wrongKey.PublicKey().Bytes())
	bad, err := StartProbe(p)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(bad.Close)
	if requestLocalHTTPS(bad, target) == nil || hits.Load() != 1 {
		t.Fatal("REALITY accepted an unauthenticated peer or bypassed the proxy")
	}
}

func localHTTPSTarget(t *testing.T, hits *atomic.Int32, http2 bool) *httptest.Server {
	t.Helper()
	target := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		_, _ = io.WriteString(w, "exvpn-local-proof")
	}))
	target.EnableHTTP2 = http2
	// The REALITY camouflage probes deliberately trigger failed TLS handshakes;
	// retain the behavioral assertions without logging fixture socket addresses.
	target.Config.ErrorLog = log.New(io.Discard, "", 0)
	// REALITY's camouflage handshake requires TLS 1.3. Restricting the local
	// fixture does not change the application's TLS policy.
	target.TLS = &tls.Config{MinVersion: tls.VersionTLS13, CurvePreferences: []tls.CurveID{tls.X25519}}
	target.StartTLS()
	t.Cleanup(target.Close)
	return target
}

func freeUDPPort(t *testing.T) int {
	t.Helper()
	l, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.LocalAddr().(*net.UDPAddr).Port
}

func certificateLines(certificate *x509.Certificate) []string {
	return strings.Split(strings.TrimSpace(string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificate.Raw}))), "\n")
}

func testServerCertificate(t *testing.T, target *httptest.Server) object {
	t.Helper()
	key, err := x509.MarshalPKCS8PrivateKey(target.TLS.Certificates[0].PrivateKey)
	if err != nil {
		t.Fatal(err)
	}
	return object{"certificate": certificateLines(target.Certificate()), "key": strings.Split(strings.TrimSpace(string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key}))), "\n")}
}

func startLocalProtocolServer(t *testing.T, port int, protocol string, settings, stream object) {
	t.Helper()
	cfg := object{
		"log":       object{"loglevel": "none", "access": "none", "error": "none"},
		"inbounds":  []object{{"listen": "127.0.0.1", "port": port, "protocol": protocol, "settings": settings, "streamSettings": stream}},
		"outbounds": []object{{"protocol": "freedom", "settings": object{"finalRules": []object{{"action": "allow", "ip": []string{"127.0.0.1"}}}}}},
	}
	b, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal("could not encode local server configuration")
	}
	s, err := core.StartInstance("json", b)
	if err != nil {
		t.Fatalf("could not start synthetic %s server: %v", protocol, err)
	}
	t.Cleanup(func() { _ = s.Close() })
}

func startProbeWithTestRoots(t *testing.T, p Profile, root *x509.Certificate) *Runtime {
	t.Helper()
	port := freePort(t)
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}
	password := hex.EncodeToString(secret)
	b, err := BuildProbeConfig(p, ProbeOptions{Port: port, Username: "exvpn", Password: password})
	if err != nil {
		t.Fatal(err)
	}
	var cfg object
	if err = json.Unmarshal(b, &cfg); err != nil {
		t.Fatal("could not decode test probe configuration")
	}
	for _, entry := range cfg["outbounds"].([]any) {
		out := entry.(map[string]any)
		if out["tag"] != "proxy" {
			continue
		}
		tlsSettings := out["streamSettings"].(map[string]any)["tlsSettings"].(map[string]any)
		tlsSettings["disableSystemRoot"] = true
		tlsSettings["certificates"] = []object{{"certificate": certificateLines(root), "usage": "verify"}}
	}
	b, err = json.Marshal(cfg)
	if err != nil {
		t.Fatal("could not encode test probe configuration")
	}
	instance, err := core.StartInstance("json", b)
	if err != nil {
		t.Fatalf("could not start synthetic client: %v", err)
	}
	d, err := proxy.SOCKS5("tcp", "127.0.0.1:"+strconv.Itoa(port), &proxy.Auth{User: "exvpn", Password: password}, &net.Dialer{Timeout: 5 * time.Second})
	if err != nil {
		_ = instance.Close()
		t.Fatal(err)
	}
	r := &Runtime{instance: instance, dialer: d.(proxy.ContextDialer)}
	t.Cleanup(r.Close)
	return r
}

func requestLocalHTTPS(r *Runtime, target *httptest.Server) error {
	// The pinned REALITY server first probes camouflage post-handshake records
	// with a five-second read window; a cold local server needs more than 5s.
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	conn, err := r.dialer.DialContext(ctx, "tcp", strings.TrimPrefix(target.URL, "https://"))
	if err != nil {
		return err
	}
	defer conn.Close()
	deadline, _ := ctx.Deadline()
	_ = conn.SetDeadline(deadline)
	roots := x509.NewCertPool()
	roots.AddCert(target.Certificate())
	tlsConn := tls.Client(conn, &tls.Config{RootCAs: roots, ServerName: "127.0.0.1", MinVersion: tls.VersionTLS13})
	if err = tlsConn.HandshakeContext(ctx); err != nil {
		return err
	}
	if _, err = fmt.Fprint(tlsConn, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"); err != nil {
		return err
	}
	response, err := http.ReadResponse(bufio.NewReader(tlsConn), nil)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 1024))
	if err != nil {
		return err
	}
	if response.StatusCode != http.StatusOK || string(body) != "exvpn-local-proof" {
		return fmt.Errorf("unexpected synthetic HTTPS response")
	}
	return nil
}

func assertProbeStops(t *testing.T, r *Runtime, target *httptest.Server) {
	t.Helper()
	r.Close()
	r.Close()
	if requestLocalHTTPS(r, target) == nil {
		t.Fatal("closed probe still carries HTTPS")
	}
}
