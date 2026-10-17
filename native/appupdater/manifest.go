// SPDX-License-Identifier: Apache-2.0
package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	maxEnvelope        = 32 << 10
	maxPayload         = 16 << 10
	maxInstaller int64 = 512 << 20
	maxBuild           = 2147483647
)

// Build-time identities are pinned by the packaging script. Empty trust material
// fails closed; it is never supplied by a subscription, stdin, or environment.
var (
	appVersion        = "0.1.0"
	appBuild          = "0"
	updateChannel     = "beta"
	manifestFeed      = ""
	manifestKeyID     = ""
	manifestPublicKey = ""
)

type safeError string

func (e safeError) Error() string { return string(e) }

type envelope struct {
	Schema    int    `json:"schema"`
	KeyID     string `json:"keyId"`
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}

type asset struct {
	URL    string `json:"url"`
	Size   int64  `json:"sizeBytes"`
	SHA256 string `json:"sha256"`
}

type manifest struct {
	Schema      int    `json:"schema"`
	AppID       string `json:"appId"`
	Platform    string `json:"platform"`
	Channel     string `json:"channel"`
	Version     string `json:"version"`
	Build       int    `json:"build"`
	ExpiresAt   string `json:"expiresAt"`
	PublishedAt string `json:"publishedAt"`
	Asset       asset  `json:"asset"`
}

func (m manifest) identity() string { return m.Version + "+" + strconv.Itoa(m.Build) }

type trustedConfig struct {
	Version string
	Build   int
	Channel string
	Feed    string
	KeyID   string
	Key     ed25519.PublicKey
}

func pinnedConfig() (trustedConfig, error) {
	b, err := strconv.Atoi(appBuild)
	k, kerr := base64.StdEncoding.Strict().DecodeString(manifestPublicKey)
	c := trustedConfig{appVersion, b, updateChannel, manifestFeed, manifestKeyID, k}
	if err != nil || kerr != nil || !validVersion(c.Version) || b < 1 || b > maxBuild ||
		(c.Channel != "beta" && c.Channel != "stable") || c.KeyID == "" || len(k) != ed25519.PublicKeySize || !allowedReleaseURL(c.Feed, false) {
		return trustedConfig{}, safeError("not_configured")
	}
	return c, nil
}

// strictJSON additionally rejects duplicate keys. encoding/json otherwise
// accepts last-key-wins input, which makes signed metadata ambiguous to tools.
func strictJSON(data []byte, limit int, target any) error {
	if len(data) == 0 || len(data) > limit || !utf8.Valid(data) {
		return safeError("manifest_invalid")
	}
	d := json.NewDecoder(bytes.NewReader(data))
	if err := consumeJSON(d); err != nil {
		return safeError("manifest_invalid")
	}
	if _, err := d.Token(); err != io.EOF {
		return safeError("manifest_invalid")
	}
	d = json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if err := d.Decode(target); err != nil {
		return safeError("manifest_invalid")
	}
	return nil
}

func consumeJSON(d *json.Decoder) error {
	t, err := d.Token()
	if err != nil {
		return err
	}
	v, ok := t.(json.Delim)
	if !ok {
		return nil
	}
	switch v {
	case '{':
		seen := make(map[string]bool)
		for d.More() {
			key, err := d.Token()
			if err != nil {
				return err
			}
			k, ok := key.(string)
			if !ok || seen[k] {
				return errors.New("duplicate key")
			}
			seen[k] = true
			if err := consumeJSON(d); err != nil {
				return err
			}
		}
		end, err := d.Token()
		if err != nil || end != json.Delim('}') {
			return errors.New("object")
		}
	case '[':
		for d.More() {
			if err := consumeJSON(d); err != nil {
				return err
			}
		}
		end, err := d.Token()
		if err != nil || end != json.Delim(']') {
			return errors.New("array")
		}
	default:
		return errors.New("delimiter")
	}
	return nil
}

func verifyEnvelope(raw []byte, cfg trustedConfig, now time.Time) (manifest, error) {
	m, err := verifyEnvelopeMetadata(raw, cfg, now)
	if err != nil {
		return manifest{}, err
	}
	if !eligibleUpdate(m, cfg) {
		return manifest{}, safeError("update_incompatible")
	}
	return m, nil
}

func eligibleUpdate(m manifest, cfg trustedConfig) bool {
	return m.Build > cfg.Build && compareVersion(m.Version, cfg.Version) >= 0
}

