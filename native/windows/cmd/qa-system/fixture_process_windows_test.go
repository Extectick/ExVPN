//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package main

import (
	"strings"
	"testing"
)

func TestFixtureProtocolRejectsRemoteServerAndMalformedCounters(t *testing.T) {
	for _, line := range []string{
		`{"kind":"ready","profile":{"id":"qa-vless","protocol":"vless","server":"remote.invalid","port":443,"uuid":"00000000-0000-4000-8000-000000000001","transport":{"type":"tcp"}}}`,
		`{"kind":"stats","counters":{"upload":-1,"download":0,"numericUpload":0,"numericDownload":0}}`,
		`{"kind":"stats","counters":{"upload":1},"arbitrary":true}`,
		`{"kind":"stats","counters":{}} {"kind":"stats","counters":{}}`,
		`{"kind":"ready"}`,
		strings.Repeat(" ", 8193),
	} {
		if _, err := readFixtureMessage([]byte(line)); err == nil {
			t.Fatal("untrusted fixture response accepted")
		}
	}
	message, err := readFixtureMessage([]byte(`{"kind":"stats","counters":{"upload":123,"download":456,"numericUpload":12,"numericDownload":45}}`))
	if err != nil || message.Counters.NumericDownload != 45 {
		t.Fatal("valid fixture counters rejected")
	}
	ready, err := readFixtureMessage([]byte(`{"kind":"ready","profile":{"id":"qa-vless","name":"QA VLESS TCP","protocol":"vless","server":"127.0.0.1","port":45678,"uuid":"00000000-0000-4000-8000-000000000001","transport":{"type":"tcp"}}}`))
	if err != nil || ready.Profile.Port != 45678 {
		t.Fatal("valid loopback fixture rejected")
	}
}
