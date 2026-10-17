// SPDX-License-Identifier: Apache-2.0
package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

var testNow = time.Date(2026, 10, 18, 1, 0, 0, 0, time.UTC)

func testConfig() (trustedConfig, ed25519.PrivateKey) {
	// Synthetic fixture key only. It is never a release or project signing key.
	key := ed25519.NewKeyFromSeed(make([]byte, ed25519.SeedSize))
	return trustedConfig{"0.1.0", 21, "beta", "https://github.com/Extectick/ExVPN/releases/download/windows-beta/windows-x64.json", "fixture-key", key.Public().(ed25519.PublicKey)}, key
}
func testManifest(data []byte) manifest {
	h := sha256.Sum256(data)
	return manifest{Schema: 1, AppID: "exvpn", Platform: "windows-x64", Channel: "beta", Version: "0.1.0", Build: 22,
		PublishedAt: testNow.Add(-time.Hour).Format(time.RFC3339), ExpiresAt: testNow.Add(24 * time.Hour).Format(time.RFC3339),
		Asset: asset{"https://github.com/Extectick/ExVPN/releases/download/v0.1.0-beta.22/ExVPN-0.1.0+22-windows-x64.exe", int64(len(data)), hex.EncodeToString(h[:])}}
}
func signPayload(t *testing.T, payload []byte, domain bool) []byte {
	t.Helper()
	cfg, key := testConfig()
	signed := payload
	if domain {
		signed = append([]byte("ExVPN/windows-update/v1\x00"), payload...)
	}
	e := envelope{1, cfg.KeyID, base64.StdEncoding.EncodeToString(payload), base64.StdEncoding.EncodeToString(ed25519.Sign(key, signed))}
	raw, err := json.Marshal(e)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
func signManifest(t *testing.T, m manifest) []byte {
	t.Helper()
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return signPayload(t, b, true)
}

func TestSignedManifestAuthenticatesExactBytesAndDomain(t *testing.T) {
	cfg, _ := testConfig()
	m := testManifest([]byte("synthetic installer"))
	raw := signManifest(t, m)
	got, err := verifyEnvelope(raw, cfg, testNow)
	if err != nil || got.identity() != "0.1.0+22" {
		t.Fatalf("valid fixture rejected: %v", err)
	}
	var e envelope
	_ = json.Unmarshal(raw, &e)
	payload, _ := base64.StdEncoding.DecodeString(e.Payload)
	e.Payload = base64.StdEncoding.EncodeToString(append(payload, ' '))
	changed, _ := json.Marshal(e)
	if _, err = verifyEnvelope(changed, cfg, testNow); err != safeError("signature_invalid") {
		t.Fatalf("altered bytes: %v", err)
	}
	if _, err = verifyEnvelope(signPayload(t, payload, false), cfg, testNow); err != safeError("signature_invalid") {
		t.Fatalf("missing domain: %v", err)
	}
	e.KeyID = "another-key"
	changed, _ = json.Marshal(e)
	if _, err = verifyEnvelope(changed, cfg, testNow); err != safeError("signature_invalid") {
		t.Fatalf("unknown key: %v", err)
	}
}

func TestManifestRejectsIncompatibleExpiredOrUnsafeAssets(t *testing.T) {
	cfg, _ := testConfig()
	cases := []struct {
		name   string
		change func(*manifest)
		want   safeError
	}{
		{"platform", func(m *manifest) { m.Platform = "android-arm64" }, "update_incompatible"},
		{"channel", func(m *manifest) { m.Channel = "stable" }, "update_incompatible"},
		{"application", func(m *manifest) { m.AppID = "another" }, "update_incompatible"},
		{"schema", func(m *manifest) { m.Schema = 2 }, "update_incompatible"},
		{"same build", func(m *manifest) { m.Build = 21 }, "update_incompatible"},
		{"downgrade build", func(m *manifest) { m.Build = 20 }, "update_incompatible"},
		{"downgrade semver", func(m *manifest) { m.Version = "0.0.999" }, "update_incompatible"},
		{"invalid semver", func(m *manifest) { m.Version = "0.1.0-beta+22" }, "update_incompatible"},
		{"leading zero", func(m *manifest) { m.Version = "0.01.0" }, "update_incompatible"},
		{"build overflow", func(m *manifest) { m.Build = maxBuild + 1 }, "update_incompatible"},
		{"expired", func(m *manifest) { m.ExpiresAt = testNow.Format(time.RFC3339) }, "update_expired"},
		{"excess lifetime", func(m *manifest) { m.ExpiresAt = testNow.Add(30 * 24 * time.Hour).Format(time.RFC3339) }, "update_expired"},
		{"future published", func(m *manifest) { m.PublishedAt = testNow.Add(time.Minute).Format(time.RFC3339) }, "update_expired"},
		{"non UTC", func(m *manifest) { m.ExpiresAt = testNow.Add(time.Hour).Format("2006-01-02T15:04:05+00:00") }, "update_expired"},
		{"expiry before published", func(m *manifest) { m.ExpiresAt = m.PublishedAt }, "update_expired"},
		{"missing published", func(m *manifest) { m.PublishedAt = "" }, "update_expired"},
		{"oversize", func(m *manifest) { m.Asset.Size = maxInstaller + 1 }, "manifest_invalid"},
		{"empty size", func(m *manifest) { m.Asset.Size = 0 }, "manifest_invalid"},
		{"negative size", func(m *manifest) { m.Asset.Size = -1 }, "manifest_invalid"},
		{"uppercase hash", func(m *manifest) { m.Asset.SHA256 = strings.ToUpper(m.Asset.SHA256) }, "manifest_invalid"},
		{"short hash", func(m *manifest) { m.Asset.SHA256 = "00" }, "manifest_invalid"},
		{"plaintext asset", func(m *manifest) { m.Asset.URL = strings.Replace(m.Asset.URL, "https:", "http:", 1) }, "manifest_invalid"},
		{"other repo", func(m *manifest) { m.Asset.URL = strings.Replace(m.Asset.URL, "Extectick/ExVPN", "another/ExVPN", 1) }, "manifest_invalid"},
		{"non executable", func(m *manifest) { m.Asset.URL = strings.TrimSuffix(m.Asset.URL, ".exe") + ".zip" }, "manifest_invalid"},
		{"query", func(m *manifest) { m.Asset.URL += "?token=synthetic" }, "manifest_invalid"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := testManifest([]byte("fixture"))
			tc.change(&m)
			_, err := verifyEnvelope(signManifest(t, m), cfg, testNow)
			if err != tc.want {
				t.Fatalf("got %v want %v", err, tc.want)
			}
		})
	}
	m := testManifest([]byte("fixture"))
	m.Version = "0.10.0"
	if _, err := verifyEnvelope(signManifest(t, m), cfg, testNow); err != nil {
		t.Fatalf("numeric semver comparison: %v", err)
	}
}

