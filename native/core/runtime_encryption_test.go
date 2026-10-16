// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"context"
	"crypto/ecdh"
	"crypto/mlkem"
	"crypto/rand"
	"encoding/base64"
	"net"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/proxy"
)

// All keys are generated for these isolated loopback fixtures. No provider
// material, system routes, certificates or trust-store changes are involved.
func syntheticEncryptionKeyPair(t *testing.T, kind string) (public, private string) {
	t.Helper()
	var publicBytes, privateBytes []byte
	switch kind {
	case "x25519":
		key, err := ecdh.X25519().GenerateKey(rand.Reader)
		if err != nil {
			t.Fatal("could not generate synthetic X25519 key")
		}
		publicBytes, privateBytes = key.PublicKey().Bytes(), key.Bytes()
	case "mlkem768":
		key, err := mlkem.GenerateKey768()
		if err != nil {
			t.Fatal("could not generate synthetic ML-KEM key")
		}
		publicBytes, privateBytes = key.EncapsulationKey().Bytes(), key.Bytes()
	default:
		t.Fatal("unsupported synthetic key type")
	}
	return base64.RawURLEncoding.EncodeToString(publicBytes), base64.RawURLEncoding.EncodeToString(privateBytes)
}

func startLocalEncryptionFixture(t *testing.T, mode, rtt, kind string, mask *Sudoku, flow string) (Profile, *httptest.Server, *atomic.Int32) {
	t.Helper()
	hits := new(atomic.Int32)
	target := localHTTPSTarget(t, hits, false)
	publicKey, privateKey := syntheticEncryptionKeyPair(t, kind)
	p := fixture("vless")
	p.Server, p.Port = "127.0.0.1", freePort(t)
	p.TLS = TLS{}
	p.Flow = flow
	// Deterministic minimum padding avoids random sleep in this functional
	// matrix. A separate case below also checks the provider-style defaults.
	p.Encryption = "mlkem768x25519plus." + mode + "." + rtt + ".100-35-35." + publicKey
	p.Transport.TCPSudoku = mask
	stream := object{"network": "tcp", "security": "none"}
	if mask != nil {
		stream["finalmask"] = object{"tcp": []object{{"type": "sudoku", "settings": mask}}}
	}
	startLocalProtocolServer(t, p.Port, "vless", object{
		"clients":    []object{{"id": p.UUID, "flow": flow}},
		"decryption": "mlkem768x25519plus." + mode + ".60s.100-35-35." + privateKey,
	}, stream)
	return p, target, hits
}

func startEncryptionProbe(t *testing.T, p Profile) *Runtime {
	t.Helper()
	r, err := StartProbe(p)
	if err != nil {
		t.Fatalf("synthetic encryption client did not start: %v", err)
	}
	t.Cleanup(r.Close)
	return r
}

func TestLoopbackVLESSEncryptionCarriesVerifiedHTTPS(t *testing.T) {
	for _, mode := range []string{"native", "xorpub", "random"} {
		for _, rtt := range []string{"0rtt", "1rtt"} {
			for _, kind := range []string{"x25519", "mlkem768"} {
				for _, masked := range []bool{false, true} {
					maskName := "unmasked"
					var mask *Sudoku
					if masked {
						maskName = "sudoku"
						mask = &Sudoku{Password: "synthetic-loopback-mask"}
					}
					t.Run(mode+"/"+rtt+"/"+kind+"/"+maskName, func(t *testing.T) {
						p, target, hits := startLocalEncryptionFixture(t, mode, rtt, kind, mask, "")
						r := startEncryptionProbe(t, p)
						// Each request opens a fresh TCP/TLS connection. Reuse of the
						// core exercises both cold and ticket-bearing 0-RTT paths.
						for request := range 2 {
							if err := requestLocalHTTPS(r, target); err != nil {
								t.Fatalf("verified HTTPS request %d failed: %v", request+1, err)
							}
						}
						if hits.Load() != 2 {
							t.Fatal("encrypted stream did not carry both independent HTTPS requests")
						}
						assertProbeStops(t, r, target)
					})
				}
			}
		}
	}
}

