// SPDX-License-Identifier: Apache-2.0
//go:build windows

package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func generatedHandoffFixture(t *testing.T, contents io.Reader) (*store, string, string) {
	t.Helper()
	s := fixtureStore(t)
	id, err := randomID()
	if err != nil {
		t.Fatal(err)
	}
	stage, err := handoffStagePath(s.root, id)
	if err != nil {
		t.Fatal(err)
	}
	dir, err := ensureOwnedDirectory(stage, s.sid, true)
	if err != nil {
		t.Fatal(err)
	}
	dir.Close()
	self := filepath.Join(stage, handoffHelperName)
	f, err := secureNewFile(self, s.sid)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(f, contents); err != nil {
		f.Close()
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	f, err = secureReadFile(self, s.sid, false)
	if err != nil {
		t.Fatal(err)
	}
	digest, err := hashFile(f)
	f.Close()
	if err != nil {
		t.Fatal(err)
	}
	return s, self, digest
}

func TestGeneratedHandoffStagePath(t *testing.T) {
	root := filepath.Join(physicalTempDir(t), "cache")
	id, err := randomID()
	if err != nil {
		t.Fatal(err)
	}
	stage, err := handoffStagePath(root, id)
	if err != nil {
		t.Fatal(err)
	}
	// This is the production generator's real random ID, not a hand-written
	// stage length that can drift independently from beginHandoff.
	self := filepath.Join(stage, handoffHelperName)
	if got, err := validatedHandoffStagePath(root, self); err != nil || got != stage {
		t.Fatalf("generated handoff rejected: %v", err)
	}
	for name, path := range map[string]string{
		"wrong parent":      filepath.Join(root+"-other", filepath.Base(stage), handoffHelperName),
		"nested parent":     filepath.Join(root, "nested", filepath.Base(stage), handoffHelperName),
		"wrong prefix":      filepath.Join(root, "staging-"+id, handoffHelperName),
		"prefix case":       filepath.Join(root, "HANDOFF-"+id, handoffHelperName),
		"missing ID":        filepath.Join(root, handoffStagePrefix, handoffHelperName),
		"short ID":          filepath.Join(root, handoffStagePrefix+id[:len(id)-1], handoffHelperName),
		"long ID":           filepath.Join(root, handoffStagePrefix+id+"0", handoffHelperName),
		"nonhex ID":         filepath.Join(root, handoffStagePrefix+strings.Repeat("g", len(id)), handoffHelperName),
		"noncanonical ID":   filepath.Join(root, handoffStagePrefix+strings.Repeat("A", len(id)), handoffHelperName),
		"wrong executable":  filepath.Join(stage, "other.exe"),
		"executable case":   filepath.Join(stage, "EXVPN-UPDATER.EXE"),
		"executable suffix": self + ".",
		"alternate stream":  self + ":stream",
		"unclean alias":     stage + `\..\` + filepath.Base(stage) + `\` + handoffHelperName,
		"relative":          filepath.Join(filepath.Base(stage), handoffHelperName),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := validatedHandoffStagePath(root, path); err != safeError("handoff_failed") {
				t.Fatalf("invalid stage accepted: %v", err)
			}
		})
	}
	for _, invalid := range []string{"", id[:len(id)-1], id + "00", strings.Repeat("g", len(id)), strings.Repeat("A", len(id))} {
		if _, err := handoffStagePath(root, invalid); err != safeError("handoff_failed") {
			t.Fatalf("invalid generated ID accepted: %v", err)
		}
	}
}

func TestGeneratedWorkerStageRetainsPrivateDirectoryAndHelper(t *testing.T) {
	s, self, digest := generatedHandoffFixture(t, strings.NewReader("synthetic worker bytes"))
	directory, helper, err := lockHandoffStage(s.root, s.sid, self, digest)
	if err != nil {
		t.Fatalf("valid generated worker stage rejected: %v", err)
	}
	defer directory.Close()
	defer helper.Close()
	if err := os.Rename(filepath.Dir(self), filepath.Dir(self)+"-swapped"); err == nil {
		t.Fatal("verified worker directory could be replaced")
	}
	if writer, err := os.OpenFile(self, os.O_WRONLY, 0); err == nil {
		writer.Close()
		t.Fatal("verified worker bytes could be modified")
	}
	if err := os.Remove(self); err == nil {
		t.Fatal("verified worker could be deleted")
	}
}

func TestWorkerStageRejectsChangedBytesAndHardLinks(t *testing.T) {
	t.Run("wrong owner", func(t *testing.T) {
		s, self, digest := generatedHandoffFixture(t, strings.NewReader("worker bytes"))
		if directory, helper, err := lockHandoffStage(s.root, "S-1-1-0", self, digest); err != safeError("permission_denied") {
			if directory != nil {
				directory.Close()
			}
			if helper != nil {
				helper.Close()
			}
			t.Fatalf("wrong stage owner accepted: %v", err)
		}
	})
	t.Run("hash", func(t *testing.T) {
		s, self, _ := generatedHandoffFixture(t, strings.NewReader("modified worker bytes"))
		expected := sha256.Sum256([]byte("original worker bytes"))
		if directory, helper, err := lockHandoffStage(s.root, s.sid, self, hex.EncodeToString(expected[:])); err != safeError("integrity_failed") {
			if directory != nil {
				directory.Close()
			}
			if helper != nil {
				helper.Close()
			}
			t.Fatalf("modified worker accepted: %v", err)
		}
	})
	t.Run("hard link", func(t *testing.T) {
		s, self, digest := generatedHandoffFixture(t, strings.NewReader("worker bytes"))
		if err := os.Link(self, filepath.Join(filepath.Dir(self), "alias.exe")); err != nil {
			t.Fatal(err)
		}
		if directory, helper, err := lockHandoffStage(s.root, s.sid, self, digest); err == nil {
			helper.Close()
			directory.Close()
			t.Fatal("hard-linked worker accepted")
		}
	})
}

// This branch exists only in the Go test executable. The copied child exercises
// production stage locking and spawnWorker's real detached process/pipes, then
// exits. It never calls workerMain/runWorker, Program Files, UAC, or VPN APIs.
func TestMain(m *testing.M) {
	if len(os.Args) == 2 && os.Args[1] == "--worker-v1" && os.Getenv("EXVPN_HANDOFF_TEST_CHILD") != "" {
		os.Exit(handoffPipeFixture())
	}
	os.Exit(m.Run())
}

func handoffPipeFixture() int {
	self, err := os.Executable()
	if err != nil {
		return 1
	}
	reader := bufio.NewReader(io.LimitReader(os.Stdin, maxPayload+128))
	line, err := reader.ReadBytes('\n')
	var plan workerRequest
	if err != nil || strictJSON(line, maxPayload, &plan) != nil || plan.Protocol != 1 {
		return 2
	}
	sid, err := currentSID()
	if err != nil {
		return 3
	}
	directory, helper, err := lockHandoffStage(filepath.Dir(filepath.Dir(self)), sid, self, plan.HelperSHA256)
	if err != nil {
		return 4
	}
	defer directory.Close()
	defer helper.Close()
	if os.Getenv("EXVPN_HANDOFF_TEST_CHILD") == "reject-prepare" {
		_ = emit(os.Stdout, errorResponse(safeError("integrity_failed")))
		return 0
	}
	if err := emit(os.Stdout, result("prepared", manifest{})); err != nil {
		return 5
	}
	line, err = reader.ReadBytes('\n')
	var commit struct {
		Protocol int  `json:"protocol"`
		Commit   bool `json:"commit"`
	}
	if err != nil || strictJSON(line, 128, &commit) != nil || commit.Protocol != 1 || !commit.Commit {
		return 6
	}
	if err := emit(os.Stdout, result("accepted", manifest{})); err != nil {
		return 7
	}
	return 0
}

func TestSpawnWorkerUsesPreparedCommitAcceptedHandshake(t *testing.T) {
	for _, mode := range []string{"accept", "reject-prepare"} {
		t.Run(mode, func(t *testing.T) {
			t.Setenv("EXVPN_HANDOFF_TEST_CHILD", mode)
			executable, err := os.Executable()
			if err != nil {
				t.Fatal(err)
			}
			source, err := os.Open(executable)
			if err != nil {
				t.Fatal(err)
			}
			defer source.Close()
			s, self, digest := generatedHandoffFixture(t, source)
			directory, helper, err := lockHandoffStage(s.root, s.sid, self, digest)
			if err != nil {
				t.Fatal(err)
			}
			err = spawnWorker(self, filepath.Dir(self), workerRequest{1, "restart", "", os.Getpid(), 1, digest})
			helper.Close()
			directory.Close()
			// spawnWorker releases its detached child handle after the response.
			// Wait for this test-only image to exit before TempDir removes it.
			deadline := time.Now().Add(5 * time.Second)
			for {
				if removeErr := os.Remove(self); removeErr == nil {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("test-only worker did not exit")
				}
				time.Sleep(10 * time.Millisecond)
			}
			if mode == "accept" && err != nil {
				t.Fatalf("valid worker handshake rejected: %v", err)
			}
			if mode == "reject-prepare" && err != safeError("handoff_failed") {
				t.Fatalf("failed prepare accepted: %v", err)
			}
		})
	}
}
