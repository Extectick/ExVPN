// SPDX-License-Identifier: Apache-2.0
//go:build windows

package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

type ownerProcess struct {
	handle  syscall.Handle
	created uint64
}

func (p *ownerProcess) close() {
	if p != nil && p.handle != 0 {
		syscall.CloseHandle(p.handle)
		p.handle = 0
	}
}

func installedUI() (string, error) {
	pf, err := knownPath(&programFilesID)
	if err != nil {
		return "", safeError("installed_app_required")
	}
	return filepath.Join(pf, "ExVPN", "exvpn.exe"), nil
}

func validateInstalledTree() (string, string, []*os.File, error) {
	ui, err := installedUI()
	if err != nil {
		return "", "", nil, err
	}
	held, err := lockAncestors(filepath.Dir(ui))
	if err != nil {
		return "", "", nil, safeError("installed_app_required")
	}
	fail := func() (string, string, []*os.File, error) {
		for _, f := range held {
			f.Close()
		}
		return "", "", nil, safeError("installed_app_required")
	}
	if verifyFileSecurity(held[len(held)-1], "", true, false) != nil {
		return fail()
	}
	u, err := secureReadFile(ui, "", true)
	if err != nil {
		return fail()
	}
	u.Close()
	return ui, filepath.Join(filepath.Dir(ui), "exvpn-updater.exe"), held, nil
}

func closeFiles(files []*os.File) {
	for i := len(files) - 1; i >= 0; i-- {
		files[i].Close()
	}
}

func validateOwner(pid int, expectedCreated uint64, sid, ui string) (*ownerProcess, error) {
	if pid < 1 || uint64(pid) > uint64(^uint32(0)) {
		return nil, safeError("owner_invalid")
	}
	h, err := syscall.OpenProcess(processQueryLimited|synchronize, false, uint32(pid))
	if err != nil {
		return nil, safeError("owner_invalid")
	}
	p := &ownerProcess{handle: h}
	fail := func() (*ownerProcess, error) { p.close(); return nil, safeError("owner_invalid") }
	var created, exited, kernelTime, userTime syscall.Filetime
	if syscall.GetProcessTimes(h, &created, &exited, &kernelTime, &userTime) != nil {
		return fail()
	}
	p.created = uint64(created.HighDateTime)<<32 | uint64(created.LowDateTime)
	if p.created == 0 || (expectedCreated != 0 && p.created != expectedCreated) {
		return fail()
	}
	buf := make([]uint16, 32768)
	count := uint32(len(buf))
	ok, _, _ := kernel.NewProc("QueryFullProcessImageNameW").Call(uintptr(h), 0, uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&count)))
	if ok == 0 || count == 0 || count >= uint32(len(buf)) || !strings.EqualFold(filepath.Clean(syscall.UTF16ToString(buf[:count])), ui) {
		return fail()
	}
	var token syscall.Token
	if syscall.OpenProcessToken(h, syscall.TOKEN_QUERY, &token) != nil {
		return fail()
	}
	u, uerr := token.GetTokenUser()
	var tokenSID string
	if uerr == nil {
		tokenSID, uerr = u.User.Sid.String()
	}
	permission := ordinaryToken(token)
	token.Close()
	if uerr != nil || tokenSID != sid || permission != nil {
		return fail()
	}
	var ownerSession, ownSession uint32
	procSession := kernel.NewProc("ProcessIdToSessionId")
	ok1, _, _ := procSession.Call(uintptr(pid), uintptr(unsafe.Pointer(&ownerSession)))
	ok2, _, _ := procSession.Call(uintptr(os.Getpid()), uintptr(unsafe.Pointer(&ownSession)))
	if ok1 == 0 || ok2 == 0 || ownerSession != ownSession {
		return fail()
	}
	if w, err := syscall.WaitForSingleObject(h, 0); err != nil || w != waitTimeout {
		return fail()
	}
	return p, nil
}

type workerRequest struct {
	Protocol      int    `json:"protocol"`
	Mode          string `json:"mode"`
	Version       string `json:"version,omitempty"`
	ParentPID     int    `json:"parentPid"`
	ParentCreated uint64 `json:"parentCreated"`
	HelperSHA256  string `json:"helperSha256"`
}

