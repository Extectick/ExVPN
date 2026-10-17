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
	root := t.TempDir()
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
