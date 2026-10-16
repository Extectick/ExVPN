// SPDX-License-Identifier: Apache-2.0
package service

import (
	"encoding/binary"
	"net/netip"
)

// The UDP owner table has no remote endpoint. A local endpoint therefore grants
// an exception only when every potentially matching socket has the same PID.
// TCP uses the complete tuple, never the first row with a matching local port.
type flowTuple struct {
	network       string
	local, remote netip.AddrPort
}

func (f flowTuple) valid() bool {
	return (f.network == "tcp" || f.network == "udp") && f.local.IsValid() && f.remote.IsValid() &&
		f.local.Port() != 0 && f.remote.Port() != 0 && !f.local.Addr().IsUnspecified() &&
		!f.remote.Addr().IsUnspecified() && f.local.Addr().Zone() == "" && f.remote.Addr().Zone() == "" &&
		f.local.Addr().Is4() == f.remote.Addr().Is4()
}

type ownerRow struct {
	local, remote netip.AddrPort
	pid, state    uint32
	scoped        bool
}

// Layouts are the documented Windows MIB_*ROW_OWNER_PID structs. Decode bytes
// explicitly rather than casting potentially truncated/untrusted table memory.
func decodeOwnerTable(data []byte, network string, ipv6 bool) ([]ownerRow, error) {
	if len(data) < 4 || (network != "tcp" && network != "udp") {
		return nil, Code("owner_unavailable")
	}
	size, ipSize, localIP, localPort, remoteIP, remotePort, pidOffset, stateOffset := 12, 4, 0, 4, 0, 0, 8, -1
	if network == "tcp" {
		size, localIP, localPort, remoteIP, remotePort, pidOffset, stateOffset = 24, 4, 8, 12, 16, 20, 0
	}
	if ipv6 {
		ipSize, localIP, localPort = 16, 0, 20
		if network == "tcp" {
			size, remoteIP, remotePort, pidOffset, stateOffset = 56, 24, 44, 52, 48
		} else {
			size, pidOffset = 28, 24
		}
	}
	count := uint64(binary.LittleEndian.Uint32(data[:4]))
	if count > uint64((len(data)-4)/size) || count > 1<<20 {
		return nil, Code("owner_unavailable")
	}
	rows := make([]ownerRow, 0, int(count))
	for index := 0; index < int(count); index++ {
		raw := data[4+index*size : 4+(index+1)*size]
		local, _ := netip.AddrFromSlice(raw[localIP : localIP+ipSize])
		row := ownerRow{local: netip.AddrPortFrom(local.Unmap(), binary.BigEndian.Uint16(raw[localPort:localPort+2])), pid: binary.LittleEndian.Uint32(raw[pidOffset : pidOffset+4])}
		if stateOffset >= 0 {
			remote, _ := netip.AddrFromSlice(raw[remoteIP : remoteIP+ipSize])
			row.remote = netip.AddrPortFrom(remote.Unmap(), binary.BigEndian.Uint16(raw[remotePort:remotePort+2]))
			row.state = binary.LittleEndian.Uint32(raw[stateOffset : stateOffset+4])
		}
		if ipv6 {
			row.scoped = binary.LittleEndian.Uint32(raw[16:20]) != 0 || (network == "tcp" && binary.LittleEndian.Uint32(raw[40:44]) != 0)
		}
		rows = append(rows, row)
	}
	return rows, nil
}

func uniqueOwnerPID(rows []ownerRow, flow flowTuple) (uint32, error) {
	if !flow.valid() {
		return 0, Code("owner_unavailable")
	}
	var owner uint32
	for _, row := range rows {
		if row.local.Port() != flow.local.Port() {
			continue
		}
		if flow.network == "tcp" {
			if row.local != flow.local || row.remote != flow.remote || row.state < 3 || row.state > 5 {
				continue
			}
		} else {
			address := row.local.Addr()
			// IPv6 unspecified can be a dual-stack socket. The owner table does
			// not expose IPV6_V6ONLY, so include it conservatively for IPv4.
			wildcard := address.IsUnspecified() && (address.Is6() || flow.local.Addr().Is4())
			if address != flow.local.Addr() && !wildcard {
				continue
			}
		}
		if row.scoped || row.pid <= 4 || (owner != 0 && owner != row.pid) {
			return 0, Code("owner_unavailable")
		}
		owner = row.pid
	}
	if owner == 0 {
		return 0, Code("owner_unavailable")
	}
	return owner, nil
}
