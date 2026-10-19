// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"sync/atomic"
	"testing"
)

func TestLoopbackAdditionalProxyProtocolsCarryVerifiedHTTPS(t *testing.T) {
	for _, protocol := range []string{"socks5", "http"} {
		for _, encrypted := range []bool{false, true} {
			name := protocol
			if encrypted {
				name += "-tls"
			}
			t.Run(name, func(t *testing.T) {
				var hits atomic.Int32
				target := localHTTPSTarget(t, &hits, false)
				p := additionalProfile(protocol)
				p.Server = "127.0.0.1"
				p.Port = freePort(t)
				p.Username = "synthetic"
				p.Password = "password"
				if encrypted {
					p.TLS = TLS{Enabled: true, ServerName: "127.0.0.1"}
				}
				stream := outbound(p)["streamSettings"].(object)
				if encrypted {
					stream["tlsSettings"].(object)["certificates"] = []object{testServerCertificate(t, target)}
				}
				serverProtocol := protocol
				if protocol == "socks5" {
					serverProtocol = "socks"
				}
				settings := object{"accounts": []object{{"user": p.Username, "pass": p.Password}}}
				if protocol == "socks5" {
					settings["auth"] = "password"
					settings["udp"] = false
				}
				startLocalProtocolServer(t, p.Port, serverProtocol, settings, stream)
				var r *Runtime
				if encrypted {
					r = startProbeWithTestRoots(t, p, target.Certificate())
				} else {
					var err error
					r, err = StartProbe(p)
					if err != nil {
						t.Fatal(err)
					}
					t.Cleanup(r.Close)
				}
				if err := requestLocalHTTPS(r, target); err != nil || hits.Load() != 1 {
					t.Fatalf("HTTPS did not traverse proxy: %v", err)
				}
				r.Close()
				p.Password = "wrong-password"
				var bad *Runtime
				if encrypted {
					bad = startProbeWithTestRoots(t, p, target.Certificate())
				} else {
					var err error
					bad, err = StartProbe(p)
					if err != nil {
						t.Fatal(err)
					}
					t.Cleanup(bad.Close)
				}
				if requestLocalHTTPS(bad, target) == nil || hits.Load() != 1 {
					t.Fatal("bad proxy credentials bypassed authentication")
				}
				bad.Close()
				if encrypted {
					p.Password = "password"
					p.TLS.ServerName = "wrong.exvpn.test"
					wrong := startProbeWithTestRoots(t, p, target.Certificate())
					if requestLocalHTTPS(wrong, target) == nil || hits.Load() != 1 {
						t.Fatal("TLS accepted wrong identity")
					}
				}
			})
		}
	}
}
