// SPDX-License-Identifier: Apache-2.0
package service

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

type recoveryTunnel struct {
	verifyFn  func(context.Context) error
	closeFn   func() error
	statsFn   func() (Traffic, error)
	recoverFn func() bool
	closed    atomic.Bool
}

type queuedDisconnectGuard struct {
	*fakeGuard
	suspends atomic.Int32
	entered  chan struct{}
	release  chan struct{}
}

func (g *queuedDisconnectGuard) Suspend() error {
	if g.suspends.Add(1) == 2 {
		close(g.entered)
		<-g.release
	}
	return g.fakeGuard.Suspend()
}

func (t *recoveryTunnel) LUID() uint64 { return 43 }
func (t *recoveryTunnel) RecoveryRequired() bool {
	return t.recoverFn != nil && t.recoverFn()
}
func (t *recoveryTunnel) Verify(ctx context.Context) error {
	if t.verifyFn != nil {
		return t.verifyFn(ctx)
	}
	return nil
}
func (t *recoveryTunnel) Close() error {
	if t.closeFn != nil {
		if err := t.closeFn(); err != nil {
			return err
		}
	}
	t.closed.Store(true)
	return nil
}
func (t *recoveryTunnel) Statistics() (Traffic, error) {
	if t.statsFn != nil {
		return t.statsFn()
	}
	return Traffic{UploadBytes: 5, DownloadBytes: 9}, nil
}

func waitRecoveryCondition(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal("condition did not become true")
		}
		time.Sleep(time.Millisecond)
	}
}

func recoveryController(t *testing.T, guard *fakeGuard, factory TunnelFactory) *Controller {
	t.Helper()
	c, err := NewController(guard, factory, nil, true)
	if err != nil {
		t.Fatal(err)
	}
	c.monitorInterval = 3 * time.Millisecond
	c.reconnectDelays = []time.Duration{time.Millisecond, 2 * time.Millisecond, 3 * time.Millisecond}
	t.Cleanup(func() { _ = c.Shutdown() })
	return c
}

func assertGuardNeverDisarmed(t *testing.T, guard *fakeGuard) {
	t.Helper()
	guard.mu.Lock()
	defer guard.mu.Unlock()
	if !guard.armed {
		t.Fatal("persistent guard was released")
	}
	for _, event := range guard.events {
		if event == "disarm" {
			t.Fatal("recovery temporarily opened direct traffic")
		}
	}
}

func TestReconnectRecreatesFailedCoreAndKeepsOwnedProfilePolicy(t *testing.T) {
	guard := &fakeGuard{}
	var offline atomic.Bool
	first := &recoveryTunnel{verifyFn: func(context.Context) error {
		if offline.Load() {
			return Code("offline")
		}
		return nil
	}, recoverFn: offline.Load}
	second := &recoveryTunnel{}
	entered := make(chan struct{})
	release := make(chan struct{})
	var starts atomic.Int32
	var ownedValues atomic.Bool
	c := recoveryController(t, guard, func(ctx context.Context, p exvpn.Profile, paths []string) (Tunnel, error) {
		if starts.Add(1) == 1 {
			return first, nil
		}
		armed, _ := guard.Armed()
		ownedValues.Store(first.closed.Load() && armed && p.TLS.ALPN[0] == "http/1.1" && len(paths) == 1 && paths[0] == "C:/Apps/example.exe")
		close(entered)
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-release:
			return second, nil
		}
	})
	profile := syntheticProfile()
	profile.TLS.ALPN = []string{"http/1.1"}
	paths := []string{"C:/Apps/example.exe"}
	if err := c.Connect(profile, paths); err != nil {
		t.Fatal(err)
	}
	waitState(t, c, "connected")
	profile.TLS.ALPN[0] = "h2"
	paths[0] = "C:/Apps/replaced.exe"
	previousConnectedAt := time.Now().Add(-time.Minute).Unix()
	c.mu.Lock()
	c.status.ConnectedAt = previousConnectedAt
	c.mu.Unlock()
	offline.Store(true)
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("failed core was never replaced")
	}
	if status := c.Status(); status.State != "reconnecting" || status.ConnectedAt != 0 || status.ActiveProfileID != profile.ID {
		t.Fatal("incorrect reconnecting metadata")
	}
	if _, err := c.Statistics(); err != Code("statistics_unavailable") {
		t.Fatal("returned counters from a retired core")
	}
	if !ownedValues.Load() {
		t.Fatal("recovery lost core ordering, guard or immutable profile/policy")
	}
	assertGuardNeverDisarmed(t, guard)
	close(release)
	waitState(t, c, "connected")
	if c.Status().ConnectedAt <= previousConnectedAt || starts.Load() != 2 {
		t.Fatal("new HTTPS did not establish a new connection lifetime")
	}
	if _, err := c.Statistics(); err != nil {
		t.Fatal("new core counters unavailable")
	}
	assertGuardNeverDisarmed(t, guard)
}

