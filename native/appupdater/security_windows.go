// SPDX-License-Identifier: Apache-2.0
//go:build windows

package main

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"syscall"
	"unsafe"
)

var (
	kernel          = syscall.NewLazyDLL("kernel32.dll")
	advapi          = syscall.NewLazyDLL("advapi32.dll")
	shell           = syscall.NewLazyDLL("shell32.dll")
	ole             = syscall.NewLazyDLL("ole32.dll")
	getFinalPath    = kernel.NewProc("GetFinalPathNameByHandleW")
	getSecurityInfo = advapi.NewProc("GetSecurityInfo")
	getSDControl    = advapi.NewProc("GetSecurityDescriptorControl")
	getACE          = advapi.NewProc("GetAce")
	convertSDDL     = advapi.NewProc("ConvertStringSecurityDescriptorToSecurityDescriptorW")
	knownFolder     = shell.NewProc("SHGetKnownFolderPath")
	createMutex     = kernel.NewProc("CreateMutexW")
	releaseMutex    = kernel.NewProc("ReleaseMutex")
)

const (
	readControl         = 0x20000
	openReparsePoint    = 0x00200000
	backupSemantics     = 0x02000000
	fileReparse         = 0x400
	fileDirectory       = 0x10
	synchronize         = 0x00100000
	processQueryLimited = 0x1000
	waitAbandoned       = 0x80
	waitTimeout         = 0x102
)

func currentSID() (string, error) {
	t, err := syscall.OpenCurrentProcessToken()
	if err != nil {
		return "", safeError("permission_denied")
	}
	defer t.Close()
	u, err := t.GetTokenUser()
	if err != nil {
		return "", safeError("permission_denied")
	}
	s, err := u.User.Sid.String()
	if err != nil {
		return "", safeError("permission_denied")
	}
	if !strings.HasPrefix(s, "S-1-") || len(s) > 100 || s == "S-1-5-18" || s == "S-1-5-19" || s == "S-1-5-20" {
		return "", safeError("permission_denied")
	}
	return s, nil
}

func ordinaryToken(t syscall.Token) error {
	var elevated uint32
	var length uint32
	if err := syscall.GetTokenInformation(t, syscall.TokenElevation, (*byte)(unsafe.Pointer(&elevated)), 4, &length); err != nil || elevated != 0 {
		return safeError("permission_denied")
	}
	buf := make([]byte, 256)
	if err := syscall.GetTokenInformation(t, syscall.TokenIntegrityLevel, &buf[0], uint32(len(buf)), &length); err != nil {
		return safeError("permission_denied")
	}
	label := (*syscall.SIDAndAttributes)(unsafe.Pointer(&buf[0]))
	s, err := label.Sid.String()
	if err != nil || (s != "S-1-16-8192" && s != "S-1-16-8448") {
		return safeError("permission_denied")
	}
	return nil
}

func ordinaryUser() error {
	if runtime.GOARCH != "amd64" {
		return safeError("unsupported_platform")
	}
	t, err := syscall.OpenCurrentProcessToken()
	if err != nil {
		return safeError("permission_denied")
	}
	defer t.Close()
	return ordinaryToken(t)
}

type folderID struct {
	D1     uint32
	D2, D3 uint16
	D4     [8]byte
}

var localAppDataID = folderID{0xF1B32785, 0x6FBA, 0x4FCF, [8]byte{0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91}}
var programFilesID = folderID{0x905E63B6, 0xC1BF, 0x494E, [8]byte{0xB2, 0x9C, 0x65, 0xB7, 0x32, 0xD3, 0xD2, 0x1A}}

