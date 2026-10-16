//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"os"
	"runtime"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Win32 ABI definitions from fwptypes.h/fwpmtypes.h (Microsoft SDK).
// These are deliberately x64-only; struct layout is covered by ABI tests.
type wfpValue struct {
	Type  uint32
	Value uintptr
}
type wfpBlob struct {
	Size uint32
	Data *byte
}
type wfpDisplay struct{ Name, Description *uint16 }
type wfpSession struct {
	Key                 windows.GUID
	Display             wfpDisplay
	Flags, Timeout, PID uint32
	SID                 *windows.SID
	Username            *uint16
	Kernel              int32
}
type wfpSublayer struct {
	Key      windows.GUID
	Display  wfpDisplay
	Flags    uint32
	Provider *windows.GUID
	Data     wfpBlob
	Weight   uint16
}
type wfpCondition struct {
	Field windows.GUID
	Match uint32
	Value wfpValue
}
type wfpAction struct {
	Type uint32
	Key  windows.GUID
}
type wfpFilter struct {
	Key             windows.GUID
	Display         wfpDisplay
	Flags           uint32
	Provider        *windows.GUID
	Data            wfpBlob
	Layer, Sublayer windows.GUID
	Weight          wfpValue
	Count           uint32
	Conditions      *wfpCondition
	Action          wfpAction
	_               uint32
	Context         windows.GUID
	Reserved        *windows.GUID
	ID              uint64
	EffectiveWeight wfpValue
}

var wfpDLL = windows.NewLazySystemDLL("fwpuclnt.dll")
var wfpOpen = wfpDLL.NewProc("FwpmEngineOpen0")
var wfpClose = wfpDLL.NewProc("FwpmEngineClose0")
var wfpBegin = wfpDLL.NewProc("FwpmTransactionBegin0")
var wfpCommit = wfpDLL.NewProc("FwpmTransactionCommit0")
var wfpAbort = wfpDLL.NewProc("FwpmTransactionAbort0")
var wfpAddSublayer = wfpDLL.NewProc("FwpmSubLayerAdd0")
var wfpDeleteSublayer = wfpDLL.NewProc("FwpmSubLayerDeleteByKey0")
var wfpAdd = wfpDLL.NewProc("FwpmFilterAdd0")
var wfpDelete = wfpDLL.NewProc("FwpmFilterDeleteByKey0")
var wfpGet = wfpDLL.NewProc("FwpmFilterGetByKey0")
var wfpAppID = wfpDLL.NewProc("FwpmGetAppIdFromFileName0")
var wfpFree = wfpDLL.NewProc("FwpmFreeMemory0")

func guid(s string) windows.GUID {
	g, e := windows.GUIDFromString(s)
	if e != nil {
		panic("invalid static WFP GUID")
	}
	return g
}

var guardSublayer = guid("{A6925C6A-74D5-453E-B38C-BA7F26FE7547}")
var guardLayers = []windows.GUID{
	guid("{C38D57D1-05A7-4C33-904F-7FBCEEE60E82}"), // ALE_AUTH_CONNECT_V4
	guid("{4A72393B-319F-44BC-84C3-BA54DCB3B6B4}"), // ALE_AUTH_CONNECT_V6
	guid("{E1CD9FE7-F4B5-4273-96C0-592E487B8650}"), // ALE_AUTH_RECV_ACCEPT_V4
	guid("{A3B42C97-9F04-4672-B87E-CEE9C483257F}"), // ALE_AUTH_RECV_ACCEPT_V6
}
var fieldFlags = guid("{632CE23B-5167-435C-86D7-E9036848AA8C}")
var fieldAppID = guid("{D78E1E87-8644-4EA5-9437-D809ECEFC971}")
var fieldUserID = guid("{AF043A0A-B34D-4F86-979C-C90E9FCB6E66}")
var fieldLocalInterface = guid("{4CD62A49-59C3-4969-B7F3-BDA5D32890A4}")
var fieldNextInterface = guid("{93AE8F5B-7F6F-4719-98C8-14E9A74D1F04}")
var fieldArrivalInterface = guid("{618A9B6D-386B-4136-AD6E-B51587CFB1CD}")

const wfpPersistent = 1
const wfpDynamic = 1
const wfpBlock = 0x1001
const wfpPermit = 0x1002
const wfpAlreadyExists = 0x80320009
const wfpFilterNotFound = 0x80320003
const wfpSublayerNotFound = 0x80320007