func TestInitialHTTPSWithChangedUnderlayEntersImmediateRecovery(t *testing.T) {
	guard := &fakeGuard{}
	var changed atomic.Bool
	first := &recoveryTunnel{
		verifyFn:  func(context.Context) error { changed.Store(true); return nil },
		recoverFn: changed.Load,
	}
	entered, release := make(chan struct{}), make(chan struct{})
	var starts atomic.Int32
	c := recoveryController(t, guard, func(ctx context.Context, _ exvpn.Profile, _ []string) (Tunnel, error) {
		if starts.Add(1) == 1 {
			return first, nil
		}
		close(entered)
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-release:
			return &recoveryTunnel{}, nil
		}
	})
	c.monitorInterval = time.Hour
	if err := c.Connect(syntheticProfile(), nil); err != nil {
		t.Fatal(err)
	}
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("dirty initial connection waited for the normal monitor interval")
	}
	if status := c.Status(); status.State != "reconnecting" || status.ConnectedAt != 0 || !first.closed.Load() {
		t.Fatal("a dirty initial lease was published as connected")
	}
	assertGuardNeverDisarmed(t, guard)
	close(release)
	waitState(t, c, "connected")
}

func TestInitialFailureDoesNotHideCleanupFailure(t *testing.T) {
	for _, stage := range []string{"factory", "https"} {
		for _, cleanup := range []string{"suspend", "close"} {
			t.Run(stage+"/"+cleanup, func(t *testing.T) {
				guard := &fakeGuard{}
				if cleanup == "suspend" {
					guard.fail = "suspend"
				}
				tunnel := &recoveryTunnel{
					verifyFn: func(context.Context) error { return Code("remote_unreachable") },
					closeFn: func() error {
						if cleanup == "close" {
							return Code("outbound_close_failed")
						}
						return nil
					},
				}
				c := recoveryController(t, guard, func(context.Context, exvpn.Profile, []string) (Tunnel, error) {
					if stage == "factory" {
						return tunnel, Code("core_start_failed")
					}
					return tunnel, nil
				})
				if err := c.Connect(syntheticProfile(), nil); err != nil {
					t.Fatal(err)
				}
				waitState(t, c, "blocked")
				want := "tunnel_stop_failed"
				if cleanup == "suspend" {
					want = "guard_suspend_failed"
				}
				if c.Status().Code != want {
					t.Fatal("initial failure masked terminal cleanup failure")
				}
				c.mu.Lock()
				retained := c.tunnel == tunnel
				c.mu.Unlock()
				if !retained {
					t.Fatal("failed owner was forgotten")
				}
				assertGuardNeverDisarmed(t, guard)
			})
		}
	}
}

func TestReconnectRetriesFreshFactoryAndChangedUnderlayWithoutReleasingGuard(t *testing.T) {
	guard := &fakeGuard{}
	var offline atomic.Bool
	first := &recoveryTunnel{verifyFn: func(context.Context) error {
		if offline.Load() {
			return Code("offline")
		}
		return nil
	}, recoverFn: offline.Load}
	failedHTTPS := &recoveryTunnel{
		verifyFn:  func(context.Context) error { return Code("offline") },
		recoverFn: func() bool { return true },
	}
	var starts atomic.Int32
	c := recoveryController(t, guard, func(context.Context, exvpn.Profile, []string) (Tunnel, error) {
		switch starts.Add(1) {
		case 1:
			return first, nil
		case 2:
			return nil, Code("bootstrap_https_failed")
		case 3:
			return failedHTTPS, nil
		default:
			return &recoveryTunnel{}, nil
		}
	})
	_ = c.Connect(syntheticProfile(), nil)
	waitState(t, c, "connected")
	offline.Store(true)
	waitRecoveryCondition(t, func() bool { return starts.Load() >= 4 && c.Status().State == "connected" })
	if !first.closed.Load() || !failedHTTPS.closed.Load() || starts.Load() != 4 {
		t.Fatal("failed attempts were not retired before fresh retry")
	}
	assertGuardNeverDisarmed(t, guard)
}

