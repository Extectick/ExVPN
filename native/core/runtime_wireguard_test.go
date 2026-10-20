// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"

	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	"golang.org/x/net/dns/dnsmessage"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

type wireguardFixture struct {
	profile Profile
	device  *device.Device
	network *netstack.Net
}

func startWireguardFixture(t *testing.T) *wireguardFixture {
	t.Helper()
	serverKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal("could not create synthetic server key")
	}
	clientKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal("could not create synthetic client key")
	}
	var preshared [32]byte
	if _, err := rand.Read(preshared[:]); err != nil {
		t.Fatal("could not create synthetic preshared key")
	}
	tun, network, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.7.0.1"), netip.MustParseAddr("fd00:7::1")}, nil, 1420)
	if err != nil {
		t.Fatal("synthetic userspace network failed")
	}
	dev := device.NewDevice(tun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelSilent, ""))
	t.Cleanup(dev.Close)
	port := freeUDPPort(t)
	config := fmt.Sprintf("private_key=%s\nlisten_port=%d\npublic_key=%s\npreshared_key=%s\nallowed_ip=10.7.0.2/32\nallowed_ip=fd00:7::2/128\n", hex.EncodeToString(serverKey.Bytes()), port, hex.EncodeToString(clientKey.PublicKey().Bytes()), hex.EncodeToString(preshared[:]))
	if err = dev.IpcSet(config); err != nil {
		t.Fatal("synthetic WireGuard server config failed")
	}
	if err = dev.Up(); err != nil {
		t.Fatal("synthetic WireGuard server failed")
	}
	p := additionalProfile("wireguard")
	p.Server = "127.0.0.1"
	p.Port = port
	p.WireGuard.PrivateKey = base64.StdEncoding.EncodeToString(clientKey.Bytes())
	p.WireGuard.PublicKey = base64.StdEncoding.EncodeToString(serverKey.PublicKey().Bytes())
	p.WireGuard.PreSharedKey = base64.StdEncoding.EncodeToString(preshared[:])
	p.WireGuard.Reserved = nil
	return &wireguardFixture{profile: p, device: dev, network: network}
}

func wireguardHTTPSTarget(t *testing.T, f *wireguardFixture, ip string, hits *atomic.Int32) *httptest.Server {
	t.Helper()
	listener, err := f.network.ListenTCP(&net.TCPAddr{IP: net.ParseIP(ip), Port: 8443})
	if err != nil {
		t.Fatal("synthetic HTTPS listener failed")
	}
	target := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		_, _ = io.WriteString(w, "exvpn-local-proof")
	}))
	_ = target.Listener.Close()
	target.Listener = listener
	target.StartTLS()
	t.Cleanup(target.Close)
	return target
}

