// SPDX-License-Identifier: Apache-2.0
package main

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"time"
)

func main() {
	// Deliberately no panic text, request, OS error, or provider data on stderr.
	defer func() {
		if recover() != nil {
			_ = emit(os.Stdout, errorResponse(safeError("operation_failed")))
			os.Exit(1)
		}
	}()
	if len(os.Args) == 2 && os.Args[1] == "--worker-v1" {
		workerMain()
		return
	}
	if len(os.Args) != 3 || os.Args[2] != "--json" {
		_ = emit(os.Stdout, errorResponse(safeError("invalid_request")))
		os.Exit(1)
	}
	command := os.Args[1]
	req, err := readRequest(os.Stdin, command)
	if err != nil {
		_ = emit(os.Stdout, errorResponse(err))
		os.Exit(1)
	}
	r, err := run(context.Background(), command, req, os.Stdout)
	if err != nil {
		_ = emit(os.Stdout, errorResponse(err))
		os.Exit(1)
	}
	if err := emit(os.Stdout, r); err != nil {
		os.Exit(1)
	}
}

func run(ctx context.Context, command string, req request, out io.Writer) (response, error) {
	if err := ordinaryUser(); err != nil {
		return response{}, err
	}
	// A signed Dart patch restart is useful even in a build with no full-update
	// feed configured. It still uses the fixed installed UI and the same handoff.
	if command == "restart-ui" {
		return beginHandoff(req, trustedConfig{}, nil)
	}
	cfg, err := pinnedConfig()
	if err != nil {
		return response{}, err
	}
	s, err := openStore(true)
	if err != nil {
		return response{}, err
	}
	defer s.close()
	switch command {
	case "check":
		if err := s.consumePreviousResult(cfg); err != nil {
			return response{}, err
		}
		raw, absent, err := newDownloader(20*time.Second).fetchManifest(ctx, cfg.Feed)
		if err != nil {
			return response{}, err
		}
		if absent {
			if err := s.clearAvailable(cfg.Channel); err != nil {
				return response{}, err
			}
			return result("upToDate", manifest{}), nil
		}
		m, err := verifyEnvelopeMetadata(raw, cfg, time.Now().UTC())
		if err != nil {
			return response{}, err
		}
		if !eligibleUpdate(m, cfg) {
			if err := s.clearAvailable(cfg.Channel); err != nil {
				return response{}, err
			}
			return result("upToDate", manifest{}), nil
		}
		if err := s.writeAtomic(s.availablePath(cfg.Channel), raw); err != nil {
			return response{}, err
		}
		return result("available", m), nil
	case "download":
		m, raw, err := s.readAvailable(cfg, req.Version, time.Now().UTC())
		if err != nil {
			return response{}, err
		}
		// Reuse only after rechecking the signature and every installed byte.
		if ready, f, err := s.ready(cfg, req.Version, time.Now().UTC()); err == nil {
			f.Close()
			return result("ready", ready), nil
		}
		id, err := randomID()
		if err != nil {
			return response{}, err
		}
		temp := filepath.Join(s.root, "installer-"+id+".part")
		f, err := secureNewFile(temp, s.sid)
		if err != nil {
			return response{}, safeError("cache_unavailable")
		}
		defer func() { f.Close(); os.Remove(temp) }()
		err = newDownloader(20*time.Minute).fetchInstaller(ctx, m.Asset, f, func(received, total int64) {
			_ = emit(out, response{Type: "progress", Received: received, Total: total})
		})
		if err != nil {
			return response{}, err
		}
		if err = f.Close(); err != nil {
			return response{}, safeError("cache_unavailable")
		}
		if err = os.Rename(temp, s.readyPath(m)); err != nil {
			return response{}, safeError("cache_unavailable")
		}
		// Readiness is committed last. A crash before this point cannot authorize
		// execution. Handoff always rechecks the exact installer handle again.
		if err = s.writeAtomic(s.envelopePath(m), raw); err != nil {
			return response{}, err
		}
		return result("ready", m), nil
	case "handoff":
		return beginHandoff(req, cfg, s)
	}
	return response{}, safeError("invalid_request")
}