func TestRemoteOutageKeepsHealthyCoreAndExclusionsUntilHTTPSReturns(t *testing.T) {
	for _, replacement := range []bool{false, true} {
		name := "original_core"
		if replacement {
			name = "replacement_core"
		}
		t.Run(name, func(t *testing.T) {
			guard := &fakeGuard{}
			var remoteOffline, underlayChanged atomic.Bool
			var failedChecks, starts atomic.Int32
			healthy := &recoveryTunnel{verifyFn: func(context.Context) error {
				if remoteOffline.Load() {
					failedChecks.Add(1)
					return Code("remote_unreachable")
				}
				return nil
			}}
			first := healthy
			if replacement {
				first = &recoveryTunnel{recoverFn: underlayChanged.Load}
			}
			c := recoveryController(t, guard, func(context.Context, exvpn.Profile, []string) (Tunnel, error) {
				if starts.Add(1) == 1 {
					return first, nil
				}
				return healthy, nil
			})
			if err := c.Connect(syntheticProfile(), []string{"C:/Apps/example.exe"}); err != nil {
				t.Fatal(err)
			}
			waitState(t, c, "connected")
			remoteOffline.Store(true)
			if replacement {
				underlayChanged.Store(true)
			}
			waitRecoveryCondition(t, func() bool { return failedChecks.Load() >= 3 })
			wantStarts := int32(1)
			if replacement {
				wantStarts = 2
			}
			if healthy.closed.Load() || starts.Load() != wantStarts || c.Status().State != "reconnecting" || c.Status().ConnectedAt != 0 {
				t.Fatal("remote outage retired a healthy core or claimed verified VPN")
			}
			policy := c.Handle(Request{Command: "getExclusions"})
			if !policy.OK || len(policy.Exclusions) != 1 || policy.Exclusions[0] != "C:/Apps/example.exe" {
				t.Fatal("remote outage lost the confirmed direct policy")
			}
			assertGuardNeverDisarmed(t, guard)
			remoteOffline.Store(false)
			waitState(t, c, "connected")
			if starts.Load() != wantStarts || c.Status().ConnectedAt == 0 {
				t.Fatal("restored HTTPS did not reuse the healthy core")
			}
		})
	}
}

func TestReconnectStopsOnCleanupOrGuardFailure(t *testing.T) {
	for _, failure := range []string{"suspend", "close", "permit", "bootstrap_permit_failed", "bootstrap_close_failed", "outbound_close_failed", "outbound_watcher_unavailable", "outbound_lease_busy"} {
		t.Run(failure, func(t *testing.T) {
			guard := &fakeGuard{}
			var offline atomic.Bool
			first := &recoveryTunnel{verifyFn: func(context.Context) error {
				if offline.Load() {
					return Code("offline")
				}
				return nil
			}, recoverFn: offline.Load, closeFn: func() error {
				if failure == "close" {
					return Code("close_failed")
				}
				return nil
			}}
			var starts atomic.Int32
			c := recoveryController(t, guard, func(context.Context, exvpn.Profile, []string) (Tunnel, error) {
				if starts.Add(1) == 1 {
					return first, nil
				}
				if failure != "suspend" && failure != "close" && failure != "permit" {
					return nil, Code(failure)
				}
				return &recoveryTunnel{}, nil
			})
			_ = c.Connect(syntheticProfile(), nil)
			waitState(t, c, "connected")
			guard.mu.Lock()
			if failure == "suspend" || failure == "permit" {
				guard.fail = failure
			}
			guard.mu.Unlock()
			offline.Store(true)
			waitState(t, c, "blocked")
			wantStarts := int32(2)
			if failure == "suspend" || failure == "close" {
				wantStarts = 1
				c.mu.Lock()
				retained := c.tunnel == first
				c.mu.Unlock()
				if !retained {
					t.Fatal("failed close lost ownership of the old core")
				}
			}
			time.Sleep(15 * time.Millisecond)
			if starts.Load() != wantStarts {
				t.Fatal("guard/cleanup failure was retried")
			}
			assertGuardNeverDisarmed(t, guard)
		})
	}
}

