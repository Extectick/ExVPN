//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
// Disposable-guest QA launcher. Never included in an ExVPN install package.
package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const inputRoot = `C:\ExVPN-App-QA`
const outputRoot = `C:\ExVPN-App-QA-Results`
const qaRoot = `C:\Program Files\ExVPN UI QA`
const controlRoot = `C:\Program Files\ExVPN UI QA Control`

var stage = "guest-validation"
var runID string

type tokenFacts struct {
	Administrator   bool   `json:"administratorToken"`
	Elevated        bool   `json:"elevated"`
	Medium          bool   `json:"mediumIntegrity"`
	NoAdminPrivs    bool   `json:"adminPrivilegesAbsent"`
	SameUser        bool   `json:"sameInstallerOwner"`
	Integrity       string `json:"integritySid"`
	Interactive     bool   `json:"interactiveGroupEnabled"`
	RestrictingSIDs uint32 `json:"restrictingSidCount"`
}

func read32(token windows.Token, class uint32) (uint32, error) {
	var value, size uint32
	err := windows.GetTokenInformation(token, class, (*byte)(unsafe.Pointer(&value)), 4, &size)
	if err == nil && size != 4 {
		err = errors.New("unexpected token information size")
	}
	return value, err
}

func readVariable(token windows.Token, class uint32) ([]byte, error) {
	var size uint32
	err := windows.GetTokenInformation(token, class, nil, 0, &size)
	if err != windows.ERROR_INSUFFICIENT_BUFFER || size < 4 || size > 65536 {
		return nil, errors.New("invalid token information size")
	}
	data := make([]byte, size)
	err = windows.GetTokenInformation(token, class, &data[0], size, &size)
	return data, err
}

func inspect(token windows.Token, owner string) (tokenFacts, error) {
	var result tokenFacts
	user, err := token.GetTokenUser()
	if err != nil {
		return result, err
	}
	result.SameUser = user.User.Sid.String() == owner
	groups, err := token.GetTokenGroups()
	if err != nil {
		return result, err
	}
	for _, group := range groups.AllGroups() {
		if group.Sid.String() == "S-1-5-4" && group.Attributes&windows.SE_GROUP_ENABLED != 0 {
			result.Interactive = true
		}
		if group.Sid.String() == "S-1-5-32-544" && group.Attributes&windows.SE_GROUP_ENABLED != 0 && group.Attributes&windows.SE_GROUP_USE_FOR_DENY_ONLY == 0 {
			result.Administrator = true
		}
	}
	elevated, err := read32(token, windows.TokenElevation)
	if err != nil {
		return result, err
	}
	result.Elevated = elevated != 0
	restricting, err := readVariable(token, windows.TokenRestrictedSids)
	if err != nil {
		return result, err
	}
	result.RestrictingSIDs = binary.LittleEndian.Uint32(restricting)
	label, err := readVariable(token, windows.TokenIntegrityLevel)
	if err != nil {
		return result, err
	}
	result.Integrity = (*windows.Tokenmandatorylabel)(unsafe.Pointer(&label[0])).Label.Sid.String()
	runtime.KeepAlive(label)
	result.Medium = result.Integrity == "S-1-16-8192"
	privileges, err := readVariable(token, windows.TokenPrivileges)
	if err != nil {
		return result, err
	}
	var notify windows.LUID
	if err = windows.LookupPrivilegeValue(nil, windows.StringToUTF16Ptr("SeChangeNotifyPrivilege"), &notify); err != nil {
		return result, err
	}
	result.NoAdminPrivs = true
	for _, privilege := range (*windows.Tokenprivileges)(unsafe.Pointer(&privileges[0])).AllPrivileges() {
		// A disabled privilege may be reenabled by the process; require deletion.
		if privilege.Luid != notify && privilege.Attributes&windows.SE_PRIVILEGE_REMOVED == 0 {
			result.NoAdminPrivs = false
		}
	}
	runtime.KeepAlive(privileges)
	return result, nil
}

func (f tokenFacts) limited() bool {
	return !f.Administrator && !f.Elevated && f.Medium && f.NoAdminPrivs && f.SameUser && f.RestrictingSIDs == 0
}

func reducedToken(source windows.Token) (windows.Token, error) {
	admin, err := windows.StringToSid("S-1-5-32-544")
	if err != nil {
		return 0, err
	}
	disabled := windows.SIDAndAttributes{Sid: admin}
	var target windows.Token
	create := windows.NewLazySystemDLL("advapi32.dll").NewProc("CreateRestrictedToken")
	// DISABLE_MAX_PRIVILEGE | LUA_TOKEN; never SANDBOX_INERT.
	ok, _, callErr := create.Call(uintptr(source), 5, 1, uintptr(unsafe.Pointer(&disabled)), 0, 0, 0, 0, uintptr(unsafe.Pointer(&target)))
	runtime.KeepAlive(admin)
	if ok == 0 {
		return 0, callErr
	}
	medium, err := windows.StringToSid("S-1-16-8192")
	if err == nil {
		label := windows.Tokenmandatorylabel{Label: windows.SIDAndAttributes{Sid: medium, Attributes: windows.SE_GROUP_INTEGRITY}}
		err = windows.SetTokenInformation(target, windows.TokenIntegrityLevel, (*byte)(unsafe.Pointer(&label)), label.Size())
		runtime.KeepAlive(medium)
	}
	if err != nil {
		target.Close()
		return 0, err
	}
	return target, nil
}

