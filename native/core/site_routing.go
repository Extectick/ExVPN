// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/netip"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/xtls/xray-core/common/session"
)

const (
	MaxSiteRules      = 1024
	MaxSitePresets    = 8
	MaxSiteTotalRules = 2048
	MaxSiteStateBytes = 512 * 1024
)

// SiteRoutingPolicy is privileged local policy, never provider configuration.
// Rules are canonical plain domains, numeric addresses, or numeric CIDRs.
type SiteRoutingPolicy struct {
	Mode  string   `json:"mode"`
	Rules []string `json:"rules"`
}

type SiteRoutingPreset struct {
	ID     string            `json:"id"`
	Name   string            `json:"name"`
	Policy SiteRoutingPolicy `json:"policy"`
}

// The saved library has no authority until its policy is deliberately applied.
type SiteRoutingState struct {
	Schema         int                 `json:"schema"`
	Policy         SiteRoutingPolicy   `json:"policy"`
	SavedPresets   []SiteRoutingPreset `json:"savedPresets"`
	SelectedPreset string              `json:"selectedPreset"`
}

func siteRejected() error { return CodeError("site_routing_rejected") }

func DefaultSiteRoutingState() SiteRoutingState {
	return SiteRoutingState{
		Schema:         1,
		Policy:         SiteRoutingPolicy{Mode: RoutingDisabled, Rules: []string{}},
		SavedPresets:   []SiteRoutingPreset{},
		SelectedPreset: "russia-basic",
	}
}

func validSiteMode(mode string) bool {
	return mode == RoutingDisabled || mode == RoutingExclude || mode == RoutingInclude
}

// Active does not grant direct access. Platform dispatchers must still verify
// the current connection owner before calling the policy decision helper.
func (p SiteRoutingPolicy) Active() bool {
	return p.Mode == RoutingInclude || (p.Mode == RoutingExclude && len(p.Rules) != 0)
}

func (p SiteRoutingPolicy) Validate() error {
	if !validSiteMode(p.Mode) || p.Rules == nil || len(p.Rules) > MaxSiteRules {
		return siteRejected()
	}
	seen := make(map[string]bool, len(p.Rules))
	for _, rule := range p.Rules {
		canonical, err := CanonicalRule(rule)
		if err != nil || rule != canonical || seen[rule] {
			return siteRejected()
		}
		seen[rule] = true
	}
	return nil
}

func validSiteID(id string) bool {
	if len(id) == 0 || len(id) > 64 {
		return false
	}
	for i, c := range []byte(id) {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || (i > 0 && (c == '-' || c == '_' || c == '.'))) {
			return false
		}
	}
	return true
}

func validSiteName(name string) bool {
	if name == "" || !utf8.ValidString(name) || utf8.RuneCountInString(name) > 80 || strings.TrimSpace(name) != name {
		return false
	}
	for _, c := range name {
		if unicode.IsControl(c) || unicode.Is(unicode.Cf, c) || c == '\u2028' || c == '\u2029' {
			return false
		}
	}
	return true
}

func (s SiteRoutingState) Validate() error {
	if s.Schema != 1 || s.Policy.Validate() != nil || s.SavedPresets == nil || len(s.SavedPresets) > MaxSitePresets ||
		(s.SelectedPreset != "" && !validSiteID(s.SelectedPreset)) {
		return siteRejected()
	}
	total := len(s.Policy.Rules)
	seen := make(map[string]bool, len(s.SavedPresets))
	for _, preset := range s.SavedPresets {
		if !validSiteID(preset.ID) || !validSiteName(preset.Name) || seen[preset.ID] || preset.Policy.Validate() != nil {
			return siteRejected()
		}
		seen[preset.ID] = true
		total += len(preset.Policy.Rules)
		if total > MaxSiteTotalRules {
			return siteRejected()
		}
	}
	encoded, err := json.Marshal(s)
	if err != nil || len(encoded) > MaxSiteStateBytes {
		return siteRejected()
	}
	return nil
}

func cloneSiteRules(rules []string) []string {
	if rules == nil {
		return nil
	}
	return append(make([]string, 0, len(rules)), rules...)
}

func (p SiteRoutingPolicy) Clone() SiteRoutingPolicy {
	return SiteRoutingPolicy{Mode: p.Mode, Rules: cloneSiteRules(p.Rules)}
}

