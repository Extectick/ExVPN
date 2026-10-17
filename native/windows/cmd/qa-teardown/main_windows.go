//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
// Disposable-Sandbox-only experiment. Never included in production packages.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	service "github.com/Extectick/ExVPN/native/windows"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
)

const gate = 10 * time.Second
const absentLUID = uint64(24)<<48 | uint64(0xffffff)<<24 // Valid encoding; never assume absence.

var runPattern = regexp.MustCompile(`^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`)
var hashPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)

type config struct {
	RunID          string `json:"runId"`
	ForbiddenHost  string `json:"forbiddenHost"`
	HelperSHA256   string `json:"helperSha256"`
	ServiceSHA256  string `json:"serviceSha256"`
	ServiceCommand string `json:"serviceCommand"`
	Address        string `json:"address"`
	PayloadHex     string `json:"payloadHex"`
	HostResults    string `json:"hostResults,omitempty"`
}

type identity struct {
	PID     uint32 `json:"pid"`
	Created uint64 `json:"created"`
}

type ownership struct {
	RunID     string            `json:"runId"`
	Identity  identity          `json:"identity"`
	FilterIDs map[string]uint64 `json:"filterIds"`
}

type peerResult struct {
	RunID       string     `json:"runId"`
	Case        string     `json:"case"`
	Positive    bool       `json:"positiveEstablished"`
	ReadEnd     string     `json:"readEnd"`
	EOF         bool       `json:"eof"`
	Passed      bool       `json:"passed"`
	ElapsedMS   int64      `json:"elapsedMs"`
	FinalStates []uint32   `json:"finalStates"`
	Samples     []snapshot `json:"samples"`
}

type snapshot struct {
	ElapsedMS int64    `json:"elapsedMs"`
	States    []uint32 `json:"states"`
}

func readJSON(path string, target any) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	d := json.NewDecoder(io.LimitReader(f, 1<<20))
	d.DisallowUnknownFields()
	if err = d.Decode(target); err != nil {
		return errors.New("invalid_json")
	}
	if d.Decode(new(any)) != io.EOF {
		return errors.New("trailing_json")
	}
	return nil
}

func writeJSON(path string, value any) error {
	b, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	// Every checkpoint has a unique filename. Never replace historical evidence.
	f, err := os.CreateTemp(filepath.Dir(path), ".qa-checkpoint-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	_, err = f.Write(b)
	closeErr := f.Close()
	if err = errors.Join(err, closeErr); err != nil {
		return err
	}
	from, err := windows.UTF16PtrFromString(f.Name())
	if err != nil {
		return err
	}
	to, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	// No REPLACE_EXISTING: a duplicate checkpoint must fail rather than overwrite.
	return windows.MoveFileEx(from, to, windows.MOVEFILE_WRITE_THROUGH)
}

func waitJSON(path string, value any, timeout time.Duration) error {
	until := time.Now().Add(timeout)
	for time.Now().Before(until) {
		if err := readJSON(path, value); err == nil {
			return nil
		} else if !os.IsNotExist(err) {
			return errors.New("checkpoint_invalid")
		}
		time.Sleep(20 * time.Millisecond)
	}
	return errors.New("checkpoint_timeout")
}

func validateConfig(c config) error {
	a, err := netip.ParseAddrPort(c.Address)
	if !runPattern.MatchString(c.RunID) || c.RunID == "00000000-0000-0000-0000-000000000000" ||
		c.ForbiddenHost == "" || !hashPattern.MatchString(c.HelperSHA256) || !hashPattern.MatchString(c.ServiceSHA256) ||
		!hashPattern.MatchString(c.PayloadHex) || !strings.HasPrefix(c.ServiceCommand, `"C:\Program Files\ExVPN Service\exvpn-service.exe" `) ||
		err != nil || !a.Addr().Is4() || a.Addr().IsLoopback() || a.Addr().IsUnspecified() || a.Addr().IsMulticast() || a.Port() < 1024 {
		return errors.New("config_rejected")
	}
	return nil
}

func fileHash(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:]), nil
}

