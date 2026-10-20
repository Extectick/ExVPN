// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/netip"
	"reflect"
	"strings"
	"testing"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
)

func TestSiteCanonicalRulesHaveOneStableNativeFormat(t *testing.T) {
	for input, want := range map[string]string{
		"EXAMPLE.COM.":          "example.com",
		"sub.example.com":       "sub.example.com",
		"XN--E1AFMKFD.XN--P1AI": "xn--e1afmkfd.xn--p1ai",
		"192.0.2.1":             "192.0.2.1",
		"192.0.2.129/24":        "192.0.2.0/24",
		"0.0.0.0/0":             "0.0.0.0/0",
		"2001:0DB8:0000:0000:0000:0000:0000:0001": "2001:db8::1",
		"2001:db8:abcd::1234/48":                  "2001:db8:abcd::/48",
		"::ffff:192.0.2.1":                        "192.0.2.1",
		"::ffff:c000:201":                         "192.0.2.1",
		"::ffff:192.0.2.129/120":                  "192.0.2.0/24",
		"::ffff:192.0.2.129/96":                   "0.0.0.0/0",
		"::ffff:192.0.2.129/80":                   "::/80",
		"2001:db8::1/0":                           "::/0",
	} {
		t.Run(input, func(t *testing.T) {
			actual, err := CanonicalRule(input)
			if err != nil || actual != want {
				t.Fatalf("canonical = %q, %v; want %q", actual, err, want)
			}
			if again, err := CanonicalRule(actual); err != nil || again != actual {
				t.Fatal("canonicalization is not idempotent")
			}
		})
	}
}

func TestSiteRulesRejectConfigSyntaxAmbiguousIPsAndUnsafeNames(t *testing.T) {
	for _, input := range []string{
		"", "example", "localhost", "example..com", ".example.com", "example.com..",
		"-bad.example", "bad-.example", "_service.example", "bad.123",
		"001.2.3.4", "192.0.2.999", "127.1", "0x7f000001", "192.0.2.1.",
		"192.0.2.1/33", "2001:db8::1/129", "fe80::1%eth0", "[2001:db8::1]",
		"example.com:443", "192.0.2.1:443", "https://example.com", "example.com/path",
		"example.com?token=synthetic", "user@example.com", "*.example.com", "geosite:ru",
		"regexp:.*", "full:example.com", " пример.рф", "пример.рф", "example.com\x00",
		" example.com", "example.com ", "example\n.com", strings.Repeat("a", 64) + ".example",
		strings.Repeat("a", 255) + ".example",
	} {
		t.Run(input, func(t *testing.T) {
			if _, err := CanonicalRule(input); err == nil || err.Error() != "site_routing_rejected" {
				t.Fatalf("unsafe rule accepted, or value-bearing error: %v", err)
			}
		})
	}
}