func hashFile(f *os.File) (string, error) {
	info, err := f.Stat()
	if err != nil || info.Size() < 1 || info.Size() > 64<<20 {
		return "", safeError("handoff_failed")
	}
	if _, err = f.Seek(0, 0); err != nil {
		return "", safeError("handoff_failed")
	}
	h := sha256.New()
	if _, err = io.Copy(h, io.LimitReader(f, 64<<20+1)); err != nil {
		return "", safeError("handoff_failed")
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func beginHandoff(req request, cfg trustedConfig, existing *store) (response, error) {
	ui, helper, installedHeld, err := validateInstalledTree()
	if err != nil {
		return response{}, err
	}
	defer closeFiles(installedHeld)
	self, err := os.Executable()
	if err != nil || !strings.EqualFold(filepath.Clean(self), helper) {
		return response{}, safeError("installed_app_required")
	}
	s := existing
	if s == nil {
		s, err = openStore(true)
		if err != nil {
			return response{}, err
		}
		defer s.close()
	}
	owner, err := validateOwner(req.ParentPID, 0, s.sid, ui)
	if err != nil {
		return response{}, err
	}
	defer owner.close()
	mode := "restart"
	var m manifest
	if req.Version != "" {
		mode = "install"
		var installer *os.File
		m, installer, err = s.ready(cfg, req.Version, time.Now().UTC())
		if err != nil {
			return response{}, err
		}
		defer installer.Close()
	}
	source, err := secureReadFile(helper, "", true)
	if err != nil {
		return response{}, safeError("installed_app_required")
	}
	defer source.Close()
	digest, err := hashFile(source)
	if err != nil {
		return response{}, err
	}
	id, err := randomID()
	if err != nil {
		return response{}, err
	}
	stage := filepath.Join(s.root, "handoff-"+id)
	stageDir, err := ensureOwnedDirectory(stage, s.sid, true)
	if err != nil {
		return response{}, err
	}
	defer stageDir.Close()
	childPath := filepath.Join(stage, "exvpn-updater.exe")
	dest, err := secureNewFile(childPath, s.sid)
	if err != nil {
		return response{}, err
	}
	if _, err = source.Seek(0, 0); err != nil {
		dest.Close()
		return response{}, safeError("handoff_failed")
	}
	if _, err = io.Copy(dest, io.LimitReader(source, 64<<20+1)); err != nil {
		dest.Close()
		return response{}, safeError("handoff_failed")
	}
	if err = dest.Sync(); err != nil {
		dest.Close()
		return response{}, safeError("handoff_failed")
	}
	dest.Close()
	lockedCopy, err := secureReadFile(childPath, s.sid, false)
	if err != nil {
		return response{}, err
	}
	defer lockedCopy.Close()
	copyDigest, err := hashFile(lockedCopy)
	if err != nil || copyDigest != digest {
		return response{}, safeError("integrity_failed")
	}
	plan := workerRequest{1, mode, req.Version, req.ParentPID, owner.created, digest}
	if err := spawnWorker(childPath, stage, plan); err != nil {
		return response{}, err
	}
	return result("accepted", m), nil
}

func spawnWorker(exe, directory string, plan workerRequest) error {
	inputR, inputW, err := os.Pipe()
	if err != nil {
		return safeError("handoff_failed")
	}
	defer inputR.Close()
	defer inputW.Close()
	outputR, outputW, err := os.Pipe()
	if err != nil {
		return safeError("handoff_failed")
	}
	defer outputR.Close()
	defer outputW.Close()
	null, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		return safeError("handoff_failed")
	}
	defer null.Close()
	proc, err := os.StartProcess(exe, []string{exe, "--worker-v1"}, &os.ProcAttr{
		Dir: directory, Env: os.Environ(), Files: []*os.File{inputR, outputW, null},
		Sys: &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x00000008 | 0x00000200},
	})
	if err != nil {
		return safeError("handoff_failed")
	}
	defer proc.Release()
	inputR.Close()
	outputW.Close()
	if err := json.NewEncoder(inputW).Encode(plan); err != nil {
		return safeError("handoff_failed")
	}
	type completion struct {
		reply response
		err   error
	}
	done := make(chan completion, 1)
	reader := bufio.NewReader(io.LimitReader(outputR, 8193))
	readReply := func() {
		line, err := reader.ReadBytes('\n')
		var reply response
		if err == nil {
			err = strictJSON(bytes.TrimSpace(line), 4096, &reply)
		}
		done <- completion{reply, err}
	}
	go readReply()
	select {
	case got := <-done:
		if got.err != nil || got.reply.Type != "result" || got.reply.Status != "prepared" {
			return safeError("handoff_failed")
		}
	case <-time.After(55 * time.Second):
		return safeError("handoff_failed")
	}
	// The detached child cannot proceed after a parent timeout/pipe loss unless
	// this explicit commit arrives after signature, hash, and owner validation.
	if err := json.NewEncoder(inputW).Encode(struct {
		Protocol int  `json:"protocol"`
		Commit   bool `json:"commit"`
	}{1, true}); err != nil {
		return safeError("handoff_failed")
	}
	inputW.Close()
	go readReply()
	select {
	case got := <-done:
		if got.err != nil || got.reply.Type != "result" || got.reply.Status != "accepted" {
			return safeError("handoff_failed")
		}
		return nil
	case <-time.After(3 * time.Second):
		return safeError("handoff_failed")
	}
}

