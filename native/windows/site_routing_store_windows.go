//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"runtime"
	"unsafe"

	exvpn "github.com/Extectick/ExVPN/native/core"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const sitePolicyValueName = "siteRouting"
const sitePolicyInitialized = "siteRoutingInitialized"

func (s *windowsPolicyStore) sitePolicyBytes() ([]byte, error) {
	if s.checkACL() != nil {
		return nil, Code("site_routing_unavailable")
	}
	buffer := make([]byte, maxSitePolicyBytes+4096)
	n, kind, err := s.key.GetValue(sitePolicyValueName, buffer)
	if errors.Is(err, registry.ErrNotExist) {
		// Existing pre-site-policy installations can seed this separate value.
		// Once initialized, a missing value is corruption, never a silent reset.
		_, _, markerErr := s.key.GetIntegerValue(sitePolicyInitialized)
		if errors.Is(markerErr, registry.ErrNotExist) {
			return nil, policyMissing
		}
		return nil, Code("site_routing_unavailable")
	}
	if err != nil || kind != registry.BINARY || n <= 0 || n > len(buffer) {
		return nil, Code("site_routing_unavailable")
	}
	return buffer[:n], nil
}

func (s *windowsPolicyStore) LoadSiteRouting() (exvpn.SiteRoutingState, error) {
	ciphertext, err := s.sitePolicyBytes()
	if err != nil {
		return exvpn.SiteRoutingState{}, err
	}
	plain, err := cryptSitePolicy(ciphertext, s.owner, false)
	if err != nil {
		return exvpn.SiteRoutingState{}, Code("site_routing_unavailable")
	}
	defer clear(plain)
	return decodeSitePolicy(s.owner, plain)
}

func (s *windowsPolicyStore) SaveSiteRouting(state exvpn.SiteRoutingState) error {
	plain, err := encodeSitePolicy(s.owner, state)
	if err != nil {
		return err
	}
	defer clear(plain)
	ciphertext, err := cryptSitePolicy(plain, s.owner, true)
	if err != nil || s.checkACL() != nil || s.key.SetBinaryValue(sitePolicyValueName, ciphertext) != nil {
		return Code("native_storage_unavailable")
	}
	actual, err := s.sitePolicyBytes()
	if err != nil || !bytes.Equal(actual, ciphertext) || s.key.SetDWordValue(sitePolicyInitialized, 1) != nil {
		return Code("native_storage_unavailable")
	}
	marker, kind, err := s.key.GetIntegerValue(sitePolicyInitialized)
	if err != nil || kind != registry.DWORD || marker != 1 {
		return Code("native_storage_unavailable")
	}
	code, _, _ := policyRegFlush.Call(uintptr(s.key))
	if uint32(code) != 0 {
		return Code("native_storage_unavailable")
	}
	return nil
}

func cryptSitePolicy(input []byte, owner string, protect bool) ([]byte, error) {
	if len(input) == 0 || len(input) > maxSitePolicyBytes+4096 {
		return nil, Code("native_storage_unavailable")
	}
	// Separate purpose and owner binding prevents swapping application-policy
	// ciphertext into this store, even for the same installed owner account.
	entropy := sha256.Sum256([]byte("ExVPN.SitePolicy.v1\x00" + owner))
	in := windows.DataBlob{Size: uint32(len(input)), Data: &input[0]}
	extra := windows.DataBlob{Size: uint32(len(entropy)), Data: &entropy[0]}
	var out windows.DataBlob
	var err error
	if protect {
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
	if out.Size == 0 || out.Size > maxSitePolicyBytes+4096 || out.Data == nil {
		return nil, Code("native_storage_unavailable")
	}
	return append([]byte{}, unsafe.Slice(out.Data, int(out.Size))...), nil
}
