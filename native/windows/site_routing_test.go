// SPDX-License-Identifier: Apache-2.0
package service

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

func fixtureSiteState() exvpn.SiteRoutingState {
	state := exvpn.DefaultSiteRoutingState()
	state.Policy = exvpn.SiteRoutingPolicy{Mode: exvpn.RoutingInclude, Rules: []string{"example.com", "203.0.113.0/24"}}
	state.SavedPresets = []exvpn.SiteRoutingPreset{{ID: "user-synthetic", Name: "Мой список", Policy: state.Policy.Clone()}}
	state.SelectedPreset = "user-synthetic"
	return state
}

func TestSiteRoutingOwnerEnvelopeRejectsWrongOwnerAndMalformedState(t *testing.T) {
	state := fixtureSiteState()
	b, err := encodeSitePolicy("owner-a", state)
	if err != nil {
		t.Fatal(err)
	}
	got, err := decodeSitePolicy("owner-a", b)
	if err != nil || !reflect.DeepEqual(got, state) {
		t.Fatal("site policy did not round-trip")
	}
	if _, err := decodeSitePolicy("owner-b", b); err == nil {
		t.Fatal("owner copy accepted")
	}
	for _, raw := range []string{
		strings.Replace(string(b), `"schema":1`, `"schema":1,"schema":1`, 1),
		strings.Replace(string(b), `"schema":1`, `"schema":2`, 1),
		strings.Replace(string(b), `"example.com"`, `"EXAMPLE.com"`, 1),
		strings.Replace(string(b), `"rules":[`, `"extra":true,"rules":[`, 1),
		string(b) + `{}`,
	} {
		if _, err := decodeSitePolicy("owner-a", []byte(raw)); err == nil {
			t.Fatal("malformed site document accepted")
		}
	}
}

func TestSiteRoutingIPCIsClosedAndCannotRideConnectOrStatus(t *testing.T) {
	state := fixtureSiteState()
	b, _ := json.Marshal(Request{Version: 1, ID: "fixture", Command: "set_site_routing", SiteRouting: &state})
	if r, err := DecodeRequest(b); err != nil || r.SiteRouting == nil {
		t.Fatal("valid site state rejected")
	}
	for _, command := range []string{"status", "get_site_routing", "getApplicationRouting", "connect"} {
		b, _ = json.Marshal(Request{Version: 1, ID: "fixture", Command: command, SiteRouting: &state})
		if _, err := DecodeRequest(b); err == nil {
			t.Fatal("site state entered unrelated command")
		}
	}
	for _, raw := range []string{
		`{"version":1,"id":"fixture","command":"set_site_routing","siteRouting":null}`,
		`{"version":1,"id":"fixture","command":"set_site_routing","siteRouting":{}}`,
		`{"version":1,"id":"fixture","command":"set_site_routing"}`,
		`{"version":1,"id":"fixture","command":"get_site_routing","exclusions":[]}`,
	} {
		if _, err := DecodeRequest([]byte(raw)); err == nil {
			t.Fatal("invalid site IPC accepted")
		}
	}
}

func nonExactSiteStates(t *testing.T) map[string]json.RawMessage {
	t.Helper()
	valid, err := json.Marshal(fixtureSiteState())
	if err != nil {
		t.Fatal(err)
	}
	raw := string(valid)
	return map[string]json.RawMessage{
		"missing-selection":      []byte(strings.Replace(raw, `,"selectedPreset":"user-synthetic"`, ``, 1)),
		"wrong-case-selection":   []byte(strings.Replace(raw, `"selectedPreset":`, `"SelectedPreset":`, 1)),
		"case-alias-selection":   []byte(strings.Replace(raw, `"selectedPreset":`, `"SelectedPreset":"user-synthetic","selectedPreset":`, 1)),
		"wrong-case-policy-mode": []byte(strings.Replace(raw, `"mode":`, `"Mode":`, 1)),
		"case-alias-policy-mode": []byte(strings.Replace(raw, `"mode":`, `"Mode":"include","mode":`, 1)),
		"missing-preset-name":    []byte(strings.Replace(raw, `,"name":"Мой список"`, ``, 1)),
		"wrong-case-preset-id":   []byte(strings.Replace(raw, `"id":`, `"Id":`, 1)),
		"case-alias-preset-id":   []byte(strings.Replace(raw, `"id":`, `"Id":"user-synthetic","id":`, 1)),
	}
}

