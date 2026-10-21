//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
// Independent-process HTTPS probe. Never shipped with the VPN application.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

func main() {
	mode := flag.String("mode", "numeric", "Fixed independent HTTPS, DNS or synthetic ClientHello routing probe")
	flag.Parse()
	if (*mode != "health" && *mode != "numeric" && *mode != "numeric6" && *mode != "alternate" && *mode != "dns-tun" && *mode != "dns-fresh-a" && *mode != "dns-fresh-aaaa" && *mode != "raw-plain" && *mode != "raw-ech-before" && *mode != "raw-ech-after" && *mode != "raw-no-sni" && *mode != "hold") || flag.NArg() != 0 {
		fmt.Println(`{"error":"invalid_mode"}`)
		return
	}
	if strings.HasPrefix(*mode, "raw-") {
		runClientHelloProbe(*mode)
		return
	}
	if strings.HasPrefix(*mode, "dns-fresh-") {
		runFreshDNSProbe(*mode)
		return
	}
	if *mode == "hold" {
		// Keep this exact executable discoverable in the real application list.
		// No network is opened; the test terminates its own child after selection.
		time.Sleep(90 * time.Second)
		return
	}
	if *mode == "dns-tun" {
		started := time.Now()
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		resolver := net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			var dialer net.Dialer
			return dialer.DialContext(ctx, network, "172.31.255.2:53")
		}}
		addresses, err := resolver.LookupHost(ctx, "www.gstatic.com")
		b, _ := json.Marshal(map[string]any{"mode": *mode, "success": err == nil && len(addresses) > 0, "addressCount": len(addresses), "durationMs": time.Since(started).Milliseconds()})
		fmt.Println(string(b))
		return
	}
	target := "https://1.1.1.1/cdn-cgi/trace"
	if *mode == "numeric6" {
		target = "https://[2606:4700:4700::1111]/cdn-cgi/trace"
	}
	if *mode == "health" {
		target = "https://www.gstatic.com/generate_204"
	}
	if *mode == "alternate" {
		target = "https://one.one.one.one/cdn-cgi/trace"
	}
	started := time.Now()
	transport := &http.Transport{TLSHandshakeTimeout: 8 * time.Second, ResponseHeaderTimeout: 8 * time.Second, DisableKeepAlives: true}
	defer transport.CloseIdleConnections()
	client := http.Client{Transport: transport, Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	report := map[string]any{"success": false, "mode": *mode}
	response, err := client.Get(target)
	if err == nil {
		body, e := io.ReadAll(io.LimitReader(response.Body, 32769))
		_ = response.Body.Close()
		if e == nil && len(body) <= 32768 {
			digest := sha256.Sum256(body)
			report["httpStatus"] = response.StatusCode
			report["bodySha256"] = hex.EncodeToString(digest[:])
			report["responseBytes"] = len(body)
			report["success"] = response.StatusCode == 200 || response.StatusCode == 204
			for _, line := range strings.Split(string(body), "\n") {
				if address := net.ParseIP(strings.TrimPrefix(line, "ip=")); strings.HasPrefix(line, "ip=") && address != nil {
					ipDigest := sha256.Sum256([]byte(address.String()))
					report["egressIpSha256"] = hex.EncodeToString(ipDigest[:])
				}
			}
		} else {
			report["error"] = "body_failed"
		}
	} else {
		report["error"] = "network"
	}
	report["durationMs"] = time.Since(started).Milliseconds()
	b, _ := json.Marshal(report)
	fmt.Println(string(b))
}
