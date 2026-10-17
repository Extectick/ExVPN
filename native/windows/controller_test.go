// SPDX-License-Identifier: Apache-2.0
package service

import (
	"context"
	"sync"
	"testing"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

type fakeGuard struct {
	mu     sync.Mutex
	armed  bool
	permit bool
	events []string
	fail   string
}

func (g *fakeGuard) event(s string) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.events = append(g.events, s)
	if g.fail == s {
		return Code("fault")
	}
	if s == "arm" {
		g.armed = true
	}
	if s == "disarm" {
		g.armed = false
	}
	if s == "permit" {
		g.permit = true
	}
	if s == "suspend" {
		g.permit = false
	}
	return nil
}
func (g *fakeGuard) Armed() (bool, error)      { g.mu.Lock(); defer g.mu.Unlock(); return g.armed, nil }
func (g *fakeGuard) Arm() error                { return g.event("arm") }
func (g *fakeGuard) PermitTunnel(uint64) error { return g.event("permit") }
func (g *fakeGuard) Suspend() error            { return g.event("suspend") }
func (g *fakeGuard) Disarm() error             { return g.event("disarm") }

type fakeTunnel struct {
	g          *fakeGuard
	verify     func(context.Context) error
	closeError bool
}

func (t *fakeTunnel) LUID() uint64 { return 42 }
func (t *fakeTunnel) Verify(ctx context.Context) error {
	_ = t.g.event("verify")
	if t.verify != nil {
		return t.verify(ctx)
	}
	return nil
}
func (t *fakeTunnel) Close() error {
	_ = t.g.event("close")
	if t.closeError {
		return Code("close_failed")
	}
	return nil
}
func waitState(t *testing.T, c *Controller, state string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if c.Status().State == state {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("wanted %s got %+v", state, c.Status())
}
func newFixture(t *testing.T, g *fakeGuard, tun *fakeTunnel) *Controller {
	t.Helper()
	c, e := NewController(g, func(context.Context, exvpn.Profile, []string) (Tunnel, error) { _ = g.event("start"); return tun, nil }, nil, true)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { _ = c.Shutdown() })
	return c
}
func TestConnectRequiresVerifiedHTTPSAndDisconnectOrder(t *testing.T) {
	g := &fakeGuard{}
	verified := make(chan struct{})
	tun := &fakeTunnel{g: g, verify: func(ctx context.Context) error {
		select {
		case <-verified:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}}
	c := newFixture(t, g, tun)
	if e := c.Connect(syntheticProfile(), nil); e != nil {
		t.Fatal(e)
	}
	if c.Status().State != "connecting" {
		t.Fatal("premature connected")
	}
	if e := c.Connect(syntheticProfile(), nil); e != Code("connection_busy") {
		t.Fatal("duplicate attempt")
	}
	close(verified)
	waitState(t, c, "connected")
	if c.Status().ConnectedAt == 0 || c.Status().Capabilities.Verified {
		t.Fatal("incorrect verification metadata")
	}
	if e := c.Disconnect(); e != nil {
		t.Fatal(e)
	}
	waitState(t, c, "disconnected")
	g.mu.Lock()
	defer g.mu.Unlock()
	want := []string{"arm", "start", "permit", "verify", "close", "suspend", "disarm"}
	if len(g.events) != len(want) {
		t.Fatalf("events: %v", g.events)
	}
	for i, s := range want {
		if g.events[i] != s {
			t.Fatalf("events: %v", g.events)
		}
	}
}
func TestFailedProbeKeepsGuard(t *testing.T) {
	g := &fakeGuard{}
	c := newFixture(t, g, &fakeTunnel{g: g, verify: func(context.Context) error { return Code("offline") }})
	_ = c.Connect(syntheticProfile(), nil)
	waitState(t, c, "blocked")
	if !c.Status().GuardActive {
		t.Fatal("guard released")
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	for _, e := range g.events {
		if e == "disarm" {
			t.Fatal("silently reopened network")
		}
	}
}
func TestDisconnectCancelsInFlightAndCannotBecomeConnectedLater(t *testing.T) {
	g := &fakeGuard{}
	started := make(chan struct{})
	c := newFixture(t, g, &fakeTunnel{g: g, verify: func(ctx context.Context) error { close(started); <-ctx.Done(); return ctx.Err() }})
	_ = c.Connect(syntheticProfile(), nil)
	<-started
	if e := c.Disconnect(); e != nil {
		t.Fatal(e)
	}
	waitState(t, c, "disconnected")
	time.Sleep(10 * time.Millisecond)
	if c.Status().State != "disconnected" {
		t.Fatal("stale completion")
	}
}
func TestShutdownKeepsLatchAndClosesCore(t *testing.T) {
	g := &fakeGuard{}
	c := newFixture(t, g, &fakeTunnel{g: g})
	_ = c.Connect(syntheticProfile(), nil)
	waitState(t, c, "connected")
	if e := c.Shutdown(); e != nil {
		t.Fatal(e)
	}
	if s := c.Status(); s.State != "blocked" || !s.GuardActive {
		t.Fatal(s)
	}
	if e := c.Connect(syntheticProfile(), nil); e != Code("service_stopping") {
		t.Fatal(e)
	}
}
func TestCloseFailureNeverDisarms(t *testing.T) {
	g := &fakeGuard{}
	c := newFixture(t, g, &fakeTunnel{g: g, closeError: true})
	_ = c.Connect(syntheticProfile(), nil)
	waitState(t, c, "connected")
	if e := c.Disconnect(); e == nil {
		t.Fatal("accepted failed close")
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.armed {
		t.Fatal("released latch")
	}
	for _, e := range g.events {
		if e == "disarm" {
			t.Fatal("disarmed after failed close")
		}
	}
}
func TestCloseFailureDuringProbeFailureCannotBeForgotten(t *testing.T) {
	g := &fakeGuard{}
	c := newFixture(t, g, &fakeTunnel{g: g, closeError: true, verify: func(context.Context) error { return Code("offline") }})
	_ = c.Connect(syntheticProfile(), nil)
	waitState(t, c, "blocked")
	if e := c.Disconnect(); e == nil {
		t.Fatal("lost failed cleanup")
	}
	armed, _ := g.Armed()
	if !armed {
		t.Fatal("released latch")
	}
}
func TestRecoveredLatchAndDisabledNetworking(t *testing.T) {
	g := &fakeGuard{armed: true}
	c, e := NewController(g, nil, nil, false)
	if e != nil {
		t.Fatal(e)
	}
	if c.Status().State != "blocked" {
		t.Fatal(c.Status())
	}
	if e = c.Connect(syntheticProfile(), nil); e != Code("system_testing_required") {
		t.Fatal(e)
	}
	if c.Status().Capabilities.SystemTunnel {
		t.Fatal("advertised disabled networking")
	}
}

func TestExclusionsOwnedByServiceAndRecoveredStateIsUnknown(t *testing.T) {
	g := &fakeGuard{}
	c := newFixture(t, g, &fakeTunnel{g: g})
	set := Request{Version: 1, ID: "set", Command: "setExclusions", Exclusions: []string{"C:/Apps/example.exe"}}
	if r := c.Handle(set); !r.OK {
		t.Fatal(r.Code)
	}
	get := Request{Version: 1, ID: "get", Command: "getExclusions"}
	r := c.Handle(get)
	if !r.OK || len(r.Exclusions) != 1 || r.Exclusions[0] != "C:/Apps/example.exe" {
		t.Fatal("service forgot UI-independent state")
	}
	_ = c.Connect(syntheticProfile(), r.Exclusions)
	waitState(t, c, "connected")
	if r := c.Handle(set); r.OK || r.Code != "reconnect_required" {
		t.Fatal("changed active routing without reconnect")
	}
	recovered, e := NewController(&fakeGuard{armed: true}, nil, nil, false)
	if e != nil {
		t.Fatal(e)
	}
	if r := recovered.Handle(get); r.OK || r.Code != "exclusions_unavailable" {
		t.Fatal("unknown policy returned as empty list")
	}
}
func TestGuardFailureDoesNotStartTunnel(t *testing.T) {
	t.Run("recovered_latch", func(t *testing.T) {
		g := &fakeGuard{armed: true, fail: "arm"}
		c := newFixture(t, g, &fakeTunnel{g: g})
		_ = c.Connect(syntheticProfile(), nil)
		deadline := time.Now().Add(3 * time.Second)
		for c.Status().Code != "guard_arm_failed" && time.Now().Before(deadline) {
			time.Sleep(time.Millisecond)
		}
		if s := c.Status(); s.State != "blocked" || !s.GuardActive || s.Code != "guard_arm_failed" {
			t.Fatal("existing latch forgotten after arm transaction failure")
		}
	})
	for _, fault := range []string{"arm", "permit"} {
		t.Run(fault, func(t *testing.T) {
			g := &fakeGuard{fail: fault}
			c := newFixture(t, g, &fakeTunnel{g: g})
			_ = c.Connect(syntheticProfile(), nil)
			if fault == "arm" {
				waitState(t, c, "error")
			} else {
				waitState(t, c, "blocked")
			}
			g.mu.Lock()
			defer g.mu.Unlock()
			for _, e := range g.events {
				if e == "verify" {
					t.Fatal("verified without guard")
				}
				if fault == "arm" && e == "start" {
					t.Fatal("started without guard")
				}
			}
		})
	}
}

type measuredTunnel struct {
	*fakeTunnel
	traffic Traffic
}

func (t *measuredTunnel) Statistics() (Traffic, error) { return t.traffic, nil }
func TestStatisticsAreUnavailableOutsideActiveTunnel(t *testing.T) {
	g := &fakeGuard{}
	tun := &measuredTunnel{fakeTunnel: &fakeTunnel{g: g}, traffic: Traffic{UploadBytes: 128, DownloadBytes: 512}}
	c, err := NewController(g, func(context.Context, exvpn.Profile, []string) (Tunnel, error) { return tun, nil }, nil, true)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Shutdown() })
	request := Request{Version: 1, ID: "stats", Command: "stats"}
	if r := c.Handle(request); r.OK || r.Traffic != nil || r.Code != "statistics_unavailable" {
		t.Fatal("disconnected counters invented")
	}
	if err = c.Connect(syntheticProfile(), nil); err != nil {
		t.Fatal(err)
	}
	waitState(t, c, "connected")
	if r := c.Handle(request); !r.OK || r.Traffic == nil || *r.Traffic != tun.traffic {
		t.Fatal("active counters lost")
	}
	if err = c.Disconnect(); err != nil {
		t.Fatal(err)
	}
	if r := c.Handle(request); r.OK || r.Traffic != nil {
		t.Fatal("stale counters after disconnect")
	}
}
