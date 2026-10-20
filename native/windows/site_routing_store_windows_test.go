//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"reflect"
	"testing"

	"golang.org/x/sys/windows/registry"
)

func TestWindowsSiteRoutingDPAPIIsSeparateOwnerBoundAndSurvivesReopen(t *testing.T) {
	s, path, sid := policyRegistryFixture(t)
	if err := s.Save([]string{"C:/Apps/Synthetic.exe"}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.LoadSiteRouting(); err != policyMissing {
		t.Fatal("pre-site installation could not initialize")
	}
	state := fixtureSiteState()
	if err := s.SaveSiteRouting(state); err != nil {
		t.Fatal(err)
	}
	b, err := s.sitePolicyBytes()
	if err != nil || bytes.Contains(b, []byte("example.com")) {
		t.Fatal("site rules persisted in plaintext")
	}
	reopened, err := openPolicyKey(registry.CURRENT_USER, path, s.owner, []string{sid})
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if got, err := reopened.LoadSiteRouting(); err != nil || !reflect.DeepEqual(got, state) {
		t.Fatal("site state reopen failed")
	}
	other := *s
	other.owner = "synthetic-owner-b"
	if _, err := other.LoadSiteRouting(); err == nil {
		t.Fatal("site ciphertext moved to another owner")
	}
	if app, err := s.Load(); err != nil || len(app) != 1 || app[0] != "C:/Apps/Synthetic.exe" {
		t.Fatal("site storage overwrote application policy")
	}
	if err := s.key.SetBinaryValue(policyValueName, b); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Load(); err == nil {
		t.Fatal("site ciphertext accepted as application policy")
	}
}

func TestWindowsSiteRoutingDeletionAfterInitializationIsNotFreshState(t *testing.T) {
	s, _, _ := policyRegistryFixture(t)
	if err := s.SaveSiteRouting(fixtureSiteState()); err != nil {
		t.Fatal(err)
	}
	if err := s.key.DeleteValue(sitePolicyValueName); err != nil {
		t.Fatal(err)
	}
	if _, err := s.LoadSiteRouting(); err != Code("site_routing_unavailable") {
		t.Fatal("missing saved site state silently became disabled")
	}
}
