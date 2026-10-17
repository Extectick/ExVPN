//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
)

func noApplicationReparse(path string) bool {
	clean := filepath.Clean(path)
	if !filepath.IsAbs(clean) || strings.HasPrefix(clean, `\\`) {
		return false
	}
	volume := filepath.VolumeName(clean)
	current := volume + string(filepath.Separator)
	for _, part := range strings.Split(strings.TrimPrefix(clean, current), string(filepath.Separator)) {
		if part == "" || part == "." || part == ".." {
			return false
		}
		current = filepath.Join(current, part)
		name, err := windows.UTF16PtrFromString(current)
		if err != nil {
			return false
		}
		attributes, err := windows.GetFileAttributes(name)
		if err != nil || attributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
			return false
		}
	}
	return true
}

func canonicalApplicationExecutable(path string) (string, error) {
	if !noApplicationReparse(path) {
		return "", Code("executable_unavailable")
	}
	canonical, err := canonicalExecutable(path)
	if err != nil || !strings.EqualFold(filepath.ToSlash(canonical), strings.ReplaceAll(path, "\\", "/")) {
		return "", Code("executable_unavailable")
	}
	return canonical, nil
}

func validStoredApplicationPath(path string) bool {
	root, exe, family := discordFamilyRoot(path)
	anchor := family && len(strings.Split(strings.ReplaceAll(path, "\\", "/"), "/")) == 7
	if _, err := canonicalApplicationExecutable(path); err == nil && !anchor {
		return true
	}
	// Removed version directories are the sole exception to existence at policy
	// reload. A current exact family image must exist under the same real root.
	if _, err := os.Lstat(path); !anchor && !os.IsNotExist(err) {
		return false
	}
	key := applicationPathKey(path)
	if !family {
		return false
	}
	if !noApplicationReparse(root) {
		return false
	}
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) > 512 {
		return false
	}
	for _, entry := range entries {
		if !entry.IsDir() || !discordVersion.MatchString(strings.ToLower(entry.Name())) {
			continue
		}
		candidate := filepath.Join(root, entry.Name(), exe)
		if applicationPathKey(candidate) != key {
			continue
		}
		if _, err := canonicalApplicationExecutable(candidate); err == nil {
			return true
		}
	}
	return false
}