func knownPath(id *folderID) (string, error) {
	var result *uint16
	hr, _, _ := knownFolder.Call(uintptr(unsafe.Pointer(id)), 0, 0, uintptr(unsafe.Pointer(&result)))
	if int32(hr) < 0 || result == nil {
		return "", safeError("cache_unavailable")
	}
	defer ole.NewProc("CoTaskMemFree").Call(uintptr(unsafe.Pointer(result)))
	buf := unsafe.Slice(result, 32768)
	var n int
	for n < len(buf) && buf[n] != 0 {
		n++
	}
	if n == 0 || n == len(buf) {
		return "", safeError("cache_unavailable")
	}
	p := filepath.Clean(syscall.UTF16ToString(buf[:n]))
	if !localAbsolute(p) {
		return "", safeError("cache_unavailable")
	}
	volume, _ := syscall.UTF16PtrFromString(filepath.VolumeName(p) + `\`)
	driveType, _, _ := kernel.NewProc("GetDriveTypeW").Call(uintptr(unsafe.Pointer(volume)))
	if driveType != 3 {
		return "", safeError("cache_unavailable")
	}
	return p, nil
}

func localAbsolute(p string) bool {
	v := filepath.VolumeName(p)
	return filepath.IsAbs(p) && len(v) == 2 && v[1] == ':' && !strings.Contains(p[2:], ":") && !strings.Contains(p, "\x00") && filepath.Clean(p) == p
}

func pathFromHandle(handle syscall.Handle) (string, error) {
	buf := make([]uint16, 32768)
	n, _, _ := getFinalPath.Call(uintptr(handle), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), 0)
	if n == 0 || n >= uintptr(len(buf)) {
		return "", safeError("cache_unavailable")
	}
	actual := strings.TrimPrefix(syscall.UTF16ToString(buf[:n]), `\\?\`)
	if !localAbsolute(actual) {
		return "", safeError("cache_unavailable")
	}
	return actual, nil
}

func finalPath(handle syscall.Handle, expected string) error {
	actual, err := pathFromHandle(handle)
	if err != nil {
		return err
	}
	if !strings.EqualFold(filepath.Clean(actual), filepath.Clean(expected)) {
		return safeError("cache_unavailable")
	}
	return nil
}

func lockPath(path string, directory bool) (*os.File, error) {
	f, err := openPathObject(path, directory)
	if err != nil {
		return nil, err
	}
	if err = finalPath(syscall.Handle(f.Fd()), path); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}

// Opening an object and validating its physical path are separate only for the
// fixed AppData bootstrap below, where MSIX can redirect a non-reparse directory.
// All ordinary file/directory callers must use lockPath, which also demands an
// exact physical path match.
func openPathObject(path string, directory bool) (*os.File, error) {
	if !localAbsolute(path) {
		return nil, safeError("cache_unavailable")
	}
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return nil, safeError("cache_unavailable")
	}
	access, share, flags := uint32(syscall.GENERIC_READ|readControl), uint32(syscall.FILE_SHARE_READ), uint32(openReparsePoint)
	if directory {
		// Metadata-only opens do not participate in Windows sharing checks.
		// FILE_LIST_DIRECTORY (GENERIC_READ) is necessary to deny rename/delete
		// of an ancestor while the verified child path is being used.
		access = syscall.GENERIC_READ | readControl
		share |= syscall.FILE_SHARE_WRITE
		flags |= backupSemantics
	}
	h, err := syscall.CreateFile(p, access, share, nil, syscall.OPEN_EXISTING, flags, 0)
	if err != nil {
		return nil, safeError("cache_unavailable")
	}
	f := os.NewFile(uintptr(h), path)
	var info syscall.ByHandleFileInformation
	if err = syscall.GetFileInformationByHandle(h, &info); err != nil || info.FileAttributes&fileReparse != 0 ||
		(info.FileAttributes&fileDirectory != 0) != directory || (!directory && info.NumberOfLinks != 1) {
		f.Close()
		return nil, safeError("cache_unavailable")
	}
	return f, nil
}

var packageFamilyName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9.-]{0,49}_[A-Za-z0-9]{13}$`)

func currentPackageFamily() (string, error) {
	proc := kernel.NewProc("GetCurrentPackageFamilyName")
	var length uint32
	status, _, _ := proc.Call(uintptr(unsafe.Pointer(&length)), 0)
	if status == 15700 {
		return "", nil
	} // APPMODEL_ERROR_NO_PACKAGE.
	if status != 122 || length < 2 || length > 256 {
		return "", safeError("cache_unavailable")
	}
	buf := make([]uint16, length)
	status, _, _ = proc.Call(uintptr(unsafe.Pointer(&length)), uintptr(unsafe.Pointer(&buf[0])))
	if status != 0 {
		return "", safeError("cache_unavailable")
	}
	family := syscall.UTF16ToString(buf)
	if !packageFamilyName.MatchString(family) {
		return "", safeError("cache_unavailable")
	}
	return family, nil
}

func allowedAppDataRedirection(local, actual, family string) bool {
	if !localAbsolute(local) || !localAbsolute(actual) {
		return false
	}
	rel, err := filepath.Rel(local, actual)
	if err != nil {
		return false
	}
	parts := strings.Split(rel, `\`)
	return len(parts) == 5 && strings.EqualFold(parts[0], "Packages") && packageFamilyName.MatchString(parts[1]) && (family == "" || strings.EqualFold(parts[1], family)) &&
		strings.EqualFold(parts[2], "LocalCache") && strings.EqualFold(parts[3], "Local") && strings.EqualFold(parts[4], "ExVPN")
}

// Windows can inherit MSIX filesystem virtualization from a packaged launcher
// while KnownFolder still returns the ordinary LocalAppData path. Only this
// fixed product directory may bootstrap to the OS's private package cache. No
// reparse point, arbitrary alias, different user root, or caller path is allowed.
func openProductDirectory(local, sid string) (string, []*os.File, error) {
	logical := filepath.Join(local, "ExVPN")
	sa, free, err := securityAttributes(sid, true)
	if err != nil {
		return "", nil, err
	}
	defer free()
	p, _ := syscall.UTF16PtrFromString(logical)
	if err = syscall.CreateDirectory(p, sa); err != nil && err != syscall.ERROR_ALREADY_EXISTS {
		return "", nil, safeError("cache_unavailable")
	}
	f, err := openPathObject(logical, true)
	if err != nil {
		return "", nil, err
	}
	held := []*os.File{f}
	fail := func(err error) (string, []*os.File, error) { closeFiles(held); return "", nil, err }
	if err = verifyFileSecurity(f, sid, false, false); err != nil {
		return fail(err)
	}
	actual, err := pathFromHandle(syscall.Handle(f.Fd()))
	if err != nil {
		return fail(err)
	}
	if strings.EqualFold(actual, logical) {
		return logical, held, nil
	}
	family, err := currentPackageFamily()
	if err != nil {
		return fail(err)
	}
	if !allowedAppDataRedirection(local, actual, family) {
		return fail(safeError("cache_unavailable"))
	}
	physical, err := lockAncestors(actual)
	if err != nil {
		return fail(err)
	}
	held = append(held, physical...)
	var sourceInfo, targetInfo syscall.ByHandleFileInformation
	if syscall.GetFileInformationByHandle(syscall.Handle(f.Fd()), &sourceInfo) != nil ||
		syscall.GetFileInformationByHandle(syscall.Handle(physical[len(physical)-1].Fd()), &targetInfo) != nil ||
		sourceInfo.VolumeSerialNumber != targetInfo.VolumeSerialNumber || sourceInfo.FileIndexHigh != targetInfo.FileIndexHigh || sourceInfo.FileIndexLow != targetInfo.FileIndexLow {
		return fail(safeError("cache_unavailable"))
	}
	return actual, held, nil
}

// Keep each ancestor open without FILE_SHARE_DELETE. Reparse components and
// parent-directory swaps cannot redirect later opens or the eventual installer.
func lockAncestors(path string) ([]*os.File, error) {
	if !localAbsolute(path) {
		return nil, safeError("cache_unavailable")
	}
	volume := filepath.VolumeName(path)
	current := volume + `\`
	var held []*os.File
	fail := func() ([]*os.File, error) {
		for _, f := range held {
			f.Close()
		}
		return nil, safeError("cache_unavailable")
	}
	f, err := lockPath(current, true)
	if err != nil {
		return fail()
	}
	held = append(held, f)
	for _, part := range strings.Split(strings.TrimPrefix(path, current), `\`) {
		if part == "" || part == "." || part == ".." || strings.TrimRight(part, ". ") != part {
			return fail()
		}
		current = filepath.Join(current, part)
		f, err = lockPath(current, true)
		if err != nil {
			return fail()
		}
		held = append(held, f)
	}
	return held, nil
}

func securityAttributes(sid string, inheritable bool) (*syscall.SecurityAttributes, func(), error) {
	flags := ""
	if inheritable {
		flags = "OICI"
	}
	sddl := "O:" + sid + "G:" + sid + "D:P(A;" + flags + ";FA;;;SY)(A;" + flags + ";FA;;;BA)(A;" + flags + ";FA;;;" + sid + ")"
	p, err := syscall.UTF16PtrFromString(sddl)
	if err != nil {
		return nil, nil, safeError("cache_unavailable")
	}
	var sd uintptr
	ok, _, _ := convertSDDL.Call(uintptr(unsafe.Pointer(p)), 1, uintptr(unsafe.Pointer(&sd)), 0)
	if ok == 0 {
		return nil, nil, safeError("cache_unavailable")
	}
	sa := &syscall.SecurityAttributes{Length: uint32(unsafe.Sizeof(syscall.SecurityAttributes{})), SecurityDescriptor: sd}
	return sa, func() { syscall.LocalFree(syscall.Handle(sd)) }, nil
}

type aclHeader struct {
	Revision, Reserved     byte
	Size, Count, Reserved2 uint16
}
type aceHeader struct {
	Type, Flags byte
	Size        uint16
}

// Cache roots/files require an owner-only protected DACL. Installed files may
// grant read/execute to Users, but only SYSTEM/Administrators may write them.
func verifyFileSecurity(f *os.File, sid string, installed, strict bool) error {
	return verifyHandleSecurity(f.Fd(), 1, sid, installed, strict)
}

func verifyHandleSecurity(handle uintptr, objectType uint32, sid string, installed, strict bool) error {
	var owner *syscall.SID
	var dacl *aclHeader
	var sd uintptr
	status, _, _ := getSecurityInfo.Call(handle, uintptr(objectType), 1|4, uintptr(unsafe.Pointer(&owner)), 0, uintptr(unsafe.Pointer(&dacl)), 0, uintptr(unsafe.Pointer(&sd)))
	if status != 0 || sd == 0 || owner == nil || dacl == nil {
		return safeError("permission_denied")
	}
	defer syscall.LocalFree(syscall.Handle(sd))
	ownerText, err := owner.String()
	if err != nil {
		return safeError("permission_denied")
	}
	if installed {
		if ownerText != "S-1-5-18" && ownerText != "S-1-5-32-544" {
			return safeError("permission_denied")
		}
	} else if ownerText != sid {
		return safeError("permission_denied")
	}
	var control uint16
	var revision uint32
	ok, _, _ := getSDControl.Call(sd, uintptr(unsafe.Pointer(&control)), uintptr(unsafe.Pointer(&revision)))
	if ok == 0 || (strict && control&0x1000 == 0) || dacl.Count == 0 || dacl.Count > 64 {
		return safeError("permission_denied")
	}
	seen := map[string]bool{}
	fullAccess := uint32(0x1F01FF)
	if objectType == 6 {
		fullAccess = 0x1F0001
	}
	for i := uint16(0); i < dacl.Count; i++ {
		var ace unsafe.Pointer
		ok, _, _ := getACE.Call(uintptr(unsafe.Pointer(dacl)), uintptr(i), uintptr(unsafe.Pointer(&ace)))
		if ok == 0 || ace == nil {
			return safeError("permission_denied")
		}
		h := (*aceHeader)(ace)
		if h.Size < 16 || (h.Type != 0 && h.Type != 1) {
			return safeError("permission_denied")
		}
		if h.Type == 1 {
			if strict {
				return safeError("permission_denied")
			}
			continue
		}
		mask := *(*uint32)(unsafe.Add(ace, 4))
		aceSID, err := (*syscall.SID)(unsafe.Add(ace, 8)).String()
		if err != nil {
			return safeError("permission_denied")
		}
		trusted := aceSID == "S-1-5-18" || aceSID == "S-1-5-32-544" || (!installed && aceSID == sid)
		if !trusted && mask&(0x10000000|0x40000000|0xD0156) != 0 {
			return safeError("permission_denied")
		}
		if strict {
			if !trusted || seen[aceSID] || h.Flags&0x10 != 0 || mask != fullAccess {
				return safeError("permission_denied")
			}
			seen[aceSID] = true
		}
	}
	if strict && len(seen) != 3 {
		return safeError("permission_denied")
	}
	return nil
}

func ensureOwnedDirectory(path, sid string, strict bool) (*os.File, error) {
	sa, free, err := securityAttributes(sid, true)
	if err != nil {
		return nil, err
	}
	defer free()
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return nil, safeError("cache_unavailable")
	}
	if err = syscall.CreateDirectory(p, sa); err != nil && err != syscall.ERROR_ALREADY_EXISTS {
		return nil, safeError("cache_unavailable")
	}
	f, err := lockPath(path, true)
	if err != nil {
		return nil, err
	}
	if err = verifyFileSecurity(f, sid, false, strict); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}

func secureNewFile(path, sid string) (*os.File, error) {
	sa, free, err := securityAttributes(sid, false)
	if err != nil {
		return nil, err
	}
	defer free()
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return nil, safeError("cache_unavailable")
	}
	h, err := syscall.CreateFile(p, syscall.GENERIC_READ|syscall.GENERIC_WRITE|readControl, syscall.FILE_SHARE_READ, sa, syscall.CREATE_NEW, openReparsePoint, 0)
	if err != nil {
		return nil, safeError("cache_unavailable")
	}
	f := os.NewFile(uintptr(h), path)
	if finalPath(h, path) != nil || verifyFileSecurity(f, sid, false, true) != nil {
		f.Close()
		return nil, safeError("cache_unavailable")
	}
	return f, nil
}

func secureReadFile(path, sid string, installed bool) (*os.File, error) {
	f, err := lockPath(path, false)
	if err != nil {
		return nil, err
	}
	if err = verifyFileSecurity(f, sid, installed, !installed); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}

func namedLease(name, sid string) (func(), error) {
	// The mutex is only a per-user concurrency lease; the signed manifest and
	// locked file handles remain the authorization boundary.
	sa, free, err := securityAttributes(sid, false)
	if err != nil {
		return nil, err
	}
	defer free()
	p, _ := syscall.UTF16PtrFromString(name)
	h, _, _ := createMutex.Call(uintptr(unsafe.Pointer(sa)), 0, uintptr(unsafe.Pointer(p)))
	if h == 0 {
		return nil, safeError("permission_denied")
	}
	if err := verifyHandleSecurity(h, 6, sid, false, true); err != nil {
		syscall.CloseHandle(syscall.Handle(h))
		return nil, err
	}
	// Windows mutex ownership is thread-affine; keep this goroutine on its OS
	// thread until the returned release callback is invoked.
	runtime.LockOSThread()
	w, err := syscall.WaitForSingleObject(syscall.Handle(h), 0)
	if err != nil || (w != 0 && w != waitAbandoned) {
		syscall.CloseHandle(syscall.Handle(h))
		runtime.UnlockOSThread()
		return nil, safeError("operation_busy")
	}
	return func() { releaseMutex.Call(h); syscall.CloseHandle(syscall.Handle(h)); runtime.UnlockOSThread() }, nil
}

func openStore(exclusive bool) (*store, error) {
	sid, err := currentSID()
	if err != nil {
		return nil, err
	}
	s := &store{sid: sid}
	if exclusive {
		s.lease, err = namedLease(`Global\ExVPN.Updater.v1.`+sid, sid)
		if err != nil {
			return nil, err
		}
	}
	fail := func(err error) (*store, error) { s.close(); return nil, err }
	local, err := knownPath(&localAppDataID)
	if err != nil {
		return fail(err)
	}
	s.held, err = lockAncestors(local)
	if err != nil {
		return fail(err)
	}
	product, productHeld, err := openProductDirectory(local, sid)
	if err != nil {
		return fail(err)
	}
	s.held = append(s.held, productHeld...)
	s.root = filepath.Join(product, "update-cache")
	f, err := ensureOwnedDirectory(s.root, sid, true)
	if err != nil {
		return fail(err)
	}
	s.held = append(s.held, f)
	return s, nil
}
