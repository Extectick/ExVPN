//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/Microsoft/go-winio"
	"golang.org/x/sys/windows"
)

const PipeName = `\\.\pipe\ExVPN.Control.v1`

type ClientIdentity struct{ SID, Executable string }

func PipeSecurity(ownerSID string) (string, error) {
	sid, e := windows.StringToSid(ownerSID)
	if e != nil || !strings.HasPrefix(ownerSID, "S-1-5-21-") || sid.String() != ownerSID {
		return "", Code("owner_sid_invalid")
	}
	// 0x12019b = READ/WRITE/SYNCHRONIZE without FILE_CREATE_PIPE_INSTANCE.
	// GENERIC_WRITE is intentionally not granted to the owner: its expansion
	// includes FILE_CREATE_PIPE_INSTANCE and would permit a competing server.
	return "O:SYG:SYD:P(A;;GA;;;SY)(A;;0x12019b;;;" + ownerSID + ")", nil
}
func canonicalExecutable(path string) (string, error) {
	if !filepath.IsAbs(path) || strings.HasPrefix(path, `\\`) || !strings.EqualFold(filepath.Ext(path), ".exe") {
		return "", Code("executable_invalid")
	}
	p, e := filepath.EvalSymlinks(path)
	if e != nil {
		return "", Code("executable_unavailable")
	}
	s, e := os.Stat(p)
	if e != nil || !s.Mode().IsRegular() {
		return "", Code("executable_unavailable")
	}
	return filepath.Clean(p), nil
}
func ValidateExclusions(paths []string) error {
	for _, p := range paths {
		canonical, e := canonicalExecutable(p)
		if e != nil || !strings.EqualFold(filepath.ToSlash(canonical), p) {
			return Code("exclusions_rejected")
		}
	}
	return nil
}
func authorizePipe(conn net.Conn, expected ClientIdentity) error {
	f, ok := conn.(interface{ Fd() uintptr })
	if !ok {
		return Code("ipc_peer_unavailable")
	}
	var pid uint32
	if windows.GetNamedPipeClientProcessId(windows.Handle(f.Fd()), &pid) != nil {
		return Code("ipc_peer_unavailable")
	}
	p, e := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if e != nil {
		return Code("ipc_peer_unavailable")
	}
	defer windows.CloseHandle(p)
	var token windows.Token
	if windows.OpenProcessToken(p, windows.TOKEN_QUERY, &token) != nil {
		return Code("ipc_peer_unavailable")
	}
	defer token.Close()
	u, e := token.GetTokenUser()
	if e != nil || u.User.Sid.String() != expected.SID {
		return Code("ipc_access_denied")
	}
	buf := make([]uint16, 32768)
	n := uint32(len(buf))
	if windows.QueryFullProcessImageName(p, 0, &buf[0], &n) != nil {
		return Code("ipc_peer_unavailable")
	}
	actual, e := canonicalExecutable(windows.UTF16ToString(buf[:n]))
	if e != nil || !strings.EqualFold(actual, expected.Executable) {
		return Code("ipc_access_denied")
	}
	return nil
}

type PipeServer struct {
	listener    net.Listener
	identity    ClientIdentity
	controller  *Controller
	mu          sync.Mutex
	connections map[net.Conn]struct{}
	wg          sync.WaitGroup
}

func Listen(identity ClientIdentity, c *Controller) (*PipeServer, error) {
	return listenAt(PipeName, identity, c)
}
func listenAt(name string, identity ClientIdentity, c *Controller) (*PipeServer, error) {
	sddl, e := PipeSecurity(identity.SID)
	if e != nil {
		return nil, e
	}
	identity.Executable, e = canonicalExecutable(identity.Executable)
	if e != nil {
		return nil, e
	}
	l, e := winio.ListenPipe(name, &winio.PipeConfig{SecurityDescriptor: sddl, InputBufferSize: 4096, OutputBufferSize: 4096})
	if e != nil {
		return nil, Code("ipc_listen_failed")
	}
	return &PipeServer{listener: l, identity: identity, controller: c, connections: map[net.Conn]struct{}{}}, nil
}
func (s *PipeServer) Serve(ctx context.Context) error {
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			s.Close()
		case <-done:
		}
	}()
	for {
		conn, e := s.listener.Accept()
		if e != nil {
			if ctx.Err() != nil {
				return nil
			}
			return Code("ipc_accept_failed")
		}
		s.mu.Lock()
		if len(s.connections) >= 8 {
			s.mu.Unlock()
			_ = conn.Close()
			continue
		}
		s.connections[conn] = struct{}{}
		s.wg.Add(1)
		s.mu.Unlock()
		go s.serveConn(conn)
	}
}
func (s *PipeServer) serveConn(conn net.Conn) {
	defer func() { _ = conn.Close(); s.mu.Lock(); delete(s.connections, conn); s.mu.Unlock(); s.wg.Done() }()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	if authorizePipe(conn, s.identity) != nil {
		return
	}
	// One bounded request per connection. Reauthenticate every operation.
	b, e := ReadFrame(conn)
	if e != nil {
		return
	}
	r, e := DecodeRequest(b)
	if e != nil {
		_ = WriteFrame(conn, Response{Version: ProtocolVersion, Code: safeCode(e, "ipc_invalid_request"), Status: s.controller.Status()})
		return
	}
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	_ = WriteFrame(conn, s.controller.Handle(r))
}
func (s *PipeServer) Close() {
	_ = s.listener.Close()
	s.mu.Lock()
	for conn := range s.connections {
		_ = conn.Close()
	}
	s.mu.Unlock()
}
func (s *PipeServer) Wait() { s.wg.Wait() }
