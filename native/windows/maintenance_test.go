// SPDX-License-Identifier: Apache-2.0
package service

import (
	"context"
	"sync"
	"testing"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

type inspectionFaultGuard struct {
	*fakeGuard
	fault bool
}

func (g *inspectionFaultGuard) Armed() (bool, error) {
	if g.fault {
		return false, Code("inspection_failed")
	}
	return g.fakeGuard.Armed()
}

func TestIdleMaintenanceFreezesConnectionAndPolicyWithoutCleanup(t *testing.T) {
	g := &fakeGuard{}
	c := newFixture(t, g, &fakeTunnel{g: g})
	if err := c.BeginIdleMaintenance(); err != nil {
		t.Fatal(err)
	}
	if err := c.Connect(syntheticProfile(), nil); err != Code("service_stopping") {
		t.Fatalf("reserved idle service accepted connect: %v", err)
	}
	if err := c.Reconnect(syntheticProfile(), ModeVPN); err != Code("service_stopping") {
		t.Fatalf("reserved idle service accepted reconnect: %v", err)
	}
	if err := c.Disconnect(); err != Code("service_stopping") {
		t.Fatalf("reserved idle service accepted disconnect: %v", err)
	}
	if err := c.setExclusions(nil); err == nil {
		t.Fatal("reserved idle service accepted a policy write")
	}
	if s := c.Status(); s.State != "disconnected" || s.GuardActive {
		t.Fatalf("maintenance invented a native state: %+v", s)
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if len(g.events) != 0 {
		t.Fatalf("idle maintenance performed cleanup: %v", g.events)
	}
}

func TestIdleMaintenanceRefusesEveryActiveOrUnconfirmedState(t *testing.T) {
	for _, state := range []string{"connecting", "connected", "reconnecting", "blocked", "error"} {
		t.Run(state, func(t *testing.T) {
			g := &fakeGuard{}
			c := newFixture(t, g, &fakeTunnel{g: g})
			c.status.State = state
			before := c.Status()
			if err := c.BeginIdleMaintenance(); err != Code("maintenance_requires_disconnected") {
				t.Fatalf("active state accepted: %v", err)
			}
			if c.closed || c.Status() != before || len(g.events) != 0 {
				t.Fatal("refusal changed connection, guard or stopping state")
			}
		})
	}
	for _, condition := range []string{"guard-status", "guard-live", "guard-unknown", "cancel", "tunnel", "proxy-port", "profile", "stopping", "worker"} {
		t.Run(condition, func(t *testing.T) {
			g := &inspectionFaultGuard{fakeGuard: &fakeGuard{}}
			c, err := NewController(g, nil, nil, true)
			if err != nil {
				t.Fatal(err)
			}
			cancelled := false
			switch condition {
			case "guard-status":
				c.status.GuardActive = true
			case "guard-live":
				g.armed = true
			case "guard-unknown":
				g.fault = true
			case "cancel":
				c.cancel = func() { cancelled = true }
			case "tunnel":
				c.tunnel = &fakeTunnel{g: g.fakeGuard}
			case "proxy-port":
				c.status.Mode, c.status.ProxyPort = ModeProxy, 42500
			case "profile":
				c.status.ActiveProfileID = "synthetic"
			case "stopping":
				c.stopping = 1
			case "worker":
				c.ops.Lock()
				defer c.ops.Unlock()
			}
			if err := c.BeginIdleMaintenance(); err != Code("maintenance_requires_disconnected") {
				t.Fatalf("unconfirmed idle state accepted: %v", err)
			}
			if c.closed || cancelled || len(g.events) != 0 {
				t.Fatal("refusal cancelled or cleaned up an owned connection")
			}
		})
	}
}

func TestIdleMaintenanceDoesNotInterruptLiveProxy(t *testing.T) {
	g := &fakeGuard{}
	c := newFixture(t, g, &fakeTunnel{g: g})
	proxy := &fakeSystemProxy{port: 42500}
	c.SetProxyFactory(func(context.Context, exvpn.Profile, []string) (Tunnel, error) { return proxy, nil })
	if err := c.ConnectMode(syntheticProfile(), ModeProxy); err != nil {
		t.Fatal(err)
	}
	waitState(t, c, "connected")
	if err := c.BeginIdleMaintenance(); err != Code("maintenance_requires_disconnected") {
		t.Fatalf("live proxy accepted: %v", err)
	}
	if proxy.closed.Load() || c.Status().ProxyPort != 42500 || c.closed {
		t.Fatal("automatic update changed a live proxy")
	}
}

func TestIdleMaintenanceConnectRaceHasExactlyOneWinner(t *testing.T) {
	for i := 0; i < 100; i++ {
		g := &fakeGuard{}
		c, err := NewController(g, func(context.Context, exvpn.Profile, []string) (Tunnel, error) { return &fakeTunnel{g: g}, nil }, nil, true)
		if err != nil {
			t.Fatal(err)
		}
		start := make(chan struct{})
		var wg sync.WaitGroup
		var connecting, maintaining error
		wg.Add(2)
		go func() { defer wg.Done(); <-start; connecting = c.Connect(syntheticProfile(), nil) }()
		go func() { defer wg.Done(); <-start; maintaining = c.BeginIdleMaintenance() }()
		close(start)
		wg.Wait()
		if (connecting == nil) == (maintaining == nil) {
			t.Fatalf("connect and maintenance did not exclude each other: connect=%v maintenance=%v", connecting, maintaining)
		}
		if maintaining == nil {
			if connecting != Code("service_stopping") || !c.closed || c.Status().State != "disconnected" {
				t.Fatal("a connection crossed the atomic idle reservation")
			}
		} else if maintaining != Code("maintenance_requires_disconnected") || c.closed {
			t.Fatal("maintenance cancelled a connection which won the race")
		}
		if err := c.Shutdown(); err != nil {
			t.Fatal(err)
		}
	}
}
