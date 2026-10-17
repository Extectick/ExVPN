//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

// CI may expose TEMP through an 8.3 alias. Fixtures that promise an exact image
// path must use the directory's real path; production must still reject aliases.
func physicalApplicationTempDir(t *testing.T) string {
	t.Helper()
	name, err := windows.UTF16PtrFromString(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	handle, err := windows.CreateFile(name, windows.FILE_READ_ATTRIBUTES,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil, windows.OPEN_EXISTING, windows.FILE_FLAG_BACKUP_SEMANTICS|windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(handle)
	buffer := make([]uint16, 32768)
	length, err := windows.GetFinalPathNameByHandle(handle, &buffer[0], uint32(len(buffer)), 0)
	if err != nil || length == 0 || length >= uint32(len(buffer)) {
		t.Fatal("physical fixture directory unavailable", err)
	}
	return strings.TrimPrefix(windows.UTF16ToString(buffer[:length]), `\\?\`)
}

func TestFamilyAnchorRequiresInstalledLegitimateCandidate(t *testing.T) {
	// The root is not created. A valid-looking remembered identity must not by
	// itself establish an executable's existence or earn direct permission.
	root := filepath.Join(os.Getenv("SystemDrive")+string(filepath.Separator), "Users", "exvpn-absent-"+filepath.Base(filepath.Dir(t.TempDir())), "AppData", "Local", "Discord")
	anchor := filepath.ToSlash(filepath.Join(root, "Discord.exe"))
	if validStoredApplicationPath(anchor) {
		t.Fatal("missing family image granted permission")
	}
}

func TestApplicationPathsRejectReparseComponents(t *testing.T) {
	root := physicalApplicationTempDir(t)
	real := filepath.Join(root, "real")
	link := filepath.Join(root, "link")
	if err := os.Mkdir(real, 0700); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(real, "Fixture.exe")
	if err := os.WriteFile(file, []byte("synthetic resource"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := canonicalApplicationExecutable(file); err != nil {
		t.Fatal("ordinary exact file rejected", err)
	}
	// Retain the security distinction even when the runner's original TEMP was
	// short: canonical fixture identity succeeds, its real 8.3 alias must fail.
	short := make([]uint16, 32768)
	length, err := windows.GetShortPathName(windows.StringToUTF16Ptr(file), &short[0], uint32(len(short)))
	if err == nil && length > 0 && length < uint32(len(short)) {
		alias := windows.UTF16ToString(short[:length])
		if !strings.EqualFold(alias, file) {
			if _, err := canonicalApplicationExecutable(alias); err == nil {
				t.Fatal("short image alias accepted")
			}
		}
	}
	left, _ := windows.UTF16PtrFromString(link)
	right, _ := windows.UTF16PtrFromString(real)
	if err := windows.CreateSymbolicLink(left, right, windows.SYMBOLIC_LINK_FLAG_DIRECTORY|0x2 /* ALLOW_UNPRIVILEGED_CREATE */); err != nil {
		t.Skip("unprivileged symlink fixture unavailable")
	}
	alias := filepath.Join(link, "Fixture.exe")
	if _, err := canonicalApplicationExecutable(alias); err == nil {
		t.Fatal("reparse image accepted")
	}
	if !strings.EqualFold(filepath.ToSlash(file), filepath.ToSlash(filepath.Join(real, "Fixture.exe"))) {
		t.Fatal("fixture changed target")
	}
}
