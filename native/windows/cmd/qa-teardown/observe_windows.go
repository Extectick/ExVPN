//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package main

import (
	"encoding/binary"
	"errors"
	"net/netip"
	"strconv"
	"unsafe"

	"golang.org/x/sys/windows"
)

type tcpRow struct {
	local, remote netip.AddrPort
	pid, state    uint32
}

func decodeTCP(data []byte) ([]tcpRow, error) {
	if len(data) < 4 {
		return nil, errors.New("tcp_table_truncated")
	}
	count := uint64(binary.LittleEndian.Uint32(data))
	if count > uint64((len(data)-4)/24) || count > 1<<20 {
		return nil, errors.New("tcp_table_truncated")
	}
	rows := make([]tcpRow, 0, count)
	for i := 0; i < int(count); i++ {
		b := data[4+i*24 : 4+(i+1)*24]
		l, _ := netip.AddrFromSlice(b[4:8])
		r, _ := netip.AddrFromSlice(b[12:16])
		rows = append(rows, tcpRow{netip.AddrPortFrom(l, binary.BigEndian.Uint16(b[8:10])), netip.AddrPortFrom(r, binary.BigEndian.Uint16(b[16:18])), binary.LittleEndian.Uint32(b[20:24]), binary.LittleEndian.Uint32(b[0:4])})
	}
	return rows, nil
}

func tcpStates(local, remote netip.AddrPort, pid uint32) ([]uint32, error) {
	proc := windows.NewLazySystemDLL("iphlpapi.dll").NewProc("GetExtendedTcpTable")
	if proc.Find() != nil {
		return nil, errors.New("tcp_table_unavailable")
	}
	size := uint32(4096)
	for range 3 {
		if size < 4 || size > 16<<20 {
			return nil, errors.New("tcp_table_size")
		}
		b := make([]byte, size)
		r, _, _ := proc.Call(uintptr(unsafe.Pointer(&b[0])), uintptr(unsafe.Pointer(&size)), 0, windows.AF_INET, 4, 0)
		if r == uintptr(windows.ERROR_INSUFFICIENT_BUFFER) {
			continue
		}
		if r != 0 || size > uint32(len(b)) {
			return nil, errors.New("tcp_table_failed")
		}
		rows, e := decodeTCP(b[:size])
		if e != nil {
			return nil, e
		}
		states := []uint32{}
		for _, row := range rows {
			if row.local == local && row.remote == remote && (pid == 0 || row.pid == pid) {
				states = append(states, row.state)
			}
		}
		return states, nil
	}
	return nil, errors.New("tcp_table_unstable")
}

// Read-only view of FWPM_FILTER0; same x64 SDK layout used by WindowsGuard.
type filterValue struct {
	Type  uint32
	Value uintptr
}
type filterBlob struct {
	Size uint32
	Data *byte
}
type filterDisplay struct{ Name, Description *uint16 }
type filterAction struct {
	Type uint32
	Key  windows.GUID
}
type filterView struct {
	Key             windows.GUID
	Display         filterDisplay
	Flags           uint32
	Provider        *windows.GUID
	Data            filterBlob
	Layer, Sublayer windows.GUID
	Weight          filterValue
	Count           uint32
	Conditions      unsafe.Pointer
	Action          filterAction
	_               uint32
	Context         windows.GUID
	Reserved        *windows.GUID
	ID              uint64
	EffectiveWeight filterValue
}

func persistentFilterIDs() (map[string]uint64, error) {
	dll := windows.NewLazySystemDLL("fwpuclnt.dll")
	var handle windows.Handle
	r, _, _ := dll.NewProc("FwpmEngineOpen0").Call(0, 10, 0, 0, uintptr(unsafe.Pointer(&handle)))
	if uint32(r) != 0 {
		return nil, errors.New("wfp_read_open_failed")
	}
	defer dll.NewProc("FwpmEngineClose0").Call(uintptr(handle))
	ids := map[string]uint64{}
	key, _ := windows.GUIDFromString("{A6925C6B-74D5-453E-B38C-BA7F26FE7500}")
	for i := 0; i < 8; i++ {
		key.Data4[7] = byte(i + 1)
		var f *filterView
		r, _, _ = dll.NewProc("FwpmFilterGetByKey0").Call(uintptr(handle), uintptr(unsafe.Pointer(&key)), uintptr(unsafe.Pointer(&f)))
		if uint32(r) == 0x80320003 {
			continue
		}
		if uint32(r) != 0 || f == nil {
			return nil, errors.New("wfp_read_failed")
		}
		id := f.ID
		dll.NewProc("FwpmFreeMemory0").Call(uintptr(unsafe.Pointer(&f)))
		if id == 0 {
			return nil, errors.New("wfp_id_invalid")
		}
		ids[strconv.Itoa(i)] = id
	}
	return ids, nil
}

func ownedFilterSet(current, owned map[string]uint64) bool {
	if len(current) == 0 || len(owned) != 8 {
		return false
	}
	for i := 0; i < 8; i++ {
		if owned[strconv.Itoa(i)] == 0 {
			return false
		}
	}
	for k, v := range current {
		if v == 0 || owned[k] != v {
			return false
		}
	}
	return true
}
