// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"context"
	"encoding/json"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

// Own a deep profile snapshot for the entire connection generation, including
// nested ALPN, REALITY and Sudoku values. Neither an IPC caller nor a provider
// refresh may change a pending reconnect's selected server or policy.
func snapshotProfile(profile exvpn.Profile) (exvpn.Profile, error) {
	wire, err := json.Marshal(profile)
	if err != nil {
		return exvpn.Profile{}, Code("profile_rejected")
	}
	copy, err := exvpn.DecodeProfile(bytes.NewReader(wire))
	if err != nil {
		return exvpn.Profile{}, Code("profile_rejected")
	}
	return copy, nil
}

func (c *Controller) reconnect(ctx context.Context, generation uint64, profile exvpn.Profile, exclusions []string) Tunnel {
	for attempt := 0; ; attempt++ {
		delayIndex := min(attempt, len(c.reconnectDelays)-1)
		timer := time.NewTimer(c.reconnectDelays[delayIndex])
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil
		case <-timer.C:
		}
		tunnel, terminal := c.reconnectOnce(ctx, generation, profile, exclusions)
		if tunnel != nil || terminal {
			return tunnel
		}
	}
}

// The ops lock serializes every old-core read, Close and new-core publication.
// Disconnect cancels ctx before taking ops, so both the delay and an in-flight
// bootstrap/HTTPS attempt stop without a later stale connected event.
func (c *Controller) reconnectOnce(ctx context.Context, generation uint64, profile exvpn.Profile, exclusions []string) (Tunnel, bool) {
	c.ops.Lock()
	defer c.ops.Unlock()
	c.mu.Lock()
	current := ctx.Err() == nil && !c.closed && c.stopping == 0 && c.generation == generation
	c.mu.Unlock()
	if !current {
		return nil, true
	}
	fatal := func(code string) (Tunnel, bool) {
		c.mu.Lock()
		if ctx.Err() == nil && !c.closed && c.stopping == 0 && c.generation == generation {
			c.status.State, c.status.Code, c.status.GuardActive = "blocked", code, true
			c.status.ConnectedAt = 0
			if c.cancel != nil {
				c.cancel()
				c.cancel = nil
			}
		}
		c.mu.Unlock()
		return nil, true
	}
	// Suspend removes only dynamic permits. Persistent deny filters remain
	// through adapter cleanup, failed attempts and DNS bootstrap leases.
	if err := c.stopTunnel(); err != nil {
		return fatal(safeCode(err, "tunnel_stop_failed"))
	}
	if ctx.Err() != nil {
		return nil, true
	}
	// The factory owns bounded bootstrap/setup operations but receives the
	// generation's lifetime context, just as on the original connection.
	tunnel, err := c.start(ctx, profile, append([]string(nil), exclusions...))
	if tunnel != nil {
		c.mu.Lock()
		c.tunnel = tunnel
		c.mu.Unlock()
	}
	failed := func() (Tunnel, bool) {
		if stopErr := c.stopTunnel(); stopErr != nil {
			return fatal(safeCode(stopErr, "tunnel_stop_failed"))
		}
		return nil, ctx.Err() != nil
	}
	if err == Code("bootstrap_permit_failed") || err == Code("bootstrap_close_failed") || err == Code("outbound_close_failed") || err == Code("outbound_watcher_unavailable") || err == Code("outbound_lease_busy") {
		if stopErr := c.stopTunnel(); stopErr != nil {
			return fatal(safeCode(stopErr, "tunnel_stop_failed"))
		}
		return fatal(string(err.(Code)))
	}
	if err != nil || tunnel == nil || ctx.Err() != nil {
		return failed()
	}
	if c.guard.PermitTunnel(tunnel.LUID()) != nil {
		if stopErr := c.stopTunnel(); stopErr != nil {
			return fatal(safeCode(stopErr, "tunnel_stop_failed"))
		}
		return fatal("guard_permit_failed")
	}
	probe, stopProbe := context.WithTimeout(ctx, 20*time.Second)
	err = tunnel.Verify(probe)
	stopProbe()
	underlayChanged := tunnelRecoveryRequired(tunnel)
	if err != nil || ctx.Err() != nil || underlayChanged {
		// A fully started replacement still owns the application exclusions.
		// A remote outage does not justify closing that healthy direct path;
		// keep the guard and let monitor verify this core again. A changed
		// underlay or cancellation does require retiring it before another try.
		if ctx.Err() == nil && !underlayChanged && remoteTunnelVerificationFailure(err) {
			c.mu.Lock()
			current = !c.closed && c.stopping == 0 && c.generation == generation && c.tunnel == tunnel
			c.mu.Unlock()
			if current {
				return tunnel, false
			}
		}
		if err != nil && !remoteTunnelVerificationFailure(err) && ctx.Err() == nil && !underlayChanged {
			if stopErr := c.stopTunnel(); stopErr != nil {
				return fatal(safeCode(stopErr, "tunnel_stop_failed"))
			}
			return fatal(safeCode(err, "tunnel_verification_failed"))
		}
		return failed()
	}
	c.mu.Lock()
	current = ctx.Err() == nil && !c.closed && c.stopping == 0 && c.generation == generation && c.tunnel == tunnel
	if current {
		c.status.State, c.status.Code = "connected", "https_verified"
		c.status.ConnectedAt = time.Now().Unix()
	}
	c.mu.Unlock()
	if !current {
		return failed()
	}
	return tunnel, false
}
