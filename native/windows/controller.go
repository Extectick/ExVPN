// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"context"
	"sync"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

type Guard interface {
	Armed() (bool, error)
	Arm() error
	PermitTunnel(uint64) error
	Suspend() error
	Disarm() error
}
type Tunnel interface {
	LUID() uint64
	Verify(context.Context) error
	Close() error
}
type TunnelFactory func(context.Context, exvpn.Profile, []string) (Tunnel, error)

// Controller owns the privileged lifetime. UI disappearing never disconnects.
// Explicit disconnect removes the latch only after the core stopped cleanly.
type Controller struct {
	mu                 sync.Mutex
	ops                sync.Mutex
	guard              Guard
	start              TunnelFactory
	validateExclusions func([]string) error
	networkEnabled     bool
	status             Status
	tunnel             Tunnel
	cancel             context.CancelFunc
	context            context.Context
	generation         uint64
	closed             bool
	stopping           bool
	exclusions         []string
	exclusionsKnown    bool
	policy             PolicyStore
}

func NewController(g Guard, f TunnelFactory, validate func([]string) error, networkEnabled bool) (*Controller, error) {
	return NewControllerWithPolicy(g, f, validate, networkEnabled, nil)
}

// The installed service always supplies durable storage. A nil store is limited
// to isolated diagnostic/unit fixtures, whose former in-memory behavior remains.
func NewControllerWithPolicy(g Guard, f TunnelFactory, validate func([]string) error, networkEnabled bool, policy PolicyStore) (*Controller, error) {
	armed, err := g.Armed()
	if err != nil {
		return nil, Code("guard_inspection_failed")
	}
	c := &Controller{guard: g, start: f, validateExclusions: validate, networkEnabled: networkEnabled, status: Status{State: "disconnected", Code: "idle", GuardActive: armed, CoreVersion: exvpn.CoreVersion, Capabilities: Capabilities{SystemTunnel: networkEnabled, PersistentGuard: networkEnabled, ApplicationExclusions: networkEnabled, Verified: false}}}
	if armed {
		c.status.State = "blocked"
		c.status.Code = "guard_recovered"
	}
	c.exclusionsKnown = !armed
	c.policy = policy
	if policy != nil {
		paths, loadErr := policy.Load()
		switch {
		case loadErr == nil && validatePolicyPaths(paths) == nil:
			c.exclusions = append([]string{}, paths...)
			c.exclusionsKnown = true
		case loadErr == policyMissing && !armed:
			// Seed a genuinely new owner's key once. A later missing value is
			// corruption, not permission to silently forget prior exclusions.
			c.exclusionsKnown = policy.Save([]string{}) == nil
			if !c.exclusionsKnown {
				c.status.State, c.status.Code = "error", "exclusions_unavailable"
			}
		default:
			c.exclusionsKnown = false
			if !armed {
				c.status.State, c.status.Code = "error", "exclusions_unavailable"
			}
		}
	}
	return c, nil
}
func (c *Controller) Status() Status { c.mu.Lock(); defer c.mu.Unlock(); return c.status }
func (c *Controller) set(state, code string, active bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.status.State = state
	c.status.Code = code
	c.status.GuardActive = active
	if state != "connected" {
		c.status.ConnectedAt = 0
	}
}
func (c *Controller) Handle(r Request) Response {
	code := "ok"
	ok := true
	switch r.Command {
	case "status":
	case "stats":
		traffic, err := c.Statistics()
		if err != nil {
			return Response{Version: ProtocolVersion, ID: r.ID, Code: "statistics_unavailable", Status: c.Status()}
		}
		return Response{Version: ProtocolVersion, ID: r.ID, OK: true, Code: "ok", Status: c.Status(), Traffic: &traffic}
	case "getExclusions":
		c.mu.Lock()
		known := c.exclusionsKnown
		paths := append([]string{}, c.exclusions...)
		c.mu.Unlock()
		if !known {
			return Response{Version: ProtocolVersion, ID: r.ID, Code: "exclusions_unavailable", Status: c.Status()}
		}
		return Response{Version: ProtocolVersion, ID: r.ID, OK: true, Code: "ok", Status: c.Status(), Exclusions: paths}
	case "setExclusions":
		if err := c.setExclusions(r.Exclusions); err != nil {
			return Response{Version: ProtocolVersion, ID: r.ID, Code: safeCode(err, "native_storage_unavailable"), Status: c.Status()}
		}
	case "probe":
		p, e := exvpn.DecodeProfile(bytes.NewReader(r.Profile))
		if e != nil {
			return Response{Version: ProtocolVersion, ID: r.ID, Code: "profile_rejected", Status: c.Status()}
		}
		result := c.Probe(p.ID)
		return Response{Version: ProtocolVersion, ID: r.ID, OK: true, Code: "ok", Status: c.Status(), Probe: &result}
	case "validate", "connect":
		p, e := exvpn.DecodeProfile(bytes.NewReader(r.Profile))
		if e != nil {
			code = "profile_rejected"
			ok = false
			break
		}
		if r.Command == "connect" {
			e = c.connectWithPolicy(p, r.Exclusions, r.Exclusions == nil)
		} else {
			c.mu.Lock()
			_, e = c.resolvePolicyLocked(p, r.Exclusions, r.Exclusions == nil)
			c.mu.Unlock()
		}
		if e != nil {
			code, ok = safeCode(e, "config_rejected"), false
		}
	case "disconnect":
		if e := c.Disconnect(); e != nil {
			code = safeCode(e, "disconnect_failed")
			ok = false
		}
	default:
		code = "ipc_unknown_command"
		ok = false
	}
	return Response{Version: ProtocolVersion, ID: r.ID, OK: ok, Code: code, Status: c.Status()}
}
func safeCode(err error, fallback string) string {
	if e, ok := err.(Code); ok {
		return string(e)
	}
	return fallback
}
func (c *Controller) Connect(p exvpn.Profile, exclusions []string) error {
	return c.connectWithPolicy(p, exclusions, false)
}