func TestMalformedSignedJSONIsRejectedBeforeUse(t *testing.T) {
	cfg, _ := testConfig()
	valid, _ := json.Marshal(testManifest([]byte("fixture")))
	cases := [][]byte{
		append([]byte(`{"schema":1,`), valid[1:]...),
		[]byte(strings.Replace(string(valid), `"build":22`, `"build":"22"`, 1)),
		[]byte(strings.Replace(string(valid), `"sizeBytes":7`, `"sizeBytes":true`, 1)),
		append(append([]byte(nil), valid[:len(valid)-1]...), []byte(`,"executablePath":"C:\\malicious.exe"}`)...),
		append(valid, []byte(`{}`)...), []byte("null"), []byte("[]"), {0xff, '{', '}'},
	}
	for i, payload := range cases {
		if _, err := verifyEnvelope(signPayload(t, payload, true), cfg, testNow); err == nil {
			t.Fatalf("malformed signed payload %d accepted", i)
		}
	}
	if _, err := verifyEnvelope([]byte(strings.Repeat(" ", maxEnvelope+1)), cfg, testNow); err == nil {
		t.Fatal("unbounded envelope")
	}
	if _, err := verifyEnvelope([]byte(`{"schema":1,"schema":1}`), cfg, testNow); err == nil {
		t.Fatal("duplicate envelope")
	}
}

