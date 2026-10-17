//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	exvpn "github.com/Extectick/ExVPN/native/core"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/transport"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"golang.org/x/sys/windows"
)

// Child processes own actual overlapping loopback endpoints. They bind/connect
// only to loopback; no TUN, DNS, WFP, route, installer or elevated API is used.
func TestOwnerSocketHelper(t *testing.T) {
	setting := os.Getenv("EXVPN_TEST_OWNER_SOCKET")
	if setting == "" {
		return
	}
	parts := strings.Split(setting, ",")
	if len(parts) != 3 {
		os.Exit(2)
	}
	port, _ := strconv.Atoi(parts[1])
	remote, _ := strconv.Atoi(parts[2])
	kind, protocol := windows.SOCK_DGRAM, windows.IPPROTO_UDP
	if parts[0] == "tcp" {
		kind, protocol = windows.SOCK_STREAM, windows.IPPROTO_TCP
	}
	socket, err := windows.Socket(windows.AF_INET, kind, protocol)
	if err != nil {
		os.Exit(3)
	}
	if windows.SetsockoptInt(socket, windows.SOL_SOCKET, windows.SO_REUSEADDR, 1) != nil {
		os.Exit(4)
	}
	if windows.Bind(socket, &windows.SockaddrInet4{Addr: [4]byte{127, 0, 0, 1}, Port: port}) != nil {
		os.Exit(5)
	}
	if parts[0] == "tcp" {
		if windows.Connect(socket, &windows.SockaddrInet4{Addr: [4]byte{127, 0, 0, 1}, Port: remote}) != nil {
			os.Exit(6)
		}
	}
	address, err := windows.Getsockname(socket)
	if err != nil {
		os.Exit(7)
	}
	fmt.Fprintln(os.Stdout, address.(*windows.SockaddrInet4).Port)
	_, _ = io.Copy(io.Discard, os.Stdin)
	_ = windows.Closesocket(socket)
	os.Exit(0)
}

func ownerHelperExecutable(t *testing.T) string {
	t.Helper()
	ctxExecutable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	// os.Executable may retain the go-build TEMP alias used to launch this test.
	// Launch the child by its physical image so QueryFullProcessImageName returns
	// the same exact identity that the production owner verifier requires.
	ctxExecutable, err = canonicalExecutable(ctxExecutable)
	if err != nil {
		t.Fatal("canonical loopback helper image unavailable", err)
	}
	return ctxExecutable
}

func startOwnerHelper(t *testing.T, network string, port, remote int) (int, uint32) {
	t.Helper()
	ctxExecutable := ownerHelperExecutable(t)
	command := exec.Command(ctxExecutable, "-test.run=^TestOwnerSocketHelper$")
	command.Env = append(os.Environ(), fmt.Sprintf("EXVPN_TEST_OWNER_SOCKET=%s,%d,%d", network, port, remote))
	stdin, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	command.Stderr = &stderr
	if err = command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stdin.Close(); _ = command.Process.Kill(); _ = command.Wait() })
	result := make(chan string, 1)
	go func() {
		reader := bufio.NewReader(stdout)
		line, _ := reader.ReadString('\n')
		result <- strings.TrimSpace(line)
	}()
	select {
	case line := <-result:
		bound, err := strconv.Atoi(line)
		if err != nil || bound == 0 {
			t.Fatalf("loopback owner helper failed: %s", stderr.String())
		}
		return bound, uint32(command.Process.Pid)
	case <-time.After(5 * time.Second):
		t.Fatal("loopback owner helper timed out")
	}
	return 0, 0
}

