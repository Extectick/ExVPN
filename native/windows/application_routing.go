// SPDX-License-Identifier: Apache-2.0
package service

import (
	"context"
	"regexp"
	"strings"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

type ApplicationRoutingPolicy struct {
	Mode         string   `json:"mode"`
	Applications []string `json:"applications"`
}

func legacyApplicationRouting(paths []string) ApplicationRoutingPolicy {
	mode, _ := exvpn.RoutingMode("", len(paths) > 0)
	return ApplicationRoutingPolicy{Mode: mode, Applications: append([]string{}, paths...)}
}

func (p ApplicationRoutingPolicy) clone() ApplicationRoutingPolicy {
	ids := []string{}
	seen := map[string]bool{}
	for _, id := range p.Applications {
		if _, _, ok := discordFamilyRoot(id); ok {
			id = applicationPathKey(id)
		}
		key := applicationPathKey(id)
		if !seen[key] {
			ids = append(ids, id)
			seen[key] = true
		}
	}
	return ApplicationRoutingPolicy{Mode: p.Mode, Applications: ids}
}

func (p ApplicationRoutingPolicy) validate() error {
	if p.Mode != exvpn.RoutingDisabled && p.Mode != exvpn.RoutingExclude && p.Mode != exvpn.RoutingInclude {
		return Code("application_routing_rejected")
	}
	if p.Applications == nil || validatePolicyPaths(p.Applications) != nil {
		return Code("application_routing_rejected")
	}
	seen := map[string]bool{}
	for _, path := range p.Applications {
		key := applicationPathKey(path)
		if seen[key] {
			return Code("application_routing_rejected")
		}
		seen[key] = true
	}
	return nil
}

func (p ApplicationRoutingPolicy) effective() []string {
	if p.Mode == exvpn.RoutingDisabled {
		return []string{}
	}
	return p.clone().Applications
}

type applicationRoutingContextKey struct{}

func routingFromContext(ctx context.Context, paths []string) ApplicationRoutingPolicy {
	if policy, ok := ctx.Value(applicationRoutingContextKey{}).(ApplicationRoutingPolicy); ok {
		return policy.clone()
	}
	return legacyApplicationRouting(paths)
}

// A version is the only variable segment. Channel/root/executable must match
// exactly. Arbitrary folders, wildcard paths and updater/helper executables do
// not become Discord. The owner resolver verifies the real image separately.
var discordVersion = regexp.MustCompile(`^app-(0|[1-9][0-9]{0,8})(\.(0|[1-9][0-9]{0,8})){1,3}$`)

func applicationPathKey(path string) string {
	key := strings.ToLower(strings.ReplaceAll(path, "\\", "/"))
	root, exe, ok := discordFamilyRoot(key)
	if ok {
		return root + "/" + exe
	}
	return key
}

func applicationOwnerKey(path string) string {
	if _, _, ok := discordFamilyRoot(path); ok && len(strings.Split(strings.ReplaceAll(path, "\\", "/"), "/")) == 7 {
		// A family anchor is an identity, never permission for an executable
		// placed directly in that root outside a recognized version directory.
		return "non-family-image:" + strings.ToLower(strings.ReplaceAll(path, "\\", "/"))
	}
	return applicationPathKey(path)
}

func discordFamilyRoot(path string) (string, string, bool) {
	key := strings.ToLower(strings.ReplaceAll(path, "\\", "/"))
	parts := strings.Split(key, "/")
	if (len(parts) != 7 && len(parts) != 8) || parts[1] != "users" || parts[3] != "appdata" || parts[4] != "local" ||
		(len(parts) == 8 && !discordVersion.MatchString(parts[6])) {
		return "", "", false
	}
	for _, part := range parts {
		if part == "" || part == "." || part == ".." {
			return "", "", false
		}
	}
	channel, executable := parts[5], parts[len(parts)-1]
	if (channel == "discord" && executable == "discord.exe") ||
		(channel == "discordptb" && executable == "discordptb.exe") ||
		(channel == "discordcanary" && executable == "discordcanary.exe") {
		return strings.Join(parts[:6], "/"), executable, true
	}
	return "", "", false
}
