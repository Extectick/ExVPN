//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"errors"

	"golang.org/x/sys/windows/registry"
)

const protectionValueName = "connectionProtection"

func (s *windowsPolicyStore) protectionBytes() ([]byte, error) {
	if s.checkACL() != nil {
		return nil, Code("connection_protection_unavailable")
	}
	buffer := make([]byte, 8192)
	n, kind, err := s.key.GetValue(protectionValueName, buffer)
	// Older installations have no preference. Missing always defaults to ON;
	// deletion must never silently weaken the previous fail-closed policy.
	if errors.Is(err, registry.ErrNotExist) {
		return nil, policyMissing
	}
	if err != nil || kind != registry.BINARY || n <= 0 || n > len(buffer) {
		return nil, Code("connection_protection_unavailable")
	}
	return buffer[:n], nil
}

func (s *windowsPolicyStore) LoadProtection() (bool, error) {
	ciphertext, err := s.protectionBytes()
	if err != nil {
		return true, err
	}
	plain, err := policyCrypt(ciphertext, s.owner, false)
	if err != nil {
		return true, Code("connection_protection_unavailable")
	}
	defer clear(plain)
	return decodeConnectionProtection(s.owner, plain)
}

func (s *windowsPolicyStore) SaveProtection(enabled bool) error {
	plain, err := encodeConnectionProtection(s.owner, enabled)
	if err != nil {
		return Code("native_storage_unavailable")
	}
	defer clear(plain)
	ciphertext, err := policyCrypt(plain, s.owner, true)
	if err != nil || s.checkACL() != nil || s.key.SetBinaryValue(protectionValueName, ciphertext) != nil {
		return Code("native_storage_unavailable")
	}
	actual, err := s.protectionBytes()
	if err != nil || !bytes.Equal(actual, ciphertext) {
		return Code("native_storage_unavailable")
	}
	code, _, _ := policyRegFlush.Call(uintptr(s.key))
	if uint32(code) != 0 {
		return Code("native_storage_unavailable")
	}
	return nil
}
