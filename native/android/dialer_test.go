// SPDX-License-Identifier: Apache-2.0
package androidcore

import (
	"context"
	"net"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
)

func TestProtectionFailureCannotConnectTCPOrCreateUDPSocket(t *testing.T) {
	for _, network := range []xnet.Network{xnet.Network_TCP, xnet.Network_UDP} {
		called := 0
		d := ProtectedDialer{ProtectSocket: func(uintptr) bool { called++; return false }}
		conn, err := d.Dial(context.Background(), nil, xnet.Destination{Network: network, Address: xnet.LocalHostIP, Port: 9}, nil)
		if err == nil || conn != nil || called != 1 {
			t.Fatalf("protection failure was not terminal for %v", network)
		}
	}
}
func TestProtectedTCPUsesTheApprovedSocket(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	approved := false
	d := ProtectedDialer{ProtectSocket: func(uintptr) bool { approved = true; return true }}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	conn, err := d.Dial(ctx, nil, xnet.TCPDestination(xnet.LocalHostIP, xnet.Port(listener.Addr().(*net.TCPAddr).Port)), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if !approved {
		t.Fatal("socket used without OS approval")
	}
}
func TestSystemResolverIsNeverUsedForUnknownDomains(t *testing.T) {
	called := false
	d := ProtectedDialer{ProtectSocket: func(uintptr) bool { called = true; return true }}
	conn, err := d.Dial(context.Background(), nil, xnet.TCPDestination(xnet.DomainAddress("private-user-query.invalid"), 443), nil)
	if err == nil || conn != nil || called {
		t.Fatal("domain reached system socket/resolver")
	}
}
