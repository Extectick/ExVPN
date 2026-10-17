// SPDX-License-Identifier: Apache-2.0
package service

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	exvpn "github.com/Extectick/ExVPN/native/core"
)

type fakeSystemProxy struct {
	recoveryTunnel
	port int
}

func (p *fakeSystemProxy) SystemProxyPort() int { return p.port }

func TestProxyIPCModeValidation(t *testing.T) {
	profile, _ := json.Marshal(syntheticProfile())
	for _, command := range []string{"connect", "reconnect"} {
		for _, mode := range []string{"", ModeVPN, ModeProxy} {
			encoded, _ := json.Marshal(Request{Version: 1, ID: "mode", Command: command, Profile: profile, Mode: mode})
			if _, err := DecodeRequest(encoded); err != nil {
				t.Fatalf("valid %s/%s: %v", command, mode, err)
			}
		}
	}
	for _, field := range []string{`"mode":""`, `"mode":"direct"`, `"mode":1`, `"mode":null`, `"mode":[]`, `"mode":{}`, `"mode":"proxy","exclusions":[]`, `"mode":"proxy","commandLine":"evil"`} {
		body := `{"version":1,"id":"mode","command":"connect","profile":` + string(profile) + `,` + field + `}`
		if _, err := DecodeRequest([]byte(body)); err == nil {
			t.Fatalf("invalid mode payload accepted: %s", field)
		}
	}
	if _, err := DecodeRequest([]byte(`{"version":1,"id":"mode","command":"status","mode":"proxy"}`)); err == nil {
		t.Fatal("mode accepted on a non-connection command")
	}
}

