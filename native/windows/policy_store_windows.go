//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"runtime"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const policyRegistryPath = `SOFTWARE\ExVPN.ServicePolicy.v1`
const policyValueName = "policy"

var policyAdvapi = windows.NewLazySystemDLL("advapi32.dll")
var policyRegCreate = policyAdvapi.NewProc("RegCreateKeyExW")
var policyRegFlush = policyAdvapi.NewProc("RegFlushKey")

// One bounded, authenticated REG_BINARY value per installer-bound owner. The
// protected key survives service replacement and retains encrypted preferences
// on uninstall, just as the user's encrypted subscription store does.
type windowsPolicyStore struct {
	key        registry.Key
	owner      string
	principals []string
	fresh      bool
}

func openWindowsPolicyStore(owner string) (*windowsPolicyStore, error) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil || user.User.Sid.String() != "S-1-5-18" {
		return nil, Code("native_storage_unavailable")
	}
	if _, err = PipeSecurity(owner); err != nil {
		return nil, Code("native_storage_unavailable")
	}
	principals := []string{"S-1-5-18", "S-1-5-32-544"}
	root, err := openPolicyKey(registry.LOCAL_MACHINE, policyRegistryPath, owner, principals)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	return openPolicyKey(root.key, owner, owner, principals)
}

// Only tests use a temporary HKCU parent and their own explicit principal.
// Production never accepts a registry location or security descriptor over IPC.
func openPolicyKey(parent registry.Key, path, owner string, principals []string) (*windowsPolicyStore, error) {
	if len(principals) == 0 {
		return nil, Code("native_storage_unavailable")
	}
	sddl := "O:" + principals[0] + "G:" + principals[0] + "D:P"
	for _, sid := range principals {
		if _, err := windows.StringToSid(sid); err != nil {
			return nil, Code("native_storage_unavailable")
		}
		sddl += "(A;;KA;;;" + sid + ")"
	}
	sd, err := windows.SecurityDescriptorFromString(sddl)
	if err != nil {
		return nil, Code("native_storage_unavailable")
	}
	sa := windows.SecurityAttributes{SecurityDescriptor: sd}
	sa.Length = uint32(unsafe.Sizeof(sa))
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, Code("native_storage_unavailable")
	}
	var handle windows.Handle
	var disposition uint32
	// A protected DACL is supplied at creation, before any value is written.
	code, _, _ := policyRegCreate.Call(uintptr(parent), uintptr(unsafe.Pointer(name)), 0, 0, 0,
		uintptr(registry.READ|registry.WRITE|registry.WOW64_64KEY), uintptr(unsafe.Pointer(&sa)), uintptr(unsafe.Pointer(&handle)), uintptr(unsafe.Pointer(&disposition)))
	runtime.KeepAlive(sd)
	runtime.KeepAlive(sa)
	if uint32(code) != 0 {
		return nil, Code("native_storage_unavailable")
	}
	s := &windowsPolicyStore{key: registry.Key(handle), owner: owner, principals: append([]string{}, principals...), fresh: disposition == 1}
	if err = s.checkACL(); err != nil {
		s.Close()
		return nil, err
	}
	return s, nil
}

func (s *windowsPolicyStore) Close() error { return s.key.Close() }

