// SPDX-License-Identifier: Apache-2.0
package wireguardgateway

import (
	"net"
	"testing"
)

func TestGatewayOwnsOneLoopbackPeerAcrossFaultsAndPermanentClose(t *testing.T) {
	gateway, err := Start(Options{})
	if err != nil {
		t.Fatal("could not start synthetic gateway")
	}
	t.Cleanup(func() { _ = gateway.Close() })
	profile := gateway.Profile()
	if profile.Validate() != nil || profile.Server != "127.0.0.1" || profile.Port <= 0 || !gateway.Online() {
		t.Fatal("gateway did not create an authenticated loopback profile")
	}
	// A caller gets a copy; mutating its secret DTO must not change the active
	// gateway's peer credentials or address assignment.
	copy := gateway.Profile()
	copy.WireGuard.Addresses[0] = "192.0.2.2/32"
	copy.WireGuard.PrivateKey = "untrusted-change"
	if gateway.Profile().WireGuard.Addresses[0] != profile.WireGuard.Addresses[0] || gateway.Profile().WireGuard.PrivateKey != profile.WireGuard.PrivateKey {
		t.Fatal("profile leaked mutable gateway ownership")
	}
	for generation := 0; generation < 3; generation++ {
		if gateway.SetOnline(false) != nil || gateway.Online() {
			t.Fatal("gateway outage did not stop its own instance")
		}
		if gateway.SetOnline(true) != nil || !gateway.Online() {
			t.Fatal("gateway did not restore its own instance")
		}
		restored := gateway.Profile()
		if restored.Port != profile.Port || restored.WireGuard.PrivateKey != profile.WireGuard.PrivateKey || restored.WireGuard.PreSharedKey != profile.WireGuard.PreSharedKey {
			t.Fatal("gateway changed peer identity during a fault")
		}
	}
	if gateway.Close() != nil || gateway.Close() != nil || gateway.Online() || gateway.SetOnline(true) == nil {
		t.Fatal("permanently closed gateway could restart")
	}
}

func TestGatewayRejectsUnboundedPortsAndUnusableEgress(t *testing.T) {
	for _, options := range []Options{{Port: -1}, {Port: 65536}, {PhysicalInterface: "exvpn-qa-nonexistent-interface"}} {
		gateway, err := Start(options)
		if err == nil || gateway != nil {
			if gateway != nil {
				_ = gateway.Close()
			}
			t.Fatal("unsafe gateway options were accepted")
		}
	}
	interfaces, err := net.Interfaces()
	if err != nil {
		t.Fatal("could not enumerate fixture interfaces")
	}
	for _, adapter := range interfaces {
		if adapter.Flags&net.FlagLoopback != 0 {
			if gateway, err := Start(Options{PhysicalInterface: adapter.Name}); err == nil || gateway != nil {
				if gateway != nil {
					_ = gateway.Close()
				}
				t.Fatal("loopback was accepted as physical egress")
			}
			return
		}
	}
	t.Fatal("expected a loopback interface on the QA host")
}
