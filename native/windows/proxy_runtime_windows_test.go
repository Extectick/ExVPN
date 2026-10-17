//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"context"
	"crypto/x509"
	"encoding/binary"
	"encoding/hex"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
	"github.com/xtls/xray-core/transport/internet"
)

// This independent, bounded VLESS peer permits loopback targets only. It does
// not use the client's compiler or routing; a direct fallback cannot increment
// its accepted request counter. No host routes, DNS, guard or WinINET changes.
func localVLESSProxyPeer(t *testing.T, profile exvpn.Profile) (int, *atomic.Int32) {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	hits := &atomic.Int32{}
	uuid, _ := hex.DecodeString(strings.ReplaceAll(profile.UUID, "-", ""))
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer connection.Close()
				_ = connection.SetDeadline(time.Now().Add(5 * time.Second))
				header := make([]byte, 18)
				if _, err := io.ReadFull(connection, header); err != nil || header[0] != 0 || string(header[1:17]) != string(uuid) {
					return
				}
				if _, err := io.CopyN(io.Discard, connection, int64(header[17])); err != nil {
					return
				}
				var destination [4]byte
				if _, err := io.ReadFull(connection, destination[:]); err != nil || destination[0] != 1 || destination[3] != 1 {
					return
				}
				var address [4]byte
				if _, err := io.ReadFull(connection, address[:]); err != nil || address != [4]byte{127, 0, 0, 1} {
					return
				}
				target, err := net.DialTimeout("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(int(binary.BigEndian.Uint16(destination[1:3])))), time.Second)
				if err != nil {
					return
				}
				defer target.Close()
				hits.Add(1)
				if _, err := connection.Write([]byte{0, 0}); err != nil {
					return
				}
				go func() { _, _ = io.Copy(target, connection); _ = target.Close() }()
				_, _ = io.Copy(connection, target)
			}()
		}
	}()
	return listener.Addr().(*net.TCPAddr).Port, hits
}

func startLoopbackSystemProxy(t *testing.T, profile exvpn.Profile) *xraySystemProxy {
	t.Helper()
	installOutboundDialer.Do(func() { internet.UseAlternativeSystemDialer(outboundRuntime) })
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	preparer := func(ctx context.Context, resolution *endpointResolution) (context.Context, *outboundLease, error) {
		lease, err := outboundRuntime.newLease(ctx, outboundSnapshot{}, resolution)
		if err != nil {
			return nil, nil, err
		}
		return context.WithValue(lease.ctx, outboundLeaseKey{}, lease), lease, nil
	}
	tunnel, err := startSystemProxy(ctx, profile, nil, preparer)
	if tunnel != nil {
		t.Cleanup(func() { _ = tunnel.Close() })
	}
	if err != nil {
		t.Fatal(err)
	}
	return tunnel.(*xraySystemProxy)
}

func TestSystemProxyLoopbackForwardConnectTLSAndStop(t *testing.T) {
	profile := syntheticProfile()
	profile.Server = "127.0.0.1"
	profile.TLS = exvpn.TLS{}
	port, upstreamHits := localVLESSProxyPeer(t, profile)
	profile.Port = port
	var destinationHits atomic.Int32
	handler := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		destinationHits.Add(1)
		w.WriteHeader(http.StatusNoContent)
	})
	https := httptest.NewTLSServer(handler)
	defer https.Close()
	plain := httptest.NewServer(handler)
	defer plain.Close()
	proxy := startLoopbackSystemProxy(t, profile)
	roots := x509.NewCertPool()
	roots.AddCert(https.Certificate())
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := verifySystemProxy(ctx, proxy.port, https.URL, roots); err != nil {
		t.Fatalf("verified TLS through HTTP CONNECT/VLESS failed: %v", err)
	}
	endpoint, _ := url.Parse("http://127.0.0.1:" + strconv.Itoa(proxy.port))
	transport := &http.Transport{Proxy: http.ProxyURL(endpoint), DisableKeepAlives: true}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 3 * time.Second}
	response, err := client.Get(plain.URL)
	if err != nil {
		t.Fatal("HTTP forwarding failed", err)
	}
	_ = response.Body.Close()
	if response.StatusCode != 204 || destinationHits.Load() != 2 || upstreamHits.Load() != 2 {
		t.Fatal("traffic did not traverse the independent selected VLESS peer")
	}
	if traffic, err := proxy.Statistics(); err != nil || traffic.UploadBytes <= 0 || traffic.DownloadBytes <= 0 {
		t.Fatal("live proxy traffic counters missing", traffic, err)
	}
	if err := verifySystemProxy(ctx, proxy.port, https.URL, x509.NewCertPool()); err == nil {
		t.Fatal("untrusted HTTPS certificate accepted")
	}
	if err := proxy.Close(); err != nil {
		t.Fatal(err)
	}
	if err := verifySystemProxy(ctx, proxy.port, https.URL, roots); err == nil {
		t.Fatal("closed proxy still accepts traffic")
	}
}

func TestSystemProxyLoopbackUnreachablePeerHasNoDirectFallback(t *testing.T) {
	var hits atomic.Int32
	target := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { hits.Add(1); w.WriteHeader(204) }))
	defer target.Close()
	reservation, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	profile := syntheticProfile()
	profile.Server = "127.0.0.1"
	profile.Port = reservation.Addr().(*net.TCPAddr).Port
	profile.TLS = exvpn.TLS{}
	_ = reservation.Close()
	proxy := startLoopbackSystemProxy(t, profile)
	roots := x509.NewCertPool()
	roots.AddCert(target.Certificate())
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if verifySystemProxy(ctx, proxy.port, target.URL, roots) == nil || hits.Load() != 0 {
		t.Fatal("failed selected peer was bypassed")
	}
}
