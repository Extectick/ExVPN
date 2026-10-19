// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"context"
	"encoding/json"
	"reflect"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

// Candidates are normalized profiles selected by local UI, not provider routing,
// arbitrary outbounds, observer destinations or a permission to go direct.
func decodeAutomaticProfiles(selected exvpn.Profile, input []json.RawMessage) ([]exvpn.Profile, error) {
	if input == nil {
		return nil, nil
	}
	if len(input) == 0 || len(input) > 32 || selected.ID == "" {
		return nil, Code("automatic_group_rejected")
	}
	seen := map[string]bool{}
	group := make([]exvpn.Profile, 0, len(input))
	matched := false
	for _, raw := range input {
		p, err := exvpn.DecodeProfile(bytes.NewReader(raw))
		if err != nil || p.ID == "" || seen[p.ID] {
			return nil, Code("automatic_group_rejected")
		}
		seen[p.ID] = true
		if p.ID == selected.ID {
			if !reflect.DeepEqual(p, selected) {
				return nil, Code("automatic_group_rejected")
			}
			matched = true
		}
		group = append(group, p)
	}
	if !matched {
		return nil, Code("automatic_group_rejected")
	}
	return group, nil
}

func (c *Controller) clearAutomaticLocked() {
	c.automaticEpoch++
	if c.automaticCancel != nil {
		c.automaticCancel()
		c.automaticCancel = nil
	}
	c.status.AutomaticSelection = false
}

func automaticTransportFailure(code string) bool {
	switch code {
	case "tunnel_unreachable", "transport_unreachable", "proxy_unreachable", "bootstrap_https_failed", "bootstrap_no_addresses":
		return true
	}
	return false
}

// Service-owned supervision survives UI closure. One bounded native attempt is
// active at a time. A failed sweep backs off; a healthy peer is kept rather than
// chased by small ping differences. Security/config/storage errors halt the group.
func (c *Controller) runAutomatic(ctx context.Context, epoch uint64, group []exvpn.Profile, mode string) {
	ticker := time.NewTicker(c.automaticPoll)
	defer ticker.Stop()
	failures := 0
	var observedFailureGeneration uint64
	nextAllowed := time.Time{}
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		c.mu.Lock()
		if c.closed || c.stopping != 0 || c.automaticEpoch != epoch || !c.status.AutomaticSelection {
			c.mu.Unlock()
			return
		}
		state, code, active, generation := c.status.State, c.status.Code, c.status.ActiveProfileID, c.generation
		if state == "connected" {
			failures = 0
			observedFailureGeneration = 0
			nextAllowed = time.Time{}
			c.mu.Unlock()
			continue
		}
		if state == "connecting" {
			c.mu.Unlock()
			continue
		}
		if !automaticTransportFailure(code) {
			c.clearAutomaticLocked()
			c.mu.Unlock()
			return
		}
		c.mu.Unlock()
		if observedFailureGeneration != generation {
			observedFailureGeneration = generation
			failures++
			if failures >= len(group) {
				nextAllowed = time.Now().Add(c.automaticCooldown)
				failures = 0
			}
		}
		if time.Now().Before(nextAllowed) {
			continue
		}
		index := 0
		for i, p := range group {
			if p.ID == active {
				index = (i + 1) % len(group)
				break
			}
		}
		if err := c.connectInModeAutomatic(group[index], nil, true, mode, true, nil, epoch, generation); err != nil {
			c.mu.Lock()
			if c.automaticEpoch == epoch {
				c.clearAutomaticLocked()
			}
			c.mu.Unlock()
			return
		}
	}
}
