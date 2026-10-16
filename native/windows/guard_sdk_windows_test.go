//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"testing"

	"golang.org/x/sys/windows"
)

// Compare against the independently installed Microsoft SDK, not a second
// handwritten copy of the GUIDs. This reads headers only and never opens WFP
// or changes the workstation network. Windows release CI has the SDK installed.
func TestGuardIdentifiersMatchWindowsSDK(t *testing.T) {
	headers, err := filepath.Glob(filepath.Join(os.Getenv("ProgramFiles(x86)"), "Windows Kits", "10", "Include", "*", "um", "fwpmu.h"))
	if err != nil || len(headers) == 0 {
		if os.Getenv("CI") != "" {
			t.Fatal("Windows SDK required in Windows CI")
		}
		t.Skip("Windows SDK not installed")
	}
	b, err := os.ReadFile(headers[len(headers)-1])
	if err != nil {
		t.Fatal(err)
	}
	identifiers := map[string]windows.GUID{
		"FWPM_LAYER_ALE_AUTH_CONNECT_V4":      guardLayers[0],
		"FWPM_LAYER_ALE_AUTH_CONNECT_V6":      guardLayers[1],
		"FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V4":  guardLayers[2],
		"FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V6":  guardLayers[3],
		"FWPM_CONDITION_FLAGS":                fieldFlags,
		"FWPM_CONDITION_ALE_APP_ID":           fieldAppID,
		"FWPM_CONDITION_ALE_USER_ID":          fieldUserID,
		"FWPM_CONDITION_IP_LOCAL_INTERFACE":   fieldLocalInterface,
		"FWPM_CONDITION_IP_NEXTHOP_INTERFACE": fieldNextInterface,
		"FWPM_CONDITION_IP_ARRIVAL_INTERFACE": fieldArrivalInterface,
	}
	hex := regexp.MustCompile(`0x[0-9a-fA-F]+`)
	for name, actual := range identifiers {
		t.Run(name, func(t *testing.T) {
			definition := regexp.MustCompile(`(?s)DEFINE_GUID\(\s*` + regexp.QuoteMeta(name) + `\s*,([^)]*)\)`).FindSubmatch(b)
			if len(definition) != 2 {
				t.Fatal("SDK identifier missing")
			}
			values := hex.FindAllString(string(definition[1]), -1)
			if len(values) != 11 {
				t.Fatal("Unexpected SDK GUID syntax")
			}
			var numbers [11]uint64
			for i, value := range values {
				numbers[i], err = strconv.ParseUint(value[2:], 16, 32)
				if err != nil {
					t.Fatal(err)
				}
			}
			expected := windows.GUID{Data1: uint32(numbers[0]), Data2: uint16(numbers[1]), Data3: uint16(numbers[2])}
			for i := range expected.Data4 {
				expected.Data4[i] = byte(numbers[i+3])
			}
			if actual != expected {
				t.Errorf("guard uses %s; Microsoft SDK defines %s", actual.String(), expected.String())
			}
		})
	}
}
