//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
// Disposable-Sandbox-only experiment. Never included in production packages.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
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
const wireLimit = 64 << 10
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
	RunID         string     `json:"runId"`
	Case          string     `json:"case"`
	Positive      bool       `json:"positiveEstablished"`
	ReadEnd       string     `json:"readEnd"`
	EOF           bool       `json:"eof"`
	Passed        bool       `json:"passed"`
	ElapsedMS     int64      `json:"elapsedMs"`
	FinalStates   []uint32   `json:"finalStates"`
	Samples       []snapshot `json:"samples"`
	GateStarted   time.Time  `json:"gateStartedUtc"`
	GateEnded     time.Time  `json:"gateEndedUtc"`
	DataLocal     string     `json:"dataLocal"`
	DataRemote    string     `json:"dataRemote"`
	ControlLocal  string     `json:"controlLocal"`
	ControlRemote string     `json:"controlRemote"`
}

// Fixed QA protocol. The random synthetic payload also binds frames to this
// private run; no provider configuration or production command enters the wire.
type wireMessage struct {
	Version      int         `json:"version"`
	Action       string      `json:"action"`
	RunID        string      `json:"runId"`
	Case         string      `json:"case"`
	HelperSHA256 string      `json:"helperSha256"`
	Nonce        string      `json:"nonce"`
	Result       *peerResult `json:"result,omitempty"`
}

func message(c config, mode, action string) wireMessage {
	return wireMessage{Version: 1, Action: action, RunID: c.RunID, Case: mode, HelperSHA256: c.HelperSHA256, Nonce: c.PayloadHex}
}

func validateMessage(m wireMessage, c config, mode, action string) error {
	if m.Version != 1 || m.Action != action || m.RunID != c.RunID || m.Case != mode ||
		m.HelperSHA256 != c.HelperSHA256 || m.Nonce != c.PayloadHex {
		return errors.New("wire_identity_rejected")
	}
	if action != "result" {
		if m.Result != nil {
			return errors.New("wire_result_unexpected")
		}
		return nil
	}
	if m.Result == nil || m.Result.RunID != c.RunID || m.Result.Case != mode || !m.Result.Positive ||
		m.Result.ElapsedMS < 0 || (m.Result.Passed && (m.Result.ElapsedMS >= gate.Milliseconds() ||
		(m.Result.ReadEnd != "eof" && m.Result.ReadEnd != "reset") || activeTCP(m.Result.FinalStates))) {
		return errors.New("wire_result_rejected")
	}
	return nil
}

func writeFrame(w io.Writer, m wireMessage) error {
	b, err := json.Marshal(m)
	if err != nil || len(b) == 0 || len(b) > wireLimit {
		return errors.New("wire_size_rejected")
	}
	frame := make([]byte, 4+len(b))
	binary.BigEndian.PutUint32(frame, uint32(len(b)))
	copy(frame[4:], b)
	for len(frame) > 0 {
		n, e := w.Write(frame)
		if e != nil {
			return errors.New("wire_write_failed")
		}
		if n <= 0 || n > len(frame) {
			return errors.New("wire_short_write")
		}
		frame = frame[n:]
	}
	return nil
}

