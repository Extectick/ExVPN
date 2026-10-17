//go:build android

// SPDX-License-Identifier: Apache-2.0
package main

/*
#include <stdlib.h>
int exvpn_protect(int fd);
int exvpn_owner(int protocol, const char* localIP, int localPort, const char* remoteIP, int remotePort);
*/
import "C"

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
	"unsafe"

	androidcore "github.com/Extectick/ExVPN/native/android"
	exvpn "github.com/Extectick/ExVPN/native/core"
	_ "github.com/xtls/xray-core/app/policy"
	_ "github.com/xtls/xray-core/app/stats"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/stats"
	_ "github.com/xtls/xray-core/proxy/freedom"
	_ "github.com/xtls/xray-core/proxy/tun"
	"github.com/xtls/xray-core/transport/internet"
	"golang.org/x/sys/unix"
)

var state struct {
	sync.Mutex
	instance *core.Instance
	cancel   context.CancelFunc
	ctx      context.Context
	fd       int
}

func init() {
	state.fd = -1
	internet.UseAlternativeSystemDialer(androidcore.ProtectedDialer{ProtectSocket: func(fd uintptr) bool { return C.exvpn_protect(C.int(fd)) == 1 }})
	xnet.RegisterAndroidProcessFinder(func(network, src string, srcPort uint16, dst string, dstPort uint16) (int, string, string, error) {
		protocol := 6
		if strings.HasPrefix(network, "udp") {
			protocol = 17
		}
		local, remote := C.CString(src), C.CString(dst)
		defer C.free(unsafe.Pointer(local))
		defer C.free(unsafe.Pointer(remote))
		uid := int(C.exvpn_owner(C.int(protocol), local, C.int(srcPort), remote, C.int(dstPort)))
		if uid < 10000 {
			return 0, "", "", exvpn.CodeError("owner_unknown")
		}
		return uid, strconv.Itoa(uid), "", nil
	})
}

//export ExVPNValidate
func ExVPNValidate(raw *C.char) *C.char {
	_, err := exvpn.DecodeProfile(strings.NewReader(C.GoString(raw)))
	if err != nil {
		return C.CString(err.Error())
	}
	return C.CString("")
}

//export ExVPNStart
func ExVPNStart(raw *C.char, endpoint *C.char, fd C.int, uidValues *C.int, uidCount C.int, routingMode *C.char) *C.char {
	state.Lock()
	defer state.Unlock()
	if state.instance != nil {
		return C.CString("core_already_running")
	}
	if fd < 0 || uidCount < 0 || uidCount > 500 {
		return C.CString("invalid_native_request")
	}
	p, err := exvpn.DecodeProfile(strings.NewReader(C.GoString(raw)))
	if err != nil {
		return C.CString(err.Error())
	}
	uids := make([]int, int(uidCount))
	for i, v := range unsafe.Slice(uidValues, int(uidCount)) {
		uids[i] = int(v)
	}
	mode := C.GoString(routingMode)
	config, err := androidcore.BuildConfigWithRouting(p, C.GoString(endpoint), mode, uids)
	if err != nil {
		return C.CString(err.Error())
	}
	duplicate, err := unix.Dup(int(fd))
	if err != nil {
		return C.CString("tun_duplicate_failed")
	}
	if err = os.Setenv("XRAY_TUN_FD", strconv.Itoa(duplicate)); err != nil {
		_ = unix.Close(duplicate)
		return C.CString("tun_environment_failed")
	}
	compiled, err := core.LoadConfig("json", bytes.NewReader(config))
	if err != nil {
		_ = unix.Close(duplicate)
		return C.CString("core_config_rejected")
	}
	instance, err := core.New(compiled)
	if err != nil {
		_ = unix.Close(duplicate)
		return C.CString("core_start_failed")
	}
	if err = androidcore.InstallApplicationRouting(instance, mode, uids, resolveApplicationUID); err != nil {
		_ = instance.Close()
		_ = unix.Close(duplicate)
		return C.CString("owner_policy_unavailable")
	}
	if err = instance.Start(); err != nil {
		_ = instance.Close()
		_ = unix.Close(duplicate)
		return C.CString("core_start_failed")
	}
	state.instance = instance
	state.fd = duplicate
	state.ctx, state.cancel = context.WithCancel(context.Background())
	return C.CString("")
}

