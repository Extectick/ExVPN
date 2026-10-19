//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package main

import (
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	service "github.com/Extectick/ExVPN/native/windows"
)

// This controller-only diagnostic uses production WFP, TUN and supervision.
// It does not claim installed SCM IPC or distinct remote egress acceptance.
func runAutomaticFailover(interfaceIndex int, remote bool) error {
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
	primary, p, err := startIsolatedFixtureMode(interfaceIndex, remote)
	if err != nil {
		return errors.New("primary_fixture_start_failed")
	}
	defer primary.Close()
	backup, b, err := startIsolatedFixtureMode(interfaceIndex, remote)
	if err != nil {
		return errors.New("backup_fixture_start_failed")
	}
	defer backup.Close()
	p.ID, p.Name = "qa-primary", "QA primary"
	b.ID, b.Name = "qa-backup", "QA backup"
	controller, err := service.NewController(diagnosticGuard{guard}, service.WindowsTunnelFactory(guard), service.ValidateExclusions, true)
	if err != nil {
		return errors.New("controller_start_failed")
	}
	defer controller.Disconnect()
	ledger, err := os.OpenFile(filepath.Join(outputRoot, "automatic-samples.jsonl"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return errors.New("fresh_sample_ledger_required")
	}
	defer ledger.Close()
	encoder := json.NewEncoder(ledger)
	excluded := filepath.ToSlash(filepath.Join(installedRoot, "excluded-probe.exe"))
	policy := service.ApplicationRoutingPolicy{Mode: "exclude", Applications: []string{excluded}}
	if !controller.Handle(service.Request{Version: 1, ID: "qa-policy", Command: "setApplicationRouting", ApplicationRouting: &policy}).OK {
		return errors.New("routing_policy_rejected")
	}
	selected, _ := json.Marshal(p)
	other, _ := json.Marshal(b)
	response := controller.Handle(service.Request{Version: 1, ID: "qa-auto", Command: "connect", Mode: service.ModeVPN, Profile: selected, AutomaticProfiles: []json.RawMessage{selected, other}})
	if !response.OK {
		return errors.New("automatic_connect_rejected")
	}
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	deadline := time.NewTimer(12 * time.Minute)
	defer deadline.Stop()
	primaryStopped, backupStopped := false, false
	var sequence uint64
	for {
		select {
		case <-deadline.C:
			return errors.New("test_deadline")
		case <-ticker.C:
		}
		status := controller.Status()
		sequence++
		armed, guardErr := guard.Armed()
		adapter, adapterErr := net.InterfaceByName(service.TunnelName)
		adapterIndex := 0
		if adapterErr == nil {
			adapterIndex = adapter.Index
		}
		// Retain every bounded status sample; host independently verifies guard
		// and interface continuity and reads no configuration or credentials.
		report := object{"phase": "running", "status": status, "sequence": sequence, "guardArmed": armed, "guardReadFailed": guardErr != nil, "adapterPresent": adapterErr == nil, "adapterIndex": adapterIndex, "primaryStopped": primaryStopped, "backupStopped": backupStopped, "primary": primary.snapshot(), "backup": backup.snapshot(), "automaticFailover": true}
		if traffic, err := controller.Statistics(); err == nil {
			report["tunTraffic"] = traffic
		}
		writeReport(report)
		if encoder.Encode(report) != nil || ledger.Sync() != nil {
			return errors.New("sample_ledger_failed")
		}
		command, _ := os.ReadFile(filepath.Join(inputRoot, "command.txt"))
		if len(command) > 64 {
			return errors.New("test_command_rejected")
		}
		switch strings.TrimSpace(string(command)) {
		case "stop-primary":
			if !primaryStopped {
				if primary.Close() != nil {
					return errors.New("primary_stop_failed")
				}
				primaryStopped = true
			}
		case "stop-all":
			if !primaryStopped {
				if primary.Close() != nil {
					return errors.New("primary_stop_failed")
				}
				primaryStopped = true
			}
			if !backupStopped {
				if backup.Close() != nil {
					return errors.New("backup_stop_failed")
				}
				backupStopped = true
			}
		case "disconnect":
			if controller.Disconnect() != nil {
				return errors.New("disconnect_failed")
			}
			armed, err := guard.Armed()
			_, adapterErr := net.InterfaceByName(service.TunnelName)
			writeReport(object{"phase": "disconnected", "automaticFailover": true, "guardArmed": armed, "guardReadFailed": err != nil, "adapterPresent": adapterErr == nil})
			return nil
		case "":
		default:
			return errors.New("test_command_rejected")
		}
	}
}