func readFrame(r io.Reader) (wireMessage, error) {
	var m wireMessage
	var prefix [4]byte
	if _, err := io.ReadFull(r, prefix[:]); err != nil {
		return m, errors.New("wire_header_failed")
	}
	n := binary.BigEndian.Uint32(prefix[:])
	if n == 0 || n > wireLimit {
		return m, errors.New("wire_size_rejected")
	}
	b := make([]byte, int(n))
	if _, err := io.ReadFull(r, b); err != nil {
		return m, errors.New("wire_payload_failed")
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if err := d.Decode(&m); err != nil {
		return m, errors.New("wire_json_rejected")
	}
	if d.Decode(new(any)) != io.EOF {
		return m, errors.New("wire_trailing_rejected")
	}
	return m, nil
}

func expectFrame(r io.Reader, c config, mode, action string) (wireMessage, error) {
	m, err := readFrame(r)
	if err != nil {
		return m, err
	}
	return m, validateMessage(m, c, mode, action)
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
	resultRoot := filepath.Join(`C:\ExVPN-Lifecycle-QA-Results`, c.RunID)
	payload, _ := hex.DecodeString(c.PayloadHex)
	for _, mode := range []string{"A", "B", "C"} {
		if err := runClientCase(c, control, resultRoot, mode, id, payload); err != nil {
			return err
		}
	}
	return nil
}

func runClientCase(c config, control, resultRoot, mode string, id identity, payload []byte) (err error) {
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
	if _, err = expectFrame(conn, c, mode, "positive"); err != nil {
		return errors.New("server_positive_control_failed")
	}
	local := conn.LocalAddr().(*net.TCPAddr).AddrPort()
	remote := conn.RemoteAddr().(*net.TCPAddr).AddrPort()
	states, err := tcpStates(local, remote, id.PID)
	if err != nil || len(states) != 1 || states[0] != 5 {
		return errors.New("client_positive_control_failed")
	}
	if err = writeFrame(conn, message(c, mode, "close-intent")); err != nil {
		return err
	}
	if _, err = expectFrame(conn, c, mode, "close-ready"); err != nil {
		return errors.New("close_ready_missing")
	}
	readyAt := time.Now()
	result := map[string]any{"runId": c.RunID, "case": mode, "identity": id, "positiveEstablished": true, "local": local.String(), "remote": remote.String(), "payloadBytes": len(payload), "payloadDrained": true, "luidAbsenceVerified": mode != "A", "wireVersion": 1, "closeReadyUtc": readyAt.UTC()}
	var peer peerResult
	events := []map[string]any{}
	closeErr := closeInOrder(mode, guardTrace{g, &events}, func() error {
		result["readyToCloseStartedNanos"] = time.Since(readyAt).Nanoseconds()
		result["closeStartedUtc"] = time.Now().UTC()
		e := conn.Close()
		result["closeReturnedUtc"] = time.Now().UTC()
		result["readyToCloseReturnedNanos"] = time.Since(readyAt).Nanoseconds()
		if e != nil {
			return errors.New("close_failed")
		}
		return nil
	}, func() error {
		// A separate owned control connection only retrieves the already-running
		// gate. In C this happens after Disarm. No shared-folder IO is involved.
		result["resultRequestUtc"] = time.Now().UTC()
		var endpoints map[string]string
		peer, endpoints, err = requestPeerResult(c, mode, local, remote)
		if err != nil {
			return err
		}
		result["control"] = endpoints
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

func requestPeerResult(c config, mode string, dataLocal, dataRemote netip.AddrPort) (peerResult, map[string]string, error) {
	conn, err := net.DialTimeout("tcp4", c.Address, 4*time.Second)
	if err != nil {
		return peerResult{}, nil, errors.New("result_connect_failed")
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(12 * time.Second))
	local := conn.LocalAddr().(*net.TCPAddr).AddrPort()
	remote := conn.RemoteAddr().(*net.TCPAddr).AddrPort()
	if local == dataLocal && remote == dataRemote {
		return peerResult{}, nil, errors.New("control_is_data_socket")
	}
	if err = writeFrame(conn, message(c, mode, "result-request")); err != nil {
		return peerResult{}, nil, err
	}
	m, err := expectFrame(conn, c, mode, "result")
	if err != nil {
		return peerResult{}, nil, err
	}
	return *m.Result, map[string]string{"local": local.String(), "remote": remote.String()}, nil
}

func runServer(c config, configPath string) error {
	name, err := os.Hostname()
	if err != nil || !strings.EqualFold(name, c.ForbiddenHost) || !filepath.IsAbs(c.HostResults) || !strings.Contains(strings.ToLower(c.HostResults), `\.private\windows-lifecycle-results\`) {
		return errors.New("host_scope_required")
	}
	exe, err := os.Executable()
	if err != nil {
		return errors.New("host_identity_unavailable")
	}
	hash, err := fileHash(exe)
	if err != nil || hash != c.HelperSHA256 {
		return errors.New("host_helper_identity_changed")
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
		err = serveCase(c, root, mode, conn, payload, listener.(*net.TCPListener))
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

func serveCase(c config, root, mode string, conn net.Conn, payload []byte, listener *net.TCPListener) error {
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
	if err = writeFrame(conn, message(c, mode, "positive")); err != nil {
		return err
	}
	if _, err = expectFrame(conn, c, mode, "close-intent"); err != nil {
		return err
	}
	// This timestamp owns the entire gate. Neither the ready ACK flight nor a
	// late control connection can reset or extend its ten-second deadline.
	start := time.Now()
	_ = conn.SetDeadline(start.Add(gate))
	readDone := make(chan string, 1)
	readerReady := make(chan struct{})
	readerFinished := make(chan struct{})
	go func() {
		defer close(readerFinished)
		close(readerReady)
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
	<-readerReady
	if err = writeFrame(conn, message(c, mode, "close-ready")); err != nil {
		return err
	}
	result, err := observePeerGate(start, time.Now, func() ([]uint32, error) {
		return tcpStates(local, remote, 0) // Exact DATA tuple, all owners including PID0.
	}, func() { time.Sleep(25 * time.Millisecond) }, readDone)
	if err != nil {
		return err
	}
	result.RunID, result.Case, result.Positive = c.RunID, mode, true
	result.DataLocal, result.DataRemote = local.String(), remote.String()
	_ = conn.Close() // Only after the gate outcome has been frozen.
	select {
	case <-readerFinished:
	case <-time.After(time.Second):
		return errors.New("peer_reader_not_stopped")
	}

	// The queued control connection retrieves a frozen result; it never starts
	// the gate. It has a different TCP tuple and is never sampled as the data peer.
	_ = listener.SetDeadline(time.Now().Add(5 * time.Second))
	control, err := listener.AcceptTCP()
	if err != nil {
		return errors.New("result_accept_failed")
	}
	defer control.Close()
	_ = control.SetDeadline(time.Now().Add(4 * time.Second))
	controlLocal := control.LocalAddr().(*net.TCPAddr).AddrPort()
	controlRemote := control.RemoteAddr().(*net.TCPAddr).AddrPort()
	if controlLocal == local && controlRemote == remote {
		return errors.New("control_is_data_socket")
	}
	if _, err = expectFrame(control, c, mode, "result-request"); err != nil {
		return err
	}
	result.ControlLocal, result.ControlRemote = controlLocal.String(), controlRemote.String()
	m := message(c, mode, "result")
	m.Result = &result
	if err = writeFrame(control, m); err != nil {
		return err
	}
	return writeJSON(filepath.Join(root, "result-"+mode+".json"), result)
}

func activeTCP(states []uint32) bool {
	for _, state := range states {
		if state != 1 && state != 11 && state != 12 {
			return true
		}
	}
	return false
}

// The injected clock/table functions let fixtures exercise deadline boundaries
// without networking, wall-clock waits, WFP or SCM mutations.
func observePeerGate(start time.Time, now func() time.Time, sample func() ([]uint32, error), pause func(), readDone <-chan string) (peerResult, error) {
	result := peerResult{ReadEnd: "pending", Samples: []snapshot{}, GateStarted: start.UTC()}
	for {
		select {
		case result.ReadEnd = <-readDone:
		default:
		}
		states, e := sample()
		if e != nil {
			return result, e
		}
		observed := now()
		elapsed := observed.Sub(start)
		if elapsed < 0 {
			return result, errors.New("gate_clock_rejected")
		}
		result.FinalStates = states
		result.ElapsedMS = elapsed.Milliseconds()
		result.GateEnded = observed.UTC()
		result.Samples = append(result.Samples, snapshot{result.ElapsedMS, states})
		result.EOF = result.ReadEnd == "eof"
		// Check expiry BEFORE success. A late ACK/read/table result must never
		// turn a deadline failure into a PASS, even when the socket is now gone.
		if elapsed >= gate {
			break
		}
		if !activeTCP(states) && (result.EOF || result.ReadEnd == "reset") {
			result.Passed = true
			break
		}
		pause()
	}
	return result, nil
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
