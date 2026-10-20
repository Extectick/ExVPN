//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/netip"
	"os"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
	"github.com/Extectick/ExVPN/native/core/qa/wireguardgateway"
	service "github.com/Extectick/ExVPN/native/windows"
)

type wireguardFixtureMessage struct {
	Kind            string           `json:"kind"`
	Profile         *exvpn.Profile   `json:"profile,omitempty"`
	Counters        *fixtureCounters `json:"counters,omitempty"`
	WireGuardOnline *bool            `json:"wireguardOnline"`
}

func ipv4WireguardFixtureProfile(profile exvpn.Profile) (exvpn.Profile, error) {
	if profile.Protocol != "wireguard" || profile.WireGuard == nil {
		return exvpn.Profile{}, errors.New("fixture_profile_invalid")
	}
	options := *profile.WireGuard
	options.Addresses = nil
	for _, address := range profile.WireGuard.Addresses {
		prefix, err := netip.ParsePrefix(address)
		if err != nil {
			return exvpn.Profile{}, errors.New("fixture_profile_invalid")
		}
		if prefix.Addr().Is4() {
			options.Addresses = append(options.Addresses, address)
		}
	}
	profile.WireGuard = &options
	if len(options.Addresses) != 1 || profile.Validate() != nil {
		return exvpn.Profile{}, errors.New("fixture_profile_invalid")
	}
	return profile, nil
}

func fixtureObject(line []byte, allowed ...string) (map[string]json.RawMessage, error) {
	if len(line) > 8192 {
		return nil, errors.New("fixture_protocol_failed")
	}
	decoder := json.NewDecoder(bytes.NewReader(line))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return nil, errors.New("fixture_protocol_failed")
	}
	fields := make(map[string]json.RawMessage, len(allowed))
	for decoder.More() {
		token, err := decoder.Token()
		key, ok := token.(string)
		if err != nil || !ok {
			return nil, errors.New("fixture_protocol_failed")
		}
		known := false
		for _, permitted := range allowed {
			known = known || key == permitted
		}
		if _, duplicate := fields[key]; !known || duplicate {
			return nil, errors.New("fixture_protocol_failed")
		}
		var raw json.RawMessage
		if decoder.Decode(&raw) != nil || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
			return nil, errors.New("fixture_protocol_failed")
		}
		fields[key] = raw
	}
	if token, err = decoder.Token(); err != nil || token != json.Delim('}') || decoder.Decode(new(any)) != io.EOF {
		return nil, errors.New("fixture_protocol_failed")
	}
	return fields, nil
}

// WireGuard is an explicit child mode. The existing VLESS parser remains strict
// and cannot begin accepting this peer or its extra acknowledgement field.
func readWireguardFixtureMessage(line []byte) (wireguardFixtureMessage, error) {
	bad := errors.New("fixture_protocol_failed")
	fields, err := fixtureObject(line, "kind", "profile", "counters", "wireguardOnline")
	if err != nil || len(fields) != 3 {
		return wireguardFixtureMessage{}, bad
	}
	var kind string
	var online bool
	if json.Unmarshal(fields["kind"], &kind) != nil || json.Unmarshal(fields["wireguardOnline"], &online) != nil {
		return wireguardFixtureMessage{}, bad
	}
	message := wireguardFixtureMessage{Kind: kind, WireGuardOnline: &online}
	switch kind {
	case "ready":
		profile, err := exvpn.DecodeProfile(bytes.NewReader(fields["profile"]))
		if err != nil || !online || profile.ID != "qa-wireguard" || profile.Protocol != "wireguard" || profile.Server != "127.0.0.1" || profile.Transport.Type != "tcp" {
			return wireguardFixtureMessage{}, bad
		}
		message.Profile = &profile
	case "stats":
		counters, err := fixtureObject(fields["counters"], "upload", "download", "numericUpload", "numericDownload")
		if err != nil || len(counters) != 4 {
			return wireguardFixtureMessage{}, bad
		}
		var values fixtureCounters
		if json.Unmarshal(fields["counters"], &values) != nil || values.Upload < 0 || values.Download < 0 || values.NumericUpload < 0 || values.NumericDownload < 0 {
			return wireguardFixtureMessage{}, bad
		}
		message.Counters = &values
	default:
		return wireguardFixtureMessage{}, bad
	}
	return message, nil
}

func (f *isolatedFixture) setWireguardOnline(online bool) error {
	if !f.wireguard {
		return errors.New("fixture_mode_invalid")
	}
	if f.gatewayOnline.Load() == online {
		return nil
	}
	command := "offline\n"
	if online {
		command = "online\n"
	}
	if _, err := io.WriteString(f.input, command); err != nil {
		return errors.New("fixture_pipe_failed")
	}
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	poll := time.NewTicker(25 * time.Millisecond)
	defer poll.Stop()
	for {
		select {
		case <-deadline.C:
			return errors.New("fixture_transition_failed")
		case <-f.exited:
			return errors.New("fixture_stop_failed")
		case <-poll.C:
			if f.gatewayOnline.Load() == online {
				return nil
			}
		}
	}
}

// The parent and child share the exact protected executable App-ID permitted by
// production WFP, but not Xray's process-global socket ownership dialer.
func runWireguardFixtureProcess(interfaceIndex int) error {
	iface, err := net.InterfaceByIndex(interfaceIndex)
	if err != nil || iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 || iface.Name == service.TunnelName {
		return errors.New("fixture_interface_invalid")
	}
	gateway, err := wireguardgateway.Start(wireguardgateway.Options{PhysicalInterface: iface.Name})
	if err != nil {
		return errors.New("fixture_start_failed")
	}
	defer gateway.Close()
	// This Sandbox fixture has no physical IPv6 Internet egress. Advertising
	// an IPv6 client address would give WireGuard's internal resolver a working
	// IPv6 route only to this synthetic server, not to the public destination.
	// Restrict this generated QA client's capability, not product routing: the
	// server keys/port/config and production IPv6 TUN capture remain unchanged.
	profile, err := ipv4WireguardFixtureProfile(gateway.Profile())
	if err != nil {
		return errors.New("fixture_profile_invalid")
	}
	encoder := json.NewEncoder(os.Stdout)
	online := true
	if encoder.Encode(wireguardFixtureMessage{Kind: "ready", Profile: &profile, WireGuardOnline: &online}) != nil {
		return errors.New("fixture_pipe_failed")
	}
	stopped := make(chan struct{})
	defer close(stopped)
	commands := make(chan string, 1)
	go func() {
		defer close(commands)
		scanner := bufio.NewScanner(os.Stdin)
		scanner.Buffer(make([]byte, 16), 65)
		for scanner.Scan() {
			command := scanner.Text()
			if command != "offline" && command != "online" {
				command = "invalid"
			}
			select {
			case commands <- command:
			case <-stopped:
				return
			}
		}
		if scanner.Err() != nil {
			select {
			case commands <- "invalid":
			case <-stopped:
			}
		}
	}()
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case command, ok := <-commands:
			if !ok { // EOF requests normal child cleanup and releases its socket.
				return nil
			}
			if command == "invalid" || gateway.SetOnline(command == "online") != nil {
				return errors.New("fixture_transition_failed")
			}
		case <-ticker.C:
		}
		online = gateway.Online()
		traffic := gateway.Traffic()
		counters := fixtureCounters{Upload: traffic.Upload, Download: traffic.Download}
		if encoder.Encode(wireguardFixtureMessage{Kind: "stats", Counters: &counters, WireGuardOnline: &online}) != nil {
			return errors.New("fixture_pipe_failed")
		}
	}
}
