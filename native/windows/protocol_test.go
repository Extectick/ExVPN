// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"strings"
	"testing"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

func syntheticProfile() exvpn.Profile {
	return exvpn.Profile{ID: "test", Name: "Synthetic", Protocol: "vless", Server: "192.0.2.1", Port: 443, UUID: "12345678-1234-4234-8234-123456789abc", Transport: exvpn.Transport{Type: "tcp"}, TLS: exvpn.TLS{Enabled: true, ServerName: "example.com"}}
}
func TestRequestValidation(t *testing.T) {
	for _, body := range []string{
		`{"version":1,"id":"a","command":"status"}`,
		`{"version":1,"id":"a","command":"stats"}`,
		`{"version":1,"id":"a","command":"disconnect"}`,
	} {
		if _, e := DecodeRequest([]byte(body)); e != nil {
			t.Fatal(e)
		}
	}
	for _, body := range []string{
		`{"version":1,"version":2,"id":"a","command":"status"}`,
		`{"version":1,"id":"a","command":"status","profile":null}`,
		`{"version":1,"id":"a","command":"status","profile":{}}`,
		`{"version":1,"id":"a","command":"stats","exclusions":[]}`,
		`{"version":1,"id":"a","command":"status","exclusions":[]}`,
		`{"version":1,"id":"a","command":"run","path":"C:/evil.exe"}`,
		`{"version":1,"id":"../secret","command":"status"}`,
		`{"version":2,"id":"a","command":"status"}`,
		`{"version":"1","id":"a","command":"status"}`,
		`{"version":1,"id":"a","command":"status"}{}`,
		`{"version":1,"id":"a","command":"connect","profile":{}}`,
		strings.Repeat("[", 18) + "1" + strings.Repeat("]", 18),
	} {
		if _, e := DecodeRequest([]byte(body)); e == nil {
			t.Fatalf("accepted invalid fixture: %s", body)
		}
	}
	p, _ := json.Marshal(syntheticProfile())
	b, _ := json.Marshal(Request{Version: 1, ID: "connect_1", Command: "connect", Profile: p, Exclusions: []string{"C:/Apps/example.exe"}})
	if _, e := DecodeRequest(b); e != nil {
		t.Fatal(e)
	}
}

type shortWriter struct{ b bytes.Buffer }

func (s *shortWriter) Write(p []byte) (int, error) {
	if len(p) > 2 {
		p = p[:2]
	}
	return s.b.Write(p)
}
func TestFramingLimitsAndPartialWrites(t *testing.T) {
	w := &shortWriter{}
	if e := WriteFrame(w, Request{Version: 1, ID: "a", Command: "status"}); e != nil {
		t.Fatal(e)
	}
	b, e := ReadFrame(&w.b)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = DecodeRequest(b); e != nil {
		t.Fatal(e)
	}
	for _, n := range []uint32{0, MaxFrameBytes + 1, 0xffffffff} {
		var h [4]byte
		binary.LittleEndian.PutUint32(h[:], n)
		if _, e := ReadFrame(bytes.NewReader(h[:])); e == nil {
			t.Fatal("accepted size", n)
		}
	}
	if _, e := ReadFrame(bytes.NewReader([]byte{5, 0, 0, 0, 1})); e == nil {
		t.Fatal("accepted truncated body")
	}
}