func (s SiteRoutingState) Clone() SiteRoutingState {
	copy := SiteRoutingState{Schema: s.Schema, Policy: s.Policy.Clone(), SelectedPreset: s.SelectedPreset}
	if s.SavedPresets != nil {
		copy.SavedPresets = make([]SiteRoutingPreset, len(s.SavedPresets))
		for i, preset := range s.SavedPresets {
			copy.SavedPresets[i] = SiteRoutingPreset{ID: preset.ID, Name: preset.Name, Policy: preset.Policy.Clone()}
		}
	}
	return copy
}

// DecodeSiteRoutingState rejects duplicate/unknown fields, absent required
// fields, null lists, trailing input, and malformed values with one safe code.
func DecodeSiteRoutingState(data []byte) (SiteRoutingState, error) {
	if len(data) == 0 || len(data) > MaxSiteStateBytes || !utf8.Valid(data) || uniqueJSON(data) != nil {
		return SiteRoutingState{}, siteRejected()
	}
	fields, err := exactSiteFields(data, "schema", "policy", "savedPresets", "selectedPreset")
	if err != nil || !exactSitePolicyFields(fields["policy"]) {
		return SiteRoutingState{}, siteRejected()
	}
	var presets []json.RawMessage
	if json.Unmarshal(fields["savedPresets"], &presets) != nil || len(presets) > MaxSitePresets {
		return SiteRoutingState{}, siteRejected()
	}
	for _, raw := range presets {
		preset, err := exactSiteFields(raw, "id", "name", "policy")
		if err != nil || !exactSitePolicyFields(preset["policy"]) {
			return SiteRoutingState{}, siteRejected()
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var state SiteRoutingState
	if decoder.Decode(&state) != nil || state.Validate() != nil {
		return SiteRoutingState{}, siteRejected()
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return SiteRoutingState{}, siteRejected()
	}
	return state, nil
}

// encoding/json also accepts case-insensitive struct field aliases. Inspect
// every local DTO object before typed decoding so aliases cannot shadow policy.
func exactSiteFields(data []byte, keys ...string) (map[string]json.RawMessage, error) {
	var fields map[string]json.RawMessage
	if json.Unmarshal(data, &fields) != nil || len(fields) != len(keys) || !onlyKeys(fields, keys...) {
		return nil, siteRejected()
	}
	return fields, nil
}

func exactSitePolicyFields(data []byte) bool {
	_, err := exactSiteFields(data, "mode", "rules")
	return err == nil
}

func ReadSiteRoutingState(reader io.Reader) (SiteRoutingState, error) {
	if reader == nil {
		return SiteRoutingState{}, siteRejected()
	}
	data, err := io.ReadAll(io.LimitReader(reader, MaxSiteStateBytes+1))
	if err != nil {
		return SiteRoutingState{}, siteRejected()
	}
	return DecodeSiteRoutingState(data)
}

// CanonicalRule performs no DNS lookup. URL extraction belongs exclusively to
// the local UI; native policy cannot contain ports, geosite, regex or commands.
func CanonicalRule(rule string) (string, error) {
	if len(rule) == 0 || len(rule) > 254 {
		return "", siteRejected()
	}
	for _, c := range []byte(rule) {
		if c < 33 || c > 126 {
			return "", siteRejected()
		}
	}
	if address, err := netip.ParseAddr(rule); err == nil {
		if address.Zone() != "" {
			return "", siteRejected()
		}
		return address.Unmap().String(), nil
	}
	if prefix, err := netip.ParsePrefix(rule); err == nil {
		if prefix.Addr().Zone() != "" {
			return "", siteRejected()
		}
		if prefix.Addr().Is4In6() && prefix.Bits() >= 96 {
			prefix = netip.PrefixFrom(prefix.Addr().Unmap(), prefix.Bits()-96)
		}
		return prefix.Masked().String(), nil
	}
	domain := strings.ToLower(strings.TrimSuffix(rule, "."))
	if len(domain) == 0 || len(domain) > 253 || !strings.Contains(domain, ".") {
		return "", siteRejected()
	}
	labels := strings.Split(domain, ".")
	lastHasLetter := false
	for i, label := range labels {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return "", siteRejected()
		}
		for _, c := range []byte(label) {
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
				return "", siteRejected()
			}
			if i == len(labels)-1 && c >= 'a' && c <= 'z' {
				lastHasLetter = true
			}
		}
	}
	if !lastHasLetter {
		return "", siteRejected()
	}
	return domain, nil
}

