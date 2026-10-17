// SPDX-License-Identifier: Apache-2.0
package main

import (
	"crypto/rand"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

type store struct {
	root  string
	sid   string
	held  []*os.File
	lease func()
}

func (s *store) close() {
	for i := len(s.held) - 1; i >= 0; i-- {
		s.held[i].Close()
	}
	if s.lease != nil {
		s.lease()
	}
}

func randomID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", safeError("cache_unavailable")
	}
	return hex.EncodeToString(b), nil
}

func (s *store) availablePath(channel string) string {
	return filepath.Join(s.root, "available-"+channel+".json")
}
func (s *store) clearAvailable(channel string) error {
	if err := os.Remove(s.availablePath(channel)); err != nil && !os.IsNotExist(err) {
		return safeError("cache_unavailable")
	}
	return nil
}
func (s *store) readyPath(m manifest) string    { return filepath.Join(s.root, m.Asset.SHA256+".exe") }
func (s *store) envelopePath(m manifest) string { return filepath.Join(s.root, m.Asset.SHA256+".json") }

func (s *store) writeAtomic(path string, data []byte) error {
	id, err := randomID()
	if err != nil {
		return err
	}
	temp := filepath.Join(s.root, "metadata-"+id+".tmp")
	f, err := secureNewFile(temp, s.sid)
	if err != nil {
		return safeError("cache_unavailable")
	}
	ok := false
	defer func() {
		f.Close()
		if !ok {
			os.Remove(temp)
		}
	}()
	if _, err = f.Write(data); err != nil {
		return safeError("cache_unavailable")
	}
	if err = f.Sync(); err != nil {
		return safeError("cache_unavailable")
	}
	if err = f.Close(); err != nil {
		return safeError("cache_unavailable")
	}
	if err = os.Rename(temp, path); err != nil {
		return safeError("cache_unavailable")
	}
	ok = true
	return nil
}

func (s *store) readManifest(path string, cfg trustedConfig, now time.Time) (manifest, []byte, error) {
	f, err := secureReadFile(path, s.sid, false)
	if err != nil {
		return manifest{}, nil, safeError("update_not_ready")
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, maxEnvelope+1))
	if err != nil {
		return manifest{}, nil, safeError("cache_unavailable")
	}
	m, err := verifyEnvelope(raw, cfg, now)
	return m, raw, err
}

func (s *store) readAvailable(cfg trustedConfig, identity string, now time.Time) (manifest, []byte, error) {
	m, raw, err := s.readManifest(s.availablePath(cfg.Channel), cfg, now)
	if err != nil {
		return manifest{}, nil, err
	}
	if m.identity() != identity {
		return manifest{}, nil, safeError("update_not_ready")
	}
	return m, raw, nil
}

func (s *store) ready(cfg trustedConfig, identity string, now time.Time) (manifest, *os.File, error) {
	m, _, err := s.readAvailable(cfg, identity, now)
	if err != nil {
		return manifest{}, nil, err
	}
	ready, _, err := s.readManifest(s.envelopePath(m), cfg, now)
	if err != nil || ready.identity() != m.identity() || ready.Asset != m.Asset {
		return manifest{}, nil, safeError("update_not_ready")
	}
	f, err := secureReadFile(s.readyPath(m), s.sid, false)
	if err != nil {
		return manifest{}, nil, safeError("update_not_ready")
	}
	if err = verifyInstaller(f, m.Asset); err != nil {
		f.Close()
		return manifest{}, nil, err
	}
	return m, f, nil
}

type installReceipt struct {
	Schema  int    `json:"schema"`
	Status  string `json:"status"`
	Version string `json:"version,omitempty"`
}

func (s *store) consumePreviousResult(cfg trustedConfig) error {
	path := filepath.Join(s.root, "last-result.json")
	f, err := secureReadFile(path, s.sid, false)
	if err != nil {
		return nil
	}
	raw, readErr := io.ReadAll(io.LimitReader(f, 4097))
	f.Close()
	if readErr != nil {
		return safeError("cache_unavailable")
	}
	var receipt installReceipt
	if strictJSON(raw, 4096, &receipt) != nil || receipt.Schema != 1 || (receipt.Version != "" && !validIdentity(receipt.Version)) {
		return safeError("cache_unavailable")
	}
	if err := os.Remove(path); err != nil {
		return safeError("cache_unavailable")
	}
	switch receipt.Status {
	case "installer_failed", "launch_failed":
		return safeError("previous_install_failed")
	case "installed":
		if receipt.Version != cfg.Version+"+"+strconv.Itoa(cfg.Build) {
			return safeError("previous_install_failed")
		}
	case "restarted":
	default:
		return safeError("cache_unavailable")
	}
	return nil
}
