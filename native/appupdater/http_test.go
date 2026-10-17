// SPDX-License-Identifier: Apache-2.0
package main

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

type fixtureTransport func(*http.Request) (*http.Response, error)

func (f fixtureTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func fixtureDownloader(status int, length int64, data []byte) downloader {
	return downloader{&http.Client{Transport: fixtureTransport(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: status, ContentLength: length, Header: http.Header{}, Body: io.NopCloser(bytes.NewReader(data)), Request: r}, nil
	})}}
}

func TestManifestHTTPBoundsAndAbsentFeed(t *testing.T) {
	ctx := context.Background()
	feed := "https://github.com/Extectick/ExVPN/releases/download/windows-beta/windows-x64.json"
	if raw, absent, err := fixtureDownloader(404, -1, nil).fetchManifest(ctx, feed); err != nil || !absent || raw != nil {
		t.Fatalf("missing feed: %v", err)
	}
	for _, tc := range []struct {
		status int
		length int64
		data   []byte
	}{
		{206, 2, []byte("{}")}, {500, 2, []byte("{}")}, {200, maxEnvelope + 1, nil}, {200, -1, bytes.Repeat([]byte{' '}, maxEnvelope+1)}, {200, 100, []byte("short")}, {200, 0, nil},
	} {
		if _, _, err := fixtureDownloader(tc.status, tc.length, tc.data).fetchManifest(ctx, feed); err == nil {
			t.Fatal("invalid manifest response accepted")
		}
	}
}

func TestDownloadAuthenticatesActualStreamBeforeReady(t *testing.T) {
	data := bytes.Repeat([]byte("synthetic binary bytes"), 10000)
	m := testManifest(data)
	for _, tc := range []struct {
		name   string
		status int
		length int64
		data   []byte
		want   error
	}{
		{"valid", 200, int64(len(data)), data, nil},
		{"chunked valid", 200, -1, data, nil},
		{"partial status", 206, int64(len(data)), data, safeError("download_failed")},
		{"wrong length header", 200, int64(len(data) - 1), data, safeError("download_failed")},
		{"truncated body", 200, -1, data[:len(data)-1], safeError("integrity_failed")},
		{"excess body", 200, -1, append(append([]byte(nil), data...), 0), safeError("integrity_failed")},
		{"wrong hash", 200, -1, bytes.Repeat([]byte{0}, len(data)), safeError("integrity_failed")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f, err := os.CreateTemp(t.TempDir(), "fixture-")
			if err != nil {
				t.Fatal(err)
			}
			defer f.Close()
			var previous int64
			err = fixtureDownloader(tc.status, tc.length, tc.data).fetchInstaller(context.Background(), m.Asset, f, func(received, total int64) {
				if received < previous || received > total || total != int64(len(data)) {
					t.Fatalf("invalid progress %d/%d after %d", received, total, previous)
				}
				previous = received
			})
			if err != tc.want {
				t.Fatalf("got %v want %v", err, tc.want)
			}
			if tc.want == nil {
				if previous != int64(len(data)) {
					t.Fatal("missing final byte progress")
				}
				if err := verifyInstaller(f, m.Asset); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}

func TestOrdinaryTLSVerificationAndRedirectRestrictions(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("{}")) }))
	defer server.Close()
	d := newDownloader(2 * time.Second)
	if _, err := d.request(context.Background(), server.URL); err != safeError("network_failed") {
		t.Fatalf("untrusted TLS certificate accepted: %v", err)
	}
	for _, target := range []string{"http://github.com/Extectick/ExVPN/releases/download/tag/app.exe", "https://untrusted.invalid/app.exe"} {
		r, _ := http.NewRequest("GET", target, nil)
		if d.client.CheckRedirect(r, []*http.Request{{}}) == nil {
			t.Fatal("unsafe redirect accepted")
		}
	}
	r, _ := http.NewRequest("GET", "https://github.com/Extectick/ExVPN/releases/download/tag/app.exe", nil)
	if d.client.CheckRedirect(r, make([]*http.Request, 5)) == nil {
		t.Fatal("unbounded redirect chain")
	}
	if transport, ok := d.client.Transport.(*http.Transport); !ok || transport.TLSClientConfig.InsecureSkipVerify || transport.TLSClientConfig.MinVersion == 0 || !transport.DisableCompression {
		t.Fatal("TLS or compression policy relaxed")
	}
}

func TestCompressedTransferCannotBypassByteAccounting(t *testing.T) {
	d := downloader{&http.Client{Transport: fixtureTransport(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Encoding": []string{"gzip"}}, Body: io.NopCloser(strings.NewReader("fixture")), Request: r}, nil
	})}}
	if _, err := d.request(context.Background(), "https://github.com/Extectick/ExVPN/releases/download/tag/file.exe"); err != safeError("network_failed") {
		t.Fatalf("compression accepted %v", err)
	}
}
