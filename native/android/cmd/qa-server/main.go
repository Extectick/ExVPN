// SPDX-License-Identifier: Apache-2.0
// Local, ephemeral protocol fixtures for emulator and Windows Sandbox QA.
// This executable is not an application/server distribution component.
package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	_ "github.com/Extectick/ExVPN/native/core"
	_ "github.com/xtls/xray-core/app/policy"
	_ "github.com/xtls/xray-core/app/stats"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/stats"
	_ "github.com/xtls/xray-core/proxy/freedom"
	_ "github.com/xtls/xray-core/proxy/vless/inbound"
	_ "github.com/xtls/xray-core/proxy/vmess/inbound"
)

type object = map[string]any
type fixture struct {
	Name    string `json:"name"`
	Port    int    `json:"port"`
	Link    string `json:"-"`
	Inbound object `json:"-"`
}

func main() {
	output := flag.String("output-dir", "", "Required destination inside an ignored .private directory")
	listen := flag.String("listen-address", "127.0.0.1", "Explicit local IPv4 address; never a wildcard")
	client := flag.String("client-address", "10.0.2.2", "Same address, or Android emulator alias for loopback")
	flag.Parse()
	if flag.NArg() != 0 || !validFixtureAddress(*listen, *client) {
		fmt.Println("qa_fixture_address_rejected")
		os.Exit(2)
	}
	if err := run(*output, *listen, *client); err != nil {
		fmt.Println("qa_fixture_failed")
		os.Exit(1)
	}
}

func validFixtureAddress(listen, client string) bool {
	ip := net.ParseIP(listen)
	if ip == nil || ip.To4() == nil || ip.IsUnspecified() || ip.IsMulticast() || ip.IsLinkLocalUnicast() {
		return false
	}
	if client != listen && !(listen == "127.0.0.1" && client == "10.0.2.2") {
		return false
	}
	addresses, err := net.InterfaceAddrs()
	if err != nil {
		return false
	}
	for _, address := range addresses {
		value, _, err := net.ParseCIDR(address.String())
		if err == nil && value.Equal(ip) {
			return true
		}
	}
	return false
}

func run(output, listen, client string) error {
	abs, err := filepath.Abs(output)
	if err != nil || output == "" {
		return fmt.Errorf("private_output_required")
	}
	private := false
	for _, part := range strings.FieldsFunc(abs, func(r rune) bool { return r == '/' || r == '\\' }) {
		if part == ".private" {
			private = true
		}
	}
	if !private {
		return fmt.Errorf("private_output_required")
	}
	if err := os.MkdirAll(abs, 0700); err != nil {
		return err
	}

	// The camouflage target is local and ephemeral. Its test TLS certificate is
	// never installed in Android/Windows trust stores. REALITY authentication
	// and independent destination HTTPS remain verified normally.
	camouflage := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(204) }))
	camouflage.EnableHTTP2 = true
	camouflage.Config.ErrorLog = log.New(io.Discard, "", 0)
	camouflage.TLS = &tls.Config{MinVersion: tls.VersionTLS13, CurvePreferences: []tls.CurveID{tls.X25519}}
	camouflage.StartTLS()
	defer camouflage.Close()
	var fixtures []fixture
	for _, name := range []string{"VLESS TCP", "VLESS REALITY", "VLESS Vision", "VLESS XHTTP", "XHTTP REALITY", "VLESS gRPC", "VMess", "Shadowsocks"} {
		f, err := makeFixture(name, strings.TrimPrefix(camouflage.URL, "https://"), listen, client)
		if err != nil {
			return err
		}
		fixtures = append(fixtures, f)
	}
	inbounds := make([]any, len(fixtures))
	links := make([]string, len(fixtures))
	for i, f := range fixtures {
		inbounds[i], links[i] = f.Inbound, f.Link
	}
	configuration := object{
		"log":       object{"loglevel": "none", "access": "none", "error": "none"},
		"stats":     object{},
		"policy":    object{"system": object{"statsInboundUplink": true, "statsInboundDownlink": true}},
		"inbounds":  inbounds,
		"outbounds": []any{object{"protocol": "freedom", "settings": object{}}},
	}
	serialized, err := json.Marshal(configuration)
	if err != nil {
		return err
	}
	compiled, err := core.LoadConfig("json", bytes.NewReader(serialized))
	if err != nil {
		return err
	}
	instance, err := core.New(compiled)
	if err != nil {
		return err
	}
	defer instance.Close()
	if err = instance.Start(); err != nil {
		return err
	}
	// Only these files contain ephemeral credentials. Never print or screenshot.
	if err = os.WriteFile(filepath.Join(abs, "subscription.txt"), []byte(strings.Join(links, "\n")), 0600); err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(abs, "subscription.b64"), []byte(base64.StdEncoding.EncodeToString([]byte(strings.Join(links, "\n")))), 0600); err != nil {
		return err
	}
	metadata, _ := json.MarshalIndent(fixtures, "", "  ")
	if err = os.WriteFile(filepath.Join(abs, "manifest.json"), metadata, 0600); err != nil {
		return err
	}
	fmt.Printf("QA_READY fixtures=%d\n", len(fixtures))
	stopped := make(chan os.Signal, 1)
	signal.Notify(stopped, os.Interrupt)
	defer signal.Stop(stopped)
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	manager := instance.GetFeature(stats.ManagerType()).(stats.Manager)
	previous := make(map[string][2]int64)
	for {
		select {
		case <-stopped:
			return nil
		case <-ticker.C:
			for _, f := range fixtures {
				var value [2]int64
				for i, direction := range []string{"uplink", "downlink"} {
					if c := manager.GetCounter("inbound>>>" + f.Name + ">>>traffic>>>" + direction); c != nil {
						value[i] = c.Value()
					}
				}
				if old, ok := previous[f.Name]; !ok || old != value {
					fmt.Printf("QA_BYTES fixture=%q upload=%d download=%d\n", f.Name, value[0], value[1])
					previous[f.Name] = value
				}
			}
		}
	}
}

