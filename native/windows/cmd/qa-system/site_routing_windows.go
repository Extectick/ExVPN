//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package main

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
	service "github.com/Extectick/ExVPN/native/windows"
)

// QA-only memory storage activates the production controller's site capability.
// It is deliberately not presented as a DPAPI or installed-service test.
type siteFixtureStore struct{ state exvpn.SiteRoutingState }

func (s *siteFixtureStore) Load() ([]string, error) { return []string{}, nil }
func (s *siteFixtureStore) Save([]string) error     { return nil }
func (s *siteFixtureStore) LoadSiteRouting() (exvpn.SiteRoutingState, error) {
	return s.state.Clone(), nil
}
func (s *siteFixtureStore) SaveSiteRouting(state exvpn.SiteRoutingState) error {
	if state.Validate() != nil {
		return errors.New("test_site_policy_invalid")
	}
	s.state = state.Clone()
	return nil
}

func readSiteFixture(path string) (exvpn.SiteRoutingState, error) {
	if protectedTestPath(path) != nil {
		return exvpn.SiteRoutingState{}, errors.New("test_site_policy_protected_path_required")
	}
	f, err := os.Open(path)
	if err != nil {
		return exvpn.SiteRoutingState{}, errors.New("test_site_policy_required")
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, exvpn.MaxSiteStateBytes+1))
	if err != nil || len(b) > exvpn.MaxSiteStateBytes {
		return exvpn.SiteRoutingState{}, errors.New("test_site_policy_invalid")
	}
	state, err := exvpn.DecodeSiteRoutingState(b)
	if err != nil {
		return state, errors.New("test_site_policy_invalid")
	}
	return state, nil
}

func runSiteRouting(interfaceIndex int, remote bool) error {
	iface, err := net.InterfaceByIndex(interfaceIndex)
	if err != nil || iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 || iface.Name == service.TunnelName {
		return errors.New("physical_interface_invalid")
	}
	guard := &service.WindowsGuard{}
	if armed, err := guard.Armed(); err != nil || armed {
		return errors.New("clean_guard_required")
	}
	if _, err := net.InterfaceByName(service.TunnelName); err == nil {
		return errors.New("clean_adapter_required")
	}
	state, err := readSiteFixture(filepath.Join(installedRoot, "site-policy.json"))
	if err != nil {
		return err
	}
	fixture, profile, err := startIsolatedFixtureMode(interfaceIndex, remote)
	if err != nil {
		return errors.New("test_fixture_start_failed")
	}
	defer fixture.Close()
	store := &siteFixtureStore{state: exvpn.DefaultSiteRoutingState()}
	c, err := service.NewControllerWithPolicy(diagnosticGuard{guard}, service.WindowsTunnelFactory(guard), service.ValidateExclusions, true, store)
	if err != nil {
		return errors.New("controller_start_failed")
	}
	defer c.Disconnect()
	apply := func(request service.Request) service.Response {
		b, _ := json.Marshal(request)
		r, e := service.DecodeRequest(b)
		if e != nil {
			return service.Response{OK: false}
		}
		return c.Handle(r)
	}
	apps := service.ApplicationRoutingPolicy{Mode: "disabled", Applications: []string{}}
	if !apply(service.Request{Version: 1, ID: "qa-apps", Command: "setApplicationRouting", ApplicationRouting: &apps}).OK {
		return errors.New("test_application_policy_rejected")
	}
	if !apply(service.Request{Version: 1, ID: "qa-sites", Command: "set_site_routing", SiteRouting: &state}).OK {
		return errors.New("test_site_policy_rejected")
	}
	read := apply(service.Request{Version: 1, ID: "qa-sites-read", Command: "get_site_routing"})
	if !read.OK || read.SiteRouting == nil || !reflect.DeepEqual(*read.SiteRouting, state) {
		return errors.New("test_site_policy_readback_failed")
	}
	if c.ConnectMode(profile, service.ModeVPN) != nil {
		return errors.New("connect_rejected")
	}
	deadline := time.NewTimer(7 * time.Minute)
	defer deadline.Stop()
	tick := time.NewTicker(200 * time.Millisecond)
	defer tick.Stop()
	stopped := false
	for {
		select {
		case <-deadline.C:
			return errors.New("test_deadline")
		case <-tick.C:
		}
		armed, guardErr := guard.Armed()
		_, adapterErr := net.InterfaceByName(service.TunnelName)
		report := object{"phase": "running", "status": c.Status(), "siteRoutingMode": state.Policy.Mode, "siteRuleCount": len(state.Policy.Rules), "guardArmed": armed, "guardReadFailed": guardErr != nil, "adapterPresent": adapterErr == nil, "fixtureStopped": stopped, "remoteRelay": remote, "sitePolicyMemoryFixture": true, "durableStoreTested": false, "gatewayTraffic": fixture.snapshot()}
		if traffic, e := c.Statistics(); e == nil {
			report["tunTraffic"] = traffic
		}
		writeReport(report)
		command, _ := os.ReadFile(filepath.Join(installedRoot, "site-command.txt"))
		if len(command) > 64 {
			return errors.New("test_command_rejected")
		}
		switch strings.TrimSpace(string(command)) {
		case "":
		case "stop-fixture":
			if !stopped {
				_ = fixture.Close()
				stopped = true
			}
		case "disconnect":
			if c.Disconnect() != nil {
				return errors.New("disconnect_failed")
			}
			armed, e := guard.Armed()
			_, e2 := net.InterfaceByName(service.TunnelName)
			writeReport(object{"phase": "disconnected", "siteRoutingMode": state.Policy.Mode, "guardArmed": armed, "guardReadFailed": e != nil, "adapterPresent": e2 == nil, "durableStoreTested": false})
			return nil
		default:
			return errors.New("test_command_rejected")
		}
	}
}
