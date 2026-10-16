// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"bytes"
	"crypto/mlkem"
	"encoding/base64"
	"regexp"
	"strconv"
	"strings"
)

var encryptionPadding = regexp.MustCompile(`^(0|[1-9][0-9]*)-(0|[1-9][0-9]*)-(0|[1-9][0-9]*)$`)
var encryptionKey = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// Validate before reaching Xray's permissive parser: bounded key chains and
// padding cannot panic, allocate unbounded data, or weaken peer authentication.
func validVlessEncryption(value string) bool {
	if len(value) > 8192 {
		return false
	}
	parts := strings.Split(value, ".")
	if len(parts) < 4 || parts[0] != "mlkem768x25519plus" || !oneOf(parts[1], "native", "xorpub", "random") || !oneOf(parts[2], "0rtt", "1rtt") {
		return false
	}
	keys, padding, maximumLength := 0, 0, 0
	for _, part := range parts[3:] {
		if len(part) < 20 {
			if keys != 0 || padding >= 15 || !encryptionPadding.MatchString(part) {
				return false
			}
			var numbers [3]int
			for index, raw := range strings.Split(part, "-") {
				n, err := strconv.Atoi(raw)
				if err != nil {
					return false
				}
				numbers[index] = n
			}
			maximum := 65553
			if padding%2 != 0 {
				maximum = 1000
			}
			if numbers[0] > 100 || numbers[1] > numbers[2] || numbers[2] > maximum || (padding == 0 && (numbers[0] != 100 || numbers[1] < 35)) {
				return false
			}
			if padding%2 == 0 {
				maximumLength += numbers[2]
			}
			padding++
		} else {
			keys++
			if keys > 4 || !encryptionKey.MatchString(part) {
				return false
			}
			decoded, err := base64.RawURLEncoding.Strict().DecodeString(part)
			if err != nil || (len(decoded) != 32 && len(decoded) != 1184) || bytes.Equal(decoded, make([]byte, len(decoded))) {
				return false
			}
			if len(decoded) == 1184 {
				if _, err := mlkem.NewEncapsulationKey768(decoded); err != nil {
					return false
				}
			}
		}
	}
	return keys != 0 && maximumLength <= 65553
}

// Only a single TCP Sudoku transform is admitted. It cannot introduce listeners,
// routes, arbitrary masks, files, certificates or connection destinations.
type Sudoku struct {
	Password     string   `json:"password"`
	ASCII        string   `json:"ascii,omitempty"`
	CustomTables []string `json:"customTables,omitempty"`
	PaddingMin   int      `json:"paddingMin,omitempty"`
	PaddingMax   int      `json:"paddingMax,omitempty"`
}

func (s Sudoku) valid() bool {
	if s.Password == "" || len(s.Password) > 4096 || !oneOf(s.ASCII, "", "prefer_entropy", "prefer_ascii") {
		return false
	}
	for _, b := range []byte(s.Password) {
		if b < 0x20 || b == 0x7f {
			return false
		}
	}
	if len(s.CustomTables) > 4 || (s.ASCII == "prefer_ascii" && len(s.CustomTables) != 0) || s.PaddingMin < 0 || s.PaddingMax > 100 || s.PaddingMin > s.PaddingMax {
		return false
	}
	seen := map[string]bool{}
	for _, table := range s.CustomTables {
		if len(table) != 8 || strings.Count(table, "x") != 2 || strings.Count(table, "p") != 2 || strings.Count(table, "v") != 4 || seen[table] {
			return false
		}
		seen[table] = true
	}
	return true
}
