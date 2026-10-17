// SPDX-License-Identifier: Apache-2.0
package service

import (
	"context"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

func TestDisconnectAndShutdownKeepPermitForCloseButAlwaysSuspend(t *testing.T) {
	for _, operation := range []string{"disconnect", "shutdown"} {
		for _, fault := range []string{"none", "close", "suspend", "both"} {
			t.Run(operation+"/"+fault, func(t *testing.T) {
				guard := &fakeGuard{}
				var closeWithPermit atomic.Bool
				tunnel := &recoveryTunnel{closeFn: func() error {
					guard.mu.Lock()
					closeWithPermit.Store(guard.armed && guard.permit)
					guard.mu.Unlock()
					_ = guard.event("close")
					if fault == "close" || fault == "both" {
						return Code("close_failed")
					}
					return nil
				}}
				c := recoveryController(t, guard, func(context.Context, exvpn.Profile, []string) (Tunnel, error) { return tunnel, nil })
				c.monitorInterval = time.Hour
				if err := c.Connect(syntheticProfile(), nil); err != nil {
					t.Fatal(err)
				}
				waitState(t, c, "connected")
				guard.mu.Lock()
				guard.events = nil
				if fault == "suspend" || fault == "both" {
					guard.fail = "suspend"
				}
				guard.mu.Unlock()
				var err error
				if operation == "disconnect" {
					err = c.Disconnect()
				} else {
					err = c.Shutdown()
				}
				var expected error
				switch fault {
				case "close":
					expected = Code("tunnel_stop_failed")
				case "suspend", "both":
					expected = Code("guard_suspend_failed")
				}
				if err != expected {
					t.Fatalf("cleanup error = %v, want %v", err, expected)
				}
				if !closeWithPermit.Load() {
					t.Fatal("core Close lost its existing service permit or persistent guard")
				}
				guard.mu.Lock()
				events := append([]string(nil), guard.events...)
				armed, permitted := guard.armed, guard.permit
				guard.mu.Unlock()
				wantEvents := []string{"close", "suspend"}
				if operation == "disconnect" && expected == nil {
					wantEvents = append(wantEvents, "disarm")
				}
				if !slices.Equal(events, wantEvents) {
					t.Fatalf("cleanup order = %v, want %v", events, wantEvents)
				}
				if permitted != (fault == "suspend" || fault == "both") {
					t.Fatal("Close failure bypassed dynamic-permit revocation")
				}
				wantLatch := operation == "shutdown" || expected != nil
				if armed != wantLatch || c.Status().GuardActive != wantLatch {
					t.Fatal("persistent latch did not match cleanup outcome")
				}
				c.mu.Lock()
				retained := c.tunnel == tunnel
				c.mu.Unlock()
				if retained != (expected != nil) {
					t.Fatal("owner was cleared before both cleanup operations succeeded")
				}
				if operation == "disconnect" && expected != nil {
					if c.Status().Code != string(expected.(Code)) {
						t.Fatal("status masked the terminal cleanup failure")
					}
					if c.Connect(syntheticProfile(), nil) != Code("connection_busy") {
						t.Fatal("a failed cleanup allowed a replacement core")
					}
				}
			})
		}
	}
}

func TestDisconnectRetriesSuspensionWithoutForgettingClosedOwner(t *testing.T) {
	guard := &fakeGuard{}
	tunnel := &recoveryTunnel{}
	c := recoveryController(t, guard, func(context.Context, exvpn.Profile, []string) (Tunnel, error) { return tunnel, nil })
	c.monitorInterval = time.Hour
	if err := c.Connect(syntheticProfile(), nil); err != nil {
		t.Fatal(err)
	}
	waitState(t, c, "connected")
	guard.mu.Lock()
	guard.fail = "suspend"
	guard.mu.Unlock()
	if err := c.Disconnect(); err != Code("guard_suspend_failed") || !tunnel.closed.Load() {
		t.Fatal("Close was not attempted before the failing suspension")
	}
	assertGuardNeverDisarmed(t, guard)
	if c.Connect(syntheticProfile(), nil) != Code("connection_busy") {
		t.Fatal("failed suspension lost ownership")
	}
	guard.mu.Lock()
	guard.fail = ""
	guard.mu.Unlock()
	if err := c.Disconnect(); err != nil {
		t.Fatal(err)
	}
	if status := c.Status(); status.State != "disconnected" || status.GuardActive {
		t.Fatal("successful retry did not finish explicit disconnect")
	}
	c.mu.Lock()
	retained := c.tunnel != nil
	c.mu.Unlock()
	if retained {
		t.Fatal("successful cleanup retained the old owner")
	}
}

func TestDisconnectWithoutTunnelStillSuspendsBeforeDisarm(t *testing.T) {
	for _, failed := range []bool{false, true} {
		guard := &fakeGuard{armed: true}
		if failed {
			guard.fail = "suspend"
		}
		c, err := NewController(guard, nil, nil, true)
		if err != nil {
			t.Fatal(err)
		}
		err = c.Disconnect()
		want := []string{"suspend", "disarm"}
		if failed {
			want = []string{"suspend"}
			if err != Code("guard_suspend_failed") {
				t.Fatal("ignored failed suspension without a tunnel")
			}
		} else if err != nil {
			t.Fatal(err)
		}
		if !slices.Equal(guard.events, want) || guard.armed != failed {
			t.Fatal("cleanup without a tunnel skipped suspension or released a failed latch")
		}
	}
}

func TestShutdownWinsWhileDisconnectClosesTunnel(t *testing.T) {
	guard := &fakeGuard{}
	entered, release := make(chan struct{}), make(chan struct{})
	var enterOnce, releaseOnce sync.Once
	defer releaseOnce.Do(func() { close(release) })
	tunnel := &recoveryTunnel{closeFn: func() error {
		enterOnce.Do(func() { close(entered) })
		<-release
		return nil
	}}
	c := recoveryController(t, guard, func(context.Context, exvpn.Profile, []string) (Tunnel, error) { return tunnel, nil })
	c.monitorInterval = time.Hour
	if err := c.Connect(syntheticProfile(), nil); err != nil {
		t.Fatal(err)
	}
	waitState(t, c, "connected")
	disconnected := make(chan error, 1)
	go func() { disconnected <- c.Disconnect() }()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("disconnect did not enter Close")
	}
	stopped := make(chan error, 1)
	go func() { stopped <- c.Shutdown() }()
	waitRecoveryCondition(t, func() bool { c.mu.Lock(); defer c.mu.Unlock(); return c.closed })
	releaseOnce.Do(func() { close(release) })
	if err := awaitTeardownResult(t, disconnected); err != Code("service_stopping") {
		t.Fatalf("queued disconnect ignored Shutdown: %v", err)
	}
	if err := awaitTeardownResult(t, stopped); err != nil {
		t.Fatal(err)
	}
	assertGuardNeverDisarmed(t, guard)
	if !tunnel.closed.Load() || c.Status().State != "blocked" || c.Status().Code != "service_stopped" {
		t.Fatal("Shutdown did not finish core cleanup under the persistent latch")
	}
	if c.Disconnect() != Code("service_stopping") || c.Connect(syntheticProfile(), nil) != Code("service_stopping") {
		t.Fatal("closed controller accepted a new lifetime operation")
	}
	assertGuardNeverDisarmed(t, guard)
}

