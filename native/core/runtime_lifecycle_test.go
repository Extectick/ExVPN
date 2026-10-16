// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"io"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// A transparent loopback peer accounts for actual transport sockets, without
// using Xray's cache internals or replacing Runtime.Close. Separate peers make
// resource ownership observable while a second core remains live.
type lifecyclePeer struct {
	listener net.Listener
	backend  string
	accepted atomic.Int32
	active   atomic.Int32
	mu       sync.Mutex
	pairs    map[*lifecyclePeerPair]struct{}
	done     chan struct{}
	workers  sync.WaitGroup
	close    sync.Once
}

type lifecyclePeerPair struct {
	client, backend net.Conn
	close           sync.Once
}

func (p *lifecyclePeerPair) Close() {
	p.close.Do(func() { _ = p.client.Close(); _ = p.backend.Close() })
}

func startLifecyclePeer(t *testing.T, backendPort int) *lifecyclePeer {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal("could not start synthetic lifecycle peer")
	}
	p := &lifecyclePeer{listener: listener, backend: net.JoinHostPort("127.0.0.1", strconv.Itoa(backendPort)), pairs: make(map[*lifecyclePeerPair]struct{}), done: make(chan struct{})}
	go func() {
		defer close(p.done)
		for {
			client, err := listener.Accept()
			if err != nil {
				return
			}
			p.accepted.Add(1)
			backend, err := net.DialTimeout("tcp4", p.backend, time.Second)
			if err != nil {
				_ = client.Close()
				continue
			}
			pair := &lifecyclePeerPair{client: client, backend: backend}
			p.mu.Lock()
			p.pairs[pair] = struct{}{}
			p.active.Add(1)
			p.workers.Add(1)
			p.mu.Unlock()
			go p.forward(pair)
		}
	}()
	t.Cleanup(p.Close)
	return p
}

func (p *lifecyclePeer) forward(pair *lifecyclePeerPair) {
	defer p.workers.Done()
	completed := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(pair.backend, pair.client); completed <- struct{}{} }()
	go func() { _, _ = io.Copy(pair.client, pair.backend); completed <- struct{}{} }()
	<-completed
	pair.Close()
	<-completed
	p.mu.Lock()
	delete(p.pairs, pair)
	p.active.Add(-1)
	p.mu.Unlock()
}

func (p *lifecyclePeer) Port() int { return p.listener.Addr().(*net.TCPAddr).Port }

func (p *lifecyclePeer) Close() {
	p.close.Do(func() {
		_ = p.listener.Close()
		<-p.done // No more workers can be added before Wait.
		p.mu.Lock()
		pairs := make([]*lifecyclePeerPair, 0, len(p.pairs))
		for pair := range p.pairs {
			pairs = append(pairs, pair)
		}
		p.mu.Unlock()
		for _, pair := range pairs {
			pair.Close()
		}
		p.workers.Wait()
	})
}

func waitLifecyclePeerEmpty(t *testing.T, peer *lifecyclePeer, generation int) {
	t.Helper()
	deadline := time.Now().Add(1500 * time.Millisecond)
	for peer.active.Load() != 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if active := peer.active.Load(); active != 0 {
		t.Fatalf("Runtime.Close left %d peer transport sockets active after generation %d", active, generation)
	}
}

func TestRuntimeCloseReleasesTransportResources(t *testing.T) {
	for _, entry := range []struct {
		name, transport, mode string
		tls                   bool
	}{
		{"grpc-h2c", "grpc", "", false},
		{"grpc-tls", "grpc", "", true},
		{"xhttp-h1-packet-up", "xhttp", "packet-up", false},
		{"xhttp-h1-stream-up", "xhttp", "stream-up", false},
		{"xhttp-h1-stream-one", "xhttp", "stream-one", false},
		{"xhttp-h2-stream-one", "xhttp", "stream-one", true},
	} {
		t.Run(entry.name, func(t *testing.T) {
			var hits atomic.Int32
			target := localHTTPSTarget(t, &hits, false)
			profile := fixture("vless")
			profile.Server, profile.Port = "127.0.0.1", freePort(t)
			profile.Transport = Transport{Type: entry.transport, Mode: entry.mode}
			if entry.transport == "grpc" {
				profile.Transport.ServiceName = "exvpn-lifetime"
			} else {
				profile.Transport.Path = "/exvpn-lifetime"
			}
			profile.TLS = TLS{}
			if entry.tls {
				profile.TLS = TLS{Enabled: true, ServerName: "127.0.0.1", ALPN: []string{"h2"}}
			}
			stream := outbound(profile)["streamSettings"].(object)
			if entry.tls {
				stream["tlsSettings"].(object)["certificates"] = []object{testServerCertificate(t, target)}
			}
			startLocalProtocolServer(t, profile.Port, "vless", object{"clients": []object{{"id": profile.UUID}}, "decryption": "none"}, stream)
			retiringPeer := startLifecyclePeer(t, profile.Port)
			livePeer := startLifecyclePeer(t, profile.Port)
			start := func(peer *lifecyclePeer) *Runtime {
				p := profile
				p.Port = peer.Port()
				if entry.tls {
					return startProbeWithTestRoots(t, p, target.Certificate())
				}
				runtime, err := StartProbe(p)
				if err != nil {
					t.Fatal("synthetic runtime failed to start", err)
				}
				t.Cleanup(runtime.Close)
				return runtime
			}
			live := start(livePeer)
			if err := requestLocalHTTPS(live, target); err != nil {
				t.Fatal("independent core did not carry verified HTTPS", err)
			}
			if livePeer.accepted.Load() == 0 {
				t.Fatal("HTTPS bypassed the independent transport peer")
			}
			for generation := 1; generation <= 3; generation++ {
				before := retiringPeer.accepted.Load()
				retiring := start(retiringPeer)
				if err := requestLocalHTTPS(retiring, target); err != nil {
					t.Fatal("new generation did not carry verified HTTPS", err)
				}
				if retiringPeer.accepted.Load() <= before {
					t.Fatal("new generation did not use its owned peer")
				}
				retiring.Close() // Production Runtime.Close calls the real Instance.Close.
				retiring.Close()
				waitLifecyclePeerEmpty(t, retiringPeer, generation)
				if err := requestLocalHTTPS(live, target); err != nil {
					t.Fatal("retiring another core broke the independent live core", err)
				}
			}
			// Cached transports must neither retain sockets nor reconnect after
			// retirement. Background retry cadence is tested separately upstream.
			accepted := retiringPeer.accepted.Load()
			time.Sleep(100 * time.Millisecond)
			if retiringPeer.active.Load() != 0 || retiringPeer.accepted.Load() != accepted {
				t.Fatal("retired generations created new peer work")
			}
			live.Close()
			live.Close()
			waitLifecyclePeerEmpty(t, livePeer, 4)
			if hits.Load() != 7 {
				t.Fatalf("expected seven independent verified HTTPS responses, got %d", hits.Load())
			}
		})
	}
}