func resolveApplicationUID(network string, local, remote netip.AddrPort) (int, error) {
	protocol := 6
	if network == "udp" {
		protocol = 17
	} else if network != "tcp" {
		return 0, exvpn.CodeError("owner_unknown")
	}
	left, right := C.CString(local.Addr().String()), C.CString(remote.Addr().String())
	defer C.free(unsafe.Pointer(left))
	defer C.free(unsafe.Pointer(right))
	uid := int(C.exvpn_owner(C.int(protocol), left, C.int(local.Port()), right, C.int(remote.Port())))
	if uid < 10000 {
		return 0, exvpn.CodeError("owner_unknown")
	}
	return uid, nil
}

//export ExVPNStop
func ExVPNStop() {
	state.Lock()
	defer state.Unlock()
	if state.cancel != nil {
		state.cancel()
		state.cancel = nil
	}
	if state.instance != nil {
		_ = state.instance.Close()
		state.instance = nil
	}
	if state.fd >= 0 {
		_ = unix.Close(state.fd)
		state.fd = -1
	}
	_ = os.Unsetenv("XRAY_TUN_FD")
}

//export ExVPNCancel
func ExVPNCancel() {
	state.Lock()
	defer state.Unlock()
	if state.cancel != nil {
		state.cancel()
	}
}

//export ExVPNHealth
func ExVPNHealth() *C.char {
	state.Lock()
	instance, base := state.instance, state.ctx
	state.Unlock()
	if instance == nil {
		return C.CString(`{"reachable":false,"errorCode":"core_not_running"}`)
	}
	ctx, cancel := context.WithTimeout(base, 12*time.Second)
	defer cancel()
	transport := &http.Transport{DisableKeepAlives: true, TLSHandshakeTimeout: 8 * time.Second,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			host, port, e := net.SplitHostPort(address)
			if e != nil {
				return nil, exvpn.CodeError("health_target_invalid")
			}
			pn, e := strconv.Atoi(port)
			if e != nil {
				return nil, e
			}
			ctx = session.ContextWithInbound(ctx, &session.Inbound{Tag: "healthcheck"})
			return core.Dial(ctx, instance, xnet.TCPDestination(xnet.ParseAddress(host), xnet.Port(pn)))
		}}
	defer transport.CloseIdleConnections()
	client := http.Client{Transport: transport, Timeout: 12 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, "https://www.gstatic.com/generate_204", nil)
	began := time.Now()
	response, err := client.Do(request)
	if err != nil {
		return C.CString(`{"reachable":false,"errorCode":"tunnel_https_failed"}`)
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
	_ = response.Body.Close()
	if response.StatusCode != 204 {
		return C.CString(`{"reachable":false,"errorCode":"tunnel_https_status"}`)
	}
	result, _ := json.Marshal(map[string]any{"reachable": true, "latencyMs": time.Since(began).Milliseconds()})
	return C.CString(string(result))
}

//export ExVPNStats
func ExVPNStats() *C.char {
	state.Lock()
	defer state.Unlock()
	up, down := int64(0), int64(0)
	if state.instance == nil {
		return C.CString(`{"errorCode":"statistics_unavailable"}`)
	}
	manager, ok := state.instance.GetFeature(stats.ManagerType()).(stats.Manager)
	if !ok {
		return C.CString(`{"errorCode":"statistics_unavailable"}`)
	}
	uplink := manager.GetCounter("inbound>>>vpn>>>traffic>>>uplink")
	downlink := manager.GetCounter("inbound>>>vpn>>>traffic>>>downlink")
	if uplink == nil || downlink == nil {
		return C.CString(`{"errorCode":"statistics_unavailable"}`)
	}
	up, down = uplink.Value(), downlink.Value()
	if up < 0 || down < 0 {
		return C.CString(`{"errorCode":"statistics_unavailable"}`)
	}
	data, _ := json.Marshal(map[string]int64{"uploadBytes": up, "downloadBytes": down})
	return C.CString(string(data))
}
func main() {}
