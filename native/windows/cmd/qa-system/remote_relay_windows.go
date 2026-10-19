//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
	"golang.org/x/sys/windows"
)

// A transparent, same-executable SYSTEM relay changes only endpoint availability.
// Credentials/TLS/Host remain from a normalized private profile; no raw provider
// routes/inbounds/DNS are accepted. Upstream is fixed before guard activation.
func runRemoteRelayProcess(interfaceIndex int) error {
	f, err := os.Open(`C:\ExVPN-Automatic-Private\profile.json`)
	if err != nil {
		return errors.New("private_profile_required")
	}
	p, err := exvpn.DecodeProfile(f)
	_ = f.Close()
	if err != nil || p.Protocol != "vless" {
		return errors.New("private_profile_rejected")
	}
	addresses, err := net.DefaultResolver.LookupIP(context.Background(), "ip4", p.Server)
	if err != nil || len(addresses) == 0 {
		return errors.New("relay_resolution_failed")
	}
	endpoint := net.JoinHostPort(addresses[0].String(), strconv.Itoa(p.Port))
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return errors.New("relay_bind_failed")
	}
	defer listener.Close()
	p.ID, p.Name, p.Server, p.Port = "qa-vless", "QA remote relay", "127.0.0.1", listener.Addr().(*net.TCPAddr).Port
	if _, err = exvpn.Compile(p); err != nil {
		return errors.New("relay_profile_rejected")
	}
	var upload, download atomic.Int64
	var connections sync.Map
	stopped := make(chan struct{})
	go func() {
		_, _ = io.Copy(io.Discard, io.LimitReader(os.Stdin, 1))
		close(stopped)
		_ = listener.Close()
		connections.Range(func(key, value any) bool { _ = key.(net.Conn).Close(); return true })
	}()
	dialer := net.Dialer{Timeout: 10 * time.Second, Control: func(network, address string, c syscall.RawConn) error {
		var socketErr error
		err := c.Control(func(fd uintptr) {
			var order [4]byte
			binary.BigEndian.PutUint32(order[:], uint32(interfaceIndex))
			socketErr = windows.SetsockoptInt(windows.Handle(fd), windows.IPPROTO_IP, 31, int(binary.LittleEndian.Uint32(order[:])))
		})
		if err != nil {
			return err
		}
		return socketErr
	}}
	go func() {
		for {
			incoming, err := listener.Accept()
			if err != nil {
				return
			}
			connections.Store(incoming, true)
			go func() {
				defer incoming.Close()
				defer connections.Delete(incoming)
				upstream, err := dialer.Dial("tcp4", endpoint)
				if err != nil {
					return
				}
				connections.Store(upstream, true)
				defer upstream.Close()
				defer connections.Delete(upstream)
				done := make(chan struct{})
				go func() { n, _ := io.Copy(upstream, incoming); upload.Add(n); _ = upstream.Close(); close(done) }()
				n, _ := io.Copy(incoming, upstream)
				download.Add(n)
				_ = incoming.Close()
				<-done
			}()
		}
	}()
	encoder := json.NewEncoder(os.Stdout)
	if encoder.Encode(fixtureMessage{Kind: "ready", Profile: &p}) != nil {
		return errors.New("relay_pipe_failed")
	}
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-stopped:
			return nil
		case <-ticker.C:
			counters := fixtureCounters{Upload: upload.Load(), Download: download.Load()}
			if encoder.Encode(fixtureMessage{Kind: "stats", Counters: &counters}) != nil {
				return errors.New("relay_pipe_failed")
			}
		}
	}
}
