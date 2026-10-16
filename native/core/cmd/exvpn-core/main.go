// SPDX-License-Identifier: Apache-2.0
package main

import (
	"context"
	"encoding/json"
	"flag"
	"io"
	"os"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

func emit(v any) { _ = json.NewEncoder(os.Stdout).Encode(v) }
func fail(code string) {
	emit(map[string]any{"ok": false, "code": code, "coreVersion": exvpn.CoreVersion})
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		fail("command_required")
	}
	command := os.Args[1]
	if command == "version" {
		emit(map[string]any{"coreVersion": exvpn.CoreVersion, "coreCommit": exvpn.CoreCommit, "libXrayCandidateCommit": exvpn.LibXrayCommit, "mode": "loopback-probe-only", "systemTunnel": false})
		return
	}
	if command != "validate" && command != "probe" {
		fail("unsupported_command")
	}
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	path := flags.String("profile", "-", "profile file or - for stdin")
	target := flags.String("target", "https://www.gstatic.com/generate_204", "HTTPS test URL")
	timeout := flags.Duration("timeout", 20*time.Second, "probe timeout")
	if flags.Parse(os.Args[2:]) != nil || flags.NArg() != 0 || *timeout < time.Second || *timeout > time.Minute {
		fail("invalid_arguments")
	}
	var input io.Reader = os.Stdin
	if *path != "-" {
		f, e := os.Open(*path)
		if e != nil {
			fail("profile_read_failed")
		}
		defer f.Close()
		input = f
	}
	p, e := exvpn.DecodeProfile(input)
	if e != nil {
		fail(e.Error())
	}
	if _, e = exvpn.Compile(p); e != nil {
		fail(e.Error())
	}
	if command == "validate" {
		emit(map[string]any{"ok": true, "code": "config_valid", "coreVersion": exvpn.CoreVersion})
		return
	}
	r, e := exvpn.StartProbe(p)
	if e != nil {
		fail(e.Error())
	}
	defer r.Close()
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	result := r.Probe(ctx, *target)
	emit(result)
	if !result.OK {
		r.Close()
		os.Exit(1)
	}
}
