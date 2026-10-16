//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"encoding/binary"
	"os"
	"runtime"
	"unsafe"

	"golang.org/x/sys/windows"
)

var fieldRemoteAddress = guid("{B235AE9A-1D64-49B8-A44C-5FF3D9095045}")
var fieldRemotePort = guid("{C35A604D-D22B-4E1A-91B4-68F674EE674B}")
var fieldProtocol = guid("{3971EF2B-623E-4F9A-8CB1-6E79B806B9A7}")

// This permit exists only while resolving the selected VPN endpoint. It does
// not grant physical egress to DNS Client, the UI, exclusions, or other apps.
// The peer, protocol and port are fixed local policy, never subscription data.
func (g *WindowsGuard) beginBootstrap(luid uint64) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if luid == 0 || g.bootstrap != 0 || g.permits != 0 {
		return Code("guard_invalid_lifetime")
	}
	h, err := openWFP(true)
	if err != nil {
		return err
	}
	g.bootstrap = h
	err = transaction(h, func() error {
		// Require all four persistent blocking layers before any temporary permit.
		for i := range guardLayers {
			key := guardKey(i)
			var filter *wfpFilter
			if e := wfpCall(wfpGet, uintptr(h), uintptr(unsafe.Pointer(&key)), uintptr(unsafe.Pointer(&filter))); e != nil {
				return e
			}
			_ = wfpCall(wfpFree, uintptr(unsafe.Pointer(&filter)))
		}
		exe, e := os.Executable()
		if e != nil {
			return e
		}
		path, e := windows.UTF16PtrFromString(exe)
		if e != nil {
			return e
		}
		var app *wfpBlob
		if e = wfpCall(wfpAppID, uintptr(unsafe.Pointer(path)), uintptr(unsafe.Pointer(&app))); e != nil {
			return e
		}
		defer wfpCall(wfpFree, uintptr(unsafe.Pointer(&app)))
		sd, e := windows.SecurityDescriptorFromString("O:SYG:SYD:(A;;CCRC;;;SY)")
		if e != nil {
			return e
		}
		user := wfpBlob{Size: sd.Length(), Data: (*byte)(unsafe.Pointer(sd))}
		address := bootstrapResolverIP.As4()
		var pin runtime.Pinner
		pin.Pin(&luid)
		pin.Pin(&user)
		defer pin.Unpin()
		for _, layerIndex := range []int{0, 2} {
			direction := fieldNextInterface
			if layerIndex == 2 {
				direction = fieldArrivalInterface
			}
			conditions := []wfpCondition{
				{Field: fieldAppID, Value: wfpValue{Type: 12, Value: uintptr(unsafe.Pointer(app))}},
				{Field: fieldUserID, Value: wfpValue{Type: 14, Value: uintptr(unsafe.Pointer(&user))}},
				{Field: fieldRemoteAddress, Value: wfpValue{Type: 3, Value: uintptr(binary.BigEndian.Uint32(address[:]))}},
				{Field: fieldRemotePort, Value: wfpValue{Type: 2, Value: 443}},
				{Field: fieldProtocol, Value: wfpValue{Type: 1, Value: 6}},
				{Field: fieldLocalInterface, Value: wfpValue{Type: 4, Value: uintptr(unsafe.Pointer(&luid))}},
				{Field: direction, Value: wfpValue{Type: 4, Value: uintptr(unsafe.Pointer(&luid))}},
			}
			if e := addGuardFilter(h, 16+layerIndex, guardLayers[layerIndex], false, 8, wfpPermit, conditions); e != nil {
				return e
			}
		}
		runtime.KeepAlive(sd)
		runtime.KeepAlive(path)
		return nil
	})
	if err != nil {
		if closeErr := wfpCall(wfpClose, uintptr(h)); closeErr == nil {
			g.bootstrap = 0
		}
		// A failed close retains the handle for Suspend; no broad permit follows.
	}
	return err
}

func (g *WindowsGuard) endBootstrap() error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.bootstrap == 0 {
		return nil
	}
	if err := wfpCall(wfpClose, uintptr(g.bootstrap)); err != nil {
		return err
	}
	g.bootstrap = 0
	return nil
}