func currentIdentity() (identity, error) {
	var created, exited, kernel, user windows.Filetime
	err := windows.GetProcessTimes(windows.CurrentProcess(), &created, &exited, &kernel, &user)
	return identity{uint32(os.Getpid()), uint64(created.HighDateTime)<<32 | uint64(created.LowDateTime)}, err
}

func checkGuest(c config, mode, control string) error {
	name, err := os.Hostname()
	if err != nil || strings.EqualFold(name, c.ForbiddenHost) {
		return errors.New("forbidden_host")
	}
	u, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil || u.User.Sid.String() != "S-1-5-18" {
		return errors.New("system_required")
	}
	exe, err := os.Executable()
	if err != nil || !strings.EqualFold(control, filepath.Join(`C:\Program Files\ExVPN Teardown QA`, c.RunID)) || !strings.EqualFold(exe, filepath.Join(control, "qa-teardown.exe")) {
		return errors.New("protected_location_required")
	}
	h, err := fileHash(exe)
	if err != nil || h != c.HelperSHA256 {
		return errors.New("helper_identity_changed")
	}
	h, err = fileHash(`C:\Program Files\ExVPN Service\exvpn-service.exe`)
	if err != nil || h != c.ServiceSHA256 {
		return errors.New("service_identity_changed")
	}
	m, err := mgr.Connect()
	if err != nil {
		return errors.New("scm_unavailable")
	}
	defer m.Disconnect()
	s, err := m.OpenService("ExVPNService")
	if err != nil {
		return errors.New("service_unavailable")
	}
	defer s.Close()
	configuration, err := s.Config()
	if err != nil || configuration.BinaryPathName != c.ServiceCommand {
		return errors.New("service_binding_changed")
	}
	status, err := s.Query()
	if err != nil || (mode != "inspect" && mode != "preflight" && status.State != svc.Stopped) {
		return errors.New("service_must_be_stopped")
	}
	return nil
}

func absentProof(rows []winipcfg.MibIfRow2, row *winipcfg.MibIfRow2, lookupErr error) error {
	// GetIfEntry2 documents ERROR_FILE_NOT_FOUND when InterfaceLuid/Index does
	// not identify an interface. The pinned winipcfg wrapper returns raw errno.
	// https://learn.microsoft.com/windows/win32/api/netioapi/nf-netioapi-getifentry2
	// Invalid parameter, access denied, empty/failed enumeration are NOT absence.
	if len(rows) == 0 || row != nil || !errors.Is(lookupErr, windows.ERROR_FILE_NOT_FOUND) {
		return errors.New("luid_absence_unproven")
	}
	for _, r := range rows {
		if uint64(r.InterfaceLUID) == absentLUID {
			return errors.New("luid_exists")
		}
	}
	return nil
}

func verifyAbsentLUID() error {
	rows, err := winipcfg.GetIfTable2Ex(winipcfg.MibIfEntryNormal)
	if err != nil {
		return errors.New("interface_enumeration_failed")
	}
	row, err := winipcfg.LUID(absentLUID).Interface()
	return absentProof(rows, row, err)
}

type closeGuard interface {
	Suspend() error
	Disarm() error
}

type guardTrace struct {
	guard  closeGuard
	events *[]map[string]any
}

func (g guardTrace) Suspend() error {
	start := time.Now().UTC()
	e := g.guard.Suspend()
	*g.events = append(*g.events, map[string]any{"action": "Suspend", "startedUtc": start, "finishedUtc": time.Now().UTC(), "ok": e == nil})
	return e
}
func (g guardTrace) Disarm() error {
	start := time.Now().UTC()
	e := g.guard.Disarm()
	*g.events = append(*g.events, map[string]any{"action": "Disarm", "startedUtc": start, "finishedUtc": time.Now().UTC(), "ok": e == nil})
	return e
}

