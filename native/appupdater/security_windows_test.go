// SPDX-License-Identifier: Apache-2.0
//go:build windows

package main

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"unsafe"
)

// Hosted Windows runners can give TEMP an 8.3 alias (RUNNER~1). Production
// deliberately rejects path aliases; fixtures must use the directory's real
// path instead of loosening that check for a CI environment.
func physicalTempDir(t *testing.T) string {
	t.Helper()
	f, err := openPathObject(t.TempDir(), true)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	path, err := pathFromHandle(syscall.Handle(f.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	return path
}

func fixtureStore(t *testing.T) *store {
	t.Helper()
	sid, err := currentSID()
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(physicalTempDir(t), "owned-fixture")
	f, err := ensureOwnedDirectory(root, sid, true)
	if err != nil {
		t.Fatal(err)
	}
	s := &store{root: root, sid: sid, held: []*os.File{f}}
	t.Cleanup(s.close)
	return s
}

func TestLockedInstallerRejectsWriteDeleteAndRename(t *testing.T) {
	s := fixtureStore(t)
	path := filepath.Join(s.root, "fixture.exe")
	f, err := secureNewFile(path, s.sid)
	if err != nil {
		t.Fatal(err)
	}
	f.Write([]byte("fixture"))
	f.Close()
	locked, err := secureReadFile(path, s.sid, false)
	if err != nil {
		t.Fatal(err)
	}
	defer locked.Close()
	if writer, err := os.OpenFile(path, os.O_WRONLY, 0); err == nil {
		writer.Close()
		t.Fatal("locked installer writable")
	}
	if err := os.Remove(path); err == nil {
		t.Fatal("locked installer deleted")
	}
	if err := os.Rename(path, filepath.Join(s.root, "replaced.exe")); err == nil {
		t.Fatal("locked installer renamed")
	}
}

func TestReparseHardLinksAndParentSwapsAreRejected(t *testing.T) {
	s := fixtureStore(t)
	path := filepath.Join(s.root, "fixture.exe")
	f, err := secureNewFile(path, s.sid)
	if err != nil {
		t.Fatal(err)
	}
	f.Write([]byte("fixture"))
	f.Close()
	link := filepath.Join(s.root, "hardlink.exe")
	if err := os.Link(path, link); err != nil {
		t.Fatal(err)
	}
	if f, err := secureReadFile(path, s.sid, false); err == nil {
		f.Close()
		t.Fatal("hardlinked installer accepted")
	}
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(s.root, s.root+"-moved"); err == nil {
		t.Fatal("retained parent directory renamed")
	}
	t.Run("symlink", func(t *testing.T) {
		link := filepath.Join(s.root, "symlink.exe")
		if err := os.Symlink(path, link); err != nil {
			t.Skip("symlink creation unavailable to this test token")
		}
		if f, err := secureReadFile(link, s.sid, false); err == nil {
			f.Close()
			t.Fatal("reparse installer accepted")
		}
	})
}

func TestReadyInstallerIsReauthenticatedOnEveryHandoff(t *testing.T) {
	s := fixtureStore(t)
	cfg, _ := testConfig()
	data := []byte("synthetic installer")
	m := testManifest(data)
	raw := signManifest(t, m)
	if err := s.writeAtomic(s.availablePath(cfg.Channel), raw); err != nil {
		t.Fatal(err)
	}
	if err := s.writeAtomic(s.envelopePath(m), raw); err != nil {
		t.Fatal(err)
	}
	f, err := secureNewFile(s.readyPath(m), s.sid)
	if err != nil {
		t.Fatal(err)
	}
	f.Write(data)
	f.Close()
	_, locked, err := s.ready(cfg, m.identity(), testNow)
	if err != nil {
		t.Fatal(err)
	}
	locked.Close()
	if err := os.WriteFile(s.readyPath(m), []byte(strings.Repeat("x", len(data))), 0600); err != nil {
		t.Fatal(err)
	}
	if _, f, err := s.ready(cfg, m.identity(), testNow); err != safeError("integrity_failed") {
		if f != nil {
			f.Close()
		}
		t.Fatalf("modified installer accepted: %v", err)
	}
	if _, _, err := s.ready(cfg, "0.1.0+23", testNow); err != safeError("update_not_ready") {
		t.Fatalf("caller-selected version accepted: %v", err)
	}
	if _, _, err := s.ready(cfg, m.identity(), testNow.AddDate(0, 1, 0)); err != safeError("update_expired") {
		t.Fatalf("expired cache accepted: %v", err)
	}
}

func TestOwnerPIDCreationTimeCannotBeReused(t *testing.T) {
	sid, err := currentSID()
	if err != nil {
		t.Fatal(err)
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if owner, err := validateOwner(os.Getpid(), 1, sid, exe); err != safeError("owner_invalid") {
		if owner != nil {
			owner.close()
		}
		t.Fatalf("creation timestamp mismatch accepted %v", err)
	}
	if owner, err := validateOwner(-1, 0, sid, exe); err != safeError("owner_invalid") {
		if owner != nil {
			owner.close()
		}
		t.Fatalf("negative PID %v", err)
	}
}

func TestHelperNeverAcceptsCallerChosenPaths(t *testing.T) {
	for _, path := range []string{`\\server\share\cache`, `C:\cache\..\other`, `C:\cache:stream`, `relative\cache`} {
		if localAbsolute(path) {
			t.Fatalf("unsafe path accepted %s", path)
		}
	}
	if unsafe.Sizeof(shellExecuteInfo{}) != 112 {
		t.Fatal("unexpected SHELLEXECUTEINFO Windows x64 ABI")
	}
}

func TestWindowsSecurityFailureDoesNotLeakPaths(t *testing.T) {
	if _, err := lockPath(filepath.Join(t.TempDir(), "missing-private-token.exe"), false); err != safeError("cache_unavailable") {
		t.Fatal("unexpected error mapping")
	}
	// Merely querying the current test process is read-only and cannot change
	// routes, DNS, firewall, services, or the installed application.
	h, err := syscall.OpenProcess(processQueryLimited, false, uint32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	syscall.CloseHandle(h)
}

func TestUpdaterWriterLeaseRejectsConcurrentProcessAndReleases(t *testing.T) {
	sid, err := currentSID()
	if err != nil {
		t.Fatal(err)
	}
	id, err := randomID()
	if err != nil {
		t.Fatal(err)
	}
	name := `Global\ExVPN.Updater.Fixture.` + id
	release, err := namedLease(name, sid)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		other, err := namedLease(name, sid)
		if other != nil {
			other()
		}
		done <- err
	}()
	if err := <-done; err != safeError("operation_busy") {
		release()
		t.Fatalf("concurrent writer allowed: %v", err)
	}
	release()
	release, err = namedLease(name, sid)
	if err != nil {
		t.Fatal(err)
	}
	release()
}

func TestFailedInstallationReceiptIsConsumedExactlyOnce(t *testing.T) {
	s := fixtureStore(t)
	cfg, _ := testConfig()
	path := filepath.Join(s.root, "last-result.json")
	if err := s.writeAtomic(path, []byte(`{"schema":1,"status":"installer_failed","version":"0.1.0+22"}`)); err != nil {
		t.Fatal(err)
	}
	if err := s.consumePreviousResult(cfg); err != safeError("previous_install_failed") {
		t.Fatalf("failure was hidden: %v", err)
	}
	if err := s.consumePreviousResult(cfg); err != nil {
		t.Fatalf("receipt repeated: %v", err)
	}
	if err := s.writeAtomic(path, []byte(`{"schema":1,"status":"installed","version":"0.1.0+22"}`)); err != nil {
		t.Fatal(err)
	}
	if err := s.consumePreviousResult(cfg); err != safeError("previous_install_failed") {
		t.Fatalf("old installed build called updated: %v", err)
	}
	cfg.Build = 22
	if err := s.writeAtomic(path, []byte(`{"schema":1,"status":"installed","version":"0.1.0+22"}`)); err != nil {
		t.Fatal(err)
	}
	if err := s.consumePreviousResult(cfg); err != nil {
		t.Fatalf("successful matching build: %v", err)
	}
}

func TestAppDataRedirectionRequiresPrivatePackageShapeAndCurrentIdentity(t *testing.T) {
	local := `C:\Users\fixture\AppData\Local`
	family := "Example.App_123456789abcd"
	actual := filepath.Join(local, "Packages", family, "LocalCache", "Local", "ExVPN")
	if !allowedAppDataRedirection(local, actual, family) || !allowedAppDataRedirection(local, actual, "") {
		t.Fatal("bounded OS package cache rejected")
	}
	for _, tc := range []struct{ path, family string }{
		{actual, "Other.App_123456789abcd"},
		{filepath.Join(local, "Packages", "invalid-family", "LocalCache", "Local", "ExVPN"), ""},
		{filepath.Join(local, "Packages", family, "LocalState", "ExVPN"), family},
		{filepath.Join(local, "Packages", family, "LocalCache", "Local", "arbitrary"), family},
		{filepath.Join(local, "ExVPN"), family},
		{`C:\Users\other\AppData\Local\Packages\` + family + `\LocalCache\Local\ExVPN`, family},
		{`\\remote\share\Packages\` + family + `\LocalCache\Local\ExVPN`, family},
	} {
		if allowedAppDataRedirection(local, tc.path, tc.family) {
			t.Fatal("arbitrary cache alias accepted")
		}
	}
}

func TestProductBootstrapKeepsExactUnpackagedPathAndPrivateLocks(t *testing.T) {
	sid, err := currentSID()
	if err != nil {
		t.Fatal(err)
	}
	local := physicalTempDir(t)
	ancestors, err := lockAncestors(local)
	if err != nil {
		t.Fatal(err)
	}
	defer closeFiles(ancestors)
	product, held, err := openProductDirectory(local, sid)
	if err != nil {
		t.Fatal(err)
	}
	defer closeFiles(held)
	if !strings.EqualFold(product, filepath.Join(local, "ExVPN")) {
		t.Fatal("unpackaged product directory changed")
	}
	if err := verifyFileSecurity(held[0], sid, false, true); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(product, product+"-moved"); err == nil {
		t.Fatal("bootstrap directory is not retained")
	}
}
