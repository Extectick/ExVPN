//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/features/dns"
	"github.com/xtls/xray-core/transport/internet"
	xgrpc "github.com/xtls/xray-core/transport/internet/grpc"
	"github.com/xtls/xray-core/transport/internet/hysteria"
	"github.com/xtls/xray-core/transport/internet/splithttp"
	"github.com/xtls/xray-core/transport/internet/stat"
	"github.com/xtls/xray-core/transport/internet/tcp"
	xrayTLS "github.com/xtls/xray-core/transport/internet/tls"
	"github.com/xtls/xray-core/transport/internet/websocket"
	"google.golang.org/protobuf/proto"
)

// These fixtures open loopback only. They exercise the pinned transport code,
// including gRPC's reconstructed context and Hysteria2's PacketConn assertion;
// they are neither external VPN evidence nor an IPv6 network acceptance test.
func TestOutboundPinnedTransportLeaseLifecycle(t *testing.T) {
	installOutboundDialer.Do(func() { internet.UseAlternativeSystemDialer(outboundRuntime) })
	resolver := &outboundDNSFixture{}
	internet.InitSystemDialer(resolver, nil)
	t.Cleanup(func() { internet.InitSystemDialer(nil, nil) })
	for _, mode := range []string{"numeric", "hostname"} {
		for _, name := range []string{"tcp", "websocket", "grpc", "splithttp", "hysteria"} {
			t.Run(mode+"/"+name, func(t *testing.T) {
				server, stream := outboundTransportSettings(t, name)
				if mode == "hostname" {
					// No explicit ServerName and no IP SAN: the TLS handshake can
					// succeed only if the transport keeps the original hostname.
					certificate, key := outboundTLSFixture(t)
					alpn := []string{"h2", "http/1.1"}
					if name == "hysteria" {
						alpn = []string{"h3"}
					} else if name == "websocket" {
						alpn = []string{"http/1.1"}
					}
					server.SecurityType = serial.GetMessageType(&xrayTLS.Config{})
					stream.SecurityType = server.SecurityType
					server.SecuritySettings = &xrayTLS.Config{Certificate: []*xrayTLS.Certificate{{Certificate: certificate, Key: key}}, NextProtocol: alpn}
					stream.SecuritySettings = &xrayTLS.Config{Certificate: []*xrayTLS.Certificate{{Certificate: certificate, Usage: xrayTLS.Certificate_AUTHORITY_VERIFY}}, DisableSystemRoot: true, NextProtocol: alpn}
				}
				reserve, err := net.Listen("tcp4", "127.0.0.1:0")
				if err != nil {
					t.Fatal(err)
				}
				port := xnet.Port(reserve.Addr().(*net.TCPAddr).Port)
				_ = reserve.Close()
				if name == "hysteria" {
					packet, err := net.ListenPacket("udp4", "127.0.0.1:0")
					if err != nil {
						t.Fatal(err)
					}
					port = xnet.Port(packet.LocalAddr().(*net.UDPAddr).Port)
					_ = packet.Close()
				}
				serverCtx, stopServer := context.WithCancel(context.Background())
				defer stopServer()
				listener, err := internet.ListenTCP(serverCtx, xnet.LocalHostIP, port, server, func(conn stat.Connection) {
					go func() { defer conn.Close(); _, _ = io.Copy(conn, conn) }()
				})
				if err != nil {
					t.Fatalf("synthetic loopback transport listener failed: %v", err)
				}
				defer listener.Close()
				destination := xnet.TCPDestination(xnet.LocalHostIP, port)
				var resolution *endpointResolution
				var snapshot outboundSnapshot
				if mode == "hostname" {
					destination.Address = xnet.DomainAddress("localhost")
					resolution = &endpointResolution{name: "localhost", addresses: []netip.Addr{netip.MustParseAddr("198.51.100.5")}}
					snapshot.ipv4 = outboundRoute{index: 1, luid: 1, source: netip.MustParseAddr("127.0.0.1")}
				}
				first, err := outboundRuntime.newLease(context.Background(), snapshot, resolution)
				if err != nil {
					t.Fatal(err)
				}
				defer first.Close()
				if mode == "hostname" {
					// Test-only address seam: production validation rejects loopback
					// bootstrap maps (tested separately). Run real transports entirely
					// on loopback after exercising that strict map constructor.
					first.endpointIPs[0] = netip.MustParseAddr("127.0.0.1")
				}
				stream.SocketSettings = &internet.SocketConfig{Interface: first.token}
				ctx := context.WithValue(first.ctx, outboundLeaseKey{}, first)
				if err := outboundTransportExchange(ctx, destination, stream, 5*time.Second); err != nil {
					t.Fatalf("active %s loopback exchange failed: %v", name, err)
				}
				if err := first.Close(); err != nil {
					t.Fatal(err)
				}
				second, err := outboundRuntime.newLease(context.Background(), snapshot, resolution)
				if err != nil {
					t.Fatal(err)
				}
				defer second.Close()
				if mode == "hostname" {
					second.endpointIPs[0] = netip.MustParseAddr("127.0.0.1")
				}
				// Missing arbitrary context values must not give an old gRPC client
				// the new lease. Retry the actual old transport, not a fake dialer.
				if err := outboundTransportExchange(context.Background(), destination, stream, 300*time.Millisecond); err == nil {
					t.Fatal("retired transport escaped into the next lease")
				}
				second.mu.Lock()
				adopted := len(second.sockets)
				second.mu.Unlock()
				if adopted != 0 {
					t.Fatal("retired transport created sockets in the new lease")
				}
				_, freshStream := outboundTransportSettings(t, name)
				if name == "hysteria" || mode == "hostname" {
					freshStream.SecurityType = stream.SecurityType
					freshStream.SecuritySettings = stream.SecuritySettings
				}
				freshStream.SocketSettings = &internet.SocketConfig{Interface: second.token}
				if err := outboundTransportExchange(context.Background(), destination, freshStream, 5*time.Second); err != nil {
					t.Fatalf("fresh %s lease failed: %v", name, err)
				}
				if resolver.queries.Load() != 0 {
					t.Fatal("transport performed DNS before or after lease validation")
				}
				if mode == "hostname" && (!destination.Address.Family().IsDomain() || destination.Address.Domain() != "localhost") {
					t.Fatal("logical transport domain was replaced")
				}
			})
		}
	}
}