func closeInOrder(mode string, g closeGuard, closeSocket func() error, waitPeer func() error) error {
	switch mode {
	case "A":
		if err := closeSocket(); err != nil {
			return err
		}
		return waitPeer()
	case "B":
		if err := closeSocket(); err != nil {
			return err
		}
		peerErr := waitPeer() // Keep only this executable's self-permit alive.
		return errors.Join(peerErr, g.Suspend(), g.Disarm())
	case "C":
		if err := g.Suspend(); err != nil {
			return err
		}
		if err := closeSocket(); err != nil {
			return err
		}
		if err := g.Disarm(); err != nil {
			return err
		} // Immediately, as production.
		return waitPeer()
	default:
		return errors.New("case_rejected")
	}
}

func runClient(c config, control string) error {
	id, err := currentIdentity()
	if err != nil {
		return err
	}
	var authorized identity
	if waitJSON(filepath.Join(control, "authorized.json"), &authorized, 5*time.Second) != nil || authorized != id {
		return errors.New("client_not_authorized")
	}
	inputRoot, err := guestInputRoot(c.RunID)
	if err != nil {
		return err
	}
	serverRoot := filepath.Join(inputRoot, "server")
	resultRoot := filepath.Join(`C:\ExVPN-Lifecycle-QA-Results`, c.RunID)
	payload, _ := hex.DecodeString(c.PayloadHex)
	for _, mode := range []string{"A", "B", "C"} {
		if err := runClientCase(c, control, serverRoot, resultRoot, mode, id, payload); err != nil {
			return err
		}
	}
	return nil
}