// The child lives outside Program Files so its running image cannot prevent the
// installer from replacing the packaged helper. It inherits only its pipes and
// the ordinary user token; elevation is restricted to the verified installer.
func workerMain() {
	if err := ordinaryUser(); err != nil {
		_ = emit(os.Stdout, errorResponse(err))
		return
	}
	reader := bufio.NewReader(io.LimitReader(os.Stdin, maxPayload+128))
	raw, err := reader.ReadBytes('\n')
	var plan workerRequest
	if err != nil || strictJSON(raw, maxPayload, &plan) != nil || plan.Protocol != 1 || plan.ParentPID < 1 || plan.ParentCreated == 0 ||
		(plan.Mode != "install" && plan.Mode != "restart") || (plan.Mode == "install" && !validIdentity(plan.Version)) ||
		(plan.Mode == "restart" && plan.Version != "") || len(plan.HelperSHA256) != 64 {
		_ = emit(os.Stdout, errorResponse(safeError("invalid_request")))
		return
	}
	commit := func() error {
		done := make(chan error, 1)
		go func() {
			line, err := reader.ReadBytes('\n')
			var ack struct {
				Protocol int  `json:"protocol"`
				Commit   bool `json:"commit"`
			}
			if err == nil {
				err = strictJSON(line, 128, &ack)
			}
			if err != nil || ack.Protocol != 1 || !ack.Commit {
				done <- safeError("handoff_failed")
			} else {
				done <- nil
			}
		}()
		select {
		case err := <-done:
			return err
		case <-time.After(10 * time.Second):
			return safeError("handoff_failed")
		}
	}
	if err := runWorker(plan, commit); err != nil {
		_ = emit(os.Stdout, errorResponse(err))
	}
}

func runWorker(plan workerRequest, commit func() error) error {
	s, err := openStore(false)
	if err != nil {
		return err
	}
	defer s.close()
	lease, err := namedLease(`Global\ExVPN.UpdateHandoff.v1.`+s.sid, s.sid)
	if err != nil {
		return err
	}
	defer lease()
	self, err := os.Executable()
	if err != nil {
		return safeError("handoff_failed")
	}
	stage := filepath.Dir(self)
	stageName := filepath.Base(stage)
	if !strings.EqualFold(filepath.Dir(stage), s.root) || !strings.HasPrefix(stageName, "handoff-") || len(stageName) != 39 || filepath.Base(self) != "exvpn-updater.exe" {
		return safeError("handoff_failed")
	}
	if _, err := hex.DecodeString(strings.TrimPrefix(stageName, "handoff-")); err != nil {
		return safeError("handoff_failed")
	}
	stageHeld, err := lockPath(stage, true)
	if err != nil {
		return err
	}
	defer stageHeld.Close()
	if err = verifyFileSecurity(stageHeld, s.sid, false, true); err != nil {
		return err
	}
	selfFile, err := secureReadFile(self, s.sid, false)
	if err != nil {
		return err
	}
	defer selfFile.Close()
	selfHash, err := hashFile(selfFile)
	if err != nil || selfHash != plan.HelperSHA256 {
		return safeError("integrity_failed")
	}
	ui, helper, installedHeld, err := validateInstalledTree()
	if err != nil {
		return err
	}
	// Drop every handle in Program Files before accepting. Retaining those
	// handles would make a legitimate NSIS replacement fail sharing checks.
	source, err := secureReadFile(helper, "", true)
	if err != nil {
		closeFiles(installedHeld)
		return safeError("installed_app_required")
	}
	sourceHash, hashErr := hashFile(source)
	source.Close()
	closeFiles(installedHeld)
	if hashErr != nil || sourceHash != selfHash {
		return safeError("integrity_failed")
	}
	owner, err := validateOwner(plan.ParentPID, plan.ParentCreated, s.sid, ui)
	if err != nil {
		return err
	}
	defer owner.close()
	var m manifest
	var installer *os.File
	if plan.Mode == "install" {
		cfg, err := pinnedConfig()
		if err != nil {
			return err
		}
		m, installer, err = s.ready(cfg, plan.Version, time.Now().UTC())
		if err != nil {
			return err
		}
		defer installer.Close()
	}
	if err := emit(os.Stdout, result("prepared", m)); err != nil {
		return safeError("handoff_failed")
	}
	if err := commit(); err != nil {
		return err
	}
	if err := emit(os.Stdout, result("accepted", m)); err != nil {
		return safeError("handoff_failed")
	}
	// Do not emit after this point: stdout is only the authenticated startup
	// handshake. A caller must exit its UI gracefully after receiving accepted.
	os.Stdout.Close()
	os.Stdin.Close()
	w, err := syscall.WaitForSingleObject(owner.handle, 120000)
	if err != nil || w != 0 {
		return nil
	}
	owner.close()
	if waitForWriter(s.sid, 60000) != nil {
		return nil
	}
	status := "restarted"
	if installer != nil {
		// This exact read handle denies all writes/deletes before hashing and
		// remains held through UAC and the installer's complete process lifetime.
		exit, installErr := runInstaller(s.readyPath(m), s.sid)
		status = "installed"
		if installErr != nil || exit != 0 {
			status = "installer_failed"
		}
	}
	// Also restart after a cancelled elevation or failed install. NSIS owns
	// rollback; this process never stops services, removes WFP, or disconnects.
	receipt, _ := json.Marshal(installReceipt{1, status, plan.Version})
	// Commit before starting the UI, so its automatic initial check cannot race
	// ahead and miss a cancelled UAC or failed installer result.
	_ = s.writeAtomic(filepath.Join(s.root, "last-result.json"), receipt)
	if err := launchUI(ui); err != nil {
		receipt, _ = json.Marshal(installReceipt{1, "launch_failed", plan.Version})
		_ = s.writeAtomic(filepath.Join(s.root, "last-result.json"), receipt)
	}
	return nil
}