func TestSiteRoutingIPCDecodesRawStateWithExactSchemaKeys(t *testing.T) {
	for name, state := range nonExactSiteStates(t) {
		t.Run(name, func(t *testing.T) {
			raw, err := json.Marshal(map[string]any{
				"version": 1, "id": "fixture", "command": "set_site_routing", "siteRouting": state,
			})
			if err != nil {
				t.Fatal(err)
			}
			if _, err := DecodeRequest(raw); err != Code("site_routing_rejected") {
				t.Fatal("non-exact site state accepted at IPC boundary or unsafe error")
			}
		})
	}
	valid, err := json.Marshal(fixtureSiteState())
	if err != nil {
		t.Fatal(err)
	}
	for _, aliases := range []map[string]any{
		{"SiteRouting": json.RawMessage(valid)},
		{"siteRouting": json.RawMessage(valid), "SiteRouting": json.RawMessage(valid)},
	} {
		aliases["version"], aliases["id"], aliases["command"] = 1, "fixture", "set_site_routing"
		raw, err := json.Marshal(aliases)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := DecodeRequest(raw); err != Code("site_routing_rejected") {
			t.Fatal("case alias for siteRouting accepted at IPC boundary")
		}
	}
}

func TestSiteRoutingStoreRequiresExactOwnerEnvelopeAndRawState(t *testing.T) {
	for name, state := range nonExactSiteStates(t) {
		t.Run(name, func(t *testing.T) {
			raw, err := json.Marshal(map[string]any{"version": 1, "owner": "owner-a", "state": state})
			if err != nil {
				t.Fatal(err)
			}
			if _, err := decodeSitePolicy("owner-a", raw); err != Code("site_routing_unavailable") {
				t.Fatal("non-exact persisted site state accepted or unsafe error")
			}
		})
	}
	valid, err := encodeSitePolicy("owner-a", fixtureSiteState())
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"version", "owner", "state"} {
		for _, mutation := range []string{"missing", "wrong-case", "case-alias"} {
			t.Run(key+"/"+mutation, func(t *testing.T) {
				var fields map[string]json.RawMessage
				if err := json.Unmarshal(valid, &fields); err != nil {
					t.Fatal(err)
				}
				value := fields[key]
				if mutation != "case-alias" {
					delete(fields, key)
				}
				if mutation != "missing" {
					fields[strings.ToUpper(key[:1])+key[1:]] = value
				}
				raw, err := json.Marshal(fields)
				if err != nil {
					t.Fatal(err)
				}
				if _, err := decodeSitePolicy("owner-a", raw); err != Code("site_routing_unavailable") {
					t.Fatal("non-exact owner envelope accepted")
				}
			})
		}
	}
}

type memorySitePolicy struct {
	memoryRoutingPolicy
	state            exvpn.SiteRoutingState
	siteReadError    error
	siteWriteFailure bool
}

func newMemorySitePolicy() *memorySitePolicy {
	return &memorySitePolicy{memoryRoutingPolicy: memoryRoutingPolicy{routing: legacyApplicationRouting(nil)}, state: exvpn.DefaultSiteRoutingState()}
}
func (s *memorySitePolicy) LoadSiteRouting() (exvpn.SiteRoutingState, error) {
	return s.state.Clone(), s.siteReadError
}
func (s *memorySitePolicy) SaveSiteRouting(state exvpn.SiteRoutingState) error {
	if s.siteWriteFailure {
		return Code("native_storage_unavailable")
	}
	s.state, s.siteReadError = state.Clone(), nil
	return nil
}