func (s *windowsPolicyStore) checkACL() error {
	sd, err := windows.GetSecurityInfo(windows.Handle(s.key), windows.SE_REGISTRY_KEY,
		windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return Code("native_storage_unavailable")
	}
	owner, _, err := sd.Owner()
	if err != nil || owner == nil {
		return Code("native_storage_unavailable")
	}
	trusted := map[string]bool{}
	for _, sid := range s.principals {
		trusted[sid] = true
	}
	control, _, err := sd.Control()
	if err != nil || !trusted[owner.String()] || control&windows.SE_DACL_PROTECTED == 0 {
		return Code("native_storage_unavailable")
	}
	acl, _, err := sd.DACL()
	if err != nil || acl == nil || int(acl.AceCount) != len(trusted) {
		return Code("native_storage_unavailable")
	}
	seen := map[string]bool{}
	for i := uint32(0); i < uint32(acl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if windows.GetAce(acl, i, &ace) != nil || ace == nil || ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE || ace.Header.AceFlags != 0 {
			return Code("native_storage_unavailable")
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		if !sid.IsValid() || !trusted[sid.String()] || seen[sid.String()] || (ace.Mask != windows.KEY_ALL_ACCESS && ace.Mask != windows.GENERIC_ALL) {
			return Code("native_storage_unavailable")
		}
		seen[sid.String()] = true
	}
	return nil
}

func (s *windowsPolicyStore) read() ([]byte, error) {
	if err := s.checkACL(); err != nil {
		return nil, err
	}
	// A fixed buffer prevents a malicious/corrupt value length causing an
	// unbounded allocation. Type and size are checked before DPAPI or JSON.
	buffer := make([]byte, maxPolicyBytes+4096)
	n, kind, err := s.key.GetValue(policyValueName, buffer)
	if errors.Is(err, registry.ErrNotExist) && s.fresh {
		return nil, policyMissing
	}
	if err != nil || kind != registry.BINARY || n == 0 || n > len(buffer) {
		return nil, Code("exclusions_unavailable")
	}
	return buffer[:n], nil
}

func (s *windowsPolicyStore) Load() ([]string, error) {
	b, err := s.read()
	if err != nil {
		return nil, err
	}
	plain, err := policyCrypt(b, s.owner, false)
	if err != nil {
		return nil, Code("exclusions_unavailable")
	}
	defer clear(plain)
	return decodePolicy(s.owner, plain)
}

func (s *windowsPolicyStore) Save(paths []string) error {
	plain, err := encodePolicy(s.owner, paths)
	if err != nil {
		return err
	}
	defer clear(plain)
	b, err := policyCrypt(plain, s.owner, true)
	if err != nil || s.checkACL() != nil {
		return Code("native_storage_unavailable")
	}
	if s.key.SetBinaryValue(policyValueName, b) != nil {
		return Code("native_storage_unavailable")
	}
	// A single value replacement avoids a partially readable JSON file. Confirm
	// the bytes and flush the hive before acknowledging a policy change.
	readback, err := s.read()
	if err != nil || !bytes.Equal(readback, b) {
		return Code("native_storage_unavailable")
	}
	code, _, _ := policyRegFlush.Call(uintptr(s.key))
	if uint32(code) != 0 {
		return Code("native_storage_unavailable")
	}
	s.fresh = false
	return nil
}

func policyCrypt(input []byte, owner string, protect bool) ([]byte, error) {
	if len(input) == 0 || len(input) > maxPolicyBytes+4096 {
		return nil, Code("native_storage_unavailable")
	}
	entropy := sha256.Sum256([]byte("ExVPN.ServicePolicy.v1\x00" + owner))
	in := windows.DataBlob{Size: uint32(len(input)), Data: &input[0]}
	extra := windows.DataBlob{Size: uint32(len(entropy)), Data: &entropy[0]}
	var out windows.DataBlob
	var err error
	if protect {
		// Deliberately user-scoped to LocalSystem, not LOCAL_MACHINE (which
		// would allow other local users to decrypt a copied ciphertext).
		err = windows.CryptProtectData(&in, nil, &extra, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &out)
	} else {
		err = windows.CryptUnprotectData(&in, nil, &extra, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &out)
	}
	runtime.KeepAlive(input)
	runtime.KeepAlive(entropy)
	if err != nil {
		return nil, Code("native_storage_unavailable")
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	if out.Size == 0 || out.Size > maxPolicyBytes+4096 || out.Data == nil {
		return nil, Code("native_storage_unavailable")
	}
	value := unsafe.Slice(out.Data, int(out.Size))
	defer clear(value)
	return append([]byte{}, value...), nil
}
