// SPDX-License-Identifier: Apache-2.0
package exvpn

import (
	"bytes"
	"encoding/json"
	"reflect"
	"sync/atomic"
	"testing"
)

func tunedQuic() *QuicOptions {
	return &QuicOptions{Congestion: "bbr", MaxIdleTimeout: 10, KeepAlivePeriod: 5,
		InitStreamReceiveWindow: 8388608, MaxStreamReceiveWindow: 8388608,
		InitConnectionReceiveWindow: 20971520, MaxConnectionReceiveWindow: 20971520}
}

func TestQuicParametersCompileWithoutProviderPrivileges(t *testing.T) {
	for _, q := range []*QuicOptions{{}, {Congestion: "bbr"}, {Congestion: "reno"}, tunedQuic()} {
		p := fixture("hysteria2")
		p.Transport.QuicParams = q
		b, _ := json.Marshal(p)
		decoded, err := DecodeProfile(bytes.NewReader(b))
		if err != nil || !reflect.DeepEqual(decoded.Transport.QuicParams, q) {
			t.Fatal("normalized QUIC settings did not survive native decoding")
		}
		if _, err := Compile(decoded); err != nil {
			t.Fatal("pinned core rejected valid QUIC settings")
		}
		stream := outbound(decoded)["streamSettings"].(object)
		if !reflect.DeepEqual(stream["finalmask"], object{"quicParams": q}) ||
			stream["tlsSettings"].(object)["allowInsecure"] != false {
			t.Fatal("QUIC tuning changed TLS or added arbitrary masks")
		}
	}
}

func TestQuicParametersRejectUnsafeAndUnboundedInputs(t *testing.T) {
	for _, field := range []string{"debug", "allowInsecure", "udp", "routing", "brutalUp"} {
		p := fixture("hysteria2")
		p.Transport.QuicParams = tunedQuic()
		b, _ := json.Marshal(p)
		var raw map[string]any
		_ = json.Unmarshal(b, &raw)
		raw["transport"].(map[string]any)["quicParams"].(map[string]any)[field] = true
		b, _ = json.Marshal(raw)
		if _, err := DecodeProfile(bytes.NewReader(b)); err == nil {
			t.Fatal("QUIC settings accepted an unmodeled provider field")
		}
	}
	for _, q := range []*QuicOptions{
		{Congestion: "unknown"}, {Congestion: "force-brutal"},
		{MaxIdleTimeout: -1}, {MaxIdleTimeout: 121}, {KeepAlivePeriod: 61},
		{KeepAlivePeriod: 30}, {MaxIdleTimeout: 10, KeepAlivePeriod: 10},
		{InitStreamReceiveWindow: 16383}, {MaxStreamReceiveWindow: 16777217},
		{MaxConnectionReceiveWindow: 67108865}, {MaxStreamReceiveWindow: 1048576},
		{MaxConnectionReceiveWindow: 8388608},
	} {
		p := fixture("hysteria2")
		p.Transport.QuicParams = q
		if _, err := Compile(p); err == nil {
			t.Fatal("unsafe QUIC value crossed the native boundary")
		}
	}
	p := fixture("vless")
	p.Transport.QuicParams = tunedQuic()
	if _, err := Compile(p); err == nil {
		t.Fatal("QUIC tuning accepted on a different protocol")
	}
}

func TestHysteriaQuicTuningCarriesVerifiedHTTPSAcrossRestarts(t *testing.T) {
	for _, q := range []*QuicOptions{{Congestion: "bbr"}, tunedQuic()} {
		var hits atomic.Int32
		target := localHTTPSTarget(t, &hits, false)
		p := fixture("hysteria2")
		p.Server, p.Port = "127.0.0.1", freeUDPPort(t)
		p.TLS = TLS{Enabled: true, ServerName: "127.0.0.1", ALPN: []string{"h3"}}
		p.Transport.QuicParams = q
		stream := outbound(p)["streamSettings"].(object)
		stream["tlsSettings"].(object)["certificates"] = []object{testServerCertificate(t, target)}
		startLocalProtocolServer(t, p.Port, "hysteria", object{"version": 2, "users": []object{{"auth": p.Password}}}, stream)
		for generation := int32(1); generation <= 3; generation++ {
			r := startProbeWithTestRoots(t, p, target.Certificate())
			if requestLocalHTTPS(r, target) != nil || hits.Load() != generation {
				t.Fatal("tuned Hysteria2 failed verified HTTPS through the fixture server")
			}
			assertProbeStops(t, r, target)
		}
		p.TLS.ServerName = "wrong.exvpn.test"
		bad := startProbeWithTestRoots(t, p, target.Certificate())
		if requestLocalHTTPS(bad, target) == nil || hits.Load() != 3 {
			t.Fatal("QUIC tuning bypassed TLS server identity verification")
		}
	}
}