// SiteMatcher is an immutable numeric/suffix matcher with no resolver, files,
// sockets, timers or direct-routing authority of its own.
type SiteMatcher struct {
	mode     string
	domains  map[string]bool
	prefixes []netip.Prefix
}

func NewSiteMatcher(policy SiteRoutingPolicy) (*SiteMatcher, error) {
	if policy.Validate() != nil {
		return nil, siteRejected()
	}
	matcher := &SiteMatcher{mode: policy.Mode, domains: make(map[string]bool)}
	for _, rule := range policy.Rules {
		if address, err := netip.ParseAddr(rule); err == nil {
			matcher.prefixes = append(matcher.prefixes, netip.PrefixFrom(address, address.BitLen()))
		} else if prefix, err := netip.ParsePrefix(rule); err == nil {
			matcher.prefixes = append(matcher.prefixes, prefix)
		} else {
			matcher.domains[rule] = true
		}
	}
	return matcher, nil
}

func (m *SiteMatcher) Mode() string {
	if m == nil {
		return RoutingDisabled
	}
	return m.mode
}

func (m *SiteMatcher) Active() bool {
	return m != nil && (m.mode == RoutingInclude || (m.mode == RoutingExclude && len(m.domains)+len(m.prefixes) != 0))
}

func (m *SiteMatcher) HasDomains() bool { return m != nil && len(m.domains) != 0 }

func (m *SiteMatcher) Match(address netip.Addr, domain string) bool {
	if m == nil || !m.Active() {
		return false
	}
	if address.IsValid() && address.Zone() == "" {
		address = address.Unmap()
		for _, prefix := range m.prefixes {
			if prefix.Contains(address) {
				return true
			}
		}
	}
	if !m.HasDomains() {
		return false
	}
	canonical, err := CanonicalRule(domain)
	if err != nil || strings.ContainsAny(canonical, ":/") {
		return false
	}
	if _, err := netip.ParseAddr(canonical); err == nil {
		return false
	}
	for {
		if m.domains[canonical] {
			return true
		}
		point := strings.IndexByte(canonical, '.')
		if point < 0 {
			return false
		}
		canonical = canonical[point+1:]
	}
}

// SiteDomainFromContext observes routeOnly metadata, preserving original
// numeric tuples used for owner verification and the actual dial destination.
func SiteDomainFromContext(ctx context.Context) string {
	if ctx == nil {
		return ""
	}
	outs := session.OutboundsFromContext(ctx)
	if len(outs) == 0 || outs[len(outs)-1] == nil {
		return ""
	}
	out := outs[len(outs)-1]
	if out.RouteTarget.Address != nil && out.RouteTarget.Address.Family().IsDomain() {
		return siteRouteDomain(out.RouteTarget.Address.Domain())
	}
	if out.Target.Address != nil && out.Target.Address.Family().IsDomain() {
		return siteRouteDomain(out.Target.Address.Domain())
	}
	return ""
}

func siteRouteDomain(domain string) string {
	canonical, err := CanonicalRule(domain)
	if err != nil || strings.ContainsAny(canonical, ":/") {
		return ""
	}
	if _, err := netip.ParseAddr(canonical); err == nil {
		return ""
	}
	return canonical
}

// RouteDirectForPolicies is only a policy decision. Callers must separately
// require a freshly confirmed owner, preserve the VPN DNS route, and revalidate
// UDP ownership/destinations. An unknown mode never authorizes direct traffic.
func RouteDirectForPolicies(appMode string, appSelected bool, siteMode string, siteMatched bool, siteDomainKnown bool) bool {
	if !validSiteMode(appMode) || !validSiteMode(siteMode) {
		return false
	}
	if (appMode == RoutingInclude && appSelected) ||
		(siteMode == RoutingInclude && (siteMatched || !siteDomainKnown)) {
		return false
	}
	if (appMode == RoutingExclude && appSelected) || (siteMode == RoutingExclude && siteMatched) {
		return true
	}
	return appMode == RoutingInclude || siteMode == RoutingInclude
}
