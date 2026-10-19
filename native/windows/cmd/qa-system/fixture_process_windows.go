//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	exvpn "github.com/Extectick/ExVPN/native/core"
	service "github.com/Extectick/ExVPN/native/windows"
	"github.com/xtls/xray-core/features/stats"
	"golang.org/x/sys/windows"
)

type fixtureCounters struct {
	Upload          int64 `json:"upload"`
	Download        int64 `json:"download"`
	NumericUpload   int64 `json:"numericUpload"`
	NumericDownload int64 `json:"numericDownload"`
}

type fixtureMessage struct {
	Kind     string           `json:"kind"`
	Profile  *exvpn.Profile   `json:"profile,omitempty"`
	Counters *fixtureCounters `json:"counters,omitempty"`
}

func readFixtureMessage(line []byte) (fixtureMessage, error) {
	return readFixtureMessageMode(line, false)
}

func readFixtureMessageMode(line []byte, remote bool) (fixtureMessage, error) {
	var message fixtureMessage
	if len(line) > 8192 {
		return message, errors.New("fixture_protocol_failed")
	}
	decoder := json.NewDecoder(bytes.NewReader(line))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&message) != nil || decoder.Decode(new(any)) != io.EOF {
		return message, errors.New("fixture_protocol_failed")
	}
	if message.Kind == "ready" && message.Profile != nil && message.Counters == nil {
		p := message.Profile
		if p.ID == "qa-vless" && p.Protocol == "vless" && p.Server == "127.0.0.1" && p.Port > 0 && (p.Transport.Type == "tcp" || remote) {
			if _, err := exvpn.Compile(*p); err == nil {
				return message, nil
			}
		}
	}
	if message.Kind == "stats" && message.Profile == nil && message.Counters != nil {
		c := message.Counters
		if c.Upload >= 0 && c.Download >= 0 && c.NumericUpload >= 0 && c.NumericDownload >= 0 {
			return message, nil
		}
	}
	return fixtureMessage{}, errors.New("fixture_protocol_failed")
}

type isolatedFixture struct {
	command  *exec.Cmd
	input    io.WriteCloser
	counters atomic.Pointer[fixtureCounters]
	done     chan error
	once     sync.Once
	closeErr error
	job      windows.Handle
}

func (f *isolatedFixture) snapshot() fixtureCounters {
	if counters := f.counters.Load(); counters != nil {
		return *counters
	}
	return fixtureCounters{}
}

func (f *isolatedFixture) Close() error {
	f.once.Do(func() {
		defer windows.CloseHandle(f.job)
		_ = f.input.Close() // EOF requests a normal fixture shutdown.
		select {
		case f.closeErr = <-f.done:
		case <-time.After(8 * time.Second):
			// Only this owned fixture child is terminated; never the VPN client.
			_ = f.command.Process.Kill()
			<-f.done
			f.closeErr = errors.New("fixture_stop_failed")
		}
	})
	return f.closeErr
}

func startIsolatedFixture(interfaceIndex int) (*isolatedFixture, exvpn.Profile, error) {
	return startIsolatedFixtureMode(interfaceIndex, false)
}

