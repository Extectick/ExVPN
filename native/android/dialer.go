// SPDX-License-Identifier: Apache-2.0
package androidcore

import (
	"context"
	"net"
	"syscall"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/transport/internet"
)

// ProtectedDialer aborts socket creation when OS protection/binding fails.
// It never uses the host resolver: endpoint bootstrap precedes TUN startup;
// direct-excluded domain resolution goes through Xray's proxied DNS client.
type ProtectedDialer struct{ ProtectSocket func(uintptr) bool }

func (ProtectedDialer) DestIpAddress() xnet.IP { return nil }
func (d ProtectedDialer) protect(_ string, _ string, raw syscall.RawConn) error {
	ok := false
	err := raw.Control(func(fd uintptr) {
		if d.ProtectSocket != nil {
			ok = d.ProtectSocket(fd)
		}
	})
	if err != nil || !ok {
		return exvpn.CodeError("socket_protection_failed")
	}
	return nil
}
func (d ProtectedDialer) Dial(ctx context.Context, _ xnet.Address, destination xnet.Destination, _ *internet.SocketConfig) (net.Conn, error) {
	if destination.Address.Family().IsDomain() {
		return nil, exvpn.CodeError("unresolved_direct_destination")
	}
	if destination.Network == xnet.Network_UDP {
		ip := net.IP(destination.Address.IP())
		bind := "0.0.0.0:0"
		network := "udp4"
		if ip.To4() == nil {
			bind = "[::]:0"
			network = "udp6"
		}
		listener := net.ListenConfig{Control: d.protect}
		packet, err := listener.ListenPacket(ctx, network, bind)
		if err != nil {
			return nil, exvpn.CodeError("protected_socket_failed")
		}
		return &xnet.PacketConnWrapper{PacketConn: packet, Dest: &net.UDPAddr{IP: ip, Port: int(destination.Port)}}, nil
	}
	dialer := net.Dialer{Timeout: 15 * time.Second, Control: d.protect}
	return dialer.DialContext(ctx, destination.Network.SystemString(), destination.NetAddr())
}
