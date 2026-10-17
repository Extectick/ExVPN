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

func TestDiscordVersionFamilyMatchesOnlyExactKnownRootChannelAndImage(t *testing.T) {
	base := "C:/Users/Synthetic/AppData/Local/Discord/app-1.0.901/Discord.exe"
	for _, path := range []string{"C:/Users/Synthetic/AppData/Local/Discord/app-1.0.902/Discord.exe", `c:\users\synthetic\appdata\local\discord\app-2.1.0\DISCORD.EXE`} {
		if applicationPathKey(base) != applicationPathKey(path) {
			t.Fatal("legitimate updated version lost selection")
		}
	}
	for _, path := range []string{
		"C:/Users/Other/AppData/Local/Discord/app-1.0.902/Discord.exe",
		"C:/Users/Synthetic/AppData/Local/DiscordPTB/app-1.0.902/DiscordPTB.exe",
		"C:/Users/Synthetic/AppData/Local/DiscordCanary/app-1.0.902/DiscordCanary.exe",
		"C:/Users/Synthetic/AppData/Local/Other/app-1.0.902/Discord.exe",
		"C:/Users/Synthetic/AppData/Local/Discord/app-1.0.902/Update.exe",
		"C:/Users/Synthetic/AppData/Local/Discord/app-1.0.902/helpers/Discord.exe",
		"C:/Users/Synthetic/Extra/AppData/Local/Discord/app-1.0.902/Discord.exe",
		"C:/Users/Synthetic/AppData/Local/Discord/app-../Discord.exe",
		"C:/Users/Synthetic/AppData/Local/Discord/app-1.0.902/../Discord.exe",
		"C:/Users/Synthetic/AppData/Local/Discord/app-1.0.902-evil/Discord.exe",
		"C:/Users/Synthetic/AppData/Local/Discord-evil/app-1.0.902/Discord.exe",
		"C:/Users/Synthetic/AppData/Local/Discord/app-1.0.902/Discord.exe.extra",
	} {
		if applicationPathKey(base) == applicationPathKey(path) {
			t.Fatal("unrelated image matched Discord family")
		}
	}
}

func TestRoutingPersistenceMigrationRetainsDisabledSelection(t *testing.T) {
	owner := "S-1-5-21-111-222-333-1001"
	paths := []string{"C:/Apps/Selected.exe"}
	legacy, _ := encodePolicy(owner, paths)
	migrated, err := decodeRoutingPolicy(owner, legacy)
	if err != nil || migrated.Mode != exvpn.RoutingExclude || len(migrated.Applications) != 1 {
		t.Fatal("legacy selection migration failed")
	}
	for _, mode := range []string{exvpn.RoutingDisabled, exvpn.RoutingExclude, exvpn.RoutingInclude} {
		policy := ApplicationRoutingPolicy{Mode: mode, Applications: paths}
		encoded, err := encodeRoutingPolicy(owner, policy)
		if err != nil {
			t.Fatal(err)
		}
		read, err := decodeRoutingPolicy(owner, encoded)
		if err != nil || read.Mode != mode || len(read.Applications) != 1 {
			t.Fatal("mode/selection round-trip failed")
		}
		if mode == exvpn.RoutingDisabled && len(read.effective()) != 0 {
			t.Fatal("disabled selection remained active")
		}
		if _, err := decodeRoutingPolicy("S-1-5-21-999-222-333-1001", encoded); err == nil {
			t.Fatal("policy changed owner")
		}
	}
}

func TestRoutingWireRejectsWrongTypesAndUnexpectedPayloads(t *testing.T) {
	for _, payload := range []string{
		`"applicationRouting":{"mode":"include","applications":[]}`,
		`"applicationRouting":{"mode":"disabled","applications":["C:/Apps/A.exe"]}`,
	} {
		request, err := DecodeRequest([]byte(`{"version":1,"id":"fixture","command":"setApplicationRouting",` + payload + `}`))
		if err != nil || request.ApplicationRouting == nil {
			t.Fatal("valid policy rejected")
		}
	}
	for _, payload := range []string{
		`"applicationRouting":null`,
		`"applicationRouting":{"mode":"direct","applications":[]}`,
		`"applicationRouting":{"mode":"include","applications":null}`,
		`"applicationRouting":{"mode":1,"applications":[]}`,
		`"applicationRouting":{"mode":"include","applications":[1]}`,
		`"applicationRouting":{"mode":"include","applications":[],"direct":true}`,
		`"applicationRouting":{"mode":"include","mode":"exclude","applications":[]}`,
		`"applicationRouting":{"mode":"include","applications":["C:/Apps/A.exe","c:/apps/a.exe"]}`,
	} {
		if _, err := DecodeRequest([]byte(`{"version":1,"id":"fixture","command":"setApplicationRouting",` + payload + `}`)); err == nil {
			t.Fatal("malformed policy accepted")
		}
	}
	if _, err := DecodeRequest([]byte(`{"version":1,"id":"fixture","command":"status","applicationRouting":{"mode":"include","applications":[]}}`)); err == nil {
		t.Fatal("policy accepted on read-only command")
	}
}

