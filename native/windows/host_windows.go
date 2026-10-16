//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package service

import (
	"context"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
)

const ServiceName = "ExVPNService"

// Requires SERVICE_USER_DEFINED_CONTROL access (installer administrator). This
// explicit maintenance command disconnects and removes owned protection before
// stopping; ordinary stop/shutdown continues to preserve the crash latch.
const MaintenanceControl svc.Cmd = 128

type Host struct {
	Identity       ClientIdentity
	NetworkTesting bool
}

func (h *Host) Execute(_ []string, requests <-chan svc.ChangeRequest, changes chan<- svc.Status) (bool, uint32) {
	changes <- svc.Status{State: svc.StartPending, WaitHint: 10000}
	u, e := windows.GetCurrentProcessToken().GetTokenUser()
	if e != nil || u.User.Sid.String() != "S-1-5-18" {
		return true, 1
	}
	guard := &WindowsGuard{}
	var storage PolicyStore
	policy, policyErr := openWindowsPolicyStore(h.Identity.SID)
	if policyErr != nil {
		// Keep IPC/explicit recovery available even if local policy storage is
		// unavailable. No implicit empty exclusions or unguarded reconnect.
		storage = unavailablePolicyStore{}
	} else {
		defer policy.Close()
		storage = policy
	}
	c, e := NewControllerWithPolicy(guard, WindowsTunnelFactory(guard), ValidateExclusions, h.NetworkTesting, storage)
	if e != nil {
		return true, 2
	}
	s, e := Listen(h.Identity, c)
	if e != nil {
		return true, 3
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	defer s.Close()
	defer c.Shutdown()
	done := make(chan error, 1)
	go func() { done <- s.Serve(ctx) }()
	changes <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for {
		select {
		case <-done:
			return true, 4
		case request := <-requests:
			switch request.Cmd {
			case MaintenanceControl:
				changes <- svc.Status{State: svc.StopPending, WaitHint: 30000}
				cancel()
				s.Close()
				s.Wait()
				if c.Disconnect() != nil {
					return true, 6
				}
				return false, 0
			case svc.Interrogate:
				changes <- request.CurrentStatus
			case svc.Stop, svc.Shutdown:
				changes <- svc.Status{State: svc.StopPending, WaitHint: 30000}
				cancel()
				s.Close()
				s.Wait()
				if c.Shutdown() != nil {
					return true, 5
				}
				return false, 0
			}
		}
	}
}