func makeFixture(name, camouflage, listen, client string) (fixture, error) {
	l, err := net.Listen("tcp4", net.JoinHostPort(listen, "0"))
	if err != nil {
		return fixture{}, err
	}
	port := l.Addr().(*net.TCPAddr).Port
	_ = l.Close()
	identity := make([]byte, 16)
	if _, err = rand.Read(identity); err != nil {
		return fixture{}, err
	}
	identity[6] = (identity[6] & 0x0f) | 0x40
	identity[8] = (identity[8] & 0x3f) | 0x80
	id := fmt.Sprintf("%x-%x-%x-%x-%x", identity[0:4], identity[4:6], identity[6:8], identity[8:10], identity[10:16])
	settings := object{"decryption": "none", "clients": []any{object{"id": id}}}
	stream := object{"network": "tcp", "security": "none"}
	protocol := "vless"
	query := url.Values{"type": {"tcp"}, "security": {"none"}, "encryption": {"none"}}
	if strings.Contains(name, "XHTTP") {
		stream["network"] = "xhttp"
		stream["xhttpSettings"] = object{"path": "/exvpn-qa", "mode": "auto"}
		query.Set("type", "xhttp")
		query.Set("path", "/exvpn-qa")
		query.Set("mode", "auto")
	}
	if name == "VLESS gRPC" {
		// Deliberately h2c on the explicit local QA listener. The independent
		// destination HTTPS probe still verifies the public TLS certificate.
		stream["network"] = "grpc"
		stream["grpcSettings"] = object{"serviceName": "exvpn-qa"}
		query.Set("type", "grpc")
		query.Set("serviceName", "exvpn-qa")
	}
	if strings.Contains(name, "REALITY") || name == "VLESS Vision" {
		key, e := ecdh.X25519().GenerateKey(rand.Reader)
		if e != nil {
			return fixture{}, e
		}
		sid := make([]byte, 8)
		if _, e = rand.Read(sid); e != nil {
			return fixture{}, e
		}
		stream["security"] = "reality"
		stream["realitySettings"] = object{"target": camouflage, "serverNames": []string{"example.com"}, "privateKey": base64.RawURLEncoding.EncodeToString(key.Bytes()), "shortIds": []string{hex.EncodeToString(sid)}}
		query.Set("security", "reality")
		query.Set("sni", "example.com")
		query.Set("fp", "chrome")
		query.Set("pbk", base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes()))
		query.Set("sid", hex.EncodeToString(sid))
		if name == "VLESS Vision" {
			settings["clients"] = []any{object{"id": id, "flow": "xtls-rprx-vision"}}
			query.Set("flow", "xtls-rprx-vision")
		}
	}
	link := (&url.URL{Scheme: "vless", User: url.User(id), Host: net.JoinHostPort(client, strconv.Itoa(port)), RawQuery: query.Encode(), Fragment: name}).String()
	if name == "VMess" {
		protocol = "vmess"
		settings = object{"clients": []any{object{"id": id, "alterId": 0}}}
		encoded, _ := json.Marshal(object{"v": "2", "ps": name, "add": client, "port": strconv.Itoa(port), "id": id, "aid": "0", "scy": "auto", "net": "tcp", "type": "none", "tls": ""})
		link = "vmess://" + base64.StdEncoding.EncodeToString(encoded)
	}
	if name == "Shadowsocks" {
		protocol = "shadowsocks"
		secret := make([]byte, 32)
		if _, err := rand.Read(secret); err != nil {
			return fixture{}, err
		}
		password := base64.RawURLEncoding.EncodeToString(secret)
		settings = object{"method": "chacha20-ietf-poly1305", "password": password, "network": "tcp,udp"}
		userinfo := base64.RawURLEncoding.EncodeToString([]byte("chacha20-ietf-poly1305:" + password))
		link = "ss://" + userinfo + "@" + net.JoinHostPort(client, strconv.Itoa(port)) + "#" + name
	}
	return fixture{Name: name, Port: port, Link: link, Inbound: object{"tag": name, "listen": listen, "port": port, "protocol": protocol, "settings": settings, "streamSettings": stream}}, nil
}
