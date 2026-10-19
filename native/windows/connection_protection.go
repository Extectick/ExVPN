// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"encoding/json"
)

type ConnectionProtection struct {
	Supported     bool `json:"supported"`
	Enabled       bool `json:"enabled"`
	Active        bool `json:"active"`
	SystemManaged bool `json:"systemManaged"`
}

type ConnectionProtectionStore interface {
	LoadProtection() (bool, error)
	SaveProtection(bool) error
}

// Configuring the next lifetime never removes an already armed guard. Only an
// explicit disconnected transition may change the preference.
type connectionProtectionGuard interface {
	ConfigurePersistentProtection(bool) error
	PersistentArmed() (bool, error)
}

func (unavailablePolicyStore) LoadProtection() (bool, error) {
	return true, Code("connection_protection_unavailable")
}
func (unavailablePolicyStore) SaveProtection(bool) error { return Code("native_storage_unavailable") }

func encodeConnectionProtection(owner string, enabled bool) ([]byte, error) {
	return json.Marshal(struct {
		Version int    `json:"version"`
		Owner   string `json:"owner"`
		Enabled bool   `json:"enabled"`
	}{1, owner, enabled})
}

func decodeConnectionProtection(owner string, b []byte) (bool, error) {
	if len(b) == 0 || len(b) > 4096 || checkJSON(b) != nil {
		return true, Code("connection_protection_unavailable")
	}
	var doc struct {
		Version int    `json:"version"`
		Owner   string `json:"owner"`
		Enabled *bool  `json:"enabled"`
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if d.Decode(&doc) != nil || doc.Version != 1 || doc.Owner != owner || doc.Enabled == nil {
		return true, Code("connection_protection_unavailable")
	}
	return *doc.Enabled, nil
}

func (c *Controller) initializeConnectionProtection(policy PolicyStore) {
	c.protectionEnabled, c.protectionKnown = true, true
	if store, ok := policy.(ConnectionProtectionStore); ok {
		c.protectionStore = store
		enabled, err := store.LoadProtection()
		if err == policyMissing {
			enabled, err = true, store.SaveProtection(true)
		}
		if err != nil {
			c.protectionKnown = false
		} else {
			c.protectionEnabled = enabled
		}
	}
	if guard, ok := c.guard.(connectionProtectionGuard); ok {
		if guard.ConfigurePersistentProtection(c.protectionEnabled) != nil {
			c.protectionKnown = false
		}
	}
}

func (c *Controller) ConnectionProtection() (ConnectionProtection, error) {
	if !c.ops.TryLock() {
		return ConnectionProtection{}, Code("operation_in_progress")
	}
	defer c.ops.Unlock()
	c.mu.Lock()
	defer c.mu.Unlock()
	guard, supported := c.guard.(connectionProtectionGuard)
	value := ConnectionProtection{Supported: supported, Enabled: c.protectionEnabled}
	if !c.protectionKnown {
		return value, Code("connection_protection_unavailable")
	}
	if supported {
		active, err := guard.PersistentArmed()
		if err != nil {
			return value, Code("connection_protection_unavailable")
		}
		value.Active = active && c.status.Mode == ModeVPN
	}
	return value, nil
}

func (c *Controller) SetConnectionProtection(enabled bool) error {
	if !c.ops.TryLock() {
		return Code("connection_protection_requires_disconnected")
	}
	defer c.ops.Unlock()
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return Code("service_stopping")
	}
	if c.stopping != 0 || c.cancel != nil || c.tunnel != nil || c.status.State != "disconnected" || c.status.GuardActive || c.status.ProxyPort != 0 || c.status.AutomaticSelection {
		return Code("connection_protection_requires_disconnected")
	}
	guard, ok := c.guard.(connectionProtectionGuard)
	if !ok {
		return Code("unsupported")
	}
	armed, err := c.guard.Armed()
	if err != nil {
		return Code("connection_protection_unavailable")
	}
	if armed {
		return Code("connection_protection_requires_disconnected")
	}
	if err = guard.ConfigurePersistentProtection(enabled); err != nil {
		return Code("connection_protection_unavailable")
	}
	if c.protectionStore != nil {
		if err = c.protectionStore.SaveProtection(enabled); err != nil {
			// A failed write/flush has no confirmed durable result. Never treat
			// it as consent to an unprotected new connection.
			c.protectionKnown, c.protectionEnabled = false, true
			_ = guard.ConfigurePersistentProtection(true)
			return Code("native_storage_unavailable")
		}
	}
	c.protectionEnabled, c.protectionKnown = enabled, true
	return nil
}