// Route through the same explicit proxy tags used by the production DNS and
// protected application dispatchers. No host resolver or direct socket is used.
func wireguardUDPExchange(r *Runtime, tag string, target *net.UDPAddr, payload []byte) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	ctx = session.ContextWithInbound(ctx, &session.Inbound{Tag: tag})
	packet, err := core.DialUDP(ctx, r.instance)
	if err != nil {
		return nil, err
	}
	defer packet.Close()
	if _, err := packet.WriteTo(payload, target); err != nil {
		return nil, err
	}
	type result struct {
		payload []byte
		err     error
	}
	done := make(chan result, 1)
	go func() {
		buffer := make([]byte, 2048)
		n, _, err := packet.ReadFrom(buffer)
		done <- result{payload: buffer[:n], err: err}
	}()
	select {
	case got := <-done:
		return got.payload, got.err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func wireguardUDPListener(t *testing.T, f *wireguardFixture, ip string, port int, handle func([]byte) []byte) *net.UDPAddr {
	t.Helper()
	listener, err := f.network.ListenUDP(&net.UDPAddr{IP: net.ParseIP(ip), Port: port})
	if err != nil {
		t.Fatal("synthetic UDP listener failed")
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		buffer := make([]byte, 2048)
		for {
			n, peer, err := listener.ReadFrom(buffer)
			if err != nil {
				return
			}
			if response := handle(buffer[:n]); response != nil {
				_, _ = listener.WriteTo(response, peer)
			}
		}
	}()
	t.Cleanup(func() { _ = listener.Close(); <-done })
	return listener.LocalAddr().(*net.UDPAddr)
}

// Independent WireGuard implementation endpoint in userspace. No host TUN,
// firewall, DNS or routes are modified by this protocol acceptance fixture.
func TestLoopbackWireGuardCarriesVerifiedIPv4AndIPv6HTTPS(t *testing.T) {
	f := startWireguardFixture(t)
	r, err := StartProbe(f.profile)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(r.Close)
	for _, ip := range []string{"10.7.0.1", "fd00:7::1"} {
		t.Run(ip, func(t *testing.T) {
			var hits atomic.Int32
			target := wireguardHTTPSTarget(t, f, ip, &hits)
			if err := requestLocalHTTPS(r, target); err != nil || hits.Load() != 1 {
				t.Fatalf("WireGuard HTTPS failed: %v", err)
			}
		})
	}
	r.Close()
}

func TestWireGuardCarriesUDPAndDNSAcrossBothAddressFamiliesAndRuntimeGenerations(t *testing.T) {
	f := startWireguardFixture(t)
	var dnsHits atomic.Int32
	targets := map[string]*net.UDPAddr{}
	for _, ip := range []string{"10.7.0.1", "fd00:7::1"} {
		targets[ip+"/udp"] = wireguardUDPListener(t, f, ip, 5353, func(payload []byte) []byte {
			return append([]byte("encrypted-echo:"), payload...)
		})
		targets[ip+"/dns"] = wireguardUDPListener(t, f, ip, 53, func(payload []byte) []byte {
			var query dnsmessage.Message
			if query.Unpack(payload) != nil || len(query.Questions) != 1 || query.Questions[0].Name.String() != "fixture.exvpn.test." {
				return nil
			}
			dnsHits.Add(1)
			response := dnsmessage.Message{Header: dnsmessage.Header{ID: query.ID, Response: true, Authoritative: true}, Questions: query.Questions}
			response.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: query.Questions[0].Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 1}, Body: &dnsmessage.AResource{A: [4]byte{192, 0, 2, 77}}}}
			encoded, _ := response.Pack()
			return encoded
		})
	}
	for generation := 1; generation <= 3; generation++ {
		if generation > 1 {
			// WireGuard rejects repeated initiations for one peer within 20ms.
			// Respect its pinned anti-flood interval instead of waiting for a retry.
			time.Sleep(30 * time.Millisecond)
		}
		r, err := StartProbe(f.profile)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(r.Close)
		for _, ip := range []string{"10.7.0.1", "fd00:7::1"} {
			payload := []byte(fmt.Sprintf("generation-%d", generation))
			got, err := wireguardUDPExchange(r, "probe", targets[ip+"/udp"], payload)
			if err != nil || !bytes.Equal(got, append([]byte("encrypted-echo:"), payload...)) {
				t.Fatalf("protected UDP did not traverse authenticated WireGuard peer: generation=%d family=%s err=%v bytes=%d", generation, ip, err, len(got))
			}
			query := dnsmessage.Message{Header: dnsmessage.Header{ID: uint16(generation)}, Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName("fixture.exvpn.test."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
			encoded, _ := query.Pack()
			got, err = wireguardUDPExchange(r, "dns-query", targets[ip+"/dns"], encoded)
			var response dnsmessage.Message
			if err != nil || response.Unpack(got) != nil || !response.Response || response.ID != uint16(generation) || len(response.Answers) != 1 {
				t.Fatal("trusted DNS query did not cross WireGuard transport")
			}
			answer, ok := response.Answers[0].Body.(*dnsmessage.AResource)
			if !ok || answer.A != [4]byte{192, 0, 2, 77} {
				t.Fatal("unexpected DNS answer from synthetic peer")
			}
		}
		r.Close()
		r.Close()
	}
	if dnsHits.Load() != 6 {
		t.Fatal("DNS requests bypassed independent server")
	}
}

func TestWireGuardRejectsWrongPeerAuthenticationAndRecoversAfterServerDownUp(t *testing.T) {
	f := startWireguardFixture(t)
	var hits atomic.Int32
	target := wireguardHTTPSTarget(t, f, "10.7.0.1", &hits)
	for _, field := range []string{"server-key", "client-key", "preshared-key"} {
		t.Run(field, func(t *testing.T) {
			profile := f.profile
			options := *profile.WireGuard
			profile.WireGuard = &options
			key, err := ecdh.X25519().GenerateKey(rand.Reader)
			if err != nil {
				t.Fatal("could not create synthetic wrong key")
			}
			wrong := base64.StdEncoding.EncodeToString(key.Bytes())
			switch field {
			case "server-key":
				options.PublicKey = wrong
			case "client-key":
				options.PrivateKey = wrong
			case "preshared-key":
				options.PreSharedKey = wrong
			}
			r, err := StartProbe(profile)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(r.Close)
			bounded := &Runtime{dialer: boundedEncryptionDialer{ContextDialer: r.dialer}}
			if requestLocalHTTPS(bounded, target) == nil || hits.Load() != 0 {
				t.Fatal("wrong WireGuard key reached HTTPS destination")
			}
			r.Close()
		})
	}
	r, err := StartProbe(f.profile)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(r.Close)
	if requestLocalHTTPS(r, target) != nil || hits.Load() != 1 {
		t.Fatal("authenticated WireGuard HTTPS did not connect")
	}
	if f.device.Down() != nil {
		t.Fatal("synthetic peer down failed")
	}
	bounded := &Runtime{dialer: boundedEncryptionDialer{ContextDialer: r.dialer}}
	if requestLocalHTTPS(bounded, target) == nil || hits.Load() != 1 {
		t.Fatal("server outage did not block traffic")
	}
	if f.device.Up() != nil {
		t.Fatal("synthetic peer up failed")
	}
	// Recreating the native session models the platform reconnect supervisor.
	// A dead peer must never make the client select a direct outbound instead.
	r.Close()
	r, err = StartProbe(f.profile)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(r.Close)
	if requestLocalHTTPS(r, target) != nil || hits.Load() != 2 {
		t.Fatal("WireGuard session did not recover after server restart")
	}
	assertProbeStops(t, r, target)
}
