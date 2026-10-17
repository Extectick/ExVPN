// SPDX-License-Identifier: Apache-2.0
package main

import (
	"path/filepath"
	"testing"
)

func TestTransportOutputIsBoundedToTwoGuestPaths(t *testing.T) {
	runID := "3ad3e97f-8130-4ce8-b382-254532b6f3dc"
	for _, cycles := range []int{0, 3, 5, 20} {
		path, err := outputForTransportCycles(cycles, runID)
		want := filepath.Join(lifecycleOutputRoot, runID)
		if cycles == 0 {
			want = standardOutputRoot
		}
		if err != nil || path != want {
			t.Fatalf("cycles %d did not select the fixed QA output", cycles)
		}
	}
	for _, cycles := range []int{-1, 1, 2, 21, 1 << 30} {
		if path, err := outputForTransportCycles(cycles, runID); err == nil || path != "" {
			t.Fatalf("cycles %d was accepted", cycles)
		}
	}
	for _, badID := range []string{"", "../elsewhere", `C:\elsewhere`, "00000000-0000-0000-0000-000000000000", "3ad3e97f-8130-4ce8-b382-254532b6f3dc/child"} {
		if path, err := outputForTransportCycles(5, badID); err == nil || path != "" {
			t.Fatal("invalid lifecycle run ID was accepted")
		}
	}
}

func TestRejectedTransportOutputPreservesDiagnosticDestination(t *testing.T) {
	original := outputRoot
	t.Cleanup(func() { outputRoot = original })
	runID := "3ad3e97f-8130-4ce8-b382-254532b6f3dc"
	for _, initialCycles := range []int{0, 3} {
		if err := selectTransportOutput(initialCycles, runID); err != nil {
			t.Fatal(err)
		}
		allowedRoot := standardOutputRoot
		if initialCycles != 0 {
			allowedRoot = filepath.Join(lifecycleOutputRoot, runID)
		}
		if outputRoot != allowedRoot {
			t.Fatal("valid marker did not select its permitted output")
		}
		for _, rejected := range []struct {
			cycles int
			runID  string
		}{
			{-1, runID}, {1, runID}, {2, runID}, {21, runID},
			{3, ""}, {3, "../elsewhere"}, {3, `C:\elsewhere`},
			{3, "00000000-0000-0000-0000-000000000000"},
			{3, runID + "/child"},
		} {
			if err := selectTransportOutput(rejected.cycles, rejected.runID); err == nil {
				t.Fatal("invalid marker was accepted")
			}
			if outputRoot != allowedRoot {
				t.Fatal("rejected marker changed the diagnostic output root")
			}
			// This is the path used by save in main's failure handler. No test
			// creates or writes a real guest directory on the developer host.
			diagnostic := filepath.Join(outputRoot, "desktop-launch-error.json")
			if !filepath.IsAbs(diagnostic) || filepath.Dir(diagnostic) != allowedRoot {
				t.Fatal("failure diagnostic escaped the permitted guest root")
			}
		}
	}
}

func TestSubscriptionModeRequiresIsolatedPhaseAndRun(t *testing.T) {
	original := outputRoot
	t.Cleanup(func() { outputRoot = original })
	id := "3ad3e97f-8130-4ce8-b382-254532b6f3dc"
	for _, phase := range []string{"edit", "reopen"} {
		mode := qaRunMode{SubscriptionUi: true, SubscriptionPhase: phase}
		if err := selectRunOutput(mode, id); err != nil || outputRoot != filepath.Join(lifecycleOutputRoot, id) {
			t.Fatal("subscription phase did not select the bounded output")
		}
	}
	allowed := outputRoot
	for _, mode := range []qaRunMode{
		{SubscriptionPhase: "edit"},
		{SubscriptionUi: true},
		{SubscriptionUi: true, SubscriptionPhase: "../edit"},
		{SubscriptionUi: true, SubscriptionPhase: "edit", TransportCycles: 3},
		{SubscriptionUi: true, SubscriptionPhase: "edit", Faults: true},
		{SubscriptionUi: true, SubscriptionPhase: "edit", ProviderMatrix: true},
		{SubscriptionUi: true, SubscriptionPhase: "edit", NetworkRecovery: true},
		{SubscriptionUi: true, SubscriptionPhase: "edit", PolicyRecovery: "reset"},
	} {
		if err := selectRunOutput(mode, id); err == nil || outputRoot != allowed {
			t.Fatal("invalid mode accepted or changed the diagnostic destination")
		}
	}
	for _, bad := range []string{"", "../elsewhere", "00000000-0000-0000-0000-000000000000", id + "/child"} {
		if err := selectRunOutput(qaRunMode{SubscriptionUi: true, SubscriptionPhase: "edit"}, bad); err == nil || outputRoot != allowed {
			t.Fatal("invalid subscription run accepted or changed output")
		}
	}
}