func runClientCase(c config, control, serverRoot, resultRoot, mode string, id identity, payload []byte) (err error) {
	g := &service.WindowsGuard{}
	armed, err := g.Armed()
	if err != nil || armed {
		return errors.New("guard_not_initially_clear")
	}
	owned := false
	defer func() {
		if owned {
			err = errors.Join(err, g.Suspend(), g.Disarm())
		}
	}()
	if mode != "A" {
		if err = verifyAbsentLUID(); err != nil {
			return err
		}
		if err = g.Arm(); err != nil {
			return errors.New("arm_failed")
		}
		owned = true
		// A hard kill between Arm and this ownership checkpoint remains fail
		// closed: recovery refuses to delete filters without exact IDs. This
		// diagnostic does not inject that crash, and must not claim to cover it.
		ids, e := persistentFilterIDs()
		if e != nil || len(ids) != 8 {
			return errors.New("ownership_record_failed")
		}
		if err = writeJSON(filepath.Join(control, "ownership-"+mode+".json"), ownership{c.RunID, id, ids}); err != nil {
			return err
		}
		if err = verifyAbsentLUID(); err != nil {
			return err
		} // Recheck immediately before Permit.
		if err = g.PermitTunnel(absentLUID); err != nil {
			return errors.New("permit_failed")
		}
	}
	conn, err := net.DialTimeout("tcp4", c.Address, 4*time.Second)
	if err != nil {
		return errors.New("connect_failed")
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err = conn.Write(payload); err != nil {
		return errors.New("echo_write_failed")
	}
	echo := make([]byte, len(payload))
	if _, err = io.ReadFull(conn, echo); err != nil || !bytes.Equal(echo, payload) {
		return errors.New("echo_failed")
	}
	local := conn.LocalAddr().(*net.TCPAddr).AddrPort()
	remote := conn.RemoteAddr().(*net.TCPAddr).AddrPort()
	states, err := tcpStates(local, remote, id.PID)
	if err != nil || len(states) != 1 || states[0] != 5 {
		return errors.New("client_positive_control_failed")
	}
	var ready struct {
		RunID    string `json:"runId"`
		Case     string `json:"case"`
		Positive bool   `json:"positiveEstablished"`
	}
	if waitJSON(filepath.Join(serverRoot, "ready-"+mode+".json"), &ready, 5*time.Second) != nil || ready.RunID != c.RunID || ready.Case != mode || !ready.Positive {
		return errors.New("server_positive_control_failed")
	}
	result := map[string]any{"runId": c.RunID, "case": mode, "identity": id, "positiveEstablished": true, "local": local.String(), "remote": remote.String(), "payloadBytes": len(payload), "payloadDrained": true, "luidAbsenceVerified": mode != "A"}
	var peer peerResult
	events := []map[string]any{}
	closeErr := closeInOrder(mode, guardTrace{g, &events}, func() error {
		result["closeStartedUtc"] = time.Now().UTC()
		e := conn.Close()
		result["closeReturnedUtc"] = time.Now().UTC()
		if e != nil {
			return errors.New("close_failed")
		}
		return nil
	}, func() error {
		// In C this checkpoint occurs AFTER Disarm. Shared-folder IO must not
		// extend the intentional Suspend -> Close -> immediate Disarm interval.
		result["peerCheckpointUtc"] = time.Now().UTC()
		if err := writeJSON(filepath.Join(resultRoot, "closed-"+mode+".json"), map[string]any{"runId": c.RunID, "case": mode}); err != nil {
			return err
		}
		if waitJSON(filepath.Join(serverRoot, "result-"+mode+".json"), &peer, 12*time.Second) != nil || peer.RunID != c.RunID || peer.Case != mode {
			return errors.New("peer_report_missing")
		}
		return nil // Record negative gate without preventing the next independent case.
	})
	result["closeSequenceFinishedUtc"] = time.Now().UTC()
	result["guardCalls"] = events
	if closeErr != nil {
		return closeErr
	}
	after, err := tcpStates(local, remote, 0) // ALL owners, including PID0 after handle release.
	if err != nil {
		return err
	}
	result["guestAfterStates"] = after
	result["peer"] = peer
	result["gatePassed"] = peer.Passed
	if err = writeJSON(filepath.Join(resultRoot, "client-"+mode+".json"), result); err != nil {
		return err
	}
	return nil
}

func runServer(c config, configPath string) error {
	name, err := os.Hostname()
	if err != nil || !strings.EqualFold(name, c.ForbiddenHost) || !filepath.IsAbs(c.HostResults) || !strings.Contains(strings.ToLower(c.HostResults), `\.private\windows-lifecycle-results\`) {
		return errors.New("host_scope_required")
	}
	root, err := serverReportRoot(c.HostResults, configPath)
	if err != nil {
		return err
	}
	for _, path := range []string{c.HostResults, configPath} {
		if err = noReparseAncestors(path); err != nil {
			return err
		}
	}
	if err = os.Mkdir(root, 0700); err != nil {
		return err
	}
	listener, err := net.Listen("tcp4", c.Address)
	if err != nil {
		return errors.New("listener_failed")
	}
	defer listener.Close()
	if err = writeJSON(filepath.Join(root, "listening.json"), map[string]any{"runId": c.RunID, "ready": true}); err != nil {
		return err
	}
	payload, _ := hex.DecodeString(c.PayloadHex)
	for _, mode := range []string{"A", "B", "C"} {
		_ = listener.(*net.TCPListener).SetDeadline(time.Now().Add(35 * time.Second))
		conn, e := listener.Accept()
		if e != nil {
			return errors.New("accept_failed")
		}
		err = serveCase(c, root, mode, conn, payload)
		_ = conn.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

func serverReportRoot(results, configPath string) (string, error) {
	results = filepath.Clean(results)
	runID := filepath.Base(results)
	privateRoot := filepath.Dir(filepath.Dir(results))
	inputRoot := filepath.Join(privateRoot, "teardown-inputs", runID)
	if !filepath.IsAbs(results) || !runPattern.MatchString(runID) ||
		runID == "00000000-0000-0000-0000-000000000000" ||
		!strings.EqualFold(filepath.Base(filepath.Dir(results)), "windows-lifecycle-results") ||
		!strings.EqualFold(filepath.Base(privateRoot), ".private") ||
		!strings.EqualFold(filepath.Clean(configPath), filepath.Join(inputRoot, "payload", "marker.json")) {
		return "", errors.New("server_layout_rejected")
	}
	return filepath.Join(inputRoot, "server"), nil
}

func guestInputRoot(runID string) (string, error) {
	if !runPattern.MatchString(runID) || runID == "00000000-0000-0000-0000-000000000000" {
		return "", errors.New("guest_input_run_rejected")
	}
	return `C:\ExVPN-Teardown-Input-` + runID, nil
}

func noReparseAncestors(path string) error {
	for current := filepath.Clean(path); ; current = filepath.Dir(current) {
		p, err := windows.UTF16PtrFromString(current)
		if err != nil {
			return errors.New("input_path_invalid")
		}
		attributes, err := windows.GetFileAttributes(p)
		if err != nil || attributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
			return errors.New("input_path_untrusted")
		}
		if filepath.Dir(current) == current {
			return nil
		}
	}
}

func serveCase(c config, root, mode string, conn net.Conn, payload []byte) error {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	received := make([]byte, len(payload))
	if _, err := io.ReadFull(conn, received); err != nil || !bytes.Equal(received, payload) {
		return errors.New("payload_rejected")
	}
	if _, err := conn.Write(payload); err != nil {
		return errors.New("echo_failed")
	}
	local := conn.LocalAddr().(*net.TCPAddr).AddrPort()
	remote := conn.RemoteAddr().(*net.TCPAddr).AddrPort()
	states, err := tcpStates(local, remote, uint32(os.Getpid()))
	if err != nil || len(states) != 1 || states[0] != 5 {
		return errors.New("server_positive_control_failed")
	}
	if err = writeJSON(filepath.Join(root, "ready-"+mode+".json"), map[string]any{"runId": c.RunID, "case": mode, "positiveEstablished": true}); err != nil {
		return err
	}
	readDone := make(chan string, 1)
	go func() {
		var b [1]byte
		n, e := conn.Read(b[:])
		end := "other_error"
		if n > 0 {
			end = "unexpected_data"
		} else if e == io.EOF {
			end = "eof"
		} else if errors.Is(e, windows.WSAECONNRESET) {
			end = "reset"
		} else if ne, ok := e.(net.Error); ok && ne.Timeout() {
			end = "timeout"
		}
		if end == "eof" || end == "reset" {
			_ = conn.Close()
		}
		readDone <- end
	}()
	var closed struct {
		RunID string `json:"runId"`
		Case  string `json:"case"`
	}
	if waitJSON(filepath.Join(c.HostResults, "closed-"+mode+".json"), &closed, 10*time.Second) != nil || closed.RunID != c.RunID || closed.Case != mode {
		return errors.New("close_checkpoint_failed")
	}
	start := time.Now()
	_ = conn.SetReadDeadline(start.Add(gate))
	result := peerResult{RunID: c.RunID, Case: mode, Positive: true, ReadEnd: "pending", Samples: []snapshot{}}
	for {
		select {
		case result.ReadEnd = <-readDone:
		default:
		}
		states, e := tcpStates(local, remote, 0)
		if e != nil {
			return e
		}
		result.FinalStates = states
		result.ElapsedMS = time.Since(start).Milliseconds()
		result.Samples = append(result.Samples, snapshot{result.ElapsedMS, states})
		result.EOF = result.ReadEnd == "eof"
		active := false
		for _, state := range states {
			if state != 1 && state != 11 && state != 12 {
				active = true
			}
		}
		if !active && (result.EOF || result.ReadEnd == "reset") {
			result.Passed = true
			break
		}
		if time.Since(start) >= gate {
			break
		}
		time.Sleep(25 * time.Millisecond)
	}
	_ = conn.Close() // Owned server endpoint cleanup happens only after recording gate outcome.
	if result.ReadEnd == "pending" {
		select {
		case <-readDone:
		case <-time.After(time.Second):
		}
	}
	return writeJSON(filepath.Join(root, "result-"+mode+".json"), result)
}

func recoverGuard(c config, control string) error {
	var authorized identity
	if err := readJSON(filepath.Join(control, "authorized.json"), &authorized); err != nil {
		return errors.New("authorization_missing")
	}
	// The watchdog must first terminate and verify the exact owned process.
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, authorized.PID)
	if err == nil {
		var created, exited, kernel, user windows.Filetime
		queryErr := windows.GetProcessTimes(h, &created, &exited, &kernel, &user)
		windows.CloseHandle(h)
		// A launcher retaining its process handle can keep the terminated object
		// addressable. Require the original creation identity AND actual exit.
		if queryErr != nil || (uint64(created.HighDateTime)<<32|uint64(created.LowDateTime)) != authorized.Created ||
			(uint64(exited.HighDateTime)<<32|uint64(exited.LowDateTime)) == 0 {
			return errors.New("client_death_unproven")
		}
	} else if !errors.Is(err, windows.ERROR_INVALID_PARAMETER) {
		return errors.New("client_death_unproven")
	}
	current, err := persistentFilterIDs()
	if err != nil {
		return err
	}
	if len(current) == 0 {
		return nil
	}
	for _, mode := range []string{"C", "B"} {
		var owner ownership
		if readJSON(filepath.Join(control, "ownership-"+mode+".json"), &owner) != nil {
			continue
		}
		if owner.RunID != c.RunID || owner.Identity != authorized || !ownedFilterSet(current, owner.FilterIDs) {
			continue
		}
		g := &service.WindowsGuard{}
		if err = g.Disarm(); err != nil {
			return errors.New("owned_disarm_failed")
		}
		remaining, e := persistentFilterIDs()
		if e != nil || len(remaining) != 0 {
			return errors.New("guard_cleanup_not_verified")
		}
		return nil
	}
	return errors.New("guard_ownership_unproven")
}

func main() {
	err := run()
	// Raw OS errors can contain addresses, command lines or local identities.
	if err != nil {
		code := "qa_teardown_failed"
		if regexp.MustCompile(`^[a-z_]{1,80}$`).MatchString(err.Error()) {
			code = err.Error()
		}
		fmt.Fprintln(os.Stderr, code)
		os.Exit(1)
	}
}

func run() error {
	if len(os.Args) < 2 {
		return errors.New("mode_required")
	}
	mode := os.Args[1]
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	control := filepath.Dir(exe)
	configPath := filepath.Join(control, "config.json")
	if mode == "server" {
		if len(os.Args) != 3 {
			return errors.New("arguments_rejected")
		}
		configPath = os.Args[2]
	} else if len(os.Args) != 2 {
		return errors.New("arguments_rejected")
	}
	var c config
	if err = readJSON(configPath, &c); err != nil {
		return err
	}
	if err = validateConfig(c); err != nil {
		return err
	}
	if mode == "server" {
		return runServer(c, configPath)
	}
	if mode != "client" && mode != "cleanup" && mode != "inspect" && mode != "preflight" {
		return errors.New("mode_rejected")
	}
	if err = checkGuest(c, mode, control); err != nil {
		return err
	}
	if mode == "preflight" {
		if err = verifyAbsentLUID(); err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(map[string]bool{"luidAbsent": true})
	}
	if mode == "inspect" {
		armed, e := (&service.WindowsGuard{}).Armed()
		if e != nil {
			return e
		}
		return json.NewEncoder(os.Stdout).Encode(map[string]bool{"armed": armed})
	}
	if mode == "cleanup" {
		return recoverGuard(c, control)
	}
	return runClient(c, control)
}
