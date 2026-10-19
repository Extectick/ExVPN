// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
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

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

// Independent WireGuard implementation endpoint in userspace. No host TUN,
// firewall, DNS or routes are modified by this protocol acceptance fixture.
func TestLoopbackWireGuardCarriesVerifiedIPv4AndIPv6HTTPS(t *testing.T) {
	serverKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	clientKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tun, network, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.7.0.1"), netip.MustParseAddr("fd00:7::1")}, nil, 1420)
	if err != nil {
		t.Fatal(err)
	}
	dev := device.NewDevice(tun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelSilent, ""))
	t.Cleanup(dev.Close)
	port := freeUDPPort(t)
	config := fmt.Sprintf("private_key=%s\nlisten_port=%d\npublic_key=%s\nallowed_ip=10.7.0.2/32\nallowed_ip=fd00:7::2/128\n", hex.EncodeToString(serverKey.Bytes()), port, hex.EncodeToString(clientKey.PublicKey().Bytes()))
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
	p.WireGuard.Reserved = nil
	r, err := StartProbe(p)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(r.Close)
	for _, ip := range []string{"10.7.0.1", "fd00:7::1"} {
		t.Run(ip, func(t *testing.T) {
			listener, err := network.ListenTCP(&net.TCPAddr{IP: net.ParseIP(ip), Port: 8443})
			if err != nil {
				t.Fatal(err)
			}
			var hits atomic.Int32
			target := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				hits.Add(1)
				_, _ = io.WriteString(w, "exvpn-local-proof")
			}))
			_ = target.Listener.Close()
			target.Listener = listener
			target.StartTLS()
			t.Cleanup(target.Close)
			if err := requestLocalHTTPS(r, target); err != nil || hits.Load() != 1 {
				t.Fatalf("WireGuard HTTPS failed: %v", err)
			}
		})
	}
	r.Close()
}
