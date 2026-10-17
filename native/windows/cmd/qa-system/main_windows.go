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
	"unsafe"

	exvpn "github.com/Extectick/ExVPN/native/core"
	service "github.com/Extectick/ExVPN/native/windows"
	"github.com/xtls/xray-core/core"
	"golang.org/x/sys/windows"
)

const inputRoot = `C:\ExVPN-System-QA`
const outputRoot = `C:\ExVPN-QA`
const installedRoot = `C:\Program Files\ExVPN System QA`

type object = map[string]any

var runID string

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
	routingMode := flag.String("routing-mode", "exclude", "disabled, exclude or include; excluded-probe.exe is selected")
	fixtureProcess := flag.Bool("fixture-process", false, "Internal isolated fixture child; never starts a client tunnel")
	flag.Parse()
	if !*confirm || flag.NArg() != 0 || !validRoutingMode(*routingMode) || validateGuest() != nil {
		fmt.Println("disposable_system_guest_required")
		os.Exit(2)
	}
	if *inspect {
		armed, err := (&service.WindowsGuard{}).Armed()
		b, _ := json.Marshal(object{"utc": time.Now().UTC().Format(time.RFC3339), "runId": runID, "guardArmed": armed, "readFailed": err != nil})
		_ = os.WriteFile(filepath.Join(outputRoot, "guard-inspection.json"), b, 0600)
		return
	}
	if *fixtureProcess {
		if runFixtureProcess(*interfaceIndex) != nil {
			os.Exit(1)
		}
		return
	}
	_ = os.WriteFile(filepath.Join(outputRoot, "guard-error.json"), []byte(`{"operation":"none"}`), 0600)
	if err := run(*interfaceIndex, *routingMode); err != nil {
		// All errors returned by run are fixed codes; never expose Xray errors.
		writeReport(object{"phase": "failed", "code": err.Error(), "routingMode": *routingMode})
		os.Exit(1)
	}
}

func validateGuest() error {
	b, err := os.ReadFile(`C:\ExVPN-Package\sandbox-bundle.json`)
	var marker struct {
		Format        int
		ForbiddenHost string
		RunID         string
	}
	if err != nil || len(b) > 65536 || json.Unmarshal(b, &marker) != nil || marker.Format != 1 || marker.ForbiddenHost == "" {
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
	if err != nil || !strings.EqualFold(filepath.Dir(exe), installedRoot) || protectedTestPath(installedRoot) != nil || protectedTestPath(exe) != nil {
		return errors.New("protected_test_path_required")
	}
	if _, err := os.Stat(inputRoot); err != nil {
		return errors.New("test_input_required")
	}
	runID = marker.RunID
	return nil
}

// The fixed Program Files path alone is insufficient: refuse a junction or a
// writable replacement before the first WFP/TUN action. The guest installer
// supplies this exact protected ACL to the harness and its directory.
func protectedTestPath(path string) error {
	for current := path; filepath.Dir(current) != current; current = filepath.Dir(current) {
		info, err := os.Lstat(current)
		if err != nil || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("protected_test_path_required")
		}
		attributes, err := windows.GetFileAttributes(windows.StringToUTF16Ptr(current))
		if err != nil || attributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
			return errors.New("protected_test_path_required")
		}
	}
	sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return errors.New("protected_test_path_required")
	}
	owner, _, err := sd.Owner()
	if err != nil || owner == nil || (owner.String() != "S-1-5-18" && owner.String() != "S-1-5-32-544") {
		return errors.New("protected_test_path_required")
	}
	control, _, err := sd.Control()
	if err != nil || control&windows.SE_DACL_PROTECTED == 0 {
		return errors.New("protected_test_path_required")
	}
	acl, _, err := sd.DACL()
	if err != nil || acl == nil || acl.AceCount == 0 {
		return errors.New("protected_test_path_required")
	}
	const fileDeleteChild = 0x40 // FILE_DELETE_CHILD is absent from pinned x/sys.
	const writeRights = windows.FILE_WRITE_DATA | windows.FILE_APPEND_DATA | windows.FILE_WRITE_EA | windows.FILE_WRITE_ATTRIBUTES | windows.DELETE | fileDeleteChild | windows.WRITE_DAC | windows.WRITE_OWNER | windows.GENERIC_WRITE | windows.GENERIC_ALL
	for index := uint32(0); index < uint32(acl.AceCount); index++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if windows.GetAce(acl, index, &ace) != nil || ace == nil || ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE {
			return errors.New("protected_test_path_required")
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		if !sid.IsValid() || (ace.Mask&writeRights != 0 && sid.String() != "S-1-5-18" && sid.String() != "S-1-5-32-544") {
			return errors.New("protected_test_path_required")
		}
	}
	return nil
}

