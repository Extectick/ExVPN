//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
// Disposable-Sandbox integration harness. Never included in application packages.
package main

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
	service "github.com/Extectick/ExVPN/native/windows"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/stats"
	"golang.org/x/sys/windows"
)

const inputRoot = `C:\ExVPN-System-QA`
const outputRoot = `C:\ExVPN-QA`
const installedRoot = `C:\Program Files\ExVPN System QA`

type object = map[string]any

type diagnosticGuard struct{ *service.WindowsGuard }

func (g diagnosticGuard) result(operation string, err error) error {
	if err != nil {
		report := object{"operation": operation}
		var errno windows.Errno
		if errors.As(err, &errno) {
			report["win32Code"] = fmt.Sprintf("0x%08x", uint32(errno))
		}
		b, _ := json.MarshalIndent(report, "", "  ")
		_ = os.WriteFile(filepath.Join(outputRoot, "guard-error.json"), b, 0600)
	}
	return err
}
func (g diagnosticGuard) Arm() error { return g.result("arm", g.WindowsGuard.Arm()) }
func (g diagnosticGuard) PermitTunnel(luid uint64) error {
	return g.result("permit", g.WindowsGuard.PermitTunnel(luid))
}
func (g diagnosticGuard) Suspend() error { return g.result("suspend", g.WindowsGuard.Suspend()) }
func (g diagnosticGuard) Disarm() error  { return g.result("disarm", g.WindowsGuard.Disarm()) }

func main() {
	confirm := flag.Bool("confirm-disposable-guest", false, "Required isolated Windows Sandbox confirmation")
	inspect := flag.Bool("inspect-guard", false, "Read owned persistent guard state without starting a tunnel")
	interfaceIndex := flag.Int("interface-index", 0, "Guest physical default-route interface, before TUN creation")
	flag.Parse()
	if !*confirm || flag.NArg() != 0 || validateGuest() != nil {
		fmt.Println("disposable_system_guest_required")
		os.Exit(2)
	}
	if *inspect {
		armed, err := (&service.WindowsGuard{}).Armed()
		b, _ := json.Marshal(object{"utc": time.Now().UTC().Format(time.RFC3339), "guardArmed": armed, "readFailed": err != nil})
		_ = os.WriteFile(filepath.Join(outputRoot, "guard-inspection.json"), b, 0600)
		return
	}
	_ = os.WriteFile(filepath.Join(outputRoot, "guard-error.json"), []byte(`{"operation":"none"}`), 0600)
	if err := run(*interfaceIndex); err != nil {
		// All errors returned by run are fixed codes; never expose Xray errors.
		writeReport(object{"phase": "failed", "code": err.Error()})
		os.Exit(1)
	}
}

func validateGuest() error {
	b, err := os.ReadFile(`C:\ExVPN-Package\sandbox-bundle.json`)
	var marker struct{ ForbiddenHost string }
	if err != nil || len(b) > 65536 || json.Unmarshal(b, &marker) != nil || marker.ForbiddenHost == "" {
		return errors.New("marker_required")
	}
	host, err := os.Hostname()
	if err != nil || strings.EqualFold(host, marker.ForbiddenHost) {
		return errors.New("host_forbidden")
	}
	token, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil || token.User.Sid.String() != "S-1-5-18" {
		return errors.New("system_required")
	}
	exe, err := os.Executable()
	if err != nil || !strings.EqualFold(filepath.Dir(exe), installedRoot) {
		return errors.New("protected_test_path_required")
	}
	if _, err := os.Stat(inputRoot); err != nil {
		return errors.New("test_input_required")
	}
	return nil
}

func writeReport(report object) {
	report["utc"] = time.Now().UTC().Format(time.RFC3339)
	report["controllerHarness"] = true
	report["installedServiceIpcTested"] = false
	b, _ := json.MarshalIndent(report, "", "  ")
	// Output is diagnostic data only. The host never executes guest output.
	_ = os.WriteFile(filepath.Join(outputRoot, "native-network.json"), b, 0600)
}