func TestReconnectBackoffAndFactoryAreCancelledByDisconnect(t *testing.T) {
	for _, stage := range []string{"backoff", "factory", "verify"} {
		t.Run(stage, func(t *testing.T) {
			guard := &fakeGuard{}
			var offline atomic.Bool
			first := &recoveryTunnel{verifyFn: func(context.Context) error {
				if offline.Load() {
					return Code("offline")
				}
				return nil
			}, recoverFn: offline.Load}
			entered := make(chan struct{})
			late := &recoveryTunnel{}
			var starts atomic.Int32
			c := recoveryController(t, guard, func(ctx context.Context, _ exvpn.Profile, _ []string) (Tunnel, error) {
				if starts.Add(1) == 1 {
					return first, nil
				}
				if stage == "factory" {
					close(entered)
					<-ctx.Done()
					return late, nil // Deliberately stale successful factory.
				}
				late.verifyFn = func(ctx context.Context) error {
					close(entered)
					<-ctx.Done()
					return nil // Deliberately stale successful probe.
				}
				return late, nil
			})
			if stage == "backoff" {
				c.reconnectDelays = []time.Duration{time.Hour}
			}
			_ = c.Connect(syntheticProfile(), nil)
			waitState(t, c, "connected")
			offline.Store(true)
			if stage == "backoff" {
				waitState(t, c, "reconnecting")
			} else {
				select {
				case <-entered:
				case <-time.After(3 * time.Second):
					t.Fatal("recovery did not enter stage")
				}
			}
			started := time.Now()
			if err := c.Disconnect(); err != nil {
				t.Fatal(err)
			}
			if time.Since(started) > time.Second {
				t.Fatal("disconnect waited for reconnect delay")
			}
			if status := c.Status(); status.State != "disconnected" || status.ConnectedAt != 0 || status.GuardActive {
				t.Fatal("stale success survived disconnect")
			}
			if stage != "backoff" && !late.closed.Load() {
				t.Fatal("late successful factory leaked a core")
			}
		})
	}
}

func TestRetiredProbeAndStatisticsCannotPublishAfterDisconnect(t *testing.T) {
	for _, operation := range []string{"probe", "statistics"} {
		t.Run(operation, func(t *testing.T) {
			guard := &fakeGuard{}
			entered := make(chan struct{})
			release := make(chan struct{})
			var requested atomic.Bool
			tunnel := &recoveryTunnel{}
			tunnel.verifyFn = func(context.Context) error {
				if requested.Load() && operation == "probe" {
					close(entered)
					<-release
				}
				return nil
			}
			tunnel.statsFn = func() (Traffic, error) { close(entered); <-release; return Traffic{UploadBytes: 10}, nil }
			c := recoveryController(t, guard, func(context.Context, exvpn.Profile, []string) (Tunnel, error) { return tunnel, nil })
			c.monitorInterval = time.Hour
			_ = c.Connect(syntheticProfile(), nil)
			waitState(t, c, "connected")
			requested.Store(true)
			staleAccepted := make(chan bool, 1)
			go func() {
				if operation == "probe" {
					staleAccepted <- c.Probe("test").Reachable
				} else {
					_, err := c.Statistics()
					staleAccepted <- err == nil
				}
			}()
			<-entered
			disconnected := make(chan error, 1)
			go func() { disconnected <- c.Disconnect() }()
			waitRecoveryCondition(t, func() bool { c.mu.Lock(); defer c.mu.Unlock(); return c.stopping > 0 })
			if tunnel.closed.Load() {
				t.Fatal("Close raced an active old-core read")
			}
			close(release)
			if <-staleAccepted {
				t.Fatal("retired result was published after generation changed")
			}
			if err := <-disconnected; err != nil {
				t.Fatal(err)
			}
			if !tunnel.closed.Load() {
				t.Fatal("old core was not retired")
			}
		})
	}
}

func TestQueuedDisconnectKeepsNewConnectBlockedUntilBothComplete(t *testing.T) {
	guard := &queuedDisconnectGuard{fakeGuard: &fakeGuard{}, entered: make(chan struct{}), release: make(chan struct{})}
	c, err := NewController(guard, func(context.Context, exvpn.Profile, []string) (Tunnel, error) { return &recoveryTunnel{}, nil }, nil, true)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Shutdown() })
	_ = c.Connect(syntheticProfile(), nil)
	waitState(t, c, "connected")
	c.ops.Lock()
	finished := make(chan error, 2)
	go func() { finished <- c.Disconnect() }()
	go func() { finished <- c.Disconnect() }()
	waitRecoveryCondition(t, func() bool { c.mu.Lock(); defer c.mu.Unlock(); return c.stopping == 2 })
	c.ops.Unlock()
	select {
	case <-guard.entered:
	case <-time.After(3 * time.Second):
		t.Fatal("second disconnect never entered")
	}
	if err := <-finished; err != nil {
		t.Fatal(err)
	}
	connectErr := c.Connect(syntheticProfile(), nil)
	close(guard.release)
	if err := <-finished; err != nil {
		t.Fatal(err)
	}
	if connectErr != Code("connection_busy") {
		t.Fatal("first disconnect cleared the second disconnect's pending state")
	}
	if c.Status().State != "disconnected" {
		t.Fatal("queued disconnect allowed a stale automatic connection")
	}
}