func writeReport(report object) {
	report["runId"] = runID
	report["utc"] = time.Now().UTC().Format(time.RFC3339)
	report["controllerHarness"] = true
	report["installedServiceIpcTested"] = false
	b, _ := json.MarshalIndent(report, "", "  ")
	// Output is diagnostic data only. The host never executes guest output.
	target := filepath.Join(outputRoot, "native-network.json")
	temporary := target + ".tmp"
	if os.WriteFile(temporary, b, 0600) == nil {
		_ = os.Rename(temporary, target)
	}
}

func run(interfaceIndex int, mode string) error {
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
	fixture, profile, err := startIsolatedFixture(interfaceIndex)
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
	policy := service.ApplicationRoutingPolicy{Mode: mode, Applications: []string{excluded}}
	response := controller.Handle(service.Request{Version: 1, ID: "qa-routing", Command: "setApplicationRouting", ApplicationRouting: &policy})
	if !response.OK {
		return errors.New("routing_policy_rejected")
	}
	loaded := controller.Handle(service.Request{Version: 1, ID: "qa-routing-read", Command: "getApplicationRouting"})
	if !loaded.OK || loaded.ApplicationRouting == nil || loaded.ApplicationRouting.Mode != mode || len(loaded.ApplicationRouting.Applications) != 1 || !strings.EqualFold(loaded.ApplicationRouting.Applications[0], excluded) {
		return errors.New("routing_policy_readback_failed")
	}
	// The legacy Connect(profile, paths) would overwrite the modern mode.
	if err := controller.ConnectMode(profile, service.ModeVPN); err != nil {
		return errors.New("connect_rejected")
	}
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	deadline := time.NewTimer(10 * time.Minute)
	defer deadline.Stop()
	fixtureStopped := false
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
		report := object{"phase": "running", "status": status, "fixtureStopped": fixtureStopped, "routingMode": mode, "selectedProbe": "excluded-probe.exe", "sequence": sequence, "guardArmed": armed, "guardReadFailed": guardErr != nil}
		if traffic, err := controller.Statistics(); err == nil {
			report["tunTraffic"] = traffic
		}
		counters := fixture.snapshot()
		report["fixtureuplink"], report["fixturedownlink"] = counters.Upload, counters.Download
		report["numericuplink"], report["numericdownlink"] = counters.NumericUpload, counters.NumericDownload
		writeReport(report)
		// Fixed, credential-free actions from the read-only host test directory.
		command, _ := os.ReadFile(filepath.Join(inputRoot, "command.txt"))
		if len(command) > 64 {
			return errors.New("test_command_rejected")
		}
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
			writeReport(object{"phase": "disconnected", "routingMode": mode, "sequence": sequence + 1, "guardArmed": armed, "guardReadFailed": err != nil, "adapterPresent": adapterErr == nil})
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
		"stats": object{}, "policy": object{"system": object{"statsInboundUplink": true, "statsInboundDownlink": true, "statsOutboundUplink": true, "statsOutboundDownlink": true}},
		"inbounds": []any{object{"tag": "qa-fixture", "listen": "127.0.0.1", "port": port, "protocol": "vless", "settings": object{"clients": []any{object{"id": uuid}}, "decryption": "none"}}},
		// The fixture shares the privileged harness process but binds its
		// upstream to the original physical interface, never back into the TUN.
		// Independent probe executables get no such bypass or socket options.
		// Separate destination counters exclude the controller's periodic health
		// requests from each independent numeric probe's routing evidence.
		"routing": object{"rules": []any{object{"type": "field", "ip": []string{"1.1.1.1"}, "port": "443", "outboundTag": "qa-numeric"}}},
		"outbounds": []any{
			object{"tag": "qa-health", "protocol": "freedom", "settings": object{"domainStrategy": "UseIPv4"}, "streamSettings": object{"sockopt": object{"interface": physicalInterface}}},
			object{"tag": "qa-numeric", "protocol": "freedom", "settings": object{"domainStrategy": "UseIPv4"}, "streamSettings": object{"sockopt": object{"interface": physicalInterface}}},
		},
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