func run(interfaceIndex int) error {
	iface, err := net.InterfaceByIndex(interfaceIndex)
	if err != nil || iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 || iface.Name == service.TunnelName {
		return errors.New("physical_interface_invalid")
	}
	guard := &service.WindowsGuard{}
	if armed, e := guard.Armed(); e != nil || armed {
		return errors.New("clean_guard_required")
	}
	if _, e := net.InterfaceByName(service.TunnelName); e == nil {
		return errors.New("clean_adapter_required")
	}
	fixture, profile, err := startFixture(iface.Name)
	if err != nil {
		return errors.New("fixture_start_failed")
	}
	defer fixture.Close()
	controller, err := service.NewController(diagnosticGuard{guard}, service.StartTunnel, service.ValidateExclusions, true)
	if err != nil {
		return errors.New("controller_start_failed")
	}
	defer controller.Disconnect()
	excluded := filepath.ToSlash(filepath.Join(installedRoot, "excluded-probe.exe"))
	if service.ValidateExclusions([]string{excluded}) != nil {
		return errors.New("test_probe_missing")
	}
	if err := controller.Connect(profile, []string{excluded}); err != nil {
		return errors.New("connect_rejected")
	}
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	deadline := time.NewTimer(10 * time.Minute)
	defer deadline.Stop()
	fixtureStopped := false
	for {
		select {
		case <-deadline.C:
			return errors.New("test_deadline")
		case <-ticker.C:
		}
		status := controller.Status()
		report := object{"phase": "running", "status": status, "fixtureStopped": fixtureStopped}
		if traffic, err := controller.Statistics(); err == nil {
			report["tunTraffic"] = traffic
		}
		if manager, ok := fixture.GetFeature(stats.ManagerType()).(stats.Manager); ok {
			for _, direction := range []string{"uplink", "downlink"} {
				if counter := manager.GetCounter("inbound>>>qa-fixture>>>traffic>>>" + direction); counter != nil {
					report["fixture"+direction] = counter.Value()
				}
			}
		}
		writeReport(report)
		// Fixed, credential-free actions from the read-only host test directory.
		command, _ := os.ReadFile(filepath.Join(inputRoot, "command.txt"))
		switch strings.TrimSpace(string(command)) {
		case "stop-fixture":
			if !fixtureStopped {
				_ = fixture.Close()
				fixtureStopped = true
			}
		case "disconnect":
			if err := controller.Disconnect(); err != nil {
				return errors.New("disconnect_failed")
			}
			armed, err := guard.Armed()
			_, adapterErr := net.InterfaceByName(service.TunnelName)
			writeReport(object{"phase": "disconnected", "guardArmed": armed, "guardReadFailed": err != nil, "adapterPresent": adapterErr == nil})
			return nil
		}
	}
}

func startFixture(physicalInterface string) (*core.Instance, exvpn.Profile, error) {
	// A real remote server resolves destination names outside the client TUN.
	// This local fixture must emulate that separation: resolve its one health
	// destination before capture, then use a fixture-only static DNS entry.
	addresses, err := net.LookupIP("www.gstatic.com")
	if err != nil {
		return nil, exvpn.Profile{}, err
	}
	var healthIPs []string
	for _, address := range addresses {
		if v4 := address.To4(); v4 != nil {
			healthIPs = append(healthIPs, v4.String())
		}
	}
	if len(healthIPs) == 0 {
		return nil, exvpn.Profile{}, errors.New("fixture_dns_unavailable")
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, exvpn.Profile{}, err
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return nil, exvpn.Profile{}, err
	}
	id[6] = (id[6] & 0x0f) | 0x40
	id[8] = (id[8] & 0x3f) | 0x80
	uuid := fmt.Sprintf("%x-%x-%x-%x-%x", id[:4], id[4:6], id[6:8], id[8:10], id[10:])
	config := object{
		"log":   object{"loglevel": "none", "access": "none", "error": "none"},
		"dns":   object{"hosts": object{"www.gstatic.com": healthIPs}, "servers": []any{}},
		"stats": object{}, "policy": object{"system": object{"statsInboundUplink": true, "statsInboundDownlink": true}},
		"inbounds": []any{object{"tag": "qa-fixture", "listen": "127.0.0.1", "port": port, "protocol": "vless", "settings": object{"clients": []any{object{"id": uuid}}, "decryption": "none"}}},
		// The fixture shares the privileged harness process but binds its
		// upstream to the original physical interface, never back into the TUN.
		// Independent probe executables get no such bypass or socket options.
		"outbounds": []any{object{"protocol": "freedom", "settings": object{"domainStrategy": "UseIPv4"}, "streamSettings": object{"sockopt": object{"interface": physicalInterface}}}},
	}
	b, err := json.Marshal(config)
	if err != nil {
		return nil, exvpn.Profile{}, err
	}
	cfg, err := core.LoadConfig("json", bytes.NewReader(b))
	if err != nil {
		return nil, exvpn.Profile{}, err
	}
	instance, err := core.New(cfg)
	if err != nil {
		return nil, exvpn.Profile{}, err
	}
	if err := instance.Start(); err != nil {
		_ = instance.Close()
		return nil, exvpn.Profile{}, err
	}
	return instance, exvpn.Profile{ID: "qa-vless", Name: "QA VLESS TCP", Protocol: "vless", Server: "127.0.0.1", Port: port, UUID: uuid, Transport: exvpn.Transport{Type: "tcp"}}, nil
}
