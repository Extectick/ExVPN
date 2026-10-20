// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"context"
	"encoding/json"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

// Site policy is local user-owned state, separate from subscription profiles
// and from the legacy application exclusion document.
type SiteRoutingStore interface {
	LoadSiteRouting() (exvpn.SiteRoutingState, error)
	SaveSiteRouting(exvpn.SiteRoutingState) error
}

const maxSitePolicyBytes = (512 << 10) + 2048

type sitePolicyDocument struct {
	Version int                    `json:"version"`
	Owner   string                 `json:"owner"`
	State   exvpn.SiteRoutingState `json:"state"`
}

func encodeSitePolicy(owner string, state exvpn.SiteRoutingState) ([]byte, error) {
	if owner == "" || state.Validate() != nil {
		return nil, Code("site_routing_rejected")
	}
	b, err := json.Marshal(sitePolicyDocument{Version: 1, Owner: owner, State: state.Clone()})
	if err != nil || len(b) > maxSitePolicyBytes {
		return nil, Code("site_routing_rejected")
	}
	return b, nil
}

func decodeSitePolicy(owner string, b []byte) (exvpn.SiteRoutingState, error) {
	if len(b) == 0 || len(b) > maxSitePolicyBytes || checkJSON(b) != nil {
		return exvpn.SiteRoutingState{}, Code("site_routing_unavailable")
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(b, &fields) != nil || len(fields) != 3 || fields["version"] == nil || fields["owner"] == nil || fields["state"] == nil {
		return exvpn.SiteRoutingState{}, Code("site_routing_unavailable")
	}
	var doc struct {
		Version int             `json:"version"`
		Owner   string          `json:"owner"`
		State   json.RawMessage `json:"state"`
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if d.Decode(&doc) != nil || doc.Version != 1 || owner == "" || doc.Owner != owner {
		return exvpn.SiteRoutingState{}, Code("site_routing_unavailable")
	}
	state, err := exvpn.DecodeSiteRoutingState(doc.State)
	if err != nil {
		return exvpn.SiteRoutingState{}, Code("site_routing_unavailable")
	}
	return state, nil
}

func (unavailablePolicyStore) LoadSiteRouting() (exvpn.SiteRoutingState, error) {
	return exvpn.SiteRoutingState{}, Code("site_routing_unavailable")
}
func (unavailablePolicyStore) SaveSiteRouting(exvpn.SiteRoutingState) error {
	return Code("native_storage_unavailable")
}

func (c *Controller) initializeSiteRouting(policy PolicyStore, recoveredGuard bool) {
	c.siteRouting, c.siteRoutingKnown = exvpn.DefaultSiteRoutingState(), true
	store, ok := policy.(SiteRoutingStore)
	if !ok {
		// Legacy synthetic stores cannot claim this optional capability.
		return
	}
	c.siteStore = store
	state, err := store.LoadSiteRouting()
	if err == policyMissing && !recoveredGuard {
		state = exvpn.DefaultSiteRoutingState()
		err = store.SaveSiteRouting(state)
	}
	if err != nil || state.Validate() != nil {
		c.siteRoutingKnown = false
		if !recoveredGuard && c.status.State != "error" {
			c.status.State, c.status.Code = "error", "site_routing_unavailable"
		}
		return
	}
	c.siteRouting = state.Clone()
}

func (c *Controller) getSiteRouting() (exvpn.SiteRoutingState, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.siteStore == nil {
		return exvpn.SiteRoutingState{}, Code("site_routing_unavailable")
	}
	if !c.siteRoutingKnown {
		return exvpn.SiteRoutingState{}, Code("site_routing_unavailable")
	}
	return c.siteRouting.Clone(), nil
}

func (c *Controller) setSiteRouting(state exvpn.SiteRoutingState) error {
	if !c.ops.TryLock() {
		return Code("site_routing_requires_disconnected")
	}
	defer c.ops.Unlock()
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.cancel != nil || c.tunnel != nil || c.stopping != 0 {
		return Code("site_routing_requires_disconnected")
	}
	if c.siteStore == nil {
		return Code("site_routing_unavailable")
	}
	if state.Validate() != nil {
		return Code("site_routing_rejected")
	}
	if c.siteStore.SaveSiteRouting(state.Clone()) != nil {
		// A failed flush/readback has an unknown durable result. Do not
		// silently acknowledge an in-memory policy or start a new lifetime.
		c.siteRoutingKnown = false
		return Code("native_storage_unavailable")
	}
	c.siteRouting, c.siteRoutingKnown = state.Clone(), true
	if !c.status.GuardActive && c.status.State == "error" && c.status.Code == "site_routing_unavailable" {
		c.status.State, c.status.Code = "disconnected", "policy_restored"
	}
	return nil
}

type siteRoutingContextKey struct{}

func siteRoutingFromContext(ctx context.Context) exvpn.SiteRoutingPolicy {
	if policy, ok := ctx.Value(siteRoutingContextKey{}).(exvpn.SiteRoutingPolicy); ok {
		return exvpn.SiteRoutingPolicy{Mode: policy.Mode, Rules: append([]string{}, policy.Rules...)}
	}
	return exvpn.DefaultSiteRoutingState().Policy
}
