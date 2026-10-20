//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package main

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
	"github.com/Extectick/ExVPN/native/core/qa/wireguardgateway"
	service "github.com/Extectick/ExVPN/native/windows"
)

// validateGuest has already required a disposable marker, LocalSystem and a
// protected QA executable. This path is never shipped in the application.
func runProtocolProfile(interfaceIndex int, mode string, useGateway bool) error {
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
	var profile exvpn.Profile
	var gateway *wireguardgateway.Gateway
	if useGateway {
		gateway, err = wireguardgateway.Start(wireguardgateway.Options{PhysicalInterface: iface.Name})
		if err != nil {
			return errors.New("test_gateway_start_failed")
		}
		defer gateway.Close()
		profile = gateway.Profile()
	} else {
		profilePath := filepath.Join(installedRoot, "protocol-profile.json")
		if protectedTestPath(profilePath) != nil {
			return errors.New("test_profile_protected_path_required")
		}
		file, err := os.Open(profilePath)
		if err != nil {
			return errors.New("test_profile_required")
		}
		profile, err = exvpn.DecodeProfile(file)
		_ = file.Close()
		if err != nil {
			return errors.New("test_profile_invalid")
		}
	}
	controller, err := service.NewController(diagnosticGuard{guard}, service.WindowsTunnelFactory(guard), service.ValidateExclusions, true)
	if err != nil {
		return errors.New("controller_start_failed")
	}
	defer controller.Disconnect()
	selected := filepath.ToSlash(filepath.Join(installedRoot, "excluded-probe.exe"))
	policy := service.ApplicationRoutingPolicy{Mode: mode, Applications: []string{selected}}
	if !controller.Handle(service.Request{Version: 1, ID: "qa-routing", Command: "setApplicationRouting", ApplicationRouting: &policy}).OK {
		return errors.New("routing_policy_rejected")
	}
	if controller.ConnectMode(profile, service.ModeVPN) != nil {
		return errors.New("connect_rejected")
	}
	deadline := time.NewTimer(5 * time.Minute)
	defer deadline.Stop()
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-deadline.C:
			return errors.New("test_deadline")
		case <-ticker.C:
		}
		armed, guardErr := guard.Armed()
		_, adapterErr := net.InterfaceByName(service.TunnelName)
		report := object{"phase": "running", "protocol": profile.Protocol, "status": controller.Status(), "guardArmed": armed, "guardReadFailed": guardErr != nil, "adapterPresent": adapterErr == nil}
		if gateway != nil {
			report["gatewayOnline"] = gateway.Online()
		}
		if traffic, err := controller.Statistics(); err == nil {
			report["tunTraffic"] = traffic
		}
		writeReport(report)
		command, _ := os.ReadFile(filepath.Join(installedRoot, "protocol-command.txt"))
		if len(command) > 64 {
			return errors.New("test_command_rejected")
		}
		switch strings.TrimSpace(string(command)) {
		case "":
		case "stop-fixture", "start-fixture":
			if gateway == nil || gateway.SetOnline(strings.TrimSpace(string(command)) == "start-fixture") != nil {
				return errors.New("test_gateway_transition_failed")
			}
		case "disconnect":
			if controller.Disconnect() != nil {
				return errors.New("disconnect_failed")
			}
			armed, guardErr := guard.Armed()
			_, adapterErr := net.InterfaceByName(service.TunnelName)
			writeReport(object{"phase": "disconnected", "protocol": profile.Protocol, "guardArmed": armed, "guardReadFailed": guardErr != nil, "adapterPresent": adapterErr == nil})
			return nil
		default:
			return errors.New("test_command_rejected")
		}
	}
}
