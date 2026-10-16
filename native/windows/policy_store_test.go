// SPDX-License-Identifier: Apache-2.0
package service

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"sync"
	"testing"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

type memoryPolicy struct {
	paths         []string
	err           error
	failSave      bool
	saves         int
	gate, entered chan struct{}
	once          sync.Once
}

func (s *memoryPolicy) Load() ([]string, error) { return append([]string{}, s.paths...), s.err }
func (s *memoryPolicy) Save(paths []string) error {
	if s.gate != nil {
		s.once.Do(func() { close(s.entered); <-s.gate })
	}
	s.saves++
	if s.failSave {
		return errors.New("private storage details")
	}
	s.paths, s.err = append([]string{}, paths...), nil
	return nil
}

func policyController(t *testing.T, g *fakeGuard, s PolicyStore, capture func([]string)) *Controller {
	t.Helper()
	c, err := NewControllerWithPolicy(g, func(_ context.Context, _ exvpn.Profile, paths []string) (Tunnel, error) {
		if capture != nil {
			capture(paths)
		}
		return &fakeTunnel{g: g}, nil
	}, nil, true, s)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Shutdown() })
	return c
}

func TestPolicyStrictSchemaAndOwnerBinding(t *testing.T) {
	valid, err := encodePolicy("owner-a", []string{"C:/Apps/example.exe"})
	if err != nil {
		t.Fatal(err)
	}
	if paths, err := decodePolicy("owner-a", valid); err != nil || len(paths) != 1 {
		t.Fatal("valid policy rejected")
	}
	for _, b := range [][]byte{
		valid,
		[]byte(`{"version":1,"owner":"owner-b","paths":null}`),
		[]byte(`{"version":2,"owner":"owner-b","paths":[]}`),
		[]byte(`{"version":1,"owner":"owner-b","paths":[],"paths":[]}`),
		[]byte(`{"version":1,"owner":"owner-b","paths":[],"routing":{}}`),
		[]byte(`{"version":1,"owner":"owner-b","paths":[42]}`),
		[]byte(`{"version":1,"owner":"owner-b","paths":["C:/Apps/../other.exe"]}`),
		[]byte(`{"version":1,"owner":"owner-b","paths":[]} {}`),
		make([]byte, maxPolicyBytes+1),
	} {
		if _, err := decodePolicy("owner-b", b); err == nil {
			t.Fatal("invalid/cross-owner policy accepted")
		}
	}
	if _, err := encodePolicy("owner-a", make([]string, 129)); err == nil {
		t.Fatal("oversize policy accepted")
	}
}

func TestPolicySurvivesControllerCrashAndExplicitDisconnect(t *testing.T) {
	store := &memoryPolicy{err: policyMissing}
	before := policyController(t, &fakeGuard{}, store, nil)
	paths := []string{"C:/Apps/example.exe"}
	if r := before.Handle(Request{Command: "setExclusions", Exclusions: paths}); !r.OK {
		t.Fatal(r.Code)
	}
	g := &fakeGuard{armed: true}
	recovered := policyController(t, g, store, nil)
	if r := recovered.Handle(Request{Command: "getExclusions"}); !r.OK || !reflect.DeepEqual(r.Exclusions, paths) {
		t.Fatal("confirmed policy not restored")
	}
	if recovered.Status().State != "blocked" || !g.armed {
		t.Fatal("loading settings released protection")
	}
	if err := recovered.Disconnect(); err != nil {
		t.Fatal(err)
	}
	if r := recovered.Handle(Request{Command: "getExclusions"}); !r.OK || !reflect.DeepEqual(r.Exclusions, paths) {
		t.Fatal("disconnect erased exclusions")
	}
}

func TestFailedPolicyCannotBecomeAnImplicitEmptyRoute(t *testing.T) {
	for _, loadErr := range []error{policyMissing, errors.New("corrupt")} {
		g := &fakeGuard{armed: true}
		store := &memoryPolicy{err: loadErr}
		c := policyController(t, g, store, nil)
		if err := c.Disconnect(); err != nil {
			t.Fatal(err)
		}
		if r := c.Handle(Request{Command: "getExclusions"}); r.OK || r.Code != "exclusions_unavailable" {
			t.Fatal("lost unknown policy after disconnect")
		}
		profile, _ := json.Marshal(syntheticProfile())
		if r := c.Handle(Request{Command: "connect", Profile: profile}); r.OK || r.Code != "exclusions_unavailable" {
			t.Fatal("connected using an implicit empty policy")
		}
		if store.saves != 0 {
			t.Fatal("overwrote unreadable settings automatically")
		}
		if r := c.Handle(Request{Command: "setExclusions", Exclusions: []string{}}); !r.OK {
			t.Fatal("explicit reset failed", r.Code)
		}
		if r := c.Handle(Request{Command: "getExclusions"}); !r.OK || len(r.Exclusions) != 0 {
			t.Fatal("reset was not confirmed")
		}
	}
}

func TestPolicySaveFailureDoesNotStartTunnelOrPublishNewSettings(t *testing.T) {
	store := &memoryPolicy{paths: []string{"C:/Apps/old.exe"}, failSave: true}
	g := &fakeGuard{}
	c := policyController(t, g, store, nil)
	if err := c.Connect(syntheticProfile(), []string{"C:/Apps/new.exe"}); err != Code("native_storage_unavailable") {
		t.Fatal("lost storage error")
	}
	if g.armed || c.Status().State == "connecting" {
		t.Fatal("started a tunnel before durable policy confirmation")
	}
	if r := c.Handle(Request{Command: "getExclusions"}); r.OK {
		t.Fatal("uncertain policy presented as confirmed")
	}
	if !reflect.DeepEqual(store.paths, []string{"C:/Apps/old.exe"}) {
		t.Fatal("test store changed after failed write")
	}
}

func TestExplicitPolicyResetClearsOnlyTheStorageErrorAndKeepsGuard(t *testing.T) {
	for _, armed := range []bool{false, true} {
		store := &memoryPolicy{err: errors.New("corrupt")}
		g := &fakeGuard{armed: armed}
		c := policyController(t, g, store, nil)
		if r := c.Handle(Request{Command: "setExclusions", Exclusions: []string{}}); !r.OK {
			t.Fatal(r.Code)
		}
		want := "disconnected"
		if armed {
			want = "blocked"
		}
		if c.Status().State != want || g.armed != armed {
			t.Fatal("reset retained a stale error or changed protection")
		}
	}
}

func TestConnectUsesLatestSerializedConfirmedPolicy(t *testing.T) {
	store := &memoryPolicy{paths: []string{}, gate: make(chan struct{}), entered: make(chan struct{})}
	captured := make(chan []string, 1)
	c := policyController(t, &fakeGuard{}, store, func(paths []string) { captured <- paths })
	paths := []string{"C:/Apps/new.exe"}
	setDone := make(chan Response, 1)
	go func() { setDone <- c.Handle(Request{Command: "setExclusions", Exclusions: paths}) }()
	<-store.entered
	profile, _ := json.Marshal(syntheticProfile())
	connectDone := make(chan Response, 1)
	go func() { connectDone <- c.Handle(Request{Command: "connect", Profile: profile}) }()
	close(store.gate)
	if r := <-setDone; !r.OK {
		t.Fatal(r.Code)
	}
	if r := <-connectDone; !r.OK {
		t.Fatal(r.Code)
	}
	if got := <-captured; !reflect.DeepEqual(got, paths) {
		t.Fatal("connect used a stale pre-save policy")
	}
	waitState(t, c, "connected")
}
