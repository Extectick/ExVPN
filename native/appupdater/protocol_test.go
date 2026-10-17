// SPDX-License-Identifier: Apache-2.0
package main

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

func TestProtocolAcceptsOnlyFixedTypedCommands(t *testing.T) {
	valid := map[string]string{
		"check":      `{"protocol":1}`,
		"download":   `{"protocol":1,"version":"0.1.0+22"}`,
		"handoff":    `{"protocol":1,"version":"0.1.0+22","parentPid":123}`,
		"restart-ui": `{"protocol":1,"parentPid":123}`,
	}
	for cmd, line := range valid {
		if _, err := readRequest(strings.NewReader(line+"\n"), cmd); err != nil {
			t.Fatalf("%s: %v", cmd, err)
		}
	}
	cases := []struct{ cmd, line string }{
		{"check", `{"protocol":1,"url":"https://evil.invalid"}`},
		{"check", `{"protocol":1,"channel":"stable"}`},
		{"check", `{"protocol":1,"currentBuild":1}`},
		{"check", `{"protocol":1,"protocol":1}`},
		{"check", "{\"protocol\":1}\n{\"protocol\":1}"},
		{"check", `{"protocol":true}`},
		{"check", `{"protocol":1,"parentPid":1}`},
		{"download", `{"protocol":1,"version":"0.1.0+0"}`},
		{"download", `{"protocol":1,"version":"0.1.0+01"}`},
		{"download", `{"protocol":1,"version":"0.1.0+2147483648"}`},
		{"handoff", `{"protocol":1,"version":"0.1.0+22","parentPid":0}`},
		{"restart-ui", `{"protocol":1,"parentPid":"123"}`},
		{"restart-ui", `{"protocol":1,"parentPid":123,"version":"0.1.0+22"}`},
		{"execute", `{"protocol":1}`},
		{"check", strings.Repeat(" ", maxPayload+1)},
	}
	for _, tc := range cases {
		if _, err := readRequest(strings.NewReader(tc.line+"\n"), tc.cmd); err != safeError("invalid_request") {
			t.Fatalf("%s unexpected %v", tc.cmd, err)
		}
	}
}

func TestErrorsNeverExposeOSMessagesOrUnknownCodes(t *testing.T) {
	for _, err := range []error{errors.New("https://fixture.invalid/?private-token path=C:/private"), safeError("untrusted_error_with_private_text")} {
		var out bytes.Buffer
		_ = emit(&out, errorResponse(err))
		if out.String() != `{"type":"result","status":"error","errorCode":"operation_failed"}`+"\n" {
			t.Fatalf("unexpected output %s", out.String())
		}
	}
}
