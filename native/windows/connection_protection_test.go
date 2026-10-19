// SPDX-License-Identifier: Apache-2.0
package service

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

type protectionMemoryStore struct {
	memoryPolicy
	enabled                              bool
	loadErr                              error
	failProtectionSave                   bool
	protectionSaves                      int
	protectionEntered, protectionRelease chan struct{}
}

func (s *protectionMemoryStore) LoadProtection() (bool, error) { return s.enabled, s.loadErr }
func (s *protectionMemoryStore) SaveProtection(enabled bool) error {
	if s.protectionEntered != nil {
		close(s.protectionEntered)
		<-s.protectionRelease
	}
	s.protectionSaves++
	if s.failProtectionSave {
		return errors.New("private registry details")
	}
	s.enabled, s.loadErr = enabled, nil
	return nil
}

type protectionFakeGuard struct {
	fakeGuard
	persistent      bool
	inspectionError bool
}

func (g *protectionFakeGuard) ConfigurePersistentProtection(enabled bool) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.persistent = enabled
	return nil
}
func (g *protectionFakeGuard) PersistentArmed() (bool, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.inspectionError {
		return false, errors.New("private WFP error")
	}
	return g.armed && g.persistent, nil
}
func protectionFixture(t *testing.T, g *protectionFakeGuard, s PolicyStore) *Controller {
	t.Helper()
	c, err := NewControllerWithPolicy(g, func(context.Context, exvpn.Profile, []string) (Tunnel, error) {
		_ = g.event("start")
		return &fakeTunnel{g: &g.fakeGuard}, nil
	}, nil, true, s)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Shutdown() })
	return c
}

func TestConnectionProtectionDocumentStrictOwnerAndBoolean(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		b, _ := encodeConnectionProtection("owner-a", enabled)
		got, err := decodeConnectionProtection("owner-a", b)
		if err != nil || got != enabled {
			t.Fatal("confirmed bool lost")
		}
		if _, err := decodeConnectionProtection("owner-b", b); err == nil {
			t.Fatal("cross-owner accepted")
		}
	}
	for _, b := range []string{`{}`, `{"version":1,"owner":"owner-a"}`, `{"version":1,"owner":"owner-a","enabled":null}`, `{"version":1,"owner":"owner-a","enabled":"false"}`, `{"version":1,"owner":"owner-a","enabled":0}`, `{"version":2,"owner":"owner-a","enabled":false}`, `{"version":1,"owner":"owner-a","enabled":false,"extra":true}`, `{"version":1,"owner":"owner-a","enabled":false,"enabled":true}`, `{"version":1,"owner":"owner-a","enabled":false} {}`, strings.Repeat("x", 4097)} {
		got, err := decodeConnectionProtection("owner-a", []byte(b))
		if err == nil || !got {
			t.Fatal("invalid preference must never become OFF")
		}
	}
}

func TestConnectionProtectionProtocolRejectsUnexpectedOrCoercedArguments(t *testing.T) {
	for _, payload := range []string{`{"version":1,"id":"p","command":"getConnectionProtection"}`, `{"version":1,"id":"p","command":"setConnectionProtection","enabled":false}`, `{"version":1,"id":"p","command":"setConnectionProtection","enabled":true}`} {
		if _, err := DecodeRequest([]byte(payload)); err != nil {
			t.Fatal(err)
		}
	}
	for _, payload := range []string{`{"version":1,"id":"p","command":"setConnectionProtection"}`, `{"version":1,"id":"p","command":"setConnectionProtection","enabled":null}`, `{"version":1,"id":"p","command":"setConnectionProtection","enabled":"false"}`, `{"version":1,"id":"p","command":"setConnectionProtection","enabled":0}`, `{"version":1,"id":"p","command":"getConnectionProtection","enabled":false}`, `{"version":1,"id":"p","command":"disconnect","enabled":false}`, `{"version":1,"id":"p","command":"setConnectionProtection","enabled":false,"exclusions":[]}`, `{"version":1,"id":"p","command":"setConnectionProtection","enabled":false,"applicationRouting":{"mode":"disabled","applications":[]}}`} {
		if _, err := DecodeRequest([]byte(payload)); err == nil {
			t.Fatal("invalid protection payload accepted")
		}
	}
}

func TestConnectionProtectionMissingDefaultsOnAndPersistsChoice(t *testing.T) {
	s := &protectionMemoryStore{loadErr: policyMissing}
	c := protectionFixture(t, &protectionFakeGuard{}, s)
	v, err := c.ConnectionProtection()
	if err != nil || !v.Supported || !v.Enabled || v.Active || v.SystemManaged || s.protectionSaves != 1 {
		t.Fatalf("default %+v %v", v, err)
	}
	if err = c.SetConnectionProtection(false); err != nil {
		t.Fatal(err)
	}
	g2 := &protectionFakeGuard{}
	c2 := protectionFixture(t, g2, s)
	v, err = c2.ConnectionProtection()
	if err != nil || v.Enabled || v.Active {
		t.Fatal("OFF not durable")
	}
	if err = c2.Connect(syntheticProfile(), nil); err != nil {
		t.Fatal(err)
	}
	waitState(t, c2, "connected")
	v, err = c2.ConnectionProtection()
	if err != nil || v.Enabled || v.Active || !c2.Status().GuardActive || c2.Status().PersistentGuardActive {
		t.Fatal("OFF must keep live guard without claiming persistence")
	}
	if err = c2.SetConnectionProtection(true); err != Code("connection_protection_requires_disconnected") {
		t.Fatal("active switch allowed")
	}
	if err = c2.Disconnect(); err != nil {
		t.Fatal(err)
	}
	if err = c2.SetConnectionProtection(true); err != nil {
		t.Fatal(err)
	}
	if err = c2.Connect(syntheticProfile(), nil); err != nil {
		t.Fatal(err)
	}
	waitState(t, c2, "connected")
	v, err = c2.ConnectionProtection()
	if err != nil || !v.Enabled || !v.Active || !c2.Status().PersistentGuardActive {
		t.Fatal("ON was not armed")
	}
}