func TestIncludeConfigUsesOwnedDispatchAndProtectsDNS(t *testing.T) {
	for _, mode := range []string{exvpn.RoutingDisabled, exvpn.RoutingExclude, exvpn.RoutingInclude} {
		policy := ApplicationRoutingPolicy{Mode: mode, Applications: []string{"C:/Apps/A.exe"}}
		encoded, err := buildTunnelConfigWithRouting(syntheticProfile(), policy, exvpn.ProbeOptions{Port: 10808, Username: "fixture", Password: "fixture"}, nil)
		if err != nil {
			t.Fatal(err)
		}
		var cfg map[string]any
		_ = json.Unmarshal(encoded, &cfg)
		rules := cfg["routing"].(map[string]any)["rules"].([]any)
		if rules[0].(map[string]any)["outboundTag"] != "proxy" || rules[1].(map[string]any)["outboundTag"] != "dns-out" {
			t.Fatal("DNS priority lost")
		}
		if strings.Contains(string(encoded), `"outboundTag":"direct-excluded"`) || strings.Contains(string(encoded), `"process"`) {
			t.Fatal("unsafe direct/process rule")
		}
		tag := rules[2].(map[string]any)["outboundTag"]
		if (mode == exvpn.RoutingDisabled && tag != "proxy") || (mode != exvpn.RoutingDisabled && tag != applicationPolicyTag) {
			t.Fatal("incorrect mode route")
		}
	}
}

func TestRoutingContextIsGenerationSnapshot(t *testing.T) {
	p := ApplicationRoutingPolicy{Mode: exvpn.RoutingInclude, Applications: []string{"C:/Apps/A.exe"}}
	ctx := context.WithValue(context.Background(), applicationRoutingContextKey{}, p.clone())
	p.Applications[0] = "C:/Apps/B.exe"
	read := routingFromContext(ctx, nil)
	read.Applications[0] = "C:/Apps/C.exe"
	if routingFromContext(ctx, nil).Applications[0] != "C:/Apps/A.exe" {
		t.Fatal("caller changed generation policy")
	}
}

type memoryRoutingPolicy struct {
	memoryPolicy
	routing      ApplicationRoutingPolicy
	writeFailure bool
}

func (s *memoryRoutingPolicy) LoadRouting() (ApplicationRoutingPolicy, error) {
	return s.routing.clone(), s.err
}
func (s *memoryRoutingPolicy) SaveRouting(p ApplicationRoutingPolicy) error {
	if s.writeFailure {
		return Code("native_storage_unavailable")
	}
	s.routing = p.clone()
	s.err = nil
	return nil
}

func TestModernRoutingAtomicPersistenceAndLegacyCompatibility(t *testing.T) {
	store := &memoryRoutingPolicy{routing: legacyApplicationRouting([]string{"C:/Apps/A.exe"})}
	c := policyController(t, &fakeGuard{}, store, nil)
	for _, mode := range []string{exvpn.RoutingDisabled, exvpn.RoutingInclude, exvpn.RoutingExclude} {
		policy := ApplicationRoutingPolicy{Mode: mode, Applications: []string{"C:/Apps/A.exe"}}
		if r := c.Handle(Request{Command: "setApplicationRouting", ApplicationRouting: &policy}); !r.OK {
			t.Fatal(r.Code)
		}
		read := c.Handle(Request{Command: "getApplicationRouting"})
		if !read.OK || !reflect.DeepEqual(*read.ApplicationRouting, policy) {
			t.Fatal("mode/selection not confirmed atomically")
		}
		legacy := c.Handle(Request{Command: "getExclusions"})
		if !legacy.OK || ((len(legacy.Exclusions) == 1) != (mode == exvpn.RoutingExclude)) {
			t.Fatal("legacy interface exposed include/disabled as exclusions")
		}
	}
	store.writeFailure = true
	policy := ApplicationRoutingPolicy{Mode: exvpn.RoutingInclude, Applications: []string{"C:/Apps/B.exe"}}
	if r := c.Handle(Request{Command: "setApplicationRouting", ApplicationRouting: &policy}); r.OK || r.Code != "native_storage_unavailable" {
		t.Fatal("failed persistence accepted")
	}
	if r := c.Handle(Request{Command: "getApplicationRouting"}); r.OK {
		t.Fatal("uncertain write exposed confirmed policy")
	}
	store.writeFailure = false
	if r := c.Handle(Request{Command: "setExclusions", Exclusions: []string{}}); !r.OK {
		t.Fatal(r.Code)
	}
	if store.routing.Mode != exvpn.RoutingDisabled || len(store.routing.Applications) != 0 {
		t.Fatal("legacy reset failed")
	}
}

