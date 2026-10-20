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
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/xtls/xray-core/core"
	"golang.org/x/net/dns/dnsmessage"
)

func startMasqueServer(t *testing.T, p Profile, certificate *httptest.Server, targets map[string]string) *core.Instance {
	t.Helper()
	stream := object{"network": "masque", "security": "tls", "masqueSettings": object{}, "tlsSettings": object{"certificates": []object{testServerCertificate(t, certificate)}}}
	rules := []object{}
	outs := []object{{"tag": "blocked", "protocol": "blackhole"}}
	for ip, endpoint := range targets {
		tag := fmt.Sprintf("target-%d", len(outs))
		rules = append(rules, object{"type": "field", "ip": []string{ip}, "outboundTag": tag})
		outs = append(outs, object{"tag": tag, "protocol": "freedom", "settings": object{"redirect": endpoint, "finalRules": []object{{"action": "allow", "ip": []string{"127.0.0.1", "::1"}}}}})
	}
	cfg := object{
		"log": object{"loglevel": "none", "access": "none", "error": "none"},
		"inbounds": []object{{"listen": "127.0.0.1", "port": p.Port, "protocol": "masque", "settings": object{
			"users": []object{{"email": p.Username, "pass": p.Password}}, "address": []string{"10.14.0.1/24", "fd00:14::1/64"}, "mtu": 1420,
		}, "streamSettings": stream}},
		"outbounds": outs,
		"routing":   object{"domainStrategy": "AsIs", "rules": rules},
	}
	b, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal("synthetic MASQUE server encoding failed")
	}
	s, err := core.StartInstance("json", b)
	if err != nil {
		t.Fatalf("synthetic MASQUE server start failed: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func requestMasqueHTTPS(r *Runtime, target *httptest.Server, syntheticIP string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	_, port, err := net.SplitHostPort(strings.TrimPrefix(target.URL, "https://"))
	if err != nil {
		return err
	}
	conn, err := r.dialer.DialContext(ctx, "tcp", net.JoinHostPort(syntheticIP, port))
	if err != nil {
		return err
	}
	defer conn.Close()
	deadline, _ := ctx.Deadline()
	_ = conn.SetDeadline(deadline)
	roots := x509.NewCertPool()
	roots.AddCert(target.Certificate())
	secure := tls.Client(conn, &tls.Config{RootCAs: roots, ServerName: "127.0.0.1", MinVersion: tls.VersionTLS13})
	if err := secure.HandshakeContext(ctx); err != nil {
		return err
	}
	if _, err := fmt.Fprint(secure, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"); err != nil {
		return err
	}
	response, err := http.ReadResponse(bufio.NewReader(secure), nil)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 1024))
	if err != nil {
		return err
	}
	if response.StatusCode != 200 || string(body) != "exvpn-local-proof" {
		return fmt.Errorf("unexpected synthetic HTTPS result")
	}
	return nil
}

func masqueHTTPSTarget(t *testing.T, family string, hits *atomic.Int32) *httptest.Server {
	t.Helper()
	address := "127.0.0.1:0"
	if family == "tcp6" {
		address = "[::1]:0"
	}
	listener, err := net.Listen(family, address)
	if err != nil {
		t.Fatal("synthetic target listener unavailable")
	}
	target := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		_, _ = io.WriteString(w, "exvpn-local-proof")
	}))
	_ = target.Listener.Close()
	target.Listener = listener
	target.Config.ErrorLog = log.New(io.Discard, "", 0)
	target.StartTLS()
	t.Cleanup(target.Close)
	return target
}