func (c *Controller) resolvePolicyLocked(p exvpn.Profile, paths []string, stored bool) ([]string, error) {
	if stored {
		if !c.exclusionsKnown {
			return nil, Code("exclusions_unavailable")
		}
		paths = c.exclusions
	}
	if err := validateTunnelProfile(p, paths); err != nil {
		return nil, err
	}
	if validatePolicyPaths(paths) != nil || (c.validateExclusions != nil && c.validateExclusions(paths) != nil) {
		return nil, Code("exclusions_rejected")
	}
	return append([]string{}, paths...), nil
}

func (c *Controller) savePolicyLocked(paths []string) error {
	if c.policy != nil && c.policy.Save(paths) != nil {
		// A failed write/flush can have an unknown outcome. Do not publish a
		// remembered list as confirmed or silently replace it with an empty one.
		c.exclusionsKnown = false
		return Code("native_storage_unavailable")
	}
	c.exclusions, c.exclusionsKnown = append([]string{}, paths...), true
	return nil
}

func (c *Controller) setExclusions(paths []string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.cancel != nil || c.tunnel != nil || c.stopping {
		return Code("reconnect_required")
	}
	if validatePolicyPaths(paths) != nil || (c.validateExclusions != nil && c.validateExclusions(paths) != nil) {
		return Code("exclusions_rejected")
	}
	return c.savePolicyLocked(paths)
}

func (c *Controller) connectWithPolicy(p exvpn.Profile, paths []string, stored bool) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return Code("service_stopping")
	}
	if !c.networkEnabled {
		return Code("system_testing_required")
	}
	if c.cancel != nil || c.tunnel != nil || c.stopping {
		return Code("connection_busy")
	}
	exclusions, err := c.resolvePolicyLocked(p, paths, stored)
	if err != nil {
		return err
	}
	if err = c.savePolicyLocked(exclusions); err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	c.cancel = cancel
	c.context = ctx
	c.generation++
	generation := c.generation
	c.status.State = "connecting"
	c.status.Code = "starting"
	c.status.ConnectedAt = 0
	c.status.ActiveProfileID = p.ID
	go c.connect(ctx, generation, p, append([]string(nil), exclusions...))
	return nil
}
func (c *Controller) connect(ctx context.Context, generation uint64, p exvpn.Profile, exclusions []string) {
	c.ops.Lock()
	defer c.ops.Unlock()
	if ctx.Err() != nil {
		return
	}
	if e := c.guard.Arm(); e != nil {
		armed, inspection := c.guard.Armed()
		if armed || inspection != nil {
			c.set("blocked", "guard_arm_failed", true)
		} else {
			c.set("error", "guard_arm_failed", false)
		}
		c.finishAttempt(generation)
		return
	}
	c.set("connecting", "guard_armed", true)
	t, e := c.start(ctx, p, exclusions)
	if t != nil {
		c.mu.Lock()
		c.tunnel = t
		c.mu.Unlock()
	}
	stop := func() {
		if c.stopTunnel() != nil {
			c.set("blocked", "tunnel_stop_failed", true)
		}
	}
	if e != nil {
		stop()
		c.set("blocked", safeCode(e, "tunnel_start_failed"), true)
		c.finishAttempt(generation)
		return
	}
	if t == nil {
		c.set("blocked", "tunnel_start_failed", true)
		c.finishAttempt(generation)
		return
	}
	if ctx.Err() != nil {
		stop()
		return
	}
	if e = c.guard.PermitTunnel(t.LUID()); e != nil {
		stop()
		c.set("blocked", "guard_permit_failed", true)
		c.finishAttempt(generation)
		return
	}
	verifyCtx, verifyCancel := context.WithTimeout(ctx, 20*time.Second)
	e = t.Verify(verifyCtx)
	verifyCancel()
	if e != nil || ctx.Err() != nil {
		stop()
		c.set("blocked", "tunnel_unreachable", true)
		c.finishAttempt(generation)
		return
	}
	c.mu.Lock()
	if generation != c.generation || c.closed {
		c.mu.Unlock()
		stop()
		return
	}
	c.tunnel = t
	c.status.State = "connected"
	c.status.Code = "https_verified"
	c.status.ConnectedAt = time.Now().Unix()
	c.mu.Unlock()
	go c.monitor(ctx, generation, t)
}

