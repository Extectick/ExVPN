// SPDX-License-Identifier: Apache-2.0
package main

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"io"
	"net"
	"net/http"
	"os"
	"time"
)

type downloader struct{ client *http.Client }

func newDownloader(timeout time.Duration) downloader {
	return downloader{&http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			DialContext:         (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
			TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
			TLSHandshakeTimeout: 10 * time.Second, ResponseHeaderTimeout: 10 * time.Second,
			DisableCompression: true, MaxIdleConns: 2,
		},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 || !allowedRedirect(req.URL.String()) {
				return safeError("network_failed")
			}
			return nil
		},
	}}
}

func (d downloader) request(ctx context.Context, rawURL string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", rawURL, nil)
	if err != nil {
		return nil, safeError("network_failed")
	}
	req.Header.Set("Accept-Encoding", "identity")
	req.Header.Set("User-Agent", "ExVPN-Updater/1")
	resp, err := d.client.Do(req)
	if err != nil {
		return nil, safeError("network_failed")
	}
	if resp.Header.Get("Content-Encoding") != "" && resp.Header.Get("Content-Encoding") != "identity" {
		resp.Body.Close()
		return nil, safeError("network_failed")
	}
	return resp, nil
}

func (d downloader) fetchManifest(ctx context.Context, feed string) ([]byte, bool, error) {
	r, err := d.request(ctx, feed)
	if err != nil {
		return nil, false, err
	}
	defer r.Body.Close()
	if r.StatusCode == http.StatusNotFound {
		return nil, true, nil
	}
	if r.StatusCode != http.StatusOK || r.ContentLength > maxEnvelope {
		return nil, false, safeError("network_failed")
	}
	b, err := io.ReadAll(io.LimitReader(r.Body, maxEnvelope+1))
	if err != nil || len(b) == 0 || len(b) > maxEnvelope || (r.ContentLength >= 0 && r.ContentLength != int64(len(b))) {
		return nil, false, safeError("network_failed")
	}
	return b, false, nil
}

func (d downloader) fetchInstaller(ctx context.Context, a asset, file *os.File, progress func(int64, int64)) error {
	r, err := d.request(ctx, a.URL)
	if err != nil {
		return safeError("download_failed")
	}
	defer r.Body.Close()
	if r.StatusCode != http.StatusOK || (r.ContentLength >= 0 && r.ContentLength != a.Size) {
		return safeError("download_failed")
	}
	h := sha256.New()
	buf := make([]byte, 64<<10)
	var received int64
	lastProgress := time.Time{}
	reader := io.LimitReader(r.Body, a.Size+1)
	for {
		n, readErr := reader.Read(buf)
		if n > 0 {
			if received+int64(n) > a.Size {
				return safeError("integrity_failed")
			}
			if _, err := file.Write(buf[:n]); err != nil {
				return safeError("cache_unavailable")
			}
			h.Write(buf[:n])
			received += int64(n)
			if progress != nil && (time.Since(lastProgress) >= 100*time.Millisecond || received == a.Size) {
				progress(received, a.Size)
				lastProgress = time.Now()
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return safeError("download_failed")
		}
	}
	if received != a.Size || hex.EncodeToString(h.Sum(nil)) != a.SHA256 {
		return safeError("integrity_failed")
	}
	if err := file.Sync(); err != nil {
		return safeError("cache_unavailable")
	}
	return nil
}

func verifyInstaller(file *os.File, a asset) error {
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() != a.Size {
		return safeError("integrity_failed")
	}
	if _, err = file.Seek(0, io.SeekStart); err != nil {
		return safeError("integrity_failed")
	}
	h := sha256.New()
	n, err := io.Copy(h, io.LimitReader(file, a.Size+1))
	if err != nil || n != a.Size || hex.EncodeToString(h.Sum(nil)) != a.SHA256 {
		return safeError("integrity_failed")
	}
	return nil
}
