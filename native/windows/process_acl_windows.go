//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"runtime"
	"unsafe"

	"golang.org/x/sys/windows"
)

// The UI authenticates its pipe peer against SCM and the actual process image.
// SCM's default SYSTEM process DACL can deny an ordinary user even QUERY_LIMITED.
// Grant exactly that right to the installer-bound owner, on this process only.
// There is no client-supplied PID, path, ACL or access mask.
func allowClientProcessQuery(ownerSID string) error {
	process := windows.CurrentProcess()
	sd, err := windows.GetSecurityInfo(process, windows.SE_KERNEL_OBJECT, windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return Code("process_query_acl_failed")
	}
	existing, _, err := sd.DACL()
	if err != nil {
		return Code("process_query_acl_failed")
	}
	acl, err := clientQueryACL(ownerSID, existing)
	if err != nil {
		return err
	}
	err = windows.SetSecurityInfo(process, windows.SE_KERNEL_OBJECT, windows.DACL_SECURITY_INFORMATION, nil, nil, acl, nil)
	runtime.KeepAlive(sd)
	runtime.KeepAlive(acl)
	if err != nil {
		return Code("process_query_acl_failed")
	}
	confirmed, err := windows.GetSecurityInfo(process, windows.SE_KERNEL_OBJECT, windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return Code("process_query_acl_failed")
	}
	readback, _, err := confirmed.DACL()
	if err != nil || !exactClientQuery(readback, ownerSID) {
		return Code("process_query_acl_failed")
	}
	runtime.KeepAlive(confirmed)
	return nil
}

func clientQueryACL(ownerSID string, existing *windows.ACL) (*windows.ACL, error) {
	if _, err := PipeSecurity(ownerSID); err != nil || existing == nil {
		return nil, Code("process_query_acl_failed")
	}
	sid, _ := windows.StringToSid(ownerSID)
	acl, err := windows.ACLFromEntries([]windows.EXPLICIT_ACCESS{{
		AccessPermissions: windows.PROCESS_QUERY_LIMITED_INFORMATION,
		AccessMode:        windows.GRANT_ACCESS,
		Inheritance:       windows.NO_INHERITANCE,
		Trustee:           windows.TRUSTEE{TrusteeForm: windows.TRUSTEE_IS_SID, TrusteeType: windows.TRUSTEE_IS_USER, TrusteeValue: windows.TrusteeValueFromSID(sid)},
	}}, existing)
	runtime.KeepAlive(sid)
	if err != nil || !exactClientQuery(acl, ownerSID) {
		return nil, Code("process_query_acl_failed")
	}
	return acl, nil
}

func exactClientQuery(acl *windows.ACL, ownerSID string) bool {
	if acl == nil {
		return false
	}
	found := 0
	for i := uint32(0); i < uint32(acl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if windows.GetAce(acl, i, &ace) != nil || ace == nil {
			return false
		}
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE {
			continue
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		if !sid.IsValid() {
			return false
		}
		if sid.String() == ownerSID {
			if ace.Mask != windows.PROCESS_QUERY_LIMITED_INFORMATION || ace.Header.AceFlags != 0 {
				return false
			}
			found++
		}
	}
	return found == 1
}
