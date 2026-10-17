// SPDX-License-Identifier: Apache-2.0
package service

import (
	"context"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

type systemProxyTunnel interface {
	Tunnel
	SystemProxyPort() int
}

// Caller owns ops. Only an explicit transition from the owned live VPN may
// disarm protection, after that VPN's core and adapter have closed cleanly.
func (c *Controller) connectProxy(ctx context.Context, generation uint64, p exvpn.Profile, allowGuardRelease bool) {
	armed, err := c.guard.Armed()
	if err != nil || (armed && !allowGuardRelease) {
		c.set("blocked", "proxy_requires_guard_recovery", true)
		c.finishAttempt(generation)
		return
	}
	c.mu.Lock()
	if ctx.Err() != nil || c.closed || generation != c.generation {
		c.mu.Unlock()
		return
	}
	if armed && c.guard.Disarm() != nil {
		c.mu.Unlock()
		c.set("blocked", "guard_remove_failed", true)
		c.finishAttempt(generation)
		return
	}
	c.status.GuardActive = false
	c.tunnelMode = ModeProxy
	c.mu.Unlock()
	t, err := c.startProxyAttempt(ctx, generation, p)
	if err != nil {
		if closeErr := c.stopTunnel(); closeErr != nil {
			c.set("blocked", "proxy_stop_failed", false)
		} else {
			c.set("error", safeCode(err, "proxy_start_failed"), false)
		}
		c.finishAttempt(generation)
		return
	}
	go c.monitorProxy(ctx, generation, p, t)
}

func (c *Controller) startProxyAttempt(ctx context.Context, generation uint64, p exvpn.Profile) (Tunnel, error) {
	c.mu.Lock()
	factory := c.startProxy
	c.mu.Unlock()
	t, err := factory(ctx, p, nil)
	if t != nil {
		c.mu.Lock()
		c.tunnel = t
		c.mu.Unlock()
	}
	proxy, ok := t.(systemProxyTunnel)
	if err != nil {
		return nil, err
	}
	if !ok || proxy.SystemProxyPort() < 1 || proxy.SystemProxyPort() > 65535 {
		return nil, Code("proxy_start_failed")
	}
	probe, cancel := context.WithTimeout(ctx, 20*time.Second)
	err = t.Verify(probe)
	cancel()
	if err != nil || ctx.Err() != nil {
		return nil, Code("proxy_unreachable")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if ctx.Err() != nil || c.closed || c.generation != generation {
		return nil, Code("cancelled")
	}
	c.status.State, c.status.Code, c.status.GuardActive = "connected", "https_verified", false
	c.status.ConnectedAt = time.Now().Unix()
	c.status.ProxyPort = proxy.SystemProxyPort()
	return t, nil
}

func (c *Controller) monitorProxy(ctx context.Context, generation uint64, p exvpn.Profile, t Tunnel) {
	ticker := time.NewTicker(c.monitorInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		c.ops.Lock()
		c.mu.Lock()
		current := ctx.Err() == nil && !c.closed && c.generation == generation && c.stopping == 0
		c.mu.Unlock()
		if !current {
			c.ops.Unlock()
			return
		}
		if t == nil || tunnelRecoveryRequired(t) {
			if c.stopTunnel() != nil {
				c.set("blocked", "proxy_stop_failed", false)
				c.finishAttempt(generation)
				c.ops.Unlock()
				return
			}
			var err error
			t, err = c.startProxyAttempt(ctx, generation, p)
			if err != nil {
				if c.stopTunnel() != nil {
					c.set("blocked", "proxy_stop_failed", false)
					c.finishAttempt(generation)
					c.ops.Unlock()
					return
				}
				t = nil
				c.set("reconnecting", "proxy_unreachable", false)
			}
		} else {
			probe, cancel := context.WithTimeout(ctx, 12*time.Second)
			err := t.Verify(probe)
			cancel()
			c.mu.Lock()
			if ctx.Err() == nil && !c.closed && c.generation == generation {
				if err != nil {
					c.status.State, c.status.Code, c.status.ConnectedAt = "reconnecting", "proxy_unreachable", 0
				} else if c.status.State != "connected" {
					c.status.State, c.status.Code, c.status.ConnectedAt = "connected", "https_verified", time.Now().Unix()
				}
			}
			c.mu.Unlock()
		}
		c.ops.Unlock()
	}
}
