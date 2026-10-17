// SPDX-License-Identifier: Apache-2.0
package main

import (
	"errors"
	"path/filepath"
	"regexp"
)

const standardOutputRoot = `C:\ExVPN-App-QA-Results`
const lifecycleOutputRoot = `C:\ExVPN-Lifecycle-QA-Results`

type qaRunMode struct {
	TransportCycles   int
	SubscriptionUi    bool
	SubscriptionPhase string
	Faults            bool
	ProviderMatrix    bool
	NetworkRecovery   bool
	PolicyRecovery    string
}

func (m qaRunMode) output(runID string) (string, error) {
	if !m.SubscriptionUi {
		if m.SubscriptionPhase != "" {
			return "", errors.New("subscription phase without mode")
		}
		return outputForTransportCycles(m.TransportCycles, runID)
	}
	if m.TransportCycles != 0 || m.Faults || m.ProviderMatrix || m.NetworkRecovery || m.PolicyRecovery != "" || (m.SubscriptionPhase != "edit" && m.SubscriptionPhase != "reopen") {
		return "", errors.New("invalid subscription QA mode")
	}
	// Reuse only the validated per-run destination; this does not enable a
	// transport test or any service/network mutation.
	return outputForTransportCycles(3, runID)
}

func selectRunOutput(mode qaRunMode, runID string) error {
	selected, err := mode.output(runID)
	if err != nil {
		return err
	}
	outputRoot = selected
	return nil
}

// Keep the last permitted diagnostic destination if marker validation fails.
// The error handler still calls save after this function returns an error.
func selectTransportOutput(cycles int, runID string) error {
	selected, err := outputForTransportCycles(cycles, runID)
	if err != nil {
		return err
	}
	outputRoot = selected
	return nil
}

// Only two fixed guest destinations are permitted. A marker cannot supply a
// path, and a lifecycle run cannot reuse the legacy writable share.
func outputForTransportCycles(cycles int, runID string) (string, error) {
	if cycles == 0 {
		return standardOutputRoot, nil
	}
	if cycles < 3 || cycles > 20 {
		return "", errors.New("invalid transport cycle count")
	}
	if !regexp.MustCompile(`^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$`).MatchString(runID) || runID == "00000000-0000-0000-0000-000000000000" {
		return "", errors.New("invalid lifecycle run ID")
	}
	return filepath.Join(lifecycleOutputRoot, runID), nil
}
