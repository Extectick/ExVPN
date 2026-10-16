//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"testing"

	"golang.org/x/sys/windows"
)

func TestWFPResultUsesDWORD(t *testing.T) {
	for _, tc := range []struct {
		name string
		raw  uintptr
		want error
	}{
		{"success", 0, nil},
		{"success with unspecified upper register", 0x1234567800000000, nil},
		{"missing filter", 0x80320003, windows.Errno(wfpFilterNotFound)},
		// Captured from FwpmFilterGetByKey0 in a fresh Windows Sandbox. This
		// must mean an unarmed guard, not a fatal service startup failure.
		{"sign extended missing filter", 0xffffffff80320003, windows.Errno(wfpFilterNotFound)},
		{"sign extended missing sublayer", 0xffffffff80320007, windows.Errno(wfpSublayerNotFound)},
		{"sign extended existing object", 0xffffffff80320009, windows.Errno(wfpAlreadyExists)},
		{"access denied stays an error", 5, windows.ERROR_ACCESS_DENIED},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := wfpResult(tc.raw); got != tc.want {
				t.Fatalf("result for %#x = %v; want %v", tc.raw, got, tc.want)
			}
		})
	}
}