func startIsolatedFixtureMode(interfaceIndex int, remote bool) (*isolatedFixture, exvpn.Profile, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, exvpn.Profile{}, err
	}
	command := exec.Command(executable, "-confirm-disposable-guest", "-fixture-process", "-interface-index", strconv.Itoa(interfaceIndex))
	if remote {
		command.Args = append(command.Args, "-remote-relay")
	}
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	command.Stderr = io.Discard
	input, err := command.StdinPipe()
	if err != nil {
		return nil, exvpn.Profile{}, err
	}
	output, err := command.StdoutPipe()
	if err != nil {
		_ = input.Close()
		return nil, exvpn.Profile{}, err
	}
	if err := command.Start(); err != nil {
		_ = input.Close()
		return nil, exvpn.Profile{}, err
	}
	job, err := fixtureJob(command.Process.Pid)
	if err != nil {
		_ = input.Close()
		_ = command.Process.Kill()
		_ = command.Wait()
		return nil, exvpn.Profile{}, errors.New("fixture_lifetime_failed")
	}
	fixture := &isolatedFixture{command: command, input: input, done: make(chan error, 1), job: job}
	ready := make(chan exvpn.Profile, 1)
	go func() {
		scanner := bufio.NewScanner(output)
		scanner.Buffer(make([]byte, 1024), 8193)
		started, preamble := false, 0
		for scanner.Scan() {
			line := scanner.Bytes()
			// The pinned Xray config loader prints deprecation warnings before
			// logging is configured. Bound and discard that startup preamble.
			if !started && !strings.HasPrefix(string(line), "{") && preamble < 8 {
				preamble++
				continue
			}
			message, err := readFixtureMessageMode(line, remote)
			if err != nil || (!started && message.Kind != "ready") || (started && message.Kind != "stats") {
				_ = input.Close()
				break
			}
			if !started {
				started = true
				ready <- *message.Profile
			} else {
				fixture.counters.Store(message.Counters)
			}
		}
		if scanner.Err() != nil {
			_ = input.Close()
		}
		fixture.done <- command.Wait()
	}()
	select {
	case profile := <-ready:
		return fixture, profile, nil
	case <-time.After(15 * time.Second):
		_ = fixture.Close()
		return nil, exvpn.Profile{}, errors.New("fixture_start_failed")
	}
}

func fixtureJob(pid int) (windows.Handle, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return 0, err
	}
	var limits windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	limits.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	_, err = windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits)))
	if err == nil {
		var process windows.Handle
		process, err = windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(pid))
		if err == nil {
			err = windows.AssignProcessToJobObject(job, process)
			_ = windows.CloseHandle(process)
		}
	}
	if err != nil {
		_ = windows.CloseHandle(job)
		return 0, err
	}
	return job, nil
}

// The real client installs a process-global fail-closed socket dialer. A local
// server therefore needs its own process, just as a remote VPN server does.
// The child retains SYSTEM and the exact protected executable App-ID; no WFP
// exception for another executable or arbitrary direct socket is introduced.
func runFixtureProcess(interfaceIndex int) error {
	iface, err := net.InterfaceByIndex(interfaceIndex)
	if err != nil || iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 || iface.Name == service.TunnelName {
		return errors.New("fixture_interface_invalid")
	}
	instance, profile, err := startFixture(iface.Name)
	if err != nil {
		return errors.New("fixture_start_failed")
	}
	defer instance.Close()
	manager, ok := instance.GetFeature(stats.ManagerType()).(stats.Manager)
	if !ok {
		return errors.New("fixture_stats_unavailable")
	}
	encoder := json.NewEncoder(os.Stdout)
	if encoder.Encode(fixtureMessage{Kind: "ready", Profile: &profile}) != nil {
		return errors.New("fixture_pipe_failed")
	}
	stopped := make(chan struct{})
	go func() { _, _ = io.Copy(io.Discard, io.LimitReader(os.Stdin, 1)); close(stopped) }()
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-stopped:
			return nil
		case <-ticker.C:
			read := func(name string) int64 {
				if counter := manager.GetCounter(name); counter != nil {
					return counter.Value()
				}
				return 0
			}
			counters := fixtureCounters{Upload: read("inbound>>>qa-fixture>>>traffic>>>uplink"), Download: read("inbound>>>qa-fixture>>>traffic>>>downlink"), NumericUpload: read("outbound>>>qa-numeric>>>traffic>>>uplink"), NumericDownload: read("outbound>>>qa-numeric>>>traffic>>>downlink")}
			if encoder.Encode(fixtureMessage{Kind: "stats", Counters: &counters}) != nil {
				return errors.New("fixture_pipe_failed")
			}
		}
	}
}
