//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"reflect"
	"testing"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

func policyRegistryFixture(t *testing.T) (*windowsPolicyStore, string, string) {
	t.Helper()
	u, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	id := make([]byte, 16)
	if _, err = rand.Read(id); err != nil {
		t.Fatal(err)
	}
	path := `Software\ExVPN-QA-Policy-` + hex.EncodeToString(id)
	s, err := openPolicyKey(registry.CURRENT_USER, path, "synthetic-owner-a", []string{u.User.Sid.String()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = s.Close()
		if err := registry.DeleteKey(registry.CURRENT_USER, path); err != nil {
			t.Error(err)
		}
	})
	return s, path, u.User.Sid.String()
}

func TestWindowsPolicyRealDPAPIRoundTripAndReopen(t *testing.T) {
	s, path, sid := policyRegistryFixture(t)
	if _, err := s.Load(); err != policyMissing {
		t.Fatal("missing record not distinguished")
	}
	want := []string{"C:/Apps/example.exe"}
	if err := s.Save(want); err != nil {
		t.Fatal(err)
	}
	b, err := s.read()
	if err != nil || bytes.Contains(b, []byte(want[0])) {
		t.Fatal("plaintext path found or missing ciphertext")
	}
	reopened, err := openPolicyKey(registry.CURRENT_USER, path, s.owner, []string{sid})
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if got, err := reopened.Load(); err != nil || !reflect.DeepEqual(got, want) {
		t.Fatal("actual registry/DPAPI recovery failed")
	}
}

func TestWindowsPolicyRejectsTamperOwnerCopyTypeAndSize(t *testing.T) {
	s, _, _ := policyRegistryFixture(t)
	if err := s.Save([]string{"C:/Apps/example.exe"}); err != nil {
		t.Fatal(err)
	}
	b, _ := s.read()
	copyOwner := *s
	copyOwner.owner = "synthetic-owner-b"
	if err := s.key.SetBinaryValue(policyValueName, b); err != nil {
		t.Fatal(err)
	}
	if _, err := copyOwner.Load(); err == nil {
		t.Fatal("ciphertext copied across owners was accepted")
	}
	b[len(b)-1] ^= 1
	if err := s.key.SetBinaryValue(policyValueName, b); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Load(); err == nil {
		t.Fatal("tampered DPAPI record accepted")
	}
	if err := s.key.SetStringValue(policyValueName, "{}"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Load(); err == nil {
		t.Fatal("incorrect registry type accepted")
	}
	if err := s.key.SetBinaryValue(policyValueName, make([]byte, maxPolicyBytes+4097)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Load(); err == nil {
		t.Fatal("unbounded registry value accepted")
	}
	if err := s.Save([]string{}); err != nil {
		t.Fatal("explicit empty reset failed")
	}
	if got, err := s.Load(); err != nil || len(got) != 0 {
		t.Fatal("explicit reset not readable")
	}
}

func TestWindowsPolicyRejectsBroadenedACLWithoutRepair(t *testing.T) {
	s, path, sid := policyRegistryFixture(t)
	key, err := registry.OpenKey(registry.CURRENT_USER, path, registry.ALL_ACCESS)
	if err != nil {
		t.Fatal(err)
	}
	defer key.Close()
	sd, err := windows.SecurityDescriptorFromString("D:P(A;;KA;;;" + sid + ")(A;;KR;;;WD)")
	if err != nil {
		t.Fatal(err)
	}
	acl, _, err := sd.DACL()
	if err != nil {
		t.Fatal(err)
	}
	if err = windows.SetSecurityInfo(windows.Handle(key), windows.SE_REGISTRY_KEY, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil); err != nil {
		t.Fatal(err)
	}
	if err = s.Save([]string{}); err == nil {
		t.Fatal("write allowed under broadened ACL")
	}
	if _, err = s.Load(); err == nil {
		t.Fatal("read allowed under broadened ACL")
	}
	if next, err := openPolicyKey(registry.CURRENT_USER, path, s.owner, []string{sid}); err == nil {
		next.Close()
		t.Fatal("existing unsafe key silently adopted")
	}
}

func TestWindowsPolicyMissingRecordAfterInitializationIsNotFresh(t *testing.T) {
	s, path, sid := policyRegistryFixture(t)
	if err := s.Save([]string{}); err != nil {
		t.Fatal(err)
	}
	if err := s.key.DeleteValue(policyValueName); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Load(); err == nil || err == policyMissing {
		t.Fatal("deleted record treated as new install")
	}
	reopened, err := openPolicyKey(registry.CURRENT_USER, path, s.owner, []string{sid})
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if _, err := reopened.Load(); err == nil || err == policyMissing {
		t.Fatal("missing initialized record lost across restart")
	}
}
