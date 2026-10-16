//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"reflect"
	"runtime"
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

func TestClientProcessQueryGrantPreservesOtherPrincipalsAndCannotEscalate(t *testing.T) {
	const owner = "S-1-5-21-111-222-333-1001"
	const other = "S-1-5-21-111-222-333-1002"
	sd, err := windows.SecurityDescriptorFromString("D:P(D;;0x20;;;" + other + ")(A;;GA;;;SY)(A;;GA;;;BA)")
	if err != nil {
		t.Fatal(err)
	}
	baseline, _, err := sd.DACL()
	if err != nil {
		t.Fatal(err)
	}
	type entry struct {
		Kind  byte
		Flags byte
		Mask  windows.ACCESS_MASK
		SID   string
	}
	read := func(acl *windows.ACL) []entry {
		result := []entry{}
		for i := uint32(0); i < uint32(acl.AceCount); i++ {
			var ace *windows.ACCESS_ALLOWED_ACE
			if err := windows.GetAce(acl, i, &ace); err != nil {
				t.Fatal(err)
			}
			sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart)).String()
			result = append(result, entry{ace.Header.AceType, ace.Header.AceFlags, ace.Mask, sid})
		}
		return result
	}
	wantOthers := read(baseline)
	acl := baseline
	for attempt := 0; attempt < 2; attempt++ {
		acl, err = clientQueryACL(owner, acl)
		if err != nil {
			t.Fatal(err)
		}
		others := []entry{}
		count := 0
		for _, ace := range read(acl) {
			if ace.SID == owner {
				count++
				if ace.Kind != windows.ACCESS_ALLOWED_ACE_TYPE || ace.Flags != 0 || ace.Mask != 0x1000 {
					t.Fatal("UI received rights beyond limited process query")
				}
			} else {
				others = append(others, ace)
			}
		}
		if count != 1 || !reflect.DeepEqual(others, wantOthers) {
			t.Fatal("ACL update duplicated a grant or changed another principal")
		}
	}
	runtime.KeepAlive(sd)
}

func TestClientProcessQueryRejectsNullAclReservedOwnerAndBroadExistingGrant(t *testing.T) {
	const owner = "S-1-5-21-111-222-333-1001"
	if _, err := clientQueryACL(owner, nil); err == nil {
		t.Fatal("null DACL accepted")
	}
	sd, err := windows.SecurityDescriptorFromString("D:(A;;GA;;;SY)(A;;0x20;;;" + owner + ")")
	if err != nil {
		t.Fatal(err)
	}
	acl, _, err := sd.DACL()
	if err != nil {
		t.Fatal(err)
	}
	for _, sid := range []string{"", "not-a-sid", "S-1-1-0", "S-1-5-18", "S-1-5-32-544", owner} {
		if _, err := clientQueryACL(sid, acl); err == nil {
			t.Fatal("unsafe process query grant accepted")
		}
	}
	runtime.KeepAlive(sd)
}
