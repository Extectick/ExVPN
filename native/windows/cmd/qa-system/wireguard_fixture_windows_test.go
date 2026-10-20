//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

func syntheticWireguardProfile() exvpn.Profile {
	key := base64.StdEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef"))
	return exvpn.Profile{ID: "qa-wireguard", Name: "Synthetic", Protocol: "wireguard", Server: "127.0.0.1", Port: 45000, Transport: exvpn.Transport{Type: "tcp"}, WireGuard: &exvpn.WireGuardOptions{PrivateKey: key, PublicKey: key, PreSharedKey: key, Addresses: []string{"10.7.0.2/32", "fd00:7::2/128"}, MTU: 1420}}
}

func TestIPv4WireguardFixtureKeepsPeerIdentityWithoutAdvertisingMissingEgress(t *testing.T) {
	input := syntheticWireguardProfile()
	profile, err := ipv4WireguardFixtureProfile(input)
	if err != nil || profile.Validate() != nil || len(profile.WireGuard.Addresses) != 1 || profile.WireGuard.Addresses[0] != "10.7.0.2/32" {
		t.Fatal("IPv4-only fixture did not retain its one usable client address")
	}
	if profile.Server != input.Server || profile.Port != input.Port || profile.WireGuard.PrivateKey != input.WireGuard.PrivateKey || profile.WireGuard.PublicKey != input.WireGuard.PublicKey || profile.WireGuard.PreSharedKey != input.WireGuard.PreSharedKey || len(input.WireGuard.Addresses) != 2 {
		t.Fatal("fixture changed peer identity or mutated the gateway profile")
	}
	input.WireGuard.Addresses = []string{"fd00:7::2/128"}
	if _, err := ipv4WireguardFixtureProfile(input); err == nil {
		t.Fatal("fixture invented an IPv4 address")
	}
}

func TestWireguardFixtureProtocolRequiresExplicitModeAndAcknowledgedOnlineState(t *testing.T) {
	profile := syntheticWireguardProfile()
	online := true
	ready, err := json.Marshal(wireguardFixtureMessage{Kind: "ready", Profile: &profile, WireGuardOnline: &online})
	if err != nil {
		t.Fatal("synthetic fixture encoding failed")
	}
	message, err := readWireguardFixtureMessage(ready)
	if err != nil || message.Profile == nil || message.Profile.Protocol != "wireguard" || message.WireGuardOnline == nil || !*message.WireGuardOnline {
		t.Fatal("valid loopback WireGuard fixture was rejected")
	}
	if _, err := readFixtureMessage(ready); err == nil {
		t.Fatal("WireGuard expanded the default VLESS protocol")
	}
	if _, err := readFixtureMessageMode(ready, true); err == nil {
		t.Fatal("WireGuard expanded the remote VLESS protocol")
	}
	for _, state := range []bool{false, true} {
		encoded, _ := json.Marshal(wireguardFixtureMessage{Kind: "stats", Counters: &fixtureCounters{Upload: 321, Download: 456}, WireGuardOnline: &state})
		message, err := readWireguardFixtureMessage(encoded)
		if err != nil || message.Counters.Download != 456 || message.WireGuardOnline == nil || *message.WireGuardOnline != state {
			t.Fatal("actual child online acknowledgement was lost")
		}
		if _, err := readFixtureMessage(encoded); err == nil {
			t.Fatal("default fixture accepted a WireGuard acknowledgement")
		}
	}
}

func TestWireguardFixtureProtocolRejectsAmbiguousPrivateAndUnboundedMessages(t *testing.T) {
	profile := syntheticWireguardProfile()
	online := true
	ready, _ := json.Marshal(wireguardFixtureMessage{Kind: "ready", Profile: &profile, WireGuardOnline: &online})
	for _, invalid := range []string{
		`{"kind":"ready","wireguardOnline":true}`,
		`{"kind":"stats","wireguardOnline":true,"counters":{}}`,
		`{"kind":"stats","wireguardOnline":null,"counters":{"upload":0,"download":0,"numericUpload":0,"numericDownload":0}}`,
		`{"kind":"stats","wireguardOnline":"true","counters":{"upload":0,"download":0,"numericUpload":0,"numericDownload":0}}`,
		`{"kind":"stats","wireguardOnline":true,"counters":{"upload":-1,"download":0,"numericUpload":0,"numericDownload":0}}`,
		`{"kind":"stats","wireguardOnline":true,"counters":{"upload":0,"upload":1,"download":0,"numericUpload":0,"numericDownload":0}}`,
		`{"kind":"stats","kind":"stats","wireguardOnline":true,"counters":{"upload":0,"download":0,"numericUpload":0,"numericDownload":0}}`,
		`{"kind":"stats","wireguardOnline":true,"counters":{"upload":0,"download":0,"numericUpload":0,"numericDownload":0},"profile":null}`,
		`{"kind":"stats","wireguardOnline":true,"counters":{"upload":0,"download":0,"numericUpload":0,"numericDownload":0,"arbitrary":1}}`,
		strings.Replace(string(ready), `"127.0.0.1"`, `"198.51.100.8"`, 1),
		strings.Replace(string(ready), `"qa-wireguard"`, `"qa-vless"`, 1),
		strings.Replace(string(ready), `"wireguardOnline":true`, `"wireguardOnline":false`, 1),
		strings.Replace(string(ready), `"protocol":"wireguard"`, `"protocol":"wireguard","protocol":"wireguard"`, 1),
		string(ready) + ` {}`,
		strings.Repeat(" ", 8193),
	} {
		if _, err := readWireguardFixtureMessage([]byte(invalid)); err == nil || err.Error() != "fixture_protocol_failed" {
			t.Fatal("unsafe fixture response accepted or exposed private details")
		}
	}
}