// Test trust is added only to this compiled fixture, never to a profile, the
// production TLS settings, or the operating system certificate store.
func TestMasqueCarriesVerifiedIPv4IPv6HTTPSAndStopsAcrossRuntimeGenerations(t *testing.T) {
	var hits4, hits6 atomic.Int32
	target4 := masqueHTTPSTarget(t, "tcp4", &hits4)
	target6 := masqueHTTPSTarget(t, "tcp6", &hits6)
	p := masqueProfile()
	p.Port = freeUDPPort(t)
	startMasqueServer(t, p, target4, map[string]string{"198.51.100.73": strings.TrimPrefix(target4.URL, "https://"), "2001:db8::73": strings.TrimPrefix(target6.URL, "https://")})
	for generation := 1; generation <= 3; generation++ {
		r := startProbeWithTestRoots(t, p, target4.Certificate())
		if err := requestMasqueHTTPS(r, target4, "198.51.100.73"); err != nil {
			t.Fatalf("MASQUE IPv4 HTTPS failed at generation %d: %v", generation, err)
		}
		if err := requestMasqueHTTPS(r, target6, "2001:db8::73"); err != nil {
			t.Fatalf("MASQUE IPv6 HTTPS failed at generation %d: %v", generation, err)
		}
		r.Close()
		r.Close()
		if requestMasqueHTTPS(r, target4, "198.51.100.73") == nil {
			t.Fatal("closed MASQUE runtime still carries HTTPS")
		}
	}
	if hits4.Load() != 3 || hits6.Load() != 3 {
		t.Fatal("HTTPS did not pass through independent MASQUE server")
	}
}

func TestMasqueRejectsWrongCredentialsAndCertificateIdentity(t *testing.T) {
	var hits atomic.Int32
	target := masqueHTTPSTarget(t, "tcp4", &hits)
	p := masqueProfile()
	p.Port = freeUDPPort(t)
	startMasqueServer(t, p, target, map[string]string{"198.51.100.73": strings.TrimPrefix(target.URL, "https://")})
	for _, field := range []string{"password", "username", "server-name", "trust-root"} {
		t.Run(field, func(t *testing.T) {
			bad := p
			switch field {
			case "password":
				bad.Password = "wrong-password"
			case "username":
				bad.Username = "wrong-user"
			case "server-name":
				bad.TLS.ServerName = "wrong.exvpn.test"
			}
			var r *Runtime
			if field == "trust-root" {
				var err error
				r, err = StartProbe(bad)
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(r.Close)
			} else {
				r = startProbeWithTestRoots(t, bad, target.Certificate())
			}
			bounded := &Runtime{dialer: boundedEncryptionDialer{ContextDialer: r.dialer}}
			if requestMasqueHTTPS(bounded, target, "198.51.100.73") == nil || hits.Load() != 0 {
				t.Fatal("MASQUE accepted invalid authentication or reached target directly")
			}
			r.Close()
		})
	}
}

func masqueUDPListener(t *testing.T, family string, hits *atomic.Int32) *net.UDPConn {
	t.Helper()
	address := &net.UDPAddr{IP: net.ParseIP("127.0.0.1")}
	if family == "udp6" {
		address.IP = net.ParseIP("::1")
	}
	listener, err := net.ListenUDP(family, address)
	if err != nil {
		t.Fatal("synthetic UDP target listener failed")
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		buffer := make([]byte, 2048)
		for {
			n, remote, err := listener.ReadFromUDP(buffer)
			if err != nil {
				return
			}
			payload := buffer[:n]
			var response []byte
			if strings.HasPrefix(string(payload), "masque-echo:") {
				response = append([]byte("verified:"), payload...)
			} else {
				var query dnsmessage.Message
				if query.Unpack(payload) != nil || len(query.Questions) != 1 || query.Questions[0].Name.String() != "fixture.exvpn.test." {
					continue
				}
				header := dnsmessage.ResourceHeader{Name: query.Questions[0].Name, Type: query.Questions[0].Type, Class: dnsmessage.ClassINET, TTL: 1}
				var answer dnsmessage.ResourceBody = &dnsmessage.AResource{A: [4]byte{192, 0, 2, 77}}
				if header.Type == dnsmessage.TypeAAAA {
					answer = &dnsmessage.AAAAResource{AAAA: [16]byte{0x20, 0x01, 0x0d, 0xb8, 15: 77}}
				}
				message := dnsmessage.Message{Header: dnsmessage.Header{ID: query.ID, Response: true, Authoritative: true}, Questions: query.Questions, Answers: []dnsmessage.Resource{{Header: header, Body: answer}}}
				response, _ = message.Pack()
			}
			hits.Add(1)
			_, _ = listener.WriteToUDP(response, remote)
		}
	}()
	t.Cleanup(func() { _ = listener.Close(); <-done })
	return listener
}