// The keys name only ExVPN resources. Recovery never enumerates/deletes other
// providers' rules or resets Windows Firewall.
func guardKey(index int) windows.GUID {
	g := guid("{A6925C6B-74D5-453E-B38C-BA7F26FE7500}")
	g.Data4[7] = byte(index + 1)
	return g
}
func utf16(s string) *uint16 { p, _ := windows.UTF16PtrFromString(s); return p }
func wfpCall(proc *windows.LazyProc, args ...uintptr) error {
	r, _, _ := proc.Call(args...)
	return wfpResult(r)
}
func wfpResult(r uintptr) error {
	// Fwpm APIs return a DWORD, not a pointer-sized value. On x64 Windows
	// FwpmFilterGetByKey0 can sign-extend failure codes into RAX. Only the low
	// 32 bits belong to the result; preserve comparisons with FWP_E_* codes.
	code := uint32(r)
	if code != 0 {
		return windows.Errno(code)
	}
	return nil
}
func openWFP(dynamic bool) (windows.Handle, error) {
	var h windows.Handle
	s := wfpSession{Display: wfpDisplay{Name: utf16("ExVPN guard")}}
	if dynamic {
		s.Flags = wfpDynamic
	}
	e := wfpCall(wfpOpen, 0, 10, 0, uintptr(unsafe.Pointer(&s)), uintptr(unsafe.Pointer(&h)))
	runtime.KeepAlive(s)
	return h, e
}
func transaction(h windows.Handle, f func() error) error {
	if e := wfpCall(wfpBegin, uintptr(h), 0); e != nil {
		return e
	}
	if e := f(); e != nil {
		_ = wfpCall(wfpAbort, uintptr(h))
		return e
	}
	if e := wfpCall(wfpCommit, uintptr(h)); e != nil {
		_ = wfpCall(wfpAbort, uintptr(h))
		return e
	}
	return nil
}
func deleteGuardFilter(h windows.Handle, index int) error {
	k := guardKey(index)
	e := wfpCall(wfpDelete, uintptr(h), uintptr(unsafe.Pointer(&k)))
	if e == windows.Errno(wfpFilterNotFound) {
		return nil
	}
	return e
}
func addGuardFilter(h windows.Handle, index int, layer windows.GUID, persistent bool, weight uintptr, action uint32, conditions []wfpCondition) error {
	f := wfpFilter{Key: guardKey(index), Display: wfpDisplay{Name: utf16("ExVPN network guard")}, Layer: layer, Sublayer: guardSublayer, Weight: wfpValue{Type: 1, Value: weight}, Action: wfpAction{Type: action}, Count: uint32(len(conditions))}
	if persistent {
		f.Flags = wfpPersistent
	}
	if len(conditions) > 0 {
		f.Conditions = &conditions[0]
	}
	e := wfpCall(wfpAdd, uintptr(h), uintptr(unsafe.Pointer(&f)), 0, 0)
	runtime.KeepAlive(conditions)
	runtime.KeepAlive(f)
	return e
}

type WindowsGuard struct {
	mu      sync.Mutex
	permits windows.Handle
}

