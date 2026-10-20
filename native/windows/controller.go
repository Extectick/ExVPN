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
	startProxy         TunnelFactory
	tunnelMode         string
	validateExclusions func([]string) error
	networkEnabled     bool
	status             Status
	tunnel             Tunnel
	cancel             context.CancelFunc
	context            context.Context
	generation         uint64
	closed             bool
	stopping           int
	exclusions         []string
	exclusionsKnown    bool
	applicationRouting ApplicationRoutingPolicy
	siteRouting        exvpn.SiteRoutingState
	siteRoutingKnown   bool
	siteStore          SiteRoutingStore
	guardRecovered     bool
	policy             PolicyStore
	protectionEnabled  bool
	protectionKnown    bool
	protectionStore    ConnectionProtectionStore
	monitorInterval    time.Duration
	reconnectDelays    []time.Duration
	automaticEpoch     uint64
	automaticCancel    context.CancelFunc
	automaticPoll      time.Duration
	automaticCooldown  time.Duration
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
	c := &Controller{guard: g, start: f, tunnelMode: ModeVPN, validateExclusions: validate, networkEnabled: networkEnabled, status: Status{Mode: ModeVPN, State: "disconnected", Code: "idle", GuardActive: armed, CoreVersion: exvpn.CoreVersion, Capabilities: Capabilities{SystemTunnel: networkEnabled, PersistentGuard: networkEnabled, ApplicationExclusions: networkEnabled, Verified: false}}}
	c.monitorInterval = 15 * time.Second
	c.reconnectDelays = []time.Duration{5 * time.Second, 15 * time.Second, 30 * time.Second}
	c.automaticPoll, c.automaticCooldown = time.Second, 30*time.Second
	if armed {
		c.status.State = "blocked"
		c.status.Code = "guard_recovered"
	}
	c.exclusionsKnown = !armed
	c.guardRecovered = armed
	c.applicationRouting = legacyApplicationRouting(nil)
	c.policy = policy
	if policy != nil {
		var paths []string
		var loadErr error
		var routing ApplicationRoutingPolicy
		if store, ok := policy.(ApplicationRoutingStore); ok {
			routing, loadErr = store.LoadRouting()
			paths = routing.effective()
			if loadErr == nil && routing.validate() != nil {
				loadErr = Code("exclusions_unavailable")
			}
		} else {
			paths, loadErr = policy.Load()
			routing = legacyApplicationRouting(paths)
		}
		switch {
		case loadErr == nil && validatePolicyPaths(paths) == nil:
			c.exclusions = append([]string{}, paths...)
			c.applicationRouting = routing.clone()
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
	c.initializeConnectionProtection(policy)
	c.initializeSiteRouting(policy, armed)
	return c, nil
}
func (c *Controller) Status() Status {
	c.mu.Lock()
	status := c.status
	c.mu.Unlock()
	if guard, ok := c.guard.(connectionProtectionGuard); ok && status.Mode == ModeVPN {
		active, err := guard.PersistentArmed()
		status.PersistentGuardActive = err == nil && active
	}
	return status
}

// Install before serving IPC. Existing constructors remain VPN-only by default.
func (c *Controller) SetProxyFactory(factory TunnelFactory) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.startProxy = factory
	c.status.Capabilities.SystemProxy = c.networkEnabled && factory != nil
}
func (c *Controller) set(state, code string, active bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.status.State = state
	c.status.Code = code
	c.status.GuardActive = active
	if state != "connected" {
		c.status.ConnectedAt = 0
	}
	if state == "error" || state == "blocked" || state == "disconnected" {
		c.status.ProxyPort = 0
	}
}
func (c *Controller) Handle(r Request) Response {
	code := "ok"
	ok := true
	switch r.Command {
	case "clearAutomaticSelection":
		c.mu.Lock()
		c.clearAutomaticLocked()
		c.mu.Unlock()
	case "status":
	case "getConnectionProtection", "setConnectionProtection":
		if r.Command == "setConnectionProtection" {
			if r.Enabled == nil {
				return Response{Version: ProtocolVersion, ID: r.ID, Code: "ipc_invalid_payload", Status: c.Status()}
			}
			if err := c.SetConnectionProtection(*r.Enabled); err != nil {
				return Response{Version: ProtocolVersion, ID: r.ID, Code: safeCode(err, "connection_protection_unavailable"), Status: c.Status()}
			}
		}
		value, err := c.ConnectionProtection()
		if err != nil {
			return Response{Version: ProtocolVersion, ID: r.ID, Code: safeCode(err, "connection_protection_unavailable"), Status: c.Status()}
		}
		return Response{Version: ProtocolVersion, ID: r.ID, OK: true, Code: "ok", Status: c.Status(), ConnectionProtection: &value}
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
		if c.applicationRouting.Mode != exvpn.RoutingExclude {
			paths = []string{}
		}
		c.mu.Unlock()
		if !known {
			return Response{Version: ProtocolVersion, ID: r.ID, Code: "exclusions_unavailable", Status: c.Status()}
		}
		return Response{Version: ProtocolVersion, ID: r.ID, OK: true, Code: "ok", Status: c.Status(), Exclusions: paths}
	case "setExclusions":
		if err := c.setExclusions(r.Exclusions); err != nil {
			return Response{Version: ProtocolVersion, ID: r.ID, Code: safeCode(err, "native_storage_unavailable"), Status: c.Status()}
		}
	case "getApplicationRouting":
		c.mu.Lock()
		known := c.exclusionsKnown
		policy := c.applicationRouting.clone()
		c.mu.Unlock()
		if !known {
			return Response{Version: ProtocolVersion, ID: r.ID, Code: "exclusions_unavailable", Status: c.Status()}
		}
		return Response{Version: ProtocolVersion, ID: r.ID, OK: true, Code: "ok", Status: c.Status(), ApplicationRouting: &policy}
	case "setApplicationRouting":
		if r.ApplicationRouting == nil {
			return Response{Version: ProtocolVersion, ID: r.ID, Code: "application_routing_rejected", Status: c.Status()}
		}
		if err := c.setApplicationRouting(*r.ApplicationRouting); err != nil {
			return Response{Version: ProtocolVersion, ID: r.ID, Code: safeCode(err, "native_storage_unavailable"), Status: c.Status()}
		}
	case "get_site_routing", "set_site_routing":
		if r.Command == "set_site_routing" {
			if r.SiteRouting == nil {
				return Response{Version: ProtocolVersion, ID: r.ID, Code: "site_routing_rejected", Status: c.Status()}
			}
			if err := c.setSiteRouting(*r.SiteRouting); err != nil {
				return Response{Version: ProtocolVersion, ID: r.ID, Code: safeCode(err, "site_routing_unavailable"), Status: c.Status()}
			}
		}
		state, err := c.getSiteRouting()
		if err != nil {
			return Response{Version: ProtocolVersion, ID: r.ID, Code: safeCode(err, "site_routing_unavailable"), Status: c.Status()}
		}
		return Response{Version: ProtocolVersion, ID: r.ID, OK: true, Code: "ok", Status: c.Status(), SiteRouting: &state}
	case "probe":
		p, e := exvpn.DecodeProfile(bytes.NewReader(r.Profile))
		if e != nil {
			return Response{Version: ProtocolVersion, ID: r.ID, Code: "profile_rejected", Status: c.Status()}
		}
		result := c.Probe(p.ID)
		return Response{Version: ProtocolVersion, ID: r.ID, OK: true, Code: "ok", Status: c.Status(), Probe: &result}
	case "validate", "connect", "reconnect":
		p, e := exvpn.DecodeProfile(bytes.NewReader(r.Profile))
		if e != nil {
			code = "profile_rejected"
			ok = false
			break
		}
		if r.Command == "connect" || r.Command == "reconnect" {
			group, groupErr := decodeAutomaticProfiles(p, r.AutomaticProfiles)
			if groupErr != nil {
				code, ok = "automatic_group_rejected", false
				break
			}
			e = c.connectInModeAutomatic(p, r.Exclusions, r.Exclusions == nil, r.Mode, r.Command == "reconnect", group, 0, 0)
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
	if !c.siteRoutingKnown {
		return nil, Code("site_routing_unavailable")
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
	return c.saveApplicationRoutingLocked(legacyApplicationRouting(paths))
}

func (c *Controller) saveApplicationRoutingLocked(policy ApplicationRoutingPolicy) error {
	var err error
	if c.policy != nil {
		if store, ok := c.policy.(ApplicationRoutingStore); ok {
			err = store.SaveRouting(policy.clone())
		} else if policy.Mode == exvpn.RoutingInclude || (policy.Mode == exvpn.RoutingDisabled && len(policy.Applications) > 0) {
			return Code("application_routing_unsupported")
		} else {
			err = c.policy.Save(policy.Applications)
		}
	}
	if err != nil {
		// A failed write/flush can have an unknown outcome. Do not publish a
		// remembered list as confirmed or silently replace it with an empty one.
		c.exclusionsKnown = false
		return Code("native_storage_unavailable")
	}
	c.applicationRouting = policy.clone()
	c.exclusions, c.exclusionsKnown = policy.effective(), true
	return nil
}

func (c *Controller) setApplicationRouting(policy ApplicationRoutingPolicy) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.cancel != nil || c.tunnel != nil || c.stopping != 0 {
		return Code("reconnect_required")
	}
	if policy.validate() != nil {
		return Code("application_routing_rejected")
	}
	checked := policy.Applications
	if policy.Mode == exvpn.RoutingDisabled {
		remembered := map[string]bool{}
		for _, id := range c.applicationRouting.Applications {
			remembered[applicationPathKey(id)] = true
		}
		checked = []string{}
		for _, id := range policy.Applications {
			if !remembered[applicationPathKey(id)] {
				checked = append(checked, id)
			}
		}
	}
	if c.validateExclusions != nil && c.validateExclusions(checked) != nil {
		return Code("application_routing_rejected")
	}
	if err := c.saveApplicationRoutingLocked(policy); err != nil {
		return err
	}
	if !c.status.GuardActive && c.status.State == "error" && c.status.Code == "exclusions_unavailable" {
		c.status.State, c.status.Code = "disconnected", "policy_restored"
	}
	return nil
}

func (c *Controller) setExclusions(paths []string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.cancel != nil || c.tunnel != nil || c.stopping != 0 {
		return Code("reconnect_required")
	}
	if validatePolicyPaths(paths) != nil || (c.validateExclusions != nil && c.validateExclusions(paths) != nil) {
		return Code("exclusions_rejected")
	}
	if err := c.savePolicyLocked(paths); err != nil {
		return err
	}
	if !c.status.GuardActive && c.status.State == "error" && c.status.Code == "exclusions_unavailable" {
		c.status.State, c.status.Code = "disconnected", "policy_restored"
	}
	return nil
}

func (c *Controller) connectWithPolicy(p exvpn.Profile, paths []string, stored bool) error {
	return c.connectInMode(p, paths, stored, ModeVPN, false)
}

const ModeVPN = "vpn"
const ModeProxy = "proxy"

func (c *Controller) ConnectMode(p exvpn.Profile, mode string) error {
	return c.connectInMode(p, nil, true, mode, false)
}

func (c *Controller) Reconnect(p exvpn.Profile, mode string) error {
	return c.connectInMode(p, nil, true, mode, true)
}

func (c *Controller) connectInMode(p exvpn.Profile, paths []string, stored bool, mode string, replace bool) error {
	return c.connectInModeAutomatic(p, paths, stored, mode, replace, nil, 0, 0)
}

func (c *Controller) connectInModeAutomatic(p exvpn.Profile, paths []string, stored bool, mode string, replace bool, group []exvpn.Profile, epoch, expectedGeneration uint64) error {
	if mode == "" {
		mode = ModeVPN
	}
	if mode != ModeVPN && mode != ModeProxy {
		return Code("connection_mode_rejected")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return Code("service_stopping")
	}
	if epoch != 0 && (c.automaticEpoch != epoch || !c.status.AutomaticSelection || c.generation != expectedGeneration) {
		return Code("cancelled")
	}
	if !c.networkEnabled {
		return Code("system_testing_required")
	}
	if mode == ModeVPN && !c.protectionKnown {
		return Code("connection_protection_unavailable")
	}
	if c.stopping != 0 || (!replace && (c.cancel != nil || c.tunnel != nil)) {
		return Code("connection_busy")
	}
	// Explicit replacement can cancel an owned pending VPN as well as a verified
	// VPN. A recovered/unknown latch is never permission for a proxy bypass.
	ownedPendingVPN := c.cancel != nil && c.status.Mode == ModeVPN && c.status.State == "connecting" && !c.guardRecovered
	verifiedVPN := c.tunnel != nil && c.tunnelMode == ModeVPN && c.status.GuardActive && (c.status.State == "connected" || c.status.State == "reconnecting")
	allowGuardRelease := replace && (verifiedVPN || ownedPendingVPN)
	var exclusions []string
	var err error
	if mode == ModeProxy {
		if !c.siteRoutingKnown {
			return Code("site_routing_unavailable")
		}
		if c.siteRouting.Policy.Active() {
			return Code("site_routing_requires_vpn")
		}
		if c.startProxy == nil {
			return Code("proxy_unavailable")
		}
		if paths != nil {
			return Code("proxy_exclusions_unsupported")
		}
		if c.status.State == "blocked" || (c.status.GuardActive && !allowGuardRelease) {
			return Code("proxy_requires_guard_recovery")
		}
		err = validateTunnelProfile(p, nil)
	} else {
		exclusions, err = c.resolvePolicyLocked(p, paths, stored)
	}
	if err != nil {
		return err
	}
	// Compile every candidate before changing durable policy or cancelling the
	// current generation. A valid primary cannot smuggle an unusable backup.
	if epoch == 0 {
		for _, candidate := range group {
			if mode == ModeProxy {
				err = validateTunnelProfile(candidate, nil)
			} else {
				_, err = c.resolvePolicyLocked(candidate, paths, stored)
			}
			if err != nil {
				return Code("automatic_group_rejected")
			}
		}
	}
	p, err = snapshotProfile(p)
	if err != nil {
		return err
	}
	if mode == ModeVPN {
		if stored {
			err = c.saveApplicationRoutingLocked(c.applicationRouting.clone())
		} else {
			err = c.savePolicyLocked(exclusions)
		}
	}
	if err != nil {
		return err
	}
	if c.cancel != nil {
		c.cancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	if mode == ModeVPN {
		ctx = context.WithValue(ctx, applicationRoutingContextKey{}, c.applicationRouting.clone())
		ctx = context.WithValue(ctx, siteRoutingContextKey{}, c.siteRouting.Clone().Policy)
	}
	c.cancel = cancel
	c.context = ctx
	c.generation++
	generation := c.generation
	c.status.State = "connecting"
	c.status.Code = "starting"
	c.status.ConnectedAt = 0
	c.status.ActiveProfileID = p.ID
	c.status.Mode, c.status.ProxyPort = mode, 0
	if epoch == 0 {
		c.clearAutomaticLocked()
		if len(group) != 0 {
			autoContext, autoCancel := context.WithCancel(context.Background())
			c.automaticCancel = autoCancel
			c.status.AutomaticSelection = true
			go c.runAutomatic(autoContext, c.automaticEpoch, group, mode)
		}
	}
	go c.connect(ctx, generation, p, append([]string(nil), exclusions...), mode, replace, allowGuardRelease)
	return nil
}
func (c *Controller) connect(ctx context.Context, generation uint64, p exvpn.Profile, exclusions []string, mode string, replace, allowGuardRelease bool) {
	c.ops.Lock()
	defer c.ops.Unlock()
	if ctx.Err() != nil {
		return
	}
	if replace {
		c.mu.Lock()
		cleanupRequired := c.tunnel != nil || (c.tunnelMode != ModeProxy && c.status.GuardActive)
		c.mu.Unlock()
		if cleanupRequired {
			if err := c.stopTunnel(); err != nil {
				c.set("blocked", safeCode(err, "tunnel_stop_failed"), c.Status().GuardActive)
				c.finishAttempt(generation)
				return
			}
		}
	}
	if mode == ModeProxy {
		c.connectProxy(ctx, generation, p, allowGuardRelease)
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
	c.mu.Lock()
	c.tunnelMode = ModeVPN
	c.mu.Unlock()
	t, e := c.start(ctx, p, exclusions)
	if t != nil {
		c.mu.Lock()
		c.tunnel = t
		c.mu.Unlock()
	}
	stop := func() error {
		err := c.stopTunnel()
		if err != nil {
			c.set("blocked", safeCode(err, "tunnel_stop_failed"), true)
		}
		return err
	}
	fail := func(code string) {
		if stop() == nil {
			c.set("blocked", code, true)
		}
		c.finishAttempt(generation)
	}
	if e != nil {
		fail(safeCode(e, "tunnel_start_failed"))
		return
	}
	if t == nil {
		fail("tunnel_start_failed")
		return
	}
	if ctx.Err() != nil {
		stop()
		return
	}
	if e = c.guard.PermitTunnel(t.LUID()); e != nil {
		fail("guard_permit_failed")
		return
	}
	verifyCtx, verifyCancel := context.WithTimeout(ctx, 20*time.Second)
	e = t.Verify(verifyCtx)
	verifyCancel()
	if e != nil || ctx.Err() != nil {
		// Automatic selection may exhaust every remote endpoint while the
		// replacement core, TUN and known-owner direct dispatcher remain healthy.
		// Keep that core throughout cooldown: removing it blocks exclusions too.
		// The persistent guard and VPN-only DNS remain unchanged; this is never a
		// connected state or permission to route protected traffic directly.
		if ctx.Err() == nil && remoteTunnelVerificationFailure(e) && !tunnelRecoveryRequired(t) {
			c.mu.Lock()
			retain := !c.closed && c.stopping == 0 && c.generation == generation && c.tunnel == t && c.status.AutomaticSelection && c.status.GuardActive && c.tunnelMode == ModeVPN
			if retain {
				c.guardRecovered = false
				c.status.State, c.status.Code, c.status.ConnectedAt = "blocked", "tunnel_unreachable", 0
			}
			c.mu.Unlock()
			if retain {
				// Do not finishAttempt: cancellation would retire the owned lease
				// and make the retained direct dispatcher unusable during cooldown.
				go c.monitor(ctx, generation, t, p, exclusions, false)
				return
			}
		}
		code := "tunnel_unreachable"
		if e != nil && !remoteTunnelVerificationFailure(e) {
			code = safeCode(e, "tunnel_verification_failed")
		}
		fail(code)
		return
	}
	recovering := tunnelRecoveryRequired(t)
	c.mu.Lock()
	if generation != c.generation || c.closed {
		c.mu.Unlock()
		stop()
		return
	}
	c.tunnel = t
	c.guardRecovered = false
	if recovering {
		c.status.State, c.status.Code = "reconnecting", "transport_unreachable"
		c.status.ConnectedAt = 0
	} else {
		c.status.State, c.status.Code = "connected", "https_verified"
		c.status.ConnectedAt = time.Now().Unix()
	}
	c.mu.Unlock()
	go c.monitor(ctx, generation, t, p, exclusions, recovering)
}

// A changed underlay requires a new core; a remote server outage does not.
// Keep a healthy core's confirmed application exclusions working while its VPN
// endpoint is unreachable. Both cases remain under the persistent guard.
func (c *Controller) monitor(ctx context.Context, generation uint64, t Tunnel, p exvpn.Profile, exclusions []string, immediately bool) {
	ticker := time.NewTicker(c.monitorInterval)
	defer ticker.Stop()
	for {
		if !immediately {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
		immediately = false
		c.ops.Lock()
		c.mu.Lock()
		if ctx.Err() != nil || c.closed || c.generation != generation || c.tunnel != t {
			c.mu.Unlock()
			c.ops.Unlock()
			return
		}
		c.mu.Unlock()
		rebuild := tunnelRecoveryRequired(t)
		var err error
		if !rebuild {
			probe, cancel := context.WithTimeout(ctx, 12*time.Second)
			err = t.Verify(probe)
			cancel()
			// A short interface outage can occur during HTTPS and recover before
			// this call returns. The lease remembers that change until retired.
			rebuild = tunnelRecoveryRequired(t)
		}
		c.mu.Lock()
		if ctx.Err() != nil || c.closed || c.generation != generation || c.tunnel != t {
			c.mu.Unlock()
			c.ops.Unlock()
			return
		}
		if err != nil && !remoteTunnelVerificationFailure(err) {
			c.mu.Unlock()
			code := safeCode(err, "tunnel_verification_failed")
			if stopErr := c.stopTunnel(); stopErr != nil {
				code = safeCode(stopErr, "tunnel_stop_failed")
			}
			c.set("blocked", code, true)
			c.finishAttempt(generation)
			c.ops.Unlock()
			return
		}
		if err != nil || rebuild {
			c.status.State = "reconnecting"
			c.status.Code = "transport_unreachable"
			c.status.ConnectedAt = 0
		} else if c.status.State != "connected" {
			c.status.State, c.status.Code = "connected", "https_verified"
			c.status.ConnectedAt = time.Now().Unix()
		}
		c.mu.Unlock()
		c.ops.Unlock()
		if rebuild {
			t = c.reconnect(ctx, generation, p, exclusions)
			if t == nil {
				return
			}
			ticker.Reset(c.monitorInterval)
		}
	}
}

func tunnelRecoveryRequired(tunnel Tunnel) bool {
	observer, ok := tunnel.(interface{ RecoveryRequired() bool })
	return ok && observer.RecoveryRequired()
}
func (c *Controller) finishAttempt(generation uint64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.generation == generation && c.cancel != nil {
		c.cancel()
		c.cancel = nil
	}
}

// BeginIdleMaintenance atomically reserves a genuinely idle service for an app
// update. It never cancels a connection, stops a core, or removes protection.
// The same locks serialize Connect/Reconnect, workers and the stopping gate.
func (c *Controller) BeginIdleMaintenance() error {
	if !c.ops.TryLock() {
		return Code("maintenance_requires_disconnected")
	}
	defer c.ops.Unlock()
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.stopping != 0 || c.cancel != nil || c.tunnel != nil ||
		c.status.State != "disconnected" || c.status.GuardActive ||
		c.status.ProxyPort != 0 || c.status.ActiveProfileID != "" {
		return Code("maintenance_requires_disconnected")
	}
	armed, err := c.guard.Armed()
	if err != nil || armed {
		return Code("maintenance_requires_disconnected")
	}
	c.closed = true
	c.generation++
	return nil
}

func (c *Controller) Disconnect() error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return Code("service_stopping")
	}
	c.stopping++
	c.clearAutomaticLocked()
	c.generation++
	if c.cancel != nil {
		c.cancel()
		c.cancel = nil
	}
	c.mu.Unlock()
	c.ops.Lock()
	defer c.ops.Unlock()
	defer func() { c.mu.Lock(); c.stopping--; c.mu.Unlock() }()
	if err := c.stopTunnel(); err != nil {
		c.set("blocked", safeCode(err, "tunnel_stop_failed"), c.Status().GuardActive)
		return err
	}
	// Shutdown can begin while Close is in progress or while this request waits
	// for ops. Serialize the decision and Disarm with its closed transition so
	// an already-stopping service cannot lose the persistent latch.
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return Code("service_stopping")
	}
	if c.tunnelMode != ModeProxy || c.status.GuardActive {
		if err := c.guard.Disarm(); err != nil {
			c.status.State, c.status.Code, c.status.GuardActive = "blocked", "guard_remove_failed", true
			c.status.ConnectedAt = 0
			return Code("guard_remove_failed")
		}
	}
	c.status.State, c.status.Code, c.status.GuardActive = "disconnected", "explicit_disconnect", false
	c.guardRecovered = false
	c.status.ConnectedAt = 0
	c.status.ActiveProfileID = ""
	c.status.ProxyPort = 0
	if !c.exclusionsKnown && c.policy == nil {
		c.exclusions = []string{}
		c.exclusionsKnown = true
	}
	return nil
}

func (c *Controller) Probe(profileID string) ProbeResult {
	if !c.ops.TryLock() {
		return ProbeResult{ErrorCode: "probe_requires_active_tunnel"}
	}
	defer c.ops.Unlock()
	c.mu.Lock()
	t := c.tunnel
	ctx := c.context
	generation := c.generation
	active := !c.closed && c.stopping == 0 && c.status.State == "connected" && c.status.ActiveProfileID == profileID
	c.mu.Unlock()
	if t == nil || ctx == nil || ctx.Err() != nil || !active {
		return ProbeResult{ErrorCode: "probe_requires_active_tunnel"}
	}
	probe, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	started := time.Now()
	if t.Verify(probe) != nil {
		return ProbeResult{ErrorCode: "probe_connection_failed"}
	}
	c.mu.Lock()
	current := ctx.Err() == nil && !c.closed && c.stopping == 0 && c.generation == generation && c.tunnel == t
	c.mu.Unlock()
	if !current {
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
	ctx := c.context
	generation := c.generation
	active := ctx != nil && ctx.Err() == nil && c.stopping == 0 && !c.closed && c.status.State == "connected"
	c.mu.Unlock()
	if !active {
		return Traffic{}, Code("statistics_unavailable")
	}
	provider, ok := t.(interface{ Statistics() (Traffic, error) })
	if !ok {
		return Traffic{}, Code("statistics_unavailable")
	}
	traffic, err := provider.Statistics()
	c.mu.Lock()
	current := ctx.Err() == nil && !c.closed && c.stopping == 0 && c.generation == generation && c.tunnel == t
	c.mu.Unlock()
	if !current {
		return Traffic{}, Code("statistics_unavailable")
	}
	return traffic, err
}
func (c *Controller) stopTunnel() error {
	c.mu.Lock()
	t := c.tunnel
	proxyOwned := c.tunnelMode == ModeProxy
	c.mu.Unlock()
	// Keep the service's existing permit while retiring outbound sockets and
	// closing the core. Revoking it first can prevent TCP teardown from reaching
	// the peer. Persistent deny filters remain throughout this operation.
	var closeErr error
	if t != nil {
		closeErr = t.Close()
	}
	// A failed Close must still revoke dynamic permits. Preserve the owner
	// until both operations succeed so no replacement core or Disarm can run
	// after incomplete cleanup. A failed revocation takes diagnostic priority.
	if !proxyOwned {
		if e := c.guard.Suspend(); e != nil {
			return Code("guard_suspend_failed")
		}
	}
	if closeErr != nil {
		return Code("tunnel_stop_failed")
	}
	if t != nil {
		c.mu.Lock()
		c.tunnel = nil
		c.status.ProxyPort = 0
		c.mu.Unlock()
	}
	return nil
}

// Shutdown is different from an explicit user disconnect: leave persistent
// block filters in place across service stop, process death and reboot.
func (c *Controller) Shutdown() error {
	c.mu.Lock()
	c.clearAutomaticLocked()
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
	} else if c.Status().Mode == ModeProxy {
		c.set("disconnected", "service_stopped", false)
	}
	return err
}