func siteStateJSON(t *testing.T, s SiteRoutingState) []byte {
	t.Helper()
	data, err := json.Marshal(s)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestSiteStateStrictDecodeRejectsMalformedAndProviderInjectedFields(t *testing.T) {
	valid := `{"schema":1,"policy":{"mode":"include","rules":["example.com"]},"savedPresets":[],"selectedPreset":"russia-basic"}`
	if _, err := DecodeSiteRoutingState([]byte(valid)); err != nil {
		t.Fatal(err)
	}
	for _, raw := range []string{
		"", "null", "[]", `{}`, valid + `{}`,
		strings.Replace(valid, `"schema":1`, `"schema":1.0`, 1),
		strings.Replace(valid, `"schema":1`, `"schema":"1"`, 1),
		strings.Replace(valid, `"schema":1`, `"schema":1,"schema":2`, 1),
		strings.Replace(valid, `"schema":1,`, ``, 1),
		strings.Replace(valid, `"schema":1`, `"schema":2`, 1),
		strings.Replace(valid, `"rules":["example.com"]`, `"rules":null`, 1),
		strings.Replace(valid, `"rules":["example.com"]`, `"rules":[null]`, 1),
		strings.Replace(valid, `"rules":["example.com"]`, `"rules":"example.com"`, 1),
		strings.Replace(valid, `"rules":["example.com"]`, `"rules":["EXAMPLE.COM"]`, 1),
		strings.Replace(valid, `"rules":["example.com"]`, `"rules":["example.com","example.com"]`, 1),
		strings.Replace(valid, `"rules":["example.com"]`, `"rules":["geosite:ru"]`, 1),
		strings.Replace(valid, `"rules":["example.com"]`, `"rules":["example.com"],"inbounds":[]`, 1),
		strings.Replace(valid, `"savedPresets":[]`, `"savedPresets":null`, 1),
		strings.Replace(valid, `"selectedPreset":"russia-basic"`, `"selectedPreset":null`, 1),
		strings.Replace(valid, `,"selectedPreset":"russia-basic"`, ``, 1),
		strings.Replace(valid, `"schema":1`, `"schema":1,"routing":{}`, 1),
	} {
		if _, err := DecodeSiteRoutingState([]byte(raw)); err == nil || err.Error() != "site_routing_rejected" {
			t.Fatalf("malformed state accepted or unsafe error: %v", err)
		}
	}
	for _, mutate := range []func(*SiteRoutingState){
		func(s *SiteRoutingState) { s.Policy.Rules = nil },
		func(s *SiteRoutingState) { s.SavedPresets = nil },
		func(s *SiteRoutingState) { s.SelectedPreset = "https://source.invalid" },
		func(s *SiteRoutingState) { s.Policy.Mode = "unknown" },
		func(s *SiteRoutingState) {
			s.SavedPresets = []SiteRoutingPreset{{ID: "test", Name: "Preset", Policy: SiteRoutingPolicy{Mode: RoutingDisabled, Rules: []string{}}}, {ID: "test", Name: "Other", Policy: SiteRoutingPolicy{Mode: RoutingDisabled, Rules: []string{}}}}
		},
		func(s *SiteRoutingState) {
			s.SavedPresets = []SiteRoutingPreset{{ID: "../bad", Name: "Preset", Policy: SiteRoutingPolicy{Mode: RoutingDisabled, Rules: []string{}}}}
		},
		func(s *SiteRoutingState) {
			s.SavedPresets = []SiteRoutingPreset{{ID: "test", Name: "Bad\u202eName", Policy: SiteRoutingPolicy{Mode: RoutingDisabled, Rules: []string{}}}}
		},
		func(s *SiteRoutingState) {
			s.SavedPresets = []SiteRoutingPreset{{ID: "test", Name: strings.Repeat("Я", 81), Policy: SiteRoutingPolicy{Mode: RoutingDisabled, Rules: []string{}}}}
		},
	} {
		state := DefaultSiteRoutingState()
		mutate(&state)
		if state.Validate() == nil {
			t.Fatal("invalid in-memory state accepted")
		}
	}
}

func TestSiteStateEveryDTOObjectRejectsMissingCaseAliasesAndShadowFields(t *testing.T) {
	state := DefaultSiteRoutingState()
	state.SavedPresets = []SiteRoutingPreset{{ID: "saved", Name: "Saved", Policy: state.Policy.Clone()}}
	valid := siteStateJSON(t, state)
	targets := []struct {
		name   string
		object func(map[string]any) map[string]any
	}{
		{"state", func(root map[string]any) map[string]any { return root }},
		{"policy", func(root map[string]any) map[string]any { return root["policy"].(map[string]any) }},
		{"preset", func(root map[string]any) map[string]any { return root["savedPresets"].([]any)[0].(map[string]any) }},
		{"preset-policy", func(root map[string]any) map[string]any {
			return root["savedPresets"].([]any)[0].(map[string]any)["policy"].(map[string]any)
		}},
	}
	for _, target := range targets {
		var root map[string]any
		if err := json.Unmarshal(valid, &root); err != nil {
			t.Fatal(err)
		}
		for key := range target.object(root) {
			for _, mutation := range []string{"missing", "wrong-case", "case-alias"} {
				t.Run(target.name+"/"+key+"/"+mutation, func(t *testing.T) {
					var copy map[string]any
					if err := json.Unmarshal(valid, &copy); err != nil {
						t.Fatal(err)
					}
					object := target.object(copy)
					value := object[key]
					if mutation != "case-alias" {
						delete(object, key)
					}
					if mutation != "missing" {
						object[strings.ToUpper(key[:1])+key[1:]] = value
					}
					raw, err := json.Marshal(copy)
					if err != nil {
						t.Fatal(err)
					}
					if _, err = DecodeSiteRoutingState(raw); err == nil || err.Error() != "site_routing_rejected" {
						t.Fatal("non-exact local policy DTO accepted or error exposed input")
					}
				})
			}
		}
	}
}

func TestSiteStateClonePreservesEmptyListsAndDoesNotAliasUserData(t *testing.T) {
	state := DefaultSiteRoutingState()
	if state.Validate() != nil || state.Clone().Validate() != nil {
		t.Fatal("invalid default/clone")
	}
	state.Policy = SiteRoutingPolicy{Mode: RoutingExclude, Rules: []string{"example.com"}}
	state.SavedPresets = []SiteRoutingPreset{{ID: "user-1", Name: "Мой пресет", Policy: SiteRoutingPolicy{Mode: RoutingInclude, Rules: []string{"other.example"}}}}
	copy := state.Clone()
	copy.Policy.Rules[0] = "changed.example"
	copy.SavedPresets[0].Policy.Rules[0] = "changed.example"
	copy.SavedPresets[0].Name = "Changed"
	if state.Policy.Rules[0] != "example.com" || state.SavedPresets[0].Policy.Rules[0] != "other.example" || state.SavedPresets[0].Name != "Мой пресет" {
		t.Fatal("clone aliases source policy")
	}
	decoded, err := DecodeSiteRoutingState(siteStateJSON(t, state))
	if err != nil || !reflect.DeepEqual(decoded, state) {
		t.Fatal("roundtrip changed a valid local policy")
	}
}

func siteTestRules(count int, long bool) []string {
	rules := make([]string, count)
	for i := range rules {
		label := strings.Repeat("a", 57)
		// A small numeric prefix keeps all generated domains distinct.
		number := []byte{byte('0' + i/1000), byte('0' + (i/100)%10), byte('0' + (i/10)%10), byte('0' + i%10)}
		if long {
			rules[i] = strings.Repeat("a", 63) + "." + strings.Repeat("b", 63) + "." + strings.Repeat("c", 63) + "." + string(number) + label
		} else {
			rules[i] = "node" + string(number) + ".example"
		}
	}
	return rules
}

func TestSiteStateBoundsAreCheckedBeforePersistence(t *testing.T) {
	state := DefaultSiteRoutingState()
	state.Policy.Rules = siteTestRules(MaxSiteRules+1, false)
	if state.Validate() == nil {
		t.Fatal("too many rules accepted")
	}
	state = DefaultSiteRoutingState()
	for i := 0; i < MaxSitePresets+1; i++ {
		state.SavedPresets = append(state.SavedPresets, SiteRoutingPreset{ID: "user-" + string(rune('a'+i)), Name: "Preset", Policy: SiteRoutingPolicy{Mode: RoutingDisabled, Rules: []string{}}})
	}
	if state.Validate() == nil {
		t.Fatal("too many presets accepted")
	}
	state = DefaultSiteRoutingState()
	state.Policy.Rules = siteTestRules(1024, false)
	state.SavedPresets = []SiteRoutingPreset{{ID: "user-a", Name: "A", Policy: SiteRoutingPolicy{Mode: RoutingInclude, Rules: siteTestRules(1024, false)}}, {ID: "user-b", Name: "B", Policy: SiteRoutingPolicy{Mode: RoutingInclude, Rules: []string{"extra.example"}}}}
	if state.Validate() == nil {
		t.Fatal("total library bound not enforced")
	}
	state = DefaultSiteRoutingState()
	state.Policy.Rules = siteTestRules(1024, true)
	state.SavedPresets = []SiteRoutingPreset{{ID: "user-a", Name: "A", Policy: SiteRoutingPolicy{Mode: RoutingInclude, Rules: siteTestRules(1024, true)}}}
	if state.Validate() == nil {
		t.Fatal("encoded size bound not enforced")
	}
	if _, err := DecodeSiteRoutingState(bytesRepeat(' ', MaxSiteStateBytes+1)); err == nil {
		t.Fatal("oversized JSON accepted")
	}
	if _, err := ReadSiteRoutingState(&siteBrokenReader{}); err == nil || err.Error() != "site_routing_rejected" {
		t.Fatal("reader error leaked or accepted")
	}
	if _, err := ReadSiteRoutingState(nil); err == nil {
		t.Fatal("missing reader accepted")
	}
}

func bytesRepeat(b byte, n int) []byte { return []byte(strings.Repeat(string(b), n)) }

type siteBrokenReader struct{}

func (*siteBrokenReader) Read([]byte) (int, error) { return 0, errors.New("synthetic-private-error") }

var _ io.Reader = (*siteBrokenReader)(nil)

func TestSiteMatcherUsesSuffixBoundariesAndOriginalNumericDestinations(t *testing.T) {
	policy := SiteRoutingPolicy{Mode: RoutingExclude, Rules: []string{"example.com", "192.0.2.0/24", "2001:db8::/32", "198.51.100.8"}}
	matcher, err := NewSiteMatcher(policy)
	if err != nil || !matcher.Active() || !matcher.HasDomains() || matcher.Mode() != RoutingExclude {
		t.Fatal("matcher setup failed")
	}
	for _, domain := range []string{"example.com", "api.example.com", "API.EXAMPLE.COM."} {
		if !matcher.Match(netip.MustParseAddr("203.0.113.1"), domain) {
			t.Fatal("domain suffix not matched")
		}
	}
	for _, domain := range []string{"evil-example.com", "example.com.evil.test", "example.com/path", "", "192.0.2.4"} {
		if matcher.Match(netip.MustParseAddr("203.0.113.1"), domain) {
			t.Fatal("lookalike domain matched")
		}
	}
	for _, ip := range []string{"192.0.2.1", "::ffff:192.0.2.42", "2001:db8::1", "198.51.100.8"} {
		if !matcher.Match(netip.MustParseAddr(ip), "") {
			t.Fatal("original address not matched")
		}
	}
	for _, ip := range []string{"192.0.3.1", "2001:db9::1", "198.51.100.9"} {
		if matcher.Match(netip.MustParseAddr(ip), "") {
			t.Fatal("outside CIDR matched")
		}
	}
	policy.Rules[0] = "changed.example"
	if !matcher.Match(netip.Addr{}, "example.com") {
		t.Fatal("matcher aliases policy rules")
	}
	disabled, _ := NewSiteMatcher(SiteRoutingPolicy{Mode: RoutingDisabled, Rules: []string{"example.com"}})
	if disabled.Active() || disabled.Match(netip.Addr{}, "example.com") {
		t.Fatal("disabled saved rules took effect")
	}
	if _, err := NewSiteMatcher(SiteRoutingPolicy{Mode: RoutingExclude, Rules: []string{"EXAMPLE.COM"}}); err == nil {
		t.Fatal("noncanonical policy compiled")
	}
	var empty *SiteMatcher
	if empty.Active() || empty.HasDomains() || empty.Match(netip.Addr{}, "example.com") || empty.Mode() != RoutingDisabled {
		t.Fatal("nil matcher authorized a route")
	}
}

func TestSitePolicyCompositionRequiresExplicitVPNAndPreservesUnknownDomains(t *testing.T) {
	for _, c := range []struct {
		name, appMode        string
		appSelected          bool
		siteMode             string
		matched, known, want bool
	}{
		{"disabled uses VPN", RoutingDisabled, false, RoutingDisabled, false, false, false},
		{"existing app exclusion", RoutingExclude, true, RoutingDisabled, false, false, true},
		{"unselected app protected", RoutingExclude, false, RoutingDisabled, false, false, false},
		{"app include selected", RoutingInclude, true, RoutingDisabled, false, false, false},
		{"app include other", RoutingInclude, false, RoutingDisabled, false, false, true},
		{"explicit excluded site", RoutingDisabled, false, RoutingExclude, true, true, true},
		{"other site protected", RoutingDisabled, false, RoutingExclude, false, true, false},
		{"selected site through VPN", RoutingDisabled, false, RoutingInclude, true, true, false},
		{"known other site direct", RoutingDisabled, false, RoutingInclude, false, true, true},
		{"unknown site protected", RoutingDisabled, false, RoutingInclude, false, false, false},
		{"unknown beats app exclusion", RoutingExclude, true, RoutingInclude, false, false, false},
		{"site include beats app exclusion", RoutingExclude, true, RoutingInclude, true, true, false},
		{"app include beats site exclusion", RoutingInclude, true, RoutingExclude, true, true, false},
		{"explicit IP exclusion needs no domain", RoutingDisabled, false, RoutingExclude, true, false, true},
		{"selected IP through VPN without domain", RoutingDisabled, false, RoutingInclude, true, false, false},
		{"invalid app mode", "unknown", true, RoutingExclude, true, true, false},
		{"invalid site mode", RoutingExclude, true, "unknown", true, true, false},
		{"missing mode is not legacy bypass", "", true, RoutingDisabled, false, true, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			if got := RouteDirectForPolicies(c.appMode, c.appSelected, c.siteMode, c.matched, c.known); got != c.want {
				t.Fatalf("direct=%v; want %v", got, c.want)
			}
		})
	}
}

