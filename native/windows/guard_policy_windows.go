//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"runtime"
	"unsafe"

	"golang.org/x/sys/windows"
)

type guardInspection struct{ any, persistent, volatile bool }

// Injectable only inside this package's pure tests. The installed service
// always uses nativeGuardPolicy and never accepts handles or rules over IPC.
type guardPolicyBackend interface {
	inspect() (guardInspection, error)
	ensureSublayer() error
	open(bool) (windows.Handle, error)
	close(windows.Handle) error
	replace(windows.Handle, bool) error
	remove() error
}

func (g *WindowsGuard) policyBackend() guardPolicyBackend {
	if g.policy != nil {
		return g.policy
	}
	return nativeGuardPolicy{}
}

func (g *WindowsGuard) ConfigurePersistentProtection(enabled bool) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.blocks != 0 || g.permits != 0 || g.bootstrap != 0 {
		return Code("guard_invalid_lifetime")
	}
	g.volatile = !enabled
	return nil
}

func (g *WindowsGuard) PersistentArmed() (bool, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	state, err := g.policyBackend().inspect()
	return state.persistent, err
}

func (g *WindowsGuard) armPolicy() error {
	backend := g.policyBackend()
	if !g.volatile && g.blocks != 0 {
		return Code("guard_invalid_lifetime")
	}
	if g.volatile {
		state, err := backend.inspect()
		if err != nil {
			return err
		}
		if g.blocks != 0 {
			if state.volatile {
				return nil // Reconnect keeps the same live blocking lifetime.
			}
			return Code("guard_inspection_failed")
		}
		if state.any {
			// A recovered persistent/unknown latch is never silently released
			// by a stored OFF preference. Explicit disconnect is required.
			return Code("guard_recovery_required")
		}
	}
	if err := backend.ensureSublayer(); err != nil {
		return err
	}
	handle, err := backend.open(g.volatile)
	if err != nil {
		return err
	}
	if err = backend.replace(handle, !g.volatile); err != nil {
		if backend.close(handle) != nil {
			g.blocks = handle
		}
		return err
	}
	if g.volatile {
		g.blocks = handle // Held independently of temporary tunnel permits.
		return nil
	}
	if err = backend.close(handle); err != nil {
		g.blocks = handle // Preserve ownership for explicit cleanup/retry.
	}
	return err // Persistent objects survive a successful session close.
}

type nativeGuardPolicy struct{}

func (nativeGuardPolicy) open(dynamic bool) (windows.Handle, error) { return openWFP(dynamic) }
func (nativeGuardPolicy) close(h windows.Handle) error              { return wfpCall(wfpClose, uintptr(h)) }
func (nativeGuardPolicy) inspect() (guardInspection, error) {
	h, err := openWFP(false)
	if err != nil {
		return guardInspection{}, err
	}
	defer wfpCall(wfpClose, uintptr(h))
	state := guardInspection{persistent: true, volatile: true}
	for i, layer := range guardLayers {
		key := guardKey(i)
		var filter *wfpFilter
		err = wfpCall(wfpGet, uintptr(h), uintptr(unsafe.Pointer(&key)), uintptr(unsafe.Pointer(&filter)))
		if err == windows.Errno(wfpFilterNotFound) {
			state.persistent, state.volatile = false, false
			continue
		}
		if err != nil {
			return guardInspection{}, err
		}
		state.any = true
		valid := filter != nil && filter.Layer == layer && filter.Sublayer == guardSublayer && filter.Action.Type == wfpBlock && filter.Flags&0x20 == 0
		state.persistent = state.persistent && valid && filter.Flags&wfpPersistent != 0
		state.volatile = state.volatile && valid && filter.Flags&wfpPersistent == 0
		_ = wfpCall(wfpFree, uintptr(unsafe.Pointer(&filter)))
	}
	return state, nil
}

func (nativeGuardPolicy) ensureSublayer() error {
	h, err := openWFP(false)
	if err != nil {
		return err
	}
	defer wfpCall(wfpClose, uintptr(h))
	return transaction(h, func() error {
		s := wfpSublayer{Key: guardSublayer, Display: wfpDisplay{Name: utf16("ExVPN guard")}, Flags: wfpPersistent, Weight: 0xff00}
		err := wfpCall(wfpAddSublayer, uintptr(h), uintptr(unsafe.Pointer(&s)), 0)
		runtime.KeepAlive(s)
		if err == windows.Errno(wfpAlreadyExists) {
			return nil
		}
		return err
	})
}

func (nativeGuardPolicy) replace(h windows.Handle, persistent bool) error {
	return transaction(h, func() error {
		if persistent {
			for i := 0; i < 8; i++ {
				if err := deleteGuardFilter(h, i); err != nil {
					return err
				}
			}
		}
		for i, layer := range guardLayers {
			if err := addGuardFilter(h, i, layer, persistent, 0, wfpBlock, nil); err != nil {
				return err
			}
			loopback := []wfpCondition{{Field: fieldFlags, Match: 6, Value: wfpValue{Type: 3, Value: 1}}}
			if err := addGuardFilter(h, i+4, layer, persistent, 1, wfpPermit, loopback); err != nil {
				return err
			}
		}
		return nil
	})
}

func (nativeGuardPolicy) remove() error {
	h, err := openWFP(false)
	if err != nil {
		return err
	}
	defer wfpCall(wfpClose, uintptr(h))
	return transaction(h, func() error {
		for i := 0; i < 8; i++ {
			if err := deleteGuardFilter(h, i); err != nil {
				return err
			}
		}
		err := wfpCall(wfpDeleteSublayer, uintptr(h), uintptr(unsafe.Pointer(&guardSublayer)))
		if err == windows.Errno(wfpSublayerNotFound) {
			return nil
		}
		return err
	})
}
