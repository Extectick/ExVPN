// SPDX-License-Identifier: Apache-2.0
// QA-only authenticated loopback WireGuard gateway. Never packaged in ExVPN.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
	"github.com/Extectick/ExVPN/native/core/qa/wireguardgateway"
)

func fail(code string) {
	_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"ready": false, "code": code})
	os.Exit(1)
}

func main() {
	output := flag.String("output-directory", "", "New private output directory for synthetic peer credentials")
	port := flag.Int("port", 0, "Loopback UDP port, or zero for an ephemeral port")
	physical := flag.String("physical-interface", "", "Optional physical egress interface for an isolated TUN guest")
	duration := flag.Duration("duration", 20*time.Minute, "Bounded QA fixture lifetime")
	flag.Parse()
	if *output == "" || flag.NArg() != 0 || *duration < time.Minute || *duration > time.Hour {
		fail("qa_wireguard_arguments_invalid")
	}
	path, err := filepath.Abs(*output)
	if err != nil {
		fail("qa_wireguard_output_invalid")
	}
	for cursor := filepath.Dir(path); ; cursor = filepath.Dir(cursor) {
		info, err := os.Lstat(cursor)
		if err != nil || info.Mode()&os.ModeSymlink != 0 {
			fail("qa_wireguard_output_invalid")
		}
		if filepath.Dir(cursor) == cursor {
			break
		}
	}
	if os.Mkdir(path, 0700) != nil {
		fail("qa_wireguard_output_exists_or_unavailable")
	}
	gateway, err := wireguardgateway.Start(wireguardgateway.Options{Port: *port, PhysicalInterface: *physical})
	if err != nil {
		fail("qa_wireguard_start_failed")
	}
	defer gateway.Close()
	profile := gateway.Profile()
	encoded, _ := json.Marshal(profile)
	if os.WriteFile(filepath.Join(path, "client-profile.json"), encoded, 0600) != nil {
		fail("qa_wireguard_write_failed")
	}
	conf := fmt.Sprintf("[Interface]\nPrivateKey = %s\nAddress = 10.7.0.2/32, fd00:7::2/128\nMTU = 1420\n\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nEndpoint = 127.0.0.1:%d\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 15\n", profile.WireGuard.PrivateKey, profile.WireGuard.PublicKey, profile.WireGuard.PreSharedKey, profile.Port)
	if os.WriteFile(filepath.Join(path, "client.conf"), []byte(conf), 0600) != nil {
		fail("qa_wireguard_write_failed")
	}
	_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"ready": true, "udpPort": profile.Port, "pid": os.Getpid(), "coreVersion": exvpn.CoreVersion, "systemTunnel": false, "privateOutput": true, "physicalEgressBound": *physical != ""})
	writeStatus := func() {
		status, _ := json.Marshal(map[string]any{"ready": true, "online": gateway.Online(), "udpPort": profile.Port, "pid": os.Getpid(), "physicalEgressBound": *physical != ""})
		if os.WriteFile(filepath.Join(path, "status.json"), status, 0600) != nil {
			fail("qa_wireguard_status_write_failed")
		}
	}
	writeStatus()
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt)
	defer signal.Stop(stop)
	deadline := time.NewTimer(*duration)
	defer deadline.Stop()
	poll := time.NewTicker(250 * time.Millisecond)
	defer poll.Stop()
	for {
		select {
		case <-stop:
			return
		case <-deadline.C:
			return
		case <-poll.C:
			_, markerErr := os.Lstat(filepath.Join(path, "offline"))
			offline := markerErr == nil || !os.IsNotExist(markerErr)
			if gateway.Online() == offline {
				if gateway.SetOnline(!offline) != nil {
					fail("qa_wireguard_restart_failed")
				}
				writeStatus()
			}
		}
	}
}