func TestConnectionProtectionStorageFailuresNeverStartUnconfirmedVPN(t *testing.T) {
	for _, missing := range []bool{false, true} {
		s := &protectionMemoryStore{loadErr: errors.New("private failure")}
		if missing {
			s.loadErr = policyMissing
			s.failProtectionSave = true
		}
		g := &protectionFakeGuard{}
		c := protectionFixture(t, g, s)
		if _, err := c.ConnectionProtection(); err != Code("connection_protection_unavailable") {
			t.Fatal("unknown storage advertised")
		}
		if err := c.Connect(syntheticProfile(), nil); err != Code("connection_protection_unavailable") {
			t.Fatal("unknown preference connected")
		}
		if len(g.events) != 0 {
			t.Fatal("core or guard started despite unavailable policy")
		}
	}
	s := &protectionMemoryStore{enabled: true}
	c := protectionFixture(t, &protectionFakeGuard{}, s)
	s.failProtectionSave = true
	if err := c.SetConnectionProtection(false); err != Code("native_storage_unavailable") {
		t.Fatal("failed write acknowledged")
	}
	if err := c.Connect(syntheticProfile(), nil); err != Code("connection_protection_unavailable") {
		t.Fatal("failed OFF became an implicit bypass")
	}
	s.failProtectionSave = false
	if err := c.SetConnectionProtection(true); err != nil {
		t.Fatal(err)
	}
}

func TestConnectionProtectionActualInspectionAndRecoveredGuardAreNotPreference(t *testing.T) {
	g := &protectionFakeGuard{fakeGuard: fakeGuard{armed: true}}
	c := protectionFixture(t, g, &protectionMemoryStore{enabled: true})
	v, err := c.ConnectionProtection()
	if err != nil || !v.Active || !v.Enabled {
		t.Fatal("recovered real latch hidden")
	}
	if err = c.SetConnectionProtection(false); err != Code("connection_protection_requires_disconnected") {
		t.Fatal("recovered latch silently removed")
	}
	c.mu.Lock()
	c.status.Mode = ModeProxy
	c.mu.Unlock()
	v, err = c.ConnectionProtection()
	if err != nil || v.Active {
		t.Fatal("proxy advertised as protected VPN")
	}
	g.mu.Lock()
	g.inspectionError = true
	g.mu.Unlock()
	if _, err = c.ConnectionProtection(); err != Code("connection_protection_unavailable") {
		t.Fatal("WFP query error treated as known state")
	}
}

func TestConnectionProtectionSerializesWithPendingConnectAndDisconnect(t *testing.T) {
	s := &protectionMemoryStore{enabled: true, protectionEntered: make(chan struct{}), protectionRelease: make(chan struct{})}
	c := protectionFixture(t, &protectionFakeGuard{}, s)
	done := make(chan error, 1)
	go func() { done <- c.SetConnectionProtection(false) }()
	<-s.protectionEntered
	if _, err := c.ConnectionProtection(); err != Code("operation_in_progress") {
		t.Fatal("read crossed incomplete preference write")
	}
	connected := make(chan error, 1)
	go func() { connected <- c.Connect(syntheticProfile(), nil) }()
	select {
	case <-connected:
		t.Fatal("connect crossed incomplete durable write")
	case <-time.After(20 * time.Millisecond):
	}
	close(s.protectionRelease)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if err := <-connected; err != nil {
		t.Fatal(err)
	}
	waitState(t, c, "connected")
	if err := c.SetConnectionProtection(true); err != Code("connection_protection_requires_disconnected") {
		t.Fatal("live state raced setter")
	}
	if err := c.Disconnect(); err != nil {
		t.Fatal(err)
	}
}

func TestConnectionProtectionResponsePreservesFalseBoolean(t *testing.T) {
	c := protectionFixture(t, &protectionFakeGuard{}, nil)
	enabled := false
	r := c.Handle(Request{Command: "setConnectionProtection", Enabled: &enabled})
	if !r.OK || r.ConnectionProtection == nil || r.ConnectionProtection.Enabled {
		t.Fatal("setter result invalid")
	}
	b, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	if !bytesContains(b, `"enabled":false`) || !bytesContains(b, `"systemManaged":false`) {
		t.Fatal("false envelope omitted")
	}
}

func bytesContains(b []byte, s string) bool { return strings.Contains(string(b), s) }
