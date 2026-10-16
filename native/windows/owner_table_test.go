// SPDX-License-Identifier: Apache-2.0
package service

import (
	"encoding/binary"
	"net/netip"
	"testing"
)

func fixtureFlow(network string) flowTuple {
	return flowTuple{network: network, local: netip.MustParseAddrPort("192.0.2.2:50000"), remote: netip.MustParseAddrPort("198.51.100.1:443")}
}

func TestOwnerTCPRequiresFullTupleAndUniquePID(t *testing.T) {
	flow := fixtureFlow("tcp")
	one := ownerRow{local: flow.local, remote: flow.remote, pid: 101, state: 5}
	two := one
	two.pid = 202
	two.remote = netip.MustParseAddrPort("198.51.100.2:443")
	for _, rows := range [][]ownerRow{{two, one}, {one, two}} {
		pid, err := uniqueOwnerPID(rows, flow)
		if err != nil || pid != 101 {
			t.Fatal("local endpoint alone chose another process")
		}
	}
	two.remote = flow.remote
	if _, err := uniqueOwnerPID([]ownerRow{one, two}, flow); err == nil {
		t.Fatal("ambiguous full tuple granted exception")
	}
	one.remote = netip.MustParseAddrPort("198.51.100.1:444")
	if _, err := uniqueOwnerPID([]ownerRow{one}, flow); err == nil {
		t.Fatal("ignored remote port")
	}
	one.remote = flow.remote
	one.state = 2
	if _, err := uniqueOwnerPID([]ownerRow{one}, flow); err == nil {
		t.Fatal("listener treated as flow owner")
	}
}

func TestOwnerUDPRejectsAmbiguityAcrossSpecificAndWildcardBinds(t *testing.T) {
	flow := fixtureFlow("udp")
	one := ownerRow{local: flow.local, pid: 101}
	for _, wildcard := range []string{"192.0.2.2:50000", "0.0.0.0:50000", "[::]:50000"} {
		two := ownerRow{local: netip.MustParseAddrPort(wildcard), pid: 202}
		for _, rows := range [][]ownerRow{{one, two}, {two, one}} {
			if _, err := uniqueOwnerPID(rows, flow); err == nil {
				t.Fatal("ambiguous UDP owner accepted")
			}
		}
		two.pid = 101
		if pid, err := uniqueOwnerPID([]ownerRow{one, two}, flow); err != nil || pid != 101 {
			t.Fatal("same process multiple sockets rejected")
		}
	}
	one.scoped = true
	if _, err := uniqueOwnerPID([]ownerRow{one}, flow); err == nil {
		t.Fatal("unproven IPv6 scope accepted")
	}
	if _, err := uniqueOwnerPID(nil, flow); err == nil {
		t.Fatal("unknown owner accepted")
	}
}

func TestOwnerTableDecodeBoundedAndNetworkByteOrder(t *testing.T) {
	for _, network := range []string{"tcp", "udp"} {
		for _, ipv6 := range []bool{false, true} {
			size, localOffset, portOffset, pidOffset := 12, 0, 4, 8
			if network == "tcp" {
				size, localOffset, portOffset, pidOffset = 24, 4, 8, 20
			}
			if ipv6 {
				size, localOffset, portOffset, pidOffset = 28, 0, 20, 24
				if network == "tcp" {
					size, pidOffset = 56, 52
				}
			}
			data := make([]byte, 4+size)
			binary.LittleEndian.PutUint32(data, 1)
			row := data[4:]
			address := netip.MustParseAddr("192.0.2.2")
			if ipv6 {
				address = netip.MustParseAddr("2001:db8::2")
			}
			copy(row[localOffset:], address.AsSlice())
			binary.BigEndian.PutUint16(row[portOffset:], 50000)
			binary.LittleEndian.PutUint32(row[pidOffset:], 12345)
			rows, err := decodeOwnerTable(data, network, ipv6)
			if err != nil || len(rows) != 1 || rows[0].local != netip.AddrPortFrom(address, 50000) || rows[0].pid != 12345 {
				t.Fatal("incorrect documented table layout")
			}
			for _, truncated := range [][]byte{nil, data[:3], data[:len(data)-1]} {
				if _, err := decodeOwnerTable(truncated, network, ipv6); err == nil {
					t.Fatal("truncated table accepted")
				}
			}
			binary.LittleEndian.PutUint32(data, ^uint32(0))
			if _, err := decodeOwnerTable(data, network, ipv6); err == nil {
				t.Fatal("oversized row count accepted")
			}
		}
	}
}