func TestSiteRouteOnlyMetadataNeverRewritesTheOwnerTupleOrDestination(t *testing.T) {
	original := xnet.TCPDestination(xnet.IPAddress([]byte{192, 0, 2, 10}), 443)
	out := &session.Outbound{OriginalTarget: original, Target: original, RouteTarget: xnet.TCPDestination(xnet.DomainAddress("API.EXAMPLE.COM."), 443)}
	before := *out
	ctx := session.ContextWithOutbounds(context.Background(), []*session.Outbound{out})
	if got := SiteDomainFromContext(ctx); got != "api.example.com" {
		t.Fatalf("route-only domain=%q", got)
	}
	if !reflect.DeepEqual(before, *out) {
		t.Fatal("metadata lookup rewrote destination")
	}
	out.RouteTarget = xnet.TCPDestination(xnet.DomainAddress("https://bad.example"), 443)
	if SiteDomainFromContext(ctx) != "" {
		t.Fatal("invalid sniff hint can authorize direct")
	}
	out.RouteTarget = xnet.TCPDestination(xnet.DomainAddress("192.0.2.10"), 443)
	if SiteDomainFromContext(ctx) != "" {
		t.Fatal("numeric sniff hint treated as known domain")
	}
	out.RouteTarget = xnet.Destination{}
	out.Target = xnet.TCPDestination(xnet.DomainAddress("valid.example"), 443)
	if SiteDomainFromContext(ctx) != "valid.example" {
		t.Fatal("explicit target domain not read")
	}
	for _, empty := range []context.Context{nil, context.Background(), session.ContextWithOutbounds(context.Background(), []*session.Outbound{nil})} {
		if SiteDomainFromContext(empty) != "" {
			t.Fatal("missing metadata fabricated a domain")
		}
	}
}