func TestModernConnectCapturesPolicyWithoutReplacingMode(t *testing.T) {
	store := &memoryRoutingPolicy{routing: ApplicationRoutingPolicy{Mode: exvpn.RoutingInclude, Applications: []string{"C:/Apps/A.exe"}}}
	g := &fakeGuard{}
	captured := make(chan ApplicationRoutingPolicy, 1)
	c, err := NewControllerWithPolicy(g, func(ctx context.Context, _ exvpn.Profile, paths []string) (Tunnel, error) {
		captured <- routingFromContext(ctx, paths)
		return &fakeTunnel{g: g}, nil
	}, nil, true, store)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Shutdown()
	if err := c.ConnectMode(syntheticProfile(), ModeVPN); err != nil {
		t.Fatal(err)
	}
	if policy := <-captured; policy.Mode != exvpn.RoutingInclude || len(policy.Applications) != 1 {
		t.Fatal("stored mode lost before core start")
	}
	waitState(t, c, "connected")
	p := ApplicationRoutingPolicy{Mode: exvpn.RoutingDisabled, Applications: []string{}}
	if r := c.Handle(Request{Command: "setApplicationRouting", ApplicationRouting: &p}); r.OK || r.Code != "reconnect_required" {
		t.Fatal("live policy changed in place")
	}
}

func TestLegacyDiscordReadMigratesToStableAnchorWithoutInstalledApp(t *testing.T) {
	old := "C:/Users/Synthetic/AppData/Local/Discord/app-1.0.1/Discord.exe"
	anchor := "c:/users/synthetic/appdata/local/discord/discord.exe"
	encoded, _ := encodePolicy("fixture-owner", []string{old, "C:/Users/Synthetic/AppData/Local/Discord/app-1.0.2/Discord.exe"})
	policy, err := decodeRoutingPolicy("fixture-owner", encoded)
	if err != nil || len(policy.Applications) != 1 || policy.Applications[0] != anchor {
		t.Fatal("legacy family ID did not migrate")
	}
	if applicationOwnerKey(anchor) == applicationPathKey(anchor) {
		t.Fatal("virtual anchor granted access to a root executable")
	}
	if applicationOwnerKey("C:/Users/Synthetic/AppData/Local/Discord/app-2.0.0/Discord.exe") != anchor {
		t.Fatal("new version did not retain same family")
	}
}

func TestDisablingRetainsUnavailablePriorSelectionWithoutGrantingPermission(t *testing.T) {
	store := &memoryRoutingPolicy{routing: ApplicationRoutingPolicy{Mode: exvpn.RoutingExclude, Applications: []string{"C:/Apps/Old.exe"}}}
	c, err := NewControllerWithPolicy(&fakeGuard{}, nil, func(paths []string) error {
		if len(paths) > 0 {
			return Code("exclusions_rejected")
		}
		return nil
	}, true, store)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Shutdown()
	policy := ApplicationRoutingPolicy{Mode: exvpn.RoutingDisabled, Applications: []string{"C:/Apps/Old.exe"}}
	if r := c.Handle(Request{Command: "setApplicationRouting", ApplicationRouting: &policy}); !r.OK {
		t.Fatal("unavailable saved selection blocked disabling", r.Code)
	}
	policy.Mode = exvpn.RoutingInclude
	if r := c.Handle(Request{Command: "setApplicationRouting", ApplicationRouting: &policy}); r.OK {
		t.Fatal("unavailable selection earned direct routing")
	}
	policy.Mode = exvpn.RoutingDisabled
	policy.Applications = []string{"C:/Apps/NewMissing.exe"}
	if r := c.Handle(Request{Command: "setApplicationRouting", ApplicationRouting: &policy}); r.OK {
		t.Fatal("new unconfirmed identity accepted")
	}
}