func waitForWriter(sid string, timeout uint32) error {
	sa, free, err := securityAttributes(sid, false)
	if err != nil {
		return err
	}
	defer free()
	name, _ := syscall.UTF16PtrFromString(`Global\ExVPN.UI.v1.` + sid)
	h, _, _ := createMutex.Call(uintptr(unsafe.Pointer(sa)), 0, uintptr(unsafe.Pointer(name)))
	if h == 0 {
		return safeError("permission_denied")
	}
	defer syscall.CloseHandle(syscall.Handle(h))
	if err := verifyHandleSecurity(h, 6, sid, false, false); err != nil {
		return err
	}
	w, err := syscall.WaitForSingleObject(syscall.Handle(h), timeout)
	if err != nil || (w != 0 && w != waitAbandoned) {
		return safeError("operation_busy")
	}
	releaseMutex.Call(h)
	return nil
}

type shellExecuteInfo struct {
	Size, Mask                        uint32
	Window                            uintptr
	Verb, File, Parameters, Directory *uint16
	Show                              int32
	Instance                          uintptr
	IDList                            uintptr
	Class                             *uint16
	ClassKey                          uintptr
	HotKey                            uint32
	Icon                              uintptr
	Process                           syscall.Handle
}

func runInstaller(path, sid string) (uint32, error) {
	// runWorker already holds a thread-affine mutex. COM must use this same
	// STA thread for the complete ShellExecuteEx call.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	hr, _, _ := ole.NewProc("CoInitializeEx").Call(0, 0x2|0x4)
	if int32(hr) < 0 {
		return 0, safeError("handoff_failed")
	}
	defer ole.NewProc("CoUninitialize").Call()
	verb, _ := syscall.UTF16PtrFromString("runas")
	exe, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return 0, safeError("handoff_failed")
	}
	args, _ := syscall.UTF16PtrFromString("/S /APP_UPDATE=1 /OWNER_SID=" + sid)
	dir, _ := syscall.UTF16PtrFromString(filepath.Dir(path))
	info := shellExecuteInfo{Mask: 0x40 | 0x100 | 0x400, Verb: verb, File: exe, Parameters: args, Directory: dir, Show: 1}
	info.Size = uint32(unsafe.Sizeof(info))
	ok, _, _ := shell.NewProc("ShellExecuteExW").Call(uintptr(unsafe.Pointer(&info)))
	if ok == 0 || info.Process == 0 {
		return 0, safeError("handoff_failed")
	}
	defer syscall.CloseHandle(info.Process)
	if w, err := syscall.WaitForSingleObject(info.Process, 0xFFFFFFFF); err != nil || w != 0 {
		return 0, safeError("handoff_failed")
	}
	var exit uint32
	if syscall.GetExitCodeProcess(info.Process, &exit) != nil {
		return 0, safeError("handoff_failed")
	}
	return exit, nil
}

func launchUI(ui string) error {
	if err := ordinaryUser(); err != nil {
		return err
	}
	checked, _, held, err := validateInstalledTree()
	if err != nil {
		return err
	}
	defer closeFiles(held)
	if !strings.EqualFold(checked, ui) {
		return safeError("installed_app_required")
	}
	null, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		return safeError("handoff_failed")
	}
	defer null.Close()
	p, err := os.StartProcess(ui, []string{ui}, &os.ProcAttr{Dir: filepath.Dir(ui), Env: os.Environ(), Files: []*os.File{null, null, null}, Sys: &syscall.SysProcAttr{HideWindow: false, CreationFlags: 0x00000008 | 0x00000200}})
	if err != nil {
		return safeError("handoff_failed")
	}
	p.Release()
	return nil
}
