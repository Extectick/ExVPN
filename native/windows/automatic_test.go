// SPDX-License-Identifier: Apache-2.0
package service

import (
	"context"
	"encoding/json"
	"sync/atomic"
	"testing"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

func automaticRequest(t *testing.T, profiles ...exvpn.Profile) Request {
	t.Helper()
	r := Request{Version: ProtocolVersion, ID: "auto-test", Command: "connect"}
	r.Profile, _ = json.Marshal(profiles[0])
	for _, profile := range profiles {
		b, _ := json.Marshal(profile)
		r.AutomaticProfiles = append(r.AutomaticProfiles, b)
	}
	return r
}

func TestAutomaticFailoverKeepsGuardAndWorksWithoutUI(t *testing.T) {
	first, backup := syntheticProfile(), syntheticProfile()
	first.ID, backup.ID = "primary", "backup"
	guard := &fakeGuard{}
	var primaryOffline atomic.Bool
	c := recoveryController(t, guard, func(_ context.Context, p exvpn.Profile, _ []string) (Tunnel, error) {
		return &recoveryTunnel{verifyFn: func(context.Context) error {
			if p.ID == first.ID && primaryOffline.Load() {
				return Code("offline")
			}
			return nil
		}}, nil
	})
	c.automaticPoll, c.automaticCooldown = time.Millisecond, 15*time.Millisecond
	if response := c.Handle(automaticRequest(t, first, backup)); !response.OK {
		t.Fatal(response.Code)
	}
	waitRecoveryCondition(t, func() bool { return c.Status().State == "connected" })
	primaryOffline.Store(true)
	waitRecoveryCondition(t, func() bool { s := c.Status(); return s.State == "connected" && s.ActiveProfileID == backup.ID })
	if !c.Status().AutomaticSelection {
		t.Fatal("native automatic group lost")
	}
	assertGuardNeverDisarmed(t, guard)
	response := c.Handle(Request{Version: ProtocolVersion, ID: "clear", Command: "clearAutomaticSelection"})
	if !response.OK || response.Status.AutomaticSelection || response.Status.State != "connected" {
		t.Fatal("clear stopped active connection")
	}
	assertGuardNeverDisarmed(t, guard)
	if c.Disconnect() != nil {
		t.Fatal("disconnect")
	}
	time.Sleep(12 * time.Millisecond)
	if c.Status().State != "disconnected" {
		t.Fatal("automatic resurrected after disconnect")
	}
}

func TestAutomaticInitialFailureAndSecurityFailure(t *testing.T) {
	for _, security := range []bool{false, true} {
		t.Run(map[bool]string{false: "remote", true: "guard"}[security], func(t *testing.T) {
			first, backup := syntheticProfile(), syntheticProfile()
			first.ID, backup.ID = "primary", "backup"
			guard := &fakeGuard{}
			if security {
				guard.fail = "permit"
			}
			var starts atomic.Int32
			c := recoveryController(t, guard, func(_ context.Context, p exvpn.Profile, _ []string) (Tunnel, error) {
				starts.Add(1)
				return &recoveryTunnel{verifyFn: func(context.Context) error {
					if p.ID == first.ID {
						return Code("offline")
					}
					return nil
				}}, nil
			})
			c.automaticPoll = time.Millisecond
			if !c.Handle(automaticRequest(t, first, backup)).OK {
				t.Fatal("request")
			}
			if security {
				waitRecoveryCondition(t, func() bool { return c.Status().State == "blocked" && !c.Status().AutomaticSelection })
				if starts.Load() != 1 {
					t.Fatal("security failure rotated peer")
				}
			} else {
				waitRecoveryCondition(t, func() bool { return c.Status().State == "connected" && c.Status().ActiveProfileID == backup.ID })
			}
			assertGuardNeverDisarmed(t, guard)
		})
	}
}

func TestAutomaticGroupsRejectAmbiguousOrInvalidCandidates(t *testing.T) {
	selected := syntheticProfile()
	selected.ID = "selected"
	valid, _ := json.Marshal(selected)
	missing := selected
	missing.ID = "missing"
	missingRaw, _ := json.Marshal(missing)
	changed := selected
	changed.Port++
	changedRaw, _ := json.Marshal(changed)
	for _, group := range [][]json.RawMessage{{}, {valid, valid}, {missingRaw}, {changedRaw}, {json.RawMessage(`{"routing":{}}`)}} {
		if _, err := decodeAutomaticProfiles(selected, group); err == nil {
			t.Fatal("unsafe automatic group accepted")
		}
	}
	for _, command := range []string{"status", "disconnect", "clearAutomaticSelection", "probe"} {
		request := automaticRequest(t, selected)
		request.Command = command
		raw, _ := json.Marshal(request)
		if _, err := DecodeRequest(raw); err == nil {
			t.Fatal("automatic group on unrelated IPC command")
		}
	}
}

func TestAutomaticSweepCooldownClearAndStaleEpoch(t *testing.T) {
	first, backup := syntheticProfile(), syntheticProfile()
	first.ID, backup.ID = "primary", "backup"
	guard := &fakeGuard{}
	var starts atomic.Int32
	c := recoveryController(t, guard, func(context.Context, exvpn.Profile, []string) (Tunnel, error) {
		starts.Add(1)
		return &recoveryTunnel{verifyFn: func(context.Context) error { return Code("offline") }}, nil
	})
	c.automaticPoll, c.automaticCooldown = time.Millisecond, time.Hour
	if !c.Handle(automaticRequest(t, first, backup)).OK {
		t.Fatal("request")
	}
	waitRecoveryCondition(t, func() bool {
		s := c.Status()
		return starts.Load() >= 2 && (s.State == "blocked" || s.State == "reconnecting") && s.GuardActive && s.ConnectedAt == 0
	})
	time.Sleep(12 * time.Millisecond)
	if starts.Load() != 2 {
		t.Fatal("exhausted group ignored cooldown")
	}
	c.mu.Lock()
	epoch, generation := c.automaticEpoch, c.generation
	c.mu.Unlock()
	c.Handle(Request{Version: ProtocolVersion, ID: "clear", Command: "clearAutomaticSelection"})
	if err := c.connectInModeAutomatic(backup, nil, true, ModeVPN, true, nil, epoch, generation); err != Code("cancelled") {
		t.Fatal("cleared epoch could start backup")
	}
	time.Sleep(8 * time.Millisecond)
	if starts.Load() != 2 {
		t.Fatal("cleared group retained retries")
	}
	assertGuardNeverDisarmed(t, guard)
}

func TestAutomaticProxyFailoverRetainsMode(t *testing.T) {
	first, backup := syntheticProfile(), syntheticProfile()
	first.ID, backup.ID = "primary", "backup"
	guard := &fakeGuard{}
	c := recoveryController(t, guard, nil)
	c.automaticPoll = time.Millisecond
	c.SetProxyFactory(func(_ context.Context, p exvpn.Profile, _ []string) (Tunnel, error) {
		return &fakeSystemProxy{recoveryTunnel: recoveryTunnel{verifyFn: func(context.Context) error {
			if p.ID == first.ID {
				return Code("offline")
			}
			return nil
		}}, port: 10808}, nil
	})
	r := automaticRequest(t, first, backup)
	r.Mode = ModeProxy
	if response := c.Handle(r); !response.OK {
		t.Fatal(response.Code)
	}
	waitRecoveryCondition(t, func() bool { s := c.Status(); return s.State == "connected" && s.ActiveProfileID == backup.ID })
	if c.Status().Mode != ModeProxy || c.Status().GuardActive {
		t.Fatal("proxy failover changed tunnel policy")
	}
}

func TestAutomaticAllRemoteFailuresRetainLiveCoreAndExclusionsThroughCooldown(t *testing.T) {
	first, backup := syntheticProfile(), syntheticProfile()
	first.ID, backup.ID = "primary", "backup"
	guard := &fakeGuard{}
	var offline atomic.Bool
	offline.Store(true)
	var starts, failedChecks atomic.Int32
	var last atomic.Pointer[recoveryTunnel]
	c := recoveryController(t, guard, func(ctx context.Context, _ exvpn.Profile, paths []string) (Tunnel, error) {
		if len(paths) != 1 || paths[0] != "C:/Apps/example.exe" {
			t.Error("replacement lost confirmed direct application policy")
		}
		starts.Add(1)
		tunnel := &recoveryTunnel{verifyFn: func(context.Context) error {
			if ctx.Err() != nil {
				return Code("outbound_lease_retired")
			}
			if offline.Load() {
				failedChecks.Add(1)
				return Code("probe_failed")
			}
			return nil
		}}
		last.Store(tunnel)
		return tunnel, nil
	})
	c.automaticPoll, c.automaticCooldown = time.Millisecond, time.Hour
	if c.setExclusions([]string{"C:/Apps/example.exe"}) != nil || !c.Handle(automaticRequest(t, first, backup)).OK {
		t.Fatal("automatic request")
	}
	waitRecoveryCondition(t, func() bool { return starts.Load() == 2 && failedChecks.Load() >= 5 })
	retained := last.Load()
	c.mu.Lock()
	current := c.tunnel == retained && c.cancel != nil && c.context.Err() == nil && c.status.AutomaticSelection && c.status.ConnectedAt == 0 && c.status.State != "connected"
	c.mu.Unlock()
	if !current || retained.closed.Load() {
		t.Fatal("fully initialized remote-failed core was stopped or its lease cancelled during cooldown")
	}
	time.Sleep(20 * time.Millisecond)
	if starts.Load() != 2 || retained.closed.Load() {
		t.Fatal("cooldown rebuilt or closed the direct application dispatcher")
	}
	guard.mu.Lock()
	permitted := guard.permit
	guard.mu.Unlock()
	if !permitted {
		t.Fatal("cooldown revoked live TUN permit")
	}
	assertGuardNeverDisarmed(t, guard)
	offline.Store(false)
	waitRecoveryCondition(t, func() bool { return c.Status().State == "connected" })
	if starts.Load() != 2 || c.Status().ActiveProfileID != backup.ID || retained.closed.Load() {
		t.Fatal("HTTPS recovery failed to reuse retained backup core")
	}
	if c.Disconnect() != nil || !retained.closed.Load() {
		t.Fatal("explicit disconnect did not retire retained core")
	}
	time.Sleep(10 * time.Millisecond)
	if c.Status().State != "disconnected" || starts.Load() != 2 {
		t.Fatal("automatic worker resurrected after explicit disconnect")
	}
}

func TestAutomaticVerificationSecurityAndDirtyLeaseAreNeverRetained(t *testing.T) {
	for _, failure := range []string{"guard_permit_failed", "outbound_lease_retired", "unknown_failure", "dirty_underlay", "cancelled"} {
		t.Run(failure, func(t *testing.T) {
			first := syntheticProfile()
			first.ID = "selected"
			guard := &fakeGuard{}
			var owner *Controller
			tunnel := &recoveryTunnel{recoverFn: func() bool { return failure == "dirty_underlay" }, verifyFn: func(context.Context) error {
				if failure == "cancelled" {
					owner.mu.Lock()
					owner.cancel()
					owner.mu.Unlock()
					return context.Canceled
				}
				if failure == "dirty_underlay" {
					return Code("probe_failed")
				}
				return Code(failure)
			}}
			owner = recoveryController(t, guard, func(context.Context, exvpn.Profile, []string) (Tunnel, error) { return tunnel, nil })
			owner.automaticPoll, owner.automaticCooldown = time.Millisecond, time.Hour
			if !owner.Handle(automaticRequest(t, first)).OK {
				t.Fatal("request")
			}
			waitRecoveryCondition(t, tunnel.closed.Load)
			owner.mu.Lock()
			retained := owner.tunnel == tunnel
			owner.mu.Unlock()
			if retained {
				t.Fatal("unsafe or cancelled core retained")
			}
			assertGuardNeverDisarmed(t, guard)
		})
	}
}

func TestRetainedAutomaticCoreIsRetiredWhenVerificationBecomesSecurityFailure(t *testing.T) {
	profile := syntheticProfile()
	profile.ID = "only"
	guard := &fakeGuard{}
	var unsafe atomic.Bool
	var checks atomic.Int32
	tunnel := &recoveryTunnel{verifyFn: func(context.Context) error {
		checks.Add(1)
		if unsafe.Load() {
			return Code("outbound_lease_retired")
		}
		return Code("probe_failed")
	}}
	c := recoveryController(t, guard, func(context.Context, exvpn.Profile, []string) (Tunnel, error) { return tunnel, nil })
	c.automaticPoll, c.automaticCooldown = time.Millisecond, time.Hour
	if !c.Handle(automaticRequest(t, profile)).OK {
		t.Fatal("request")
	}
	waitRecoveryCondition(t, func() bool { return checks.Load() >= 3 })
	if tunnel.closed.Load() {
		t.Fatal("ordinary remote outage stopped safe core")
	}
	unsafe.Store(true)
	waitRecoveryCondition(t, func() bool { return tunnel.closed.Load() && !c.Status().AutomaticSelection })
	if c.Status().State != "blocked" || c.Status().Code != "outbound_lease_retired" {
		t.Fatal("security verification error was hidden as remote outage")
	}
	assertGuardNeverDisarmed(t, guard)
}
