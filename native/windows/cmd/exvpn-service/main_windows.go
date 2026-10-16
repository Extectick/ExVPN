//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package main

import (
	"flag"
	"fmt"
	"os"

	exvpn "github.com/Extectick/ExVPN/native/core"
	service "github.com/Extectick/ExVPN/native/windows"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

func main() {
	if len(os.Args) == 2 && os.Args[1] == "version" {
		fmt.Printf("{\"protocolVersion\":1,\"coreVersion\":%q,\"coreCommit\":%q,\"systemVerified\":false}\n", exvpn.CoreVersion, exvpn.CoreCommit)
		return
	}
	// Explicit installer/operator recovery, never called by ordinary UI. The
	// service must be stopped; no other providers' filters are enumerated.
	if len(os.Args) == 2 && os.Args[1] == "recover-guard" {
		manager, e := mgr.Connect()
		if e != nil {
			fmt.Fprintln(os.Stderr, "recovery_access_denied")
			os.Exit(1)
		}
		defer manager.Disconnect()
		s, e := manager.OpenService(service.ServiceName)
		if e != nil && e != windows.ERROR_SERVICE_DOES_NOT_EXIST {
			fmt.Fprintln(os.Stderr, "recovery_access_denied")
			os.Exit(1)
		}
		if e == nil {
			state, err := s.Query()
			s.Close()
			if err != nil || state.State != svc.Stopped {
				fmt.Fprintln(os.Stderr, "service_must_be_stopped")
				os.Exit(1)
			}
		}
		g := &service.WindowsGuard{}
		if g.Disarm() != nil {
			fmt.Fprintln(os.Stderr, "guard_recovery_failed")
			os.Exit(1)
		}
		fmt.Println("{\"ok\":true,\"code\":\"guard_removed\"}")
		return
	}
	fs := flag.NewFlagSet("exvpn-service", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	owner := fs.String("owner-sid", "", "Installer-bound local account SID")
	client := fs.String("client", "", "Installer-bound absolute ExVPN UI executable")
	testing := fs.Bool("network-testing", false, "Enable controlled system testing, not a verified release")
	if fs.Parse(os.Args[1:]) != nil || fs.NArg() != 0 {
		os.Exit(2)
	}
	isService, e := svc.IsWindowsService()
	if e != nil || !isService {
		fmt.Fprintln(os.Stderr, "service_control_manager_required")
		os.Exit(2)
	}
	if _, e = service.PipeSecurity(*owner); e != nil || *client == "" {
		os.Exit(2)
	}
	if svc.Run(service.ServiceName, &service.Host{Identity: service.ClientIdentity{SID: *owner, Executable: *client}, NetworkTesting: *testing}) != nil {
		os.Exit(1)
	}
}