type outboundDNSFixture struct{ queries atomic.Int32 }

func (*outboundDNSFixture) Type() interface{} { return dns.ClientType() }
func (*outboundDNSFixture) Start() error      { return nil }
func (*outboundDNSFixture) Close() error      { return nil }
func (r *outboundDNSFixture) LookupIP(string, dns.IPOption) ([]xnet.IP, uint32, error) {
	r.queries.Add(1)
	return nil, 0, Code("unexpected_dns")
}

func outboundTransportExchange(parent context.Context, destination xnet.Destination, settings *internet.MemoryStreamConfig, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	conn, err := internet.Dial(ctx, destination, settings)
	if err != nil {
		return fmt.Errorf("synthetic transport dial: %w", err)
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	payload := []byte("lease-fixture")
	if _, err = conn.Write(payload); err != nil {
		return Code("transport_write_failed")
	}
	response := make([]byte, len(payload))
	if _, err = io.ReadFull(conn, response); err != nil || !bytes.Equal(payload, response) {
		return Code("transport_read_failed")
	}
	return nil
}

func outboundTransportSettings(t *testing.T, name string) (*internet.MemoryStreamConfig, *internet.MemoryStreamConfig) {
	t.Helper()
	var config proto.Message
	switch name {
	case "tcp":
		config = &tcp.Config{}
	case "websocket":
		config = &websocket.Config{Path: "/fixture"}
	case "grpc":
		config = &xgrpc.Config{ServiceName: "fixture"}
	case "splithttp":
		config = &splithttp.Config{Path: "/fixture", Mode: "packet-up"}
	case "hysteria":
		config = &hysteria.Config{Auth: "synthetic-auth"}
	default:
		t.Fatal("unknown fixture transport")
	}
	server := &internet.MemoryStreamConfig{ProtocolName: name, ProtocolSettings: proto.Clone(config)}
	client := &internet.MemoryStreamConfig{ProtocolName: name, ProtocolSettings: proto.Clone(config)}
	if name == "hysteria" {
		certificate, key := outboundTLSFixture(t)
		server.SecurityType = serial.GetMessageType(&xrayTLS.Config{})
		client.SecurityType = server.SecurityType
		server.SecuritySettings = &xrayTLS.Config{Certificate: []*xrayTLS.Certificate{{Certificate: certificate, Key: key}}, NextProtocol: []string{"h3"}}
		client.SecuritySettings = &xrayTLS.Config{Certificate: []*xrayTLS.Certificate{{Certificate: certificate, Usage: xrayTLS.Certificate_AUTHORITY_VERIFY}}, DisableSystemRoot: true, ServerName: "localhost", NextProtocol: []string{"h3"}}
	}
	return server, client
}

func outboundTLSFixture(t *testing.T) ([]byte, []byte) {
	t.Helper()
	private, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "localhost"}, DNSNames: []string{"localhost"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	certificate, err := x509.CreateCertificate(rand.Reader, template, template, &private.PublicKey, private)
	if err != nil {
		t.Fatal(err)
	}
	key, err := x509.MarshalPKCS8PrivateKey(private)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificate}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key})
}