func TestMasqueCarriesUDPAndTrustedDNSAcrossBothFamilies(t *testing.T) {
	var httpsHits, udp4Hits, udp6Hits atomic.Int32
	target := masqueHTTPSTarget(t, "tcp4", &httpsHits)
	udp4 := masqueUDPListener(t, "udp4", &udp4Hits)
	udp6 := masqueUDPListener(t, "udp6", &udp6Hits)
	p := masqueProfile()
	p.Port = freeUDPPort(t)
	startMasqueServer(t, p, target, map[string]string{"198.51.100.74": udp4.LocalAddr().String(), "2001:db8::74": udp6.LocalAddr().String()})
	for generation := 1; generation <= 3; generation++ {
		r := startProbeWithTestRoots(t, p, target.Certificate())
		for _, ip := range []string{"198.51.100.74", "2001:db8::74"} {
			// Core dispatch helper is transport-neutral; the profile and compiled
			// outbound here are MASQUE. No host DNS resolver is involved.
			echo := []byte(fmt.Sprintf("masque-echo:%d", generation))
			got, err := wireguardUDPExchange(r, "probe", &net.UDPAddr{IP: net.ParseIP(ip), Port: 5353}, echo)
			if err != nil || string(got) != "verified:"+string(echo) {
				t.Fatalf("authenticated MASQUE UDP echo failed: %v", err)
			}
			for _, kind := range []dnsmessage.Type{dnsmessage.TypeA, dnsmessage.TypeAAAA} {
				query := dnsmessage.Message{Header: dnsmessage.Header{ID: uint16(generation)}, Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName("fixture.exvpn.test."), Type: kind, Class: dnsmessage.ClassINET}}}
				encoded, _ := query.Pack()
				got, err = wireguardUDPExchange(r, "dns-query", &net.UDPAddr{IP: net.ParseIP(ip), Port: 53}, encoded)
				var response dnsmessage.Message
				if err != nil || response.Unpack(got) != nil || !response.Response || response.ID != query.ID || len(response.Answers) != 1 || response.Answers[0].Header.Type != kind {
					t.Fatal("MASQUE DNS answer failed or bypassed trusted dispatcher")
				}
			}
		}
		r.Close()
	}
	if udp4Hits.Load() != 9 || udp6Hits.Load() != 9 || httpsHits.Load() != 0 {
		t.Fatal("UDP or DNS traffic did not traverse independently observed MASQUE server")
	}
}

func TestMasqueServerOutageBlocksAndFreshSessionRecovers(t *testing.T) {
	var hits atomic.Int32
	target := masqueHTTPSTarget(t, "tcp4", &hits)
	p := masqueProfile()
	p.Port = freeUDPPort(t)
	targets := map[string]string{"198.51.100.73": strings.TrimPrefix(target.URL, "https://")}
	server := startMasqueServer(t, p, target, targets)
	r := startProbeWithTestRoots(t, p, target.Certificate())
	if err := requestMasqueHTTPS(r, target, "198.51.100.73"); err != nil || hits.Load() != 1 {
		t.Fatalf("initial authenticated MASQUE request failed: %v", err)
	}
	if server.Close() != nil {
		t.Fatal("synthetic MASQUE server close failed")
	}
	bounded := &Runtime{dialer: boundedEncryptionDialer{ContextDialer: r.dialer}}
	if requestMasqueHTTPS(bounded, target, "198.51.100.73") == nil || hits.Load() != 1 {
		t.Fatal("MASQUE server outage reached target directly")
	}
	r.Close()
	startMasqueServer(t, p, target, targets)
	recovered := startProbeWithTestRoots(t, p, target.Certificate())
	if err := requestMasqueHTTPS(recovered, target, "198.51.100.73"); err != nil || hits.Load() != 2 {
		t.Fatalf("MASQUE fresh session failed after peer returned: %v", err)
	}
	recovered.Close()
}