func TestRealTwoProcessUDPReuseRejectsAmbiguousOwner(t *testing.T) {
	port, first := startOwnerHelper(t, "udp", 0, 0)
	_, second := startOwnerHelper(t, "udp", port, 0)
	flow := flowTuple{network: "udp", local: netip.AddrPortFrom(netip.MustParseAddr("127.0.0.1"), uint16(port)), remote: netip.MustParseAddrPort("127.0.0.1:443")}
	// Evidence for the pinned core defect: it reports an owner despite two
	// different live processes bound to exactly the same UDP local endpoint.
	legacy, _, _, err := xnet.FindProcess("udp", "127.0.0.1", uint16(port), "127.0.0.1", 443)
	if err != nil || (uint32(legacy) != first && uint32(legacy) != second) {
		t.Fatal("could not reproduce pinned owner lookup behavior")
	}
	if _, err = resolveProcessOwner(flow); err != Code("owner_unavailable") {
		t.Fatal("ambiguous real UDP endpoint granted a direct exception")
	}
}

func TestRealTwoProcessTCPReuseMatchesRemoteTuple(t *testing.T) {
	expectedImage := processPathKey(ownerHelperExecutable(t))
	one, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer one.Close()
	two, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer two.Close()
	remoteOne, remoteTwo := one.Addr().(*net.TCPAddr).Port, two.Addr().(*net.TCPAddr).Port
	port, first := startOwnerHelper(t, "tcp", 0, remoteOne)
	_, second := startOwnerHelper(t, "tcp", port, remoteTwo)
	for _, test := range []struct {
		remote int
		pid    uint32
	}{{remoteOne, first}, {remoteTwo, second}} {
		flow := flowTuple{network: "tcp", local: netip.AddrPortFrom(netip.MustParseAddr("127.0.0.1"), uint16(port)), remote: netip.AddrPortFrom(netip.MustParseAddr("127.0.0.1"), uint16(test.remote))}
		owner, err := resolveProcessOwner(flow)
		if err != nil || owner.pid != test.pid || owner.created == 0 || owner.path != expectedImage {
			t.Fatal("full TCP tuple did not identify the correct real process")
		}
	}
}

func TestRealLoopbackVerifiedImageRespectsAllApplicationRoutingModes(t *testing.T) {
	expectedImage := processPathKey(ownerHelperExecutable(t))
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	remote := listener.Addr().(*net.TCPAddr).Port
	port, helperPID := startOwnerHelper(t, "tcp", 0, remote)
	flow := flowTuple{network: "tcp", local: netip.AddrPortFrom(netip.MustParseAddr("127.0.0.1"), uint16(port)), remote: netip.AddrPortFrom(netip.MustParseAddr("127.0.0.1"), uint16(remote))}
	owner, err := resolveProcessOwner(flow)
	if err != nil {
		t.Fatal("real owner unavailable", err)
	}
	if owner.pid != helperPID || owner.path != expectedImage || owner.created == 0 {
		t.Fatal("real owner did not match the canonical helper image and process")
	}
	for _, mode := range []string{exvpn.RoutingDisabled, exvpn.RoutingExclude, exvpn.RoutingInclude} {
		for _, selected := range []bool{false, true} {
			direct, proxy := &countingOutbound{tag: "direct-excluded"}, &countingOutbound{tag: "proxy"}
			allowed := map[string]bool{}
			if selected {
				allowed[applicationPathKey(owner.path)] = true
			}
			policy := &applicationPolicy{Handler: direct, fallback: proxy, allowed: allowed, mode: mode, resolve: resolveProcessOwner}
			ctx := session.ContextWithInbound(context.Background(), &session.Inbound{Tag: "vpn", Name: "tun", Source: xnet.TCPDestination(xnet.ParseAddress("127.0.0.1"), xnet.Port(port))})
			ctx = session.ContextWithOutbounds(ctx, []*session.Outbound{{OriginalTarget: xnet.TCPDestination(xnet.ParseAddress("127.0.0.1"), xnet.Port(remote))}})
			policy.Dispatch(ctx, &transport.Link{})
			want := (mode == exvpn.RoutingExclude && selected) || (mode == exvpn.RoutingInclude && !selected)
			if (direct.calls == 1) != want || direct.calls+proxy.calls != 1 {
				t.Fatalf("real verified image routed incorrectly mode=%s selected=%v", mode, selected)
			}
		}
	}
}