// The adapter remains captured and guarded while a failed transport retries.
// A dead server must not leave the UI indefinitely claiming connected.
func (c *Controller) monitor(ctx context.Context, generation uint64, t Tunnel) {
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		probe, cancel := context.WithTimeout(ctx, 12*time.Second)
		err := t.Verify(probe)
		cancel()
		c.mu.Lock()
		if ctx.Err() != nil || c.closed || c.generation != generation || c.tunnel != t {
			c.mu.Unlock()
			return
		}
		if err != nil {
			c.status.State = "reconnecting"
			c.status.Code = "transport_unreachable"
		} else {
			c.status.State = "connected"
			c.status.Code = "https_verified"
		}
		c.mu.Unlock()
	}
}
func (c *Controller) finishAttempt(generation uint64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.generation == generation && c.cancel != nil {
		c.cancel()
		c.cancel = nil
	}
}
func (c *Controller) Disconnect() error {
	c.mu.Lock()
	c.stopping = true
	c.generation++
	if c.cancel != nil {
		c.cancel()
		c.cancel = nil
	}
	c.mu.Unlock()
	c.ops.Lock()
	defer c.ops.Unlock()
	defer func() { c.mu.Lock(); c.stopping = false; c.mu.Unlock() }()
	if err := c.stopTunnel(); err != nil {
		c.set("blocked", "tunnel_stop_failed", true)
		return err
	}
	if err := c.guard.Disarm(); err != nil {
		c.set("blocked", "guard_remove_failed", true)
		return Code("guard_remove_failed")
	}
	c.set("disconnected", "explicit_disconnect", false)
	c.mu.Lock()
	c.status.ActiveProfileID = ""
	if !c.exclusionsKnown && c.policy == nil {
		c.exclusions = []string{}
		c.exclusionsKnown = true
	}
	c.mu.Unlock()
	return nil
}

func (c *Controller) Probe(profileID string) ProbeResult {
	c.mu.Lock()
	t := c.tunnel
	ctx := c.context
	active := c.status.ActiveProfileID
	c.mu.Unlock()
	if t == nil || ctx == nil || ctx.Err() != nil || active != profileID {
		return ProbeResult{ErrorCode: "probe_requires_active_tunnel"}
	}
	probe, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	started := time.Now()
	if t.Verify(probe) != nil {
		return ProbeResult{ErrorCode: "probe_connection_failed"}
	}
	return ProbeResult{Reachable: true, LatencyMS: time.Since(started).Milliseconds()}
}

// Counters are read only from the currently owned live core. Missing counters
// are unavailable, never fabricated zeroes. Serializing with lifetime changes
// also prevents a read from an old tunnel after explicit disconnect.
func (c *Controller) Statistics() (Traffic, error) {
	if !c.ops.TryLock() {
		return Traffic{}, Code("statistics_unavailable")
	}
	defer c.ops.Unlock()
	c.mu.Lock()
	t := c.tunnel
	active := c.context != nil && c.context.Err() == nil && !c.stopping && !c.closed
	c.mu.Unlock()
	if !active {
		return Traffic{}, Code("statistics_unavailable")
	}
	provider, ok := t.(interface{ Statistics() (Traffic, error) })
	if !ok {
		return Traffic{}, Code("statistics_unavailable")
	}
	return provider.Statistics()
}
func (c *Controller) stopTunnel() error {
	if e := c.guard.Suspend(); e != nil {
		return Code("guard_suspend_failed")
	}
	c.mu.Lock()
	t := c.tunnel
	c.mu.Unlock()
	if t != nil {
		if e := t.Close(); e != nil {
			return Code("tunnel_stop_failed")
		}
		c.mu.Lock()
		c.tunnel = nil
		c.mu.Unlock()
	}
	return nil
}

// Shutdown is different from an explicit user disconnect: leave persistent
// block filters in place across service stop, process death and reboot.
func (c *Controller) Shutdown() error {
	c.mu.Lock()
	c.closed = true
	c.generation++
	if c.cancel != nil {
		c.cancel()
		c.cancel = nil
	}
	c.mu.Unlock()
	c.ops.Lock()
	defer c.ops.Unlock()
	err := c.stopTunnel()
	armed, e := c.guard.Armed()
	if e != nil {
		armed = true
	}
	if armed {
		c.set("blocked", "service_stopped", true)
	}
	return err
}
