//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"errors"
	"testing"

	"golang.org/x/sys/windows"
)

// A WFP lifetime model. No Windows/BFE API, registry, service or socket is used.
type protectionGuardBackend struct {
	state                                    guardInspection
	handles                                  map[windows.Handle]bool
	next                                     windows.Handle
	closeFailure, addFailure, inspectFailure bool
	removed                                  int
}

func (b *protectionGuardBackend) inspect() (guardInspection, error) {
	if b.inspectFailure {
		return guardInspection{}, errors.New("inspect")
	}
	return b.state, nil
}
func (b *protectionGuardBackend) ensureSublayer() error { return nil }
func (b *protectionGuardBackend) open(dynamic bool) (windows.Handle, error) {
	if b.handles == nil {
		b.handles = map[windows.Handle]bool{}
	}
	b.next++
	b.handles[b.next] = dynamic
	return b.next, nil
}
func (b *protectionGuardBackend) close(h windows.Handle) error {
	if b.closeFailure {
		return errors.New("close")
	}
	if b.handles[h] {
		b.state = guardInspection{}
	}
	delete(b.handles, h)
	return nil
}
func (b *protectionGuardBackend) replace(h windows.Handle, persistent bool) error {
	if b.addFailure {
		return errors.New("arm")
	}
	if b.handles[h] == persistent {
		return errors.New("wrong engine/filter lifetime")
	}
	b.state = guardInspection{any: true, persistent: persistent, volatile: !persistent}
	return nil
}
func (b *protectionGuardBackend) remove() error { b.removed++; b.state = guardInspection{}; return nil }

func TestConnectionProtectionGuardPersistentDefaultAndDynamicOffLifetime(t *testing.T) {
	for _, enabled := range []bool{true, false} {
		b := &protectionGuardBackend{}
		g := &WindowsGuard{policy: b}
		if !enabled {
			if err := g.ConfigurePersistentProtection(false); err != nil {
				t.Fatal(err)
			}
		}
		if err := g.Arm(); err != nil {
			t.Fatal(err)
		}
		armed, _ := g.Armed()
		persistent, _ := g.PersistentArmed()
		if !armed || persistent != enabled {
			t.Fatal("guard lifetime does not match explicit preference")
		}
		if err := g.Suspend(); err != nil {
			t.Fatal(err)
		}
		if !b.state.any {
			t.Fatal("suspend removed live blocking protection")
		}
		if !enabled {
			handle := g.blocks
			if handle == 0 || len(b.handles) != 1 {
				t.Fatal("dynamic blocks not owned independently")
			}
			if err := g.Arm(); err != nil || g.blocks != handle {
				t.Fatal("reconnect replaced live block lifetime")
			}
			if err := g.ConfigurePersistentProtection(true); err == nil {
				t.Fatal("active mode changed")
			}
			// Equivalent to OS rundown of the owned dynamic engine on process death.
			if err := b.close(handle); err != nil {
				t.Fatal(err)
			}
			if b.state.any {
				t.Fatal("OFF falsely persists after process lifetime")
			}
			g.blocks = 0
		} else if len(b.handles) != 0 || !b.state.persistent {
			t.Fatal("default persistent blocks lost on engine close")
		}
		if err := g.Disarm(); err != nil || b.state.any {
			t.Fatal("explicit disconnect failed")
		}
	}
}

func TestConnectionProtectionGuardOffNeverReleasesRecoveredOrPartialProtection(t *testing.T) {
	for _, state := range []guardInspection{{any: true, persistent: true}, {any: true}} {
		b := &protectionGuardBackend{state: state}
		g := &WindowsGuard{policy: b}
		if err := g.ConfigurePersistentProtection(false); err != nil {
			t.Fatal(err)
		}
		if err := g.Arm(); err != Code("guard_recovery_required") {
			t.Fatal("OFF released recovered state")
		}
		if b.removed != 0 || !b.state.any {
			t.Fatal("recovered filters altered")
		}
	}
}

func TestConnectionProtectionRecoveredPersistentGuardWithStoredOff(t *testing.T) {
	b := &protectionGuardBackend{state: guardInspection{any: true, persistent: true}}
	g := &WindowsGuard{policy: b}
	store := &protectionMemoryStore{enabled: false}
	c, err := NewControllerWithPolicy(g, nil, nil, true, store)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Shutdown() })
	value, err := c.ConnectionProtection()
	if err != nil || !value.Supported || value.Enabled || !value.Active || value.SystemManaged {
		t.Fatalf("stored preference hid actual recovered protection: %+v %v", value, err)
	}
	status := c.Status()
	if status.State != "blocked" || status.Code != "guard_recovered" || !status.GuardActive || !status.PersistentGuardActive {
		t.Fatal("recovered guard was not reported independently of preference")
	}
	for _, enabled := range []bool{false, true} {
		if err := c.SetConnectionProtection(enabled); err != Code("connection_protection_requires_disconnected") {
			t.Fatal("recovered guard allowed a preference change")
		}
	}
	if b.removed != 0 || !b.state.persistent || !b.state.any || len(b.handles) != 0 || store.protectionSaves != 0 || store.enabled {
		t.Fatal("snapshot or refused setter changed recovered filters or preference")
	}
}

func TestConnectionProtectionGuardFailuresRetainOwnedCleanupAndDenyPermitRemoval(t *testing.T) {
	b := &protectionGuardBackend{addFailure: true, closeFailure: true}
	g := &WindowsGuard{policy: b}
	_ = g.ConfigurePersistentProtection(false)
	if err := g.Arm(); err == nil || g.blocks == 0 {
		t.Fatal("failed dynamic cleanup lost ownership")
	}
	if err := g.Disarm(); err == nil || g.blocks == 0 {
		t.Fatal("failed close incorrectly forgot blocks")
	}
	b.closeFailure = false
	if err := g.Disarm(); err != nil || g.blocks != 0 {
		t.Fatal("explicit cleanup retry failed")
	}
	g.permits = 99
	if err := g.Disarm(); err != Code("guard_permits_active") {
		t.Fatal("blocks removed while permits live")
	}
	g.permits = 0
	b.inspectFailure = true
	if _, err := g.PersistentArmed(); err == nil {
		t.Fatal("query failure converted into trusted state")
	}
}