// These request access handles but never write registry/file/service data.
// Access-denied is required; another error is not proof of restricted rights.
func negativeAccess(token windows.Token, owner string) (err error) {
	stage = "impersonate-limited-token"
	var impersonation windows.Token
	if err = windows.DuplicateTokenEx(token, windows.TOKEN_QUERY|windows.TOKEN_IMPERSONATE, nil, windows.SecurityImpersonation, windows.TokenImpersonation, &impersonation); err != nil {
		return err
	}
	defer impersonation.Close()
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if err = windows.SetThreadToken(nil, impersonation); err != nil {
		return err
	}
	defer func() {
		if e := windows.RevertToSelf(); e != nil {
			os.Exit(3)
		}
	}()
	manager, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_CONNECT)
	if err != nil {
		return err
	}
	defer windows.CloseServiceHandle(manager)
	stage = "query-service-as-user"
	readService, err := windows.OpenService(manager, windows.StringToUTF16Ptr("ExVPNService"), windows.SERVICE_QUERY_STATUS|windows.SERVICE_QUERY_CONFIG)
	if err != nil {
		return err
	}
	var status windows.SERVICE_STATUS_PROCESS
	var needed uint32
	err = windows.QueryServiceStatusEx(readService, windows.SC_STATUS_PROCESS_INFO, (*byte)(unsafe.Pointer(&status)), uint32(unsafe.Sizeof(status)), &needed)
	windows.CloseServiceHandle(readService)
	if err != nil {
		return err
	}
	stage = "query-service-process-as-user"
	readProcess, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, status.ProcessId)
	if err != nil {
		return err
	}
	windows.CloseHandle(readProcess)
	stage = "deny-process-control"
	for _, access := range []uint32{windows.PROCESS_TERMINATE, windows.PROCESS_VM_READ, windows.PROCESS_VM_WRITE, windows.PROCESS_DUP_HANDLE, windows.PROCESS_CREATE_THREAD, windows.PROCESS_SET_INFORMATION, windows.PROCESS_QUERY_INFORMATION, windows.WRITE_DAC, windows.WRITE_OWNER} {
		handle, denied := windows.OpenProcess(access, false, status.ProcessId)
		if denied == nil {
			windows.CloseHandle(handle)
		}
		if denied != windows.ERROR_ACCESS_DENIED {
			return errors.New("privileged process access was not denied")
		}
	}
	stage = "open-user-ipc"
	pipe, err := windows.CreateFile(windows.StringToUTF16Ptr(`\\.\pipe\ExVPN.Control.v1`), 0x12019b, 0, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OVERLAPPED|windows.SECURITY_SQOS_PRESENT|windows.SECURITY_IDENTIFICATION, 0)
	if err != nil {
		return err
	}
	windows.CloseHandle(pipe)
	stage = "deny-service-config"
	service, denied := windows.OpenService(manager, windows.StringToUTF16Ptr("ExVPNService"), windows.SERVICE_CHANGE_CONFIG)
	if denied == nil {
		windows.CloseServiceHandle(service)
	}
	if denied != windows.ERROR_ACCESS_DENIED {
		return errors.New("service config access was not denied")
	}
	stage = "deny-policy-write"
	key, denied := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\ExVPN.ServicePolicy.v1\`+owner, registry.SET_VALUE|registry.WOW64_64KEY)
	if denied == nil {
		key.Close()
	}
	if denied != windows.ERROR_ACCESS_DENIED {
		return errors.New("policy write access was not denied")
	}
	stage = "deny-protected-file-write"
	file, denied := windows.CreateFile(windows.StringToUTF16Ptr(controlRoot+`\state.json`), windows.GENERIC_WRITE, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE, nil, windows.OPEN_EXISTING, 0, 0)
	if denied == nil {
		windows.CloseHandle(file)
	}
	if denied != windows.ERROR_ACCESS_DENIED {
		return errors.New("protected file write access was not denied")
	}
	return nil
}

func save(name string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(outputRoot, name), data, 0600)
}

func run() (uint32, error) {
	probeOnly := len(os.Args) == 2 && os.Args[1] == "--probe"
	if len(os.Args) != 1 && !probeOnly {
		return 2, errors.New("arguments refused")
	}
	exe, err := os.Executable()
	if err != nil || !strings.EqualFold(exe, inputRoot+`\qa-desktop.exe`) {
		return 2, errors.New("guest path required")
	}
	var marker struct {
		Format        int
		ForbiddenHost string
		RunID         string
		Unelevated    bool
	}
	stage = "read-marker"
	data, err := os.ReadFile(inputRoot + `\sandbox-bundle.json`)
	if err != nil || len(data) > 131072 || json.Unmarshal(bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf}), &marker) != nil {
		return 2, errors.New("guest marker required")
	}
	host, err := os.Hostname()
	if err != nil || marker.Format != 1 || marker.ForbiddenHost == "" || strings.EqualFold(host, marker.ForbiddenHost) || !marker.Unelevated || !regexp.MustCompile(`^[a-f0-9-]{36}$`).MatchString(marker.RunID) {
		return 2, errors.New("guest isolation required")
	}
	runID = marker.RunID
	var state struct{ OwnerSID string }
	stage = "read-installer-owner"
	data, err = os.ReadFile(controlRoot + `\state.json`)
	if err != nil || len(data) > 131072 || json.Unmarshal(bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf}), &state) != nil || !regexp.MustCompile(`^S-1-5-21-\d+-\d+-\d+-\d+$`).MatchString(state.OwnerSID) {
		return 2, errors.New("installer owner required")
	}
	var source windows.Token
	stage = "open-source-token"
	if err = windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_QUERY|windows.TOKEN_DUPLICATE|windows.TOKEN_ASSIGN_PRIMARY|windows.TOKEN_ADJUST_DEFAULT, &source); err != nil {
		return 2, err
	}
	defer source.Close()
	user, err := source.GetTokenUser()
	if err != nil || user.User.Sid.String() != state.OwnerSID {
		return 2, errors.New("desktop identity differs")
	}
	stage = "reduce-token"
	target, err := reducedToken(source)
	if err != nil {
		return 2, err
	}
	defer target.Close()
	stage = "inspect-reduced-token"
	facts, err := inspect(target, state.OwnerSID)
	_ = save("desktop-token.json", facts)
	if err != nil || !facts.limited() {
		return 2, errors.New("token reduction not confirmed")
	}
	if err = negativeAccess(target, state.OwnerSID); err != nil {
		return 2, err
	}
	if probeOnly {
		return 0, save("desktop-access-report.json", map[string]any{"runId": runID, "accessPassed": true, "probeOnly": true, "token": facts})
	}
	startup := windows.StartupInfo{Cb: uint32(unsafe.Sizeof(windows.StartupInfo{})), Desktop: windows.StringToUTF16Ptr(`winsta0\default`), Flags: windows.STARTF_USESHOWWINDOW, ShowWindow: windows.SW_SHOWNORMAL}
	var process windows.ProcessInformation
	stage = "create-suspended-ui"
	if err = windows.CreateProcessAsUser(target, windows.StringToUTF16Ptr(qaRoot+`\exvpn.exe`), windows.StringToUTF16Ptr(`"`+qaRoot+`\exvpn.exe"`), nil, nil, false, windows.CREATE_SUSPENDED|windows.CREATE_UNICODE_ENVIRONMENT, nil, windows.StringToUTF16Ptr(qaRoot), &startup, &process); err != nil {
		return 2, err
	}
	defer windows.CloseHandle(process.Process)
	defer windows.CloseHandle(process.Thread)
	finished := false
	defer func() {
		if !finished {
			windows.TerminateProcess(process.Process, 2)
			windows.WaitForSingleObject(process.Process, 10000)
		}
	}()
	var child windows.Token
	stage = "inspect-actual-ui-token"
	if err = windows.OpenProcessToken(process.Process, windows.TOKEN_QUERY, &child); err != nil {
		return 2, err
	}
	facts, err = inspect(child, state.OwnerSID)
	child.Close()
	if err != nil || !facts.limited() {
		return 2, errors.New("actual child token differs")
	}
	report := struct {
		tokenFacts
		RunID        string `json:"runId"`
		Desktop      bool   `json:"desktopUser"`
		Method       string `json:"tokenMethod"`
		Verified     bool   `json:"processTokenVerified"`
		AccessDenied bool   `json:"privilegedAccessDenied"`
	}{facts, marker.RunID, true, "restricted-medium-same-user", true, true}
	if err = save("launch-report.json", report); err != nil {
		return 2, err
	}
	stage = "run-ui"
	if _, err = windows.ResumeThread(process.Thread); err != nil {
		return 2, err
	}
	wait, err := windows.WaitForSingleObject(process.Process, 20*60*1000)
	if err != nil || wait != windows.WAIT_OBJECT_0 {
		return 2, errors.New("bounded UI deadline expired")
	}
	finished = true
	var code uint32
	err = windows.GetExitCodeProcess(process.Process, &code)
	return code, err
}

func main() {
	code, err := run()
	if err != nil {
		// Stable categories only; no raw Windows paths, usernames or command data.
		var code syscall.Errno
		_ = errors.As(err, &code)
		_ = save("desktop-launch-error.json", map[string]any{"failed": true, "runId": runID, "code": "limited_desktop_launch_failed", "stage": stage, "win32Code": uint32(code)})
		os.Exit(2)
	}
	os.Exit(int(code))
}