func awaitTeardownResult(t *testing.T, result <-chan error) error {
	t.Helper()
	select {
	case err := <-result:
		return err
	case <-time.After(3 * time.Second):
		t.Fatal("controller teardown did not finish")
		return nil
	}
}

func TestReconnectClosesUnderPermitAndSuspendsBeforeReplacement(t *testing.T) {
	guard := &fakeGuard{}
	var changed, closeWithPermit, replacementAfterSuspend atomic.Bool
	first := &recoveryTunnel{recoverFn: changed.Load, closeFn: func() error {
		guard.mu.Lock()
		closeWithPermit.Store(guard.armed && guard.permit)
		guard.mu.Unlock()
		return nil
	}}
	var starts atomic.Int32
	c := recoveryController(t, guard, func(context.Context, exvpn.Profile, []string) (Tunnel, error) {
		if starts.Add(1) == 1 {
			return first, nil
		}
		guard.mu.Lock()
		replacementAfterSuspend.Store(first.closed.Load() && guard.armed && !guard.permit)
		guard.mu.Unlock()
		return &recoveryTunnel{}, nil
	})
	if err := c.Connect(syntheticProfile(), nil); err != nil {
		t.Fatal(err)
	}
	waitState(t, c, "connected")
	changed.Store(true)
	waitRecoveryCondition(t, func() bool { return starts.Load() == 2 && c.Status().State == "connected" })
	if !closeWithPermit.Load() || !replacementAfterSuspend.Load() {
		t.Fatal("recovery revoked the old permit before Close or reused it for a new core")
	}
	assertGuardNeverDisarmed(t, guard)
}