func TestCurrentOrOlderCheckStillValidatesEverySignedField(t *testing.T) {
	cfg, _ := testConfig()
	for _, change := range []func(*manifest){func(m *manifest) { m.Build = 21 }, func(m *manifest) { m.Build = 20 }, func(m *manifest) { m.Version = "0.0.9" }} {
		m := testManifest([]byte("fixture"))
		change(&m)
		got, err := verifyEnvelopeMetadata(signManifest(t, m), cfg, testNow)
		if err != nil || eligibleUpdate(got, cfg) {
			t.Fatalf("expected authenticated no-update: %v", err)
		}
		if _, err := verifyEnvelope(signManifest(t, m), cfg, testNow); err != safeError("update_incompatible") {
			t.Fatalf("strict download accepted old identity: %v", err)
		}
		m.Asset.URL = "https://untrusted.invalid/app.exe"
		if _, err := verifyEnvelopeMetadata(signManifest(t, m), cfg, testNow); err != safeError("manifest_invalid") {
			t.Fatalf("old unsafe metadata skipped validation: %v", err)
		}
		m = testManifest([]byte("fixture"))
		change(&m)
		m.ExpiresAt = testNow.Format(time.RFC3339)
		if _, err := verifyEnvelopeMetadata(signManifest(t, m), cfg, testNow); err != safeError("update_expired") {
			t.Fatalf("old expired metadata skipped validation: %v", err)
		}
	}
}

func TestURLPolicyRejectsLookalikeHostsAndRedirectEscapes(t *testing.T) {
	good := []string{
		"https://github.com/Extectick/ExVPN/releases/download/windows-beta/windows-x64.json",
		"https://api.github.com/repos/Extectick/ExVPN/releases/assets/12345",
		"https://release-assets.githubusercontent.com/github-production-release-asset-2e65be/123/fixture?signature=synthetic",
		"https://objects.githubusercontent.com/github-production-release-asset-2e65be/123/fixture",
	}
	for _, u := range good {
		if !allowedRedirect(u) {
			t.Fatalf("expected allowed %s", u)
		}
	}
	bad := []string{
		"http://github.com/Extectick/ExVPN/releases/download/windows-beta/windows-x64.json",
		"https://github.com.evil.invalid/Extectick/ExVPN/releases/download/tag/app.exe",
		"https://github.com@evil.invalid/Extectick/ExVPN/releases/download/tag/app.exe",
		"https://evil@github.com/Extectick/ExVPN/releases/download/tag/app.exe",
		"https://github.com:444/Extectick/ExVPN/releases/download/tag/app.exe",
		"https://github.com/Extectick/ExVPN/releases/download/../app.exe",
		"https://github.com/Extectick/ExVPN/releases/download/%2e%2e/app.exe",
		"https://github.com/Extectick/ExVPN/releases/download/tag/app.exe#fragment",
		"https://api.github.com/repos/other/ExVPN/releases/assets/123",
		"https://api.github.com/repos/Extectick/ExVPN/releases/assets/0",
		"https://objects.githubusercontent.com/arbitrary/file.exe",
		"https://127.0.0.1/app.exe", "file:///C:/app.exe", "https://example.com/app.exe",
	}
	for _, u := range bad {
		if allowedRedirect(u) {
			t.Fatalf("unsafe redirect allowed %s", u)
		}
	}
}
