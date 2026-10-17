//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

var ownerAPI = windows.NewLazySystemDLL("iphlpapi.dll")
var tcpOwnerTable = ownerAPI.NewProc("GetExtendedTcpTable")
var udpOwnerTable = ownerAPI.NewProc("GetExtendedUdpTable")

type processOwner struct {
	pid     uint32
	created uint64
	path    string
}
type ownerResolver func(flowTuple) (processOwner, error)

func processPathKey(path string) string { return strings.ToLower(strings.ReplaceAll(path, "\\", "/")) }

func getOwnerTable(network string, ipv6 bool) ([]ownerRow, error) {
	proc, class := tcpOwnerTable, uintptr(4) // TCP_TABLE_OWNER_PID_CONNECTIONS
	if network == "udp" {
		proc, class = udpOwnerTable, 1
	}
	if network != "tcp" && network != "udp" {
		return nil, Code("owner_unavailable")
	}
	family := uintptr(windows.AF_INET)
	if ipv6 {
		family = windows.AF_INET6
	}
	if proc.Find() != nil {
		return nil, Code("owner_unavailable")
	}
	size := uint32(4096)
	for range 3 {
		if size < 4 || size > 16<<20 {
			return nil, Code("owner_unavailable")
		}
		data := make([]byte, size)
		result, _, _ := proc.Call(uintptr(unsafe.Pointer(&data[0])), uintptr(unsafe.Pointer(&size)), 0, family, class, 0)
		if result == uintptr(windows.ERROR_INSUFFICIENT_BUFFER) {
			continue
		}
		if result != 0 || size > uint32(len(data)) {
			return nil, Code("owner_unavailable")
		}
		return decodeOwnerTable(data[:size], network, ipv6)
	}
	return nil, Code("owner_unavailable")
}

func snapshotOwnerPID(flow flowTuple) (uint32, error) {
	rows, err := getOwnerTable(flow.network, false)
	if err != nil {
		return 0, err
	}
	v6, err := getOwnerTable(flow.network, true)
	if err != nil {
		return 0, err
	}
	return uniqueOwnerPID(append(rows, v6...), flow)
}

func filetimeValue(t windows.Filetime) uint64 {
	return uint64(t.HighDateTime)<<32 | uint64(t.LowDateTime)
}

func resolveProcessOwner(flow flowTuple) (processOwner, error) {
	if !flow.valid() {
		return processOwner{}, Code("owner_unavailable")
	}
	var before windows.Filetime
	windows.GetSystemTimeAsFileTime(&before)
	pid, err := snapshotOwnerPID(flow)
	if err != nil {
		return processOwner{}, err
	}
	handle, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return processOwner{}, Code("owner_unavailable")
	}
	defer windows.CloseHandle(handle)
	var created, exited, kernel, user windows.Filetime
	if windows.GetProcessTimes(handle, &created, &exited, &kernel, &user) != nil || filetimeValue(created) == 0 || filetimeValue(created) > filetimeValue(before) || filetimeValue(exited) != 0 {
		return processOwner{}, Code("owner_unavailable")
	}
	path := make([]uint16, 32768)
	size := uint32(len(path))
	if windows.QueryFullProcessImageName(handle, 0, &path[0], &size) != nil || size == 0 || size > uint32(len(path)) {
		return processOwner{}, Code("owner_unavailable")
	}
	// Re-read while retaining a process handle. A changed owner, new ambiguous
	// bind or PID reuse during the snapshot may never earn a direct exception.
	confirmed, err := snapshotOwnerPID(flow)
	if err != nil || confirmed != pid {
		return processOwner{}, Code("owner_unavailable")
	}
	var afterCreation windows.Filetime
	if windows.GetProcessTimes(handle, &afterCreation, &exited, &kernel, &user) != nil || afterCreation != created || filetimeValue(exited) != 0 {
		return processOwner{}, Code("owner_unavailable")
	}
	image := windows.UTF16ToString(path[:size])
	canonical, err := canonicalApplicationExecutable(image)
	if err != nil {
		return processOwner{}, Code("owner_unavailable")
	}
	return processOwner{pid: pid, created: filetimeValue(created), path: processPathKey(canonical)}, nil
}