// A check authenticates every field even when the package is already installed.
// Only after complete validation may an old identity become a quiet no-update.
func verifyEnvelopeMetadata(raw []byte, cfg trustedConfig, now time.Time) (manifest, error) {
	var e envelope
	if err := strictJSON(raw, maxEnvelope, &e); err != nil {
		return manifest{}, err
	}
	if e.Schema != 1 || e.KeyID != cfg.KeyID {
		return manifest{}, safeError("signature_invalid")
	}
	payload, err := base64.StdEncoding.Strict().DecodeString(e.Payload)
	sig, serr := base64.StdEncoding.Strict().DecodeString(e.Signature)
	if err != nil || serr != nil || len(payload) == 0 || len(payload) > maxPayload || len(sig) != ed25519.SignatureSize ||
		len(cfg.Key) != ed25519.PublicKeySize || !ed25519.Verify(cfg.Key, append([]byte("ExVPN/windows-update/v1\x00"), payload...), sig) {
		return manifest{}, safeError("signature_invalid")
	}
	var m manifest
	if err := strictJSON(payload, maxPayload, &m); err != nil {
		return manifest{}, err
	}
	if m.Schema != 1 || m.AppID != "exvpn" || m.Platform != "windows-x64" || m.Channel != cfg.Channel ||
		!validVersion(m.Version) || m.Build < 1 || m.Build > maxBuild {
		return manifest{}, safeError("update_incompatible")
	}
	expires, err := time.Parse(time.RFC3339, m.ExpiresAt)
	published, perr := time.Parse(time.RFC3339, m.PublishedAt)
	if err != nil || perr != nil || !strings.HasSuffix(m.ExpiresAt, "Z") || !strings.HasSuffix(m.PublishedAt, "Z") ||
		published.After(now) || !expires.After(published) || expires.Sub(published) > 30*24*time.Hour || !expires.After(now) || expires.After(now.Add(30*24*time.Hour)) {
		return manifest{}, safeError("update_expired")
	}
	digest, err := hex.DecodeString(m.Asset.SHA256)
	if err != nil || len(digest) != 32 || strings.ToLower(m.Asset.SHA256) != m.Asset.SHA256 || m.Asset.Size < 1 || m.Asset.Size > maxInstaller || !allowedReleaseURL(m.Asset.URL, true) {
		return manifest{}, safeError("manifest_invalid")
	}
	return m, nil
}

// Version identifiers are deliberately the package's numeric SemVer release
// triple. Prerelease channel and monotonic package build are separate fields.
var numericVersion = regexp.MustCompile(`^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$`)

func validVersion(s string) bool { return numericVersion.MatchString(s) }
func compareVersion(a, b string) int {
	aa, bb := strings.Split(a, "."), strings.Split(b, ".")
	if len(aa) != 3 || len(bb) != 3 {
		return -1
	}
	for i := 0; i < 3; i++ {
		x, _ := strconv.Atoi(aa[i])
		y, _ := strconv.Atoi(bb[i])
		if x < y {
			return -1
		}
		if x > y {
			return 1
		}
	}
	return 0
}

func cleanHTTPS(raw string) (*url.URL, bool) {
	u, err := url.Parse(raw)
	if err != nil || len(raw) > 4096 || u.Scheme != "https" || u.User != nil || u.Fragment != "" || u.Opaque != "" ||
		(u.Port() != "" && u.Port() != "443") || u.RawPath != "" || strings.Contains(u.Path, "\\") || strings.Contains(u.Path, "//") {
		return nil, false
	}
	for _, part := range strings.Split(u.Path, "/") {
		if part == "." || part == ".." {
			return nil, false
		}
	}
	return u, true
}

func allowedReleaseURL(raw string, executable bool) bool {
	u, ok := cleanHTTPS(raw)
	if !ok || !strings.EqualFold(u.Hostname(), "github.com") || u.RawQuery != "" {
		return false
	}
	parts := strings.Split(strings.TrimPrefix(u.Path, "/"), "/")
	if len(parts) != 6 || parts[0] != "Extectick" || parts[1] != "ExVPN" || parts[2] != "releases" || parts[3] != "download" || parts[4] == "" || parts[5] == "" {
		return false
	}
	return !executable || strings.HasSuffix(parts[5], ".exe")
}

// Redirects are permitted only for GitHub's documented release delivery hosts.
// This does not relax TLS validation; every final byte is authenticated again.
func allowedRedirect(raw string) bool {
	u, ok := cleanHTTPS(raw)
	if !ok {
		return false
	}
	switch strings.ToLower(u.Hostname()) {
	case "github.com":
		return allowedReleaseURL(raw, false)
	case "api.github.com":
		parts := strings.Split(strings.TrimPrefix(u.Path, "/"), "/")
		if len(parts) != 6 || parts[0] != "repos" || parts[1] != "Extectick" || parts[2] != "ExVPN" || parts[3] != "releases" || parts[4] != "assets" {
			return false
		}
		_, err := strconv.ParseUint(parts[5], 10, 64)
		return err == nil && parts[5] != "0"
	case "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com":
		return strings.HasPrefix(u.Path, "/github-production-release-asset/") || (strings.HasPrefix(u.Path, "/github-production-release-asset-") && len(u.Path) > len("/github-production-release-asset-"))
	}
	return false
}
