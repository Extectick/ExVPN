//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
// Read-only QA observer. Never packaged with the application.
package main

import (
	"encoding/json"
	"os"

	service "github.com/Extectick/ExVPN/native/windows"
)

func main() {
	if len(os.Args) != 1 {
		os.Exit(2)
	}
	// Armed only opens/reads WFP and never arms, disarms or changes a filter.
	armed, err := (&service.WindowsGuard{}).Armed()
	_ = json.NewEncoder(os.Stdout).Encode(map[string]bool{"guardArmed": armed, "readFailed": err != nil})
	if err != nil {
		os.Exit(1)
	}
}