func (g *WindowsGuard) Armed() (bool, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	h, e := openWFP(false)
	if e != nil {
		return false, e
	}
	defer wfpCall(wfpClose, uintptr(h))
	for i := 0; i < 4; i++ {
		k := guardKey(i)
		var f *wfpFilter
		e = wfpCall(wfpGet, uintptr(h), uintptr(unsafe.Pointer(&k)), uintptr(unsafe.Pointer(&f)))
		if e == nil {
			_ = wfpCall(wfpFree, uintptr(unsafe.Pointer(&f)))
			return true, nil
		}
		if e != windows.Errno(wfpFilterNotFound) {
			return false, e
		}
	}
	return false, nil
}
func (g *WindowsGuard) Arm() error {
	g.mu.Lock()
	defer g.mu.Unlock()
	h, e := openWFP(false)
	if e != nil {
		return e
	}
	defer wfpCall(wfpClose, uintptr(h))
	return transaction(h, func() error {
		s := wfpSublayer{Key: guardSublayer, Display: wfpDisplay{Name: utf16("ExVPN persistent guard")}, Flags: wfpPersistent, Weight: 0xff00}
		e := wfpCall(wfpAddSublayer, uintptr(h), uintptr(unsafe.Pointer(&s)), 0)
		runtime.KeepAlive(s)
		if e != nil && e != windows.Errno(wfpAlreadyExists) {
			return e
		}
		for i := 0; i < 8; i++ {
			if e := deleteGuardFilter(h, i); e != nil {
				return e
			}
		}
		for i, layer := range guardLayers {
			if e := addGuardFilter(h, i, layer, true, 0, wfpBlock, nil); e != nil {
				return e
			}
			loopback := []wfpCondition{{Field: fieldFlags, Match: 6, Value: wfpValue{Type: 3, Value: 1}}}
			if e := addGuardFilter(h, i+4, layer, true, 1, wfpPermit, loopback); e != nil {
				return e
			}
		}
		return nil
	})
}
func (g *WindowsGuard) PermitTunnel(luid uint64) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if luid == 0 || g.permits != 0 {
		return Code("guard_invalid_lifetime")
	}
	h, e := openWFP(true)
	if e != nil {
		return e
	}
	exe, e := os.Executable()
	if e != nil {
		_ = wfpCall(wfpClose, uintptr(h))
		return e
	}
	path, e := windows.UTF16PtrFromString(exe)
	if e != nil {
		_ = wfpCall(wfpClose, uintptr(h))
		return e
	}
	var app *wfpBlob
	if e = wfpCall(wfpAppID, uintptr(unsafe.Pointer(path)), uintptr(unsafe.Pointer(&app))); e != nil {
		_ = wfpCall(wfpClose, uintptr(h))
		return e
	}
	defer wfpCall(wfpFree, uintptr(unsafe.Pointer(&app)))
	// App-ID alone is insufficient: an ordinary user launching this executable
	// must not inherit the privileged core's physical-interface permit.
	sd, e := windows.SecurityDescriptorFromString("O:SYG:SYD:(A;;CCRC;;;SY)")
	if e != nil {
		_ = wfpCall(wfpClose, uintptr(h))
		return e
	}
	user := wfpBlob{Size: sd.Length(), Data: (*byte)(unsafe.Pointer(sd))}
	var pin runtime.Pinner
	pin.Pin(&luid)
	pin.Pin(&user)
	defer pin.Unpin()
	e = transaction(h, func() error {
		for i, layer := range guardLayers {
			self := []wfpCondition{{Field: fieldAppID, Value: wfpValue{Type: 12, Value: uintptr(unsafe.Pointer(app))}}, {Field: fieldUserID, Value: wfpValue{Type: 14, Value: uintptr(unsafe.Pointer(&user))}}}
			if e := addGuardFilter(h, i+8, layer, false, 8, wfpPermit, self); e != nil {
				return e
			}
			direction := fieldNextInterface
			if i >= 2 {
				direction = fieldArrivalInterface
			}
			tun := []wfpCondition{{Field: fieldLocalInterface, Value: wfpValue{Type: 4, Value: uintptr(unsafe.Pointer(&luid))}}, {Field: direction, Value: wfpValue{Type: 4, Value: uintptr(unsafe.Pointer(&luid))}}}
			if e := addGuardFilter(h, i+12, layer, false, 7, wfpPermit, tun); e != nil {
				return e
			}
		}
		return nil
	})
	runtime.KeepAlive(sd)
	runtime.KeepAlive(path)
	if e != nil {
		_ = wfpCall(wfpClose, uintptr(h))
		return e
	}
	g.permits = h
	return nil
}
func (g *WindowsGuard) Suspend() error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.permits == 0 {
		return nil
	}
	if e := wfpCall(wfpClose, uintptr(g.permits)); e != nil {
		return e
	}
	g.permits = 0
	return nil
}
func (g *WindowsGuard) Disarm() error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.permits != 0 {
		return Code("guard_permits_active")
	}
	h, e := openWFP(false)
	if e != nil {
		return e
	}
	defer wfpCall(wfpClose, uintptr(h))
	return transaction(h, func() error {
		for i := 0; i < 8; i++ {
			if e := deleteGuardFilter(h, i); e != nil {
				return e
			}
		}
		e := wfpCall(wfpDeleteSublayer, uintptr(h), uintptr(unsafe.Pointer(&guardSublayer)))
		if e == windows.Errno(wfpSublayerNotFound) {
			return nil
		}
		return e
	})
}
