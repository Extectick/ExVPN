// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/xtls/xray-core/app/proxyman"
	"github.com/xtls/xray-core/transport/internet"
)

func TestExtendedTransportPreservesOnlyRemoteSocketLiveness(t *testing.T) {
	idle, interval := 60, 20
	p := fixture("vless")
	p.Transport.TCPKeepAliveIdle, p.Transport.TCPKeepAliveInterval = &idle, &interval
	p.PacketEncoding = "xudp"
	for _, network := range []string{"tcp", "ws", "xhttp"} {
		p.Transport.Type = network
		if network == "ws" {
			p.Transport.WSEarlyDataHeaderName = "Sec-WebSocket-Protocol"
		} else {
			p.Transport.WSEarlyDataHeaderName = ""
		}
		wire, _ := json.Marshal(p)
		decoded, err := DecodeProfile(bytes.NewReader(wire))
		if err != nil {
			t.Fatal(err)
		}
		compiled, err := Compile(decoded)
		if err != nil {
			t.Fatal(err)
		}
		proxy := compiled.Outbound[1]
		senderRaw, err := proxy.SenderSettings.GetInstance()
		if err != nil {
			t.Fatal(err)
		}
		sender := senderRaw.(*proxyman.SenderConfig)
		socket := sender.StreamSettings.SocketSettings
		if socket.TcpKeepAliveIdle != 60 || socket.TcpKeepAliveInterval != 20 || socket.Mark != 0 || socket.Interface != "" || socket.Tproxy != internet.SocketConfig_Off {
			t.Fatal("liveness options changed privileged socket policy")
		}
		mux := sender.MultiplexSettings
		if mux == nil || !mux.Enabled || mux.Concurrency != -1 || mux.XudpConcurrency != 8 || mux.XudpProxyUDP443 != "allow" {
			t.Fatal("XUDP request not implemented by pinned sender")
		}
	}
}

func TestExtendedTransportRejectsUnsafeAndMalformedFields(t *testing.T) {
	wire, _ := json.Marshal(fixture("vless"))
	base := string(wire)
	for _, extra := range []string{
		`"tcpKeepAliveIdle":0`, `"tcpKeepAliveIdle":-1`, `"tcpKeepAliveIdle":86401`,
		`"tcpKeepAliveInterval":"20"`, `"tcpKeepAliveInterval":20.5`, `"tcpKeepAliveIdle":null`,
		`"sockopt":{"tcpKeepAliveIdle":60}`, `"interface":"eth0"`, `"mark":1`,
		`"domainStrategy":"UseIP"`, `"dialerProxy":"direct"`,
		`"wsEarlyDataHeaderName":"Authorization"`, `"wsEarlyDataHeaderName":"Sec-WebSocket-Protocol"`,
	} {
		raw := strings.Replace(base, `"type":"tcp"`, `"type":"tcp",`+extra, 1)
		if _, err := DecodeProfile(strings.NewReader(raw)); err == nil {
			t.Fatalf("invalid field accepted: %s", extra)
		}
	}
	for _, packet := range []string{`"none"`, `"packetaddr"`, `true`, `null`} {
		raw := strings.TrimSuffix(base, "}") + `,"packetEncoding":` + packet + `}`
		if _, err := DecodeProfile(strings.NewReader(raw)); err == nil {
			t.Fatal("invalid packet encoding accepted")
		}
	}
	for _, endpoint := range []string{"0.0.0.0", "::"} {
		p := fixture("vless")
		p.Server = endpoint
		if p.Validate() == nil {
			t.Fatal("provider placeholder treated as server")
		}
	}
	p := fixture("hysteria2")
	idle := 60
	p.Transport.TCPKeepAliveIdle = &idle
	if p.Validate() == nil {
		t.Fatal("TCP knob applied to QUIC")
	}
	p = fixture("trojan")
	p.PacketEncoding = "xudp"
	if p.Validate() == nil {
		t.Fatal("VLESS packet encoding applied to other protocol")
	}
}