func TestLoopbackVLESSEncryptionSupportsVisionAndSudokuOptions(t *testing.T) {
	for name, mask := range map[string]*Sudoku{
		"ascii-padding":   {Password: "synthetic-loopback-mask", ASCII: "prefer_ascii", PaddingMin: 10, PaddingMax: 20},
		"multiple-tables": {Password: "synthetic-loopback-mask", ASCII: "prefer_entropy", CustomTables: []string{"xxppvvvv", "vvvvppxx"}},
	} {
		t.Run(name, func(t *testing.T) {
			p, target, hits := startLocalEncryptionFixture(t, "native", "0rtt", "x25519", mask, "xtls-rprx-vision")
			// The deployed provider spelling has no explicit encryption padding.
			p.Encryption = strings.Replace(p.Encryption, ".100-35-35.", ".", 1)
			r := startEncryptionProbe(t, p)
			if err := requestLocalHTTPS(r, target); err != nil || hits.Load() != 1 {
				t.Fatalf("Vision with authenticated encryption and Sudoku failed: %v", err)
			}
		})
	}
}

func TestLoopbackVLESSEncryptionRejectsWrongPeerAndMask(t *testing.T) {
	for _, kind := range []string{"x25519", "mlkem768"} {
		t.Run(kind, func(t *testing.T) {
			mask := &Sudoku{Password: "synthetic-loopback-mask"}
			p, target, hits := startLocalEncryptionFixture(t, "native", "0rtt", kind, mask, "")
			good := startEncryptionProbe(t, p)
			if err := requestLocalHTTPS(good, target); err != nil || hits.Load() != 1 {
				t.Fatalf("authentication control fixture did not work: %v", err)
			}
			good.Close()
			wrongPublicKey, _ := syntheticEncryptionKeyPair(t, kind)
			for name, mutate := range map[string]func(*Profile){
				"peer-key":        func(p *Profile) { p.Encryption = "mlkem768x25519plus.native.0rtt.100-35-35." + wrongPublicKey },
				"sudoku-password": func(p *Profile) { p.Transport.TCPSudoku = &Sudoku{Password: "wrong-synthetic-mask"} },
				"missing-sudoku":  func(p *Profile) { p.Transport.TCPSudoku = nil },
				"user-id":         func(p *Profile) { p.UUID = "87654321-4321-4321-8321-cba987654321" },
			} {
				t.Run(name, func(t *testing.T) {
					badProfile := p
					mutate(&badProfile)
					bad := startEncryptionProbe(t, badProfile)
					// A bad mask can deliberately leave a peer waiting for more
					// bytes. Keep this negative check bounded without shortening
					// the ordinary HTTPS helper's REALITY handshake allowance.
					bounded := &Runtime{dialer: boundedEncryptionDialer{ContextDialer: bad.dialer}}
					if requestLocalHTTPS(bounded, target) == nil || hits.Load() != 1 {
						t.Fatal("unauthenticated peer reached the HTTPS destination or bypassed the proxy")
					}
				})
			}
		})
	}
}

type boundedEncryptionDialer struct{ proxy.ContextDialer }

func (d boundedEncryptionDialer) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	conn, err := d.ContextDialer.DialContext(ctx, network, address)
	if err != nil {
		return nil, err
	}
	return &boundedEncryptionConn{Conn: conn, limit: time.Now().Add(2 * time.Second)}, nil
}

type boundedEncryptionConn struct {
	net.Conn
	limit time.Time
}

func (c *boundedEncryptionConn) SetDeadline(deadline time.Time) error {
	if deadline.IsZero() || deadline.After(c.limit) {
		deadline = c.limit
	}
	return c.Conn.SetDeadline(deadline)
}
