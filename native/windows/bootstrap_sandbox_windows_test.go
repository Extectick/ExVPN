//go:build windows && amd64 && exvpn_sandbox_qa

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

// Deliberately excluded from normal tests/CI. The compiled test executable may
// run only in the prepared disposable guest, with its narrow output mapping.
func TestSandboxBootstrapNetworkPolicy(t *testing.T) {
	markerBytes, err := os.ReadFile(`C:\ExVPN-Bootstrap-QA\sandbox-bundle.json`)
	var marker struct{ ForbiddenHost string }
	host, _ := os.Hostname()
	exe, _ := os.Executable()
	user, userErr := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil || len(markerBytes) > 65536 || json.Unmarshal(markerBytes, &marker) != nil || marker.ForbiddenHost == "" || strings.EqualFold(host, marker.ForbiddenHost) || userErr != nil || user.User.Sid.String() != "S-1-5-18" || !strings.EqualFold(filepath.Dir(exe), `C:\Program Files\ExVPN Bootstrap QA`) {
		t.Fatal("disposable_system_guest_required")
	}
	if _, err := os.Stat(`C:\ExVPN-Bootstrap-Results`); err != nil {
		t.Fatal("mapped_output_required")
	}
	report := map[string]any{"status": "running", "scope": "bootstrap WFP/DoH only; no TUN or installed service IPC", "startedUtc": time.Now().UTC().Format(time.RFC3339), "steps": []string{}}
	defer func() {
		if t.Failed() {
			report["status"] = "failed"
		}
		report["finishedUtc"] = time.Now().UTC().Format(time.RFC3339)
		body, _ := json.MarshalIndent(report, "", "  ")
		_ = os.WriteFile(`C:\ExVPN-Bootstrap-Results\bootstrap-result.json`, body, 0600)
	}()
	step := func(name string) { report["steps"] = append(report["steps"].([]string), name) }
	probe := func() bool {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		output, err := exec.CommandContext(ctx, `C:\Program Files\ExVPN Bootstrap QA\protected-probe.exe`, "-mode", "numeric").Output()
		var result struct {
			Success    bool
			HTTPStatus int
		}
		return err == nil && json.Unmarshal(output, &result) == nil && result.Success && result.HTTPStatus == 200
	}
	guard := &WindowsGuard{}
	if armed, err := guard.Armed(); err != nil || armed {
		t.Fatal("clean_guard_required")
	}
	if _, err := net.InterfaceByName(TunnelName); err == nil {
		t.Fatal("clean_adapter_required")
	}
	if !probe() {
		t.Fatal("baseline_https_failed")
	}
	step("baseline_independent_https")
	route, err := selectBootstrapRoute()
	if err != nil {
		t.Fatal("route_selection_failed")
	}
	if err := guard.Arm(); err != nil {
		t.Fatal("persistent_guard_failed")
	}
	defer func() {
		suspend := guard.Suspend()
		disarm := guard.Disarm()
		report["cleanupSucceeded"] = suspend == nil && disarm == nil
		if suspend != nil || disarm != nil {
			t.Error("owned_guard_cleanup_failed")
		}
	}()
	if probe() {
		t.Fatal("independent_process_bypassed_guard")
	}
	step("independent_process_blocked_before_bootstrap")
	if err := guard.beginBootstrap(route.luid); err != nil {
		if n, ok := err.(windows.Errno); ok {
			report["permitWin32Code"] = uint32(n)
		}
		t.Fatal("bootstrap_permit_failed")
	}
	if probe() {
		t.Fatal("independent_process_inherited_bootstrap")
	}
	step("independent_process_blocked_during_bootstrap")
	for _, target := range []string{"1.0.0.1:443", "1.1.1.1:80"} {
		conn, err := net.DialTimeout("tcp4", target, 2*time.Second)
		if err == nil {
			_ = conn.Close()
			t.Fatal("bootstrap_permit_too_broad")
		}
	}
	step("other_ip_and_port_blocked_for_bootstrap_process")
	client, closeConnections, err := newBootstrapClient(route)
	if err != nil {
		t.Fatal("bootstrap_client_failed")
	}
	result, err := resolveEndpointHTTPS(context.Background(), client, bootstrapURL, "example.com")
	closeConnections()
	if err != nil {
		report["queryCode"] = safeCode(err, "bootstrap_failed")
		t.Fatal("bootstrap_query_failed")
	}
	report["resolvedAddressCount"] = len(result.addresses)
	report["minimumTtl"] = result.ttl
	step("verified_https_dns_wireformat_A_and_AAAA")
	if err := guard.endBootstrap(); err != nil {
		t.Fatal("bootstrap_close_failed")
	}
	if probe() {
		t.Fatal("guard_not_retained")
	}
	conn, err := net.DialTimeout("tcp4", "1.1.1.1:443", 2*time.Second)
	if err == nil {
		_ = conn.Close()
		t.Fatal("bootstrap_permit_survived_close")
	}
	step("bootstrap_closed_persistent_guard_retained")
	if err := guard.Disarm(); err != nil {
		t.Fatal("explicit_disarm_failed")
	}
	if !probe() {
		t.Fatal("https_not_restored")
	}
	step("explicit_disarm_restored_independent_https")
	report["status"] = "passed"
}