func TestProxyControllerNeverMutatesGuardAndPublishesVerifiedPort(t *testing.T) {
	g := &fakeGuard{}
	c := newFixture(t, g, &fakeTunnel{g: g})
	c.SetProxyFactory(func(context.Context, exvpn.Profile, []string) (Tunnel, error) {
		return &fakeSystemProxy{port: 42500}, nil
	})
	if err := c.ConnectMode(syntheticProfile(), ModeProxy); err != nil {
		t.Fatal(err)
	}
	waitState(t, c, "connected")
	if s := c.Status(); s.Mode != ModeProxy || s.ProxyPort != 42500 || s.GuardActive || !s.Capabilities.SystemProxy {
		t.Fatal(s)
	}
	if stats, err := c.Statistics(); err != nil || stats.DownloadBytes == 0 {
		t.Fatal("proxy statistics unavailable", stats, err)
	}
	if err := c.Disconnect(); err != nil {
		t.Fatal(err)
	}
	if c.Status().ProxyPort != 0 {
		t.Fatal("stale proxy port after disconnect")
	}
	if err := c.Reconnect(syntheticProfile(), ModeProxy); err != nil {
		t.Fatal(err)
	}
	waitState(t, c, "connected")
	if err := c.Shutdown(); err != nil {
		t.Fatal(err)
	}
	if c.Status().State != "disconnected" || c.Status().ProxyPort != 0 {
		t.Fatal("shutdown retained active proxy metadata")
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if len(g.events) != 0 {
		t.Fatalf("proxy mode changed guard: %v", g.events)
	}
}

func TestProxyRefusesRecoveredGuardAndFailedCleanup(t *testing.T) {
	for _, recovered := range []bool{false, true} {
		g := &fakeGuard{armed: recovered}
		c := newFixture(t, g, &fakeTunnel{g: g, closeError: true})
		c.SetProxyFactory(func(context.Context, exvpn.Profile, []string) (Tunnel, error) {
			t.Error("unsafe proxy factory invoked")
			return nil, nil
		})
		if !recovered {
			_ = c.Connect(syntheticProfile(), nil)
			waitState(t, c, "connected")
			_ = c.Disconnect()
			waitState(t, c, "blocked")
		}
		if err := c.Reconnect(syntheticProfile(), ModeProxy); err != Code("proxy_requires_guard_recovery") {
			t.Fatal(err)
		}
		assertGuardNeverDisarmed(t, g)
	}
}

func TestExplicitServerReconnectRetainsVPNGuardOnFailure(t *testing.T) {
	g := &fakeGuard{}
	c := recoveryController(t, g, func(_ context.Context, p exvpn.Profile, _ []string) (Tunnel, error) {
		if p.ID == "unreachable" {
			return nil, Code("synthetic_unreachable")
		}
		return &recoveryTunnel{}, nil
	})
	c.monitorInterval = time.Hour
	_ = c.Connect(syntheticProfile(), nil)
	waitState(t, c, "connected")
	p := syntheticProfile()
	p.ID = "unreachable"
	if err := c.Reconnect(p, ModeVPN); err != nil {
		t.Fatal(err)
	}
	waitState(t, c, "blocked")
	assertGuardNeverDisarmed(t, g)
	if c.Status().ActiveProfileID != "unreachable" {
		t.Fatal("selected profile was not owned")
	}
}

func TestExplicitVPNProxyVPNTransitionCleanupOrder(t *testing.T) {
	g := &fakeGuard{}
	c := newFixture(t, g, &fakeTunnel{g: g})
	c.SetProxyFactory(func(context.Context, exvpn.Profile, []string) (Tunnel, error) {
		if armed, _ := g.Armed(); armed {
			t.Error("proxy started before guard removal")
		}
		_ = g.event("proxy-start")
		return &fakeSystemProxy{port: 42501}, nil
	})
	_ = c.Connect(syntheticProfile(), nil)
	waitState(t, c, "connected")
	g.mu.Lock()
	g.events = nil
	g.mu.Unlock()
	if err := c.Reconnect(syntheticProfile(), ModeProxy); err != nil {
		t.Fatal(err)
	}
	waitState(t, c, "connected")
	g.mu.Lock()
	events := slices.Clone(g.events)
	g.mu.Unlock()
	if !slices.Equal(events, []string{"close", "suspend", "disarm", "proxy-start"}) {
		t.Fatal(events)
	}
	if err := c.Reconnect(syntheticProfile(), ModeVPN); err != nil {
		t.Fatal(err)
	}
	waitState(t, c, "connected")
	if s := c.Status(); s.Mode != ModeVPN || s.ProxyPort != 0 || !s.GuardActive {
		t.Fatal(s)
	}
	if err := c.Disconnect(); err != nil {
		t.Fatal(err)
	}
}

func TestProxyFailedHTTPSAndInvalidPortNeverPublishConnected(t *testing.T) {
	for _, fault := range []string{"https", "port"} {
		t.Run(fault, func(t *testing.T) {
			g := &fakeGuard{}
			c := newFixture(t, g, &fakeTunnel{g: g})
			proxy := &fakeSystemProxy{port: 42502}
			if fault == "port" {
				proxy.port = 0
			} else {
				proxy.verifyFn = func(context.Context) error { return Code("offline") }
			}
			c.SetProxyFactory(func(context.Context, exvpn.Profile, []string) (Tunnel, error) { return proxy, nil })
			if err := c.ConnectMode(syntheticProfile(), ModeProxy); err != nil {
				t.Fatal(err)
			}
			waitState(t, c, "error")
			if !proxy.closed.Load() || c.Status().ProxyPort != 0 || c.Status().GuardActive {
				t.Fatal("failed proxy retained/published")
			}
		})
	}
}

func TestProxyModeSwitchCancelsPendingHTTPSWithoutStalePublication(t *testing.T) {
	g := &fakeGuard{}
	c := newFixture(t, g, &fakeTunnel{g: g})
	entered := make(chan struct{})
	proxy := &fakeSystemProxy{port: 42503, recoveryTunnel: recoveryTunnel{verifyFn: func(ctx context.Context) error {
		close(entered)
		<-ctx.Done()
		return ctx.Err()
	}}}
	c.SetProxyFactory(func(context.Context, exvpn.Profile, []string) (Tunnel, error) { return proxy, nil })
	if err := c.ConnectMode(syntheticProfile(), ModeProxy); err != nil {
		t.Fatal(err)
	}
	<-entered
	if err := c.Reconnect(syntheticProfile(), ModeVPN); err != nil {
		t.Fatal(err)
	}
	waitState(t, c, "connected")
	if s := c.Status(); s.Mode != ModeVPN || s.ProxyPort != 0 || !s.GuardActive || !proxy.closed.Load() {
		t.Fatal("retired proxy completion affected replacement VPN", s)
	}
}

func TestSystemProxyConfigHasOnlyLoopbackHTTPAndSelectedOutbound(t *testing.T) {
	encoded, err := BuildSystemProxyConfig(syntheticProfile(), 42111)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{`"tun"`, `"freedom"`, `"direct-excluded"`, `"socks"`, "autoSystem", "application-policy"} {
		if strings.Contains(string(encoded), forbidden) {
			t.Fatalf("unexpected system behavior: %s", forbidden)
		}
	}
	var config struct {
		Inbounds []struct {
			Listen   string
			Port     int
			Protocol string
		}
		Routing struct {
			Rules []struct{ OutboundTag string }
		}
	}
	if err := json.Unmarshal(encoded, &config); err != nil {
		t.Fatal(err)
	}
	if len(config.Inbounds) != 1 || config.Inbounds[0].Listen != "127.0.0.1" || config.Inbounds[0].Protocol != "http" || config.Inbounds[0].Port != 42111 {
		t.Fatal("unsafe HTTP listener")
	}
	for _, rule := range config.Routing.Rules {
		if rule.OutboundTag != "proxy" {
			t.Fatal("HTTP path can escape selected outbound")
		}
	}
}

func TestLatestProxyRequestSafelyCancelsOwnedPendingVPNButNotRecoveredGuard(t *testing.T) {
	for _, recovered := range []bool{false, true} {
		t.Run(fmt.Sprint(recovered), func(t *testing.T) {
			g := &fakeGuard{armed: recovered}
			entered := make(chan struct{})
			c, err := NewController(g, func(ctx context.Context, _ exvpn.Profile, _ []string) (Tunnel, error) {
				close(entered)
				<-ctx.Done()
				return nil, Code("cancelled")
			}, nil, true)
			if err != nil {
				t.Fatal(err)
			}
			defer c.Shutdown()
			c.SetProxyFactory(func(context.Context, exvpn.Profile, []string) (Tunnel, error) {
				if armed, _ := g.Armed(); armed {
					t.Error("proxy started before owned guard cleanup")
				}
				_ = g.event("proxy-start")
				return &fakeSystemProxy{port: 42509}, nil
			})
			if err := c.Connect(syntheticProfile(), nil); err != nil {
				t.Fatal(err)
			}
			<-entered
			err = c.Reconnect(syntheticProfile(), ModeProxy)
			if recovered {
				if err != Code("proxy_requires_guard_recovery") {
					t.Fatal("recovered pending guard was released", err)
				}
				assertGuardNeverDisarmed(t, g)
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			waitState(t, c, "connected")
			g.mu.Lock()
			events := slices.Clone(g.events)
			g.mu.Unlock()
			disarm, proxy := -1, -1
			for i, event := range events {
				if event == "disarm" {
					disarm = i
				}
				if event == "proxy-start" {
					proxy = i
				}
			}
			if disarm < 0 || proxy <= disarm || c.Status().Mode != ModeProxy {
				t.Fatal("pending replacement cleanup order failed", events)
			}
		})
	}
}