func TestSiteRoutingDurableStateAndFailedWriteDoNotSilentlyReset(t *testing.T) {
	store := newMemorySitePolicy()
	c := policyController(t, &fakeGuard{}, store, nil)
	state := fixtureSiteState()
	if r := c.Handle(Request{Command: "set_site_routing", SiteRouting: &state}); !r.OK {
		t.Fatal(r.Code)
	}
	state.Policy.Rules[0] = "changed.example"
	read := c.Handle(Request{Command: "get_site_routing"})
	if !read.OK || read.SiteRouting.Policy.Rules[0] != "example.com" {
		t.Fatal("policy aliased input")
	}
	store.siteWriteFailure = true
	if r := c.Handle(Request{Command: "set_site_routing", SiteRouting: &state}); r.OK || r.Code != "native_storage_unavailable" {
		t.Fatal("write failure acknowledged")
	}
	if r := c.Handle(Request{Command: "get_site_routing"}); r.OK {
		t.Fatal("uncertain write presented as confirmed")
	}
	if err := c.ConnectMode(syntheticProfile(), ModeVPN); err != Code("site_routing_unavailable") {
		t.Fatal("uncertain site state allowed connection")
	}
	store.siteWriteFailure = false
	if r := c.Handle(Request{Command: "set_site_routing", SiteRouting: &state}); !r.OK {
		t.Fatal("explicit recovery failed")
	}
	if r := c.Handle(Request{Command: "getApplicationRouting"}); !r.OK {
		t.Fatal("site state destroyed application policy")
	}
}

func TestSiteRoutingMissingUpgradeSeedsButRecoveredGuardDoesNotForget(t *testing.T) {
	store := newMemorySitePolicy()
	store.siteReadError = policyMissing
	c := policyController(t, &fakeGuard{}, store, nil)
	if r := c.Handle(Request{Command: "get_site_routing"}); !r.OK || r.SiteRouting.Policy.Mode != exvpn.RoutingDisabled {
		t.Fatal("new site policy could not seed")
	}
	store2 := newMemorySitePolicy()
	store2.siteReadError = policyMissing
	recovered := policyController(t, &fakeGuard{armed: true}, store2, nil)
	if r := recovered.Handle(Request{Command: "get_site_routing"}); r.OK {
		t.Fatal("recovered guard silently initialized site policy")
	}
	if err := recovered.ConnectMode(syntheticProfile(), ModeVPN); err != Code("site_routing_unavailable") {
		t.Fatal("unknown recovered site state allowed VPN")
	}
}

func TestSiteRoutingContextAndLiveEditingPreserveGeneration(t *testing.T) {
	store := newMemorySitePolicy()
	store.state = fixtureSiteState()
	g := &fakeGuard{}
	captured := make(chan exvpn.SiteRoutingPolicy, 1)
	c, err := NewControllerWithPolicy(g, func(ctx context.Context, _ exvpn.Profile, _ []string) (Tunnel, error) {
		captured <- siteRoutingFromContext(ctx)
		return &fakeTunnel{g: g}, nil
	}, nil, true, store)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Shutdown()
	if err := c.ConnectMode(syntheticProfile(), ModeVPN); err != nil {
		t.Fatal(err)
	}
	policy := <-captured
	if !reflect.DeepEqual(policy, store.state.Policy) {
		t.Fatal("site policy lost before core start")
	}
	waitState(t, c, "connected")
	state := exvpn.DefaultSiteRoutingState()
	if r := c.Handle(Request{Command: "set_site_routing", SiteRouting: &state}); r.OK || r.Code != "site_routing_requires_disconnected" {
		t.Fatal("live generation policy changed")
	}
	policy.Rules[0] = "changed.example"
	if siteRoutingFromContext(c.context).Rules[0] != "example.com" {
		t.Fatal("captured policy aliases caller")
	}
}

func TestSiteRoutingProxyRejectsActivePolicyRatherThanIgnoringIt(t *testing.T) {
	store := newMemorySitePolicy()
	store.state = fixtureSiteState()
	c := policyController(t, &fakeGuard{}, store, nil)
	if err := c.ConnectMode(syntheticProfile(), ModeProxy); err != Code("site_routing_requires_vpn") {
		t.Fatal("proxy ignored active site policy")
	}
	state := store.state.Clone()
	state.Policy.Mode = exvpn.RoutingDisabled
	if r := c.Handle(Request{Command: "set_site_routing", SiteRouting: &state}); !r.OK {
		t.Fatal(r.Code)
	}
	if err := c.ConnectMode(syntheticProfile(), ModeProxy); err != Code("proxy_unavailable") {
		t.Fatal("disabled site selection still affected proxy")
	}
}
