//go:build windows && amd64

// SPDX-License-Identifier: Apache-2.0
package main

import (
	"context"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"time"
)

func captureHello() ([]byte, error) {
	client, server := net.Pipe()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	defer server.Close()
	defer client.Close()
	go func() {
		_ = tls.Client(client, &tls.Config{ServerName: "public.example", MinVersion: tls.VersionTLS13}).HandshakeContext(ctx)
		_ = client.Close()
	}()
	header := make([]byte, 5)
	if _, err := io.ReadFull(server, header); err != nil {
		return nil, err
	}
	length := int(binary.BigEndian.Uint16(header[3:5]))
	if header[0] != 22 || length < 50 || length > 16384 {
		return nil, fmt.Errorf("hello_record_invalid")
	}
	body := make([]byte, length)
	if _, err := io.ReadFull(server, body); err != nil {
		return nil, err
	}
	return append(header, body...), nil
}

func extensions(record []byte) (int, []byte, error) {
	if len(record) < 50 || record[5] != 1 {
		return 0, nil, fmt.Errorf("client_hello_required")
	}
	position := 5 + 38
	position += 1 + int(record[position])
	if position+2 > len(record) {
		return 0, nil, fmt.Errorf("session_invalid")
	}
	position += 2 + int(binary.BigEndian.Uint16(record[position:position+2]))
	if position >= len(record) {
		return 0, nil, fmt.Errorf("cipher_invalid")
	}
	position += 1 + int(record[position])
	if position+2 > len(record) {
		return 0, nil, fmt.Errorf("compression_invalid")
	}
	length := int(binary.BigEndian.Uint16(record[position : position+2]))
	if position+2+length != len(record) {
		return 0, nil, fmt.Errorf("extension_length_invalid")
	}
	return position, append([]byte(nil), record[position+2:]...), nil
}

func mutate(record []byte, echBefore, echAfter, removeSNI bool) ([]byte, error) {
	position, raw, err := extensions(record)
	if err != nil {
		return nil, err
	}
	var kept []byte
	hasSNI := false
	for len(raw) > 0 {
		if len(raw) < 4 {
			return nil, fmt.Errorf("extension_header_invalid")
		}
		typ, length := binary.BigEndian.Uint16(raw[:2]), int(binary.BigEndian.Uint16(raw[2:4]))
		if length+4 > len(raw) {
			return nil, fmt.Errorf("extension_payload_invalid")
		}
		if typ == 0xfe0d {
			return nil, fmt.Errorf("unexpected_existing_ech")
		}
		if typ == 0 {
			hasSNI = true
		}
		if !(typ == 0 && removeSNI) {
			kept = append(kept, raw[:length+4]...)
		}
		raw = raw[length+4:]
	}
	if !hasSNI {
		return nil, fmt.Errorf("captured_sni_missing")
	}
	// Synthetic outer ECH envelope: outer(0), HKDF-SHA256/AES128-GCM,
	// config-id, 32-byte encapsulated key and opaque payload. This deliberately
	// does not claim a successful cryptographic ECH handshake.
	data := []byte{0, 0, 1, 0, 1, 1, 0, 32}
	data = append(data, make([]byte, 32)...)
	data = append(data, 0, 32)
	data = append(data, make([]byte, 32)...)
	ech := []byte{0xfe, 0x0d, byte(len(data) >> 8), byte(len(data))}
	ech = append(ech, data...)
	if echBefore {
		kept = append(append([]byte(nil), ech...), kept...)
	}
	if echAfter {
		kept = append(kept, ech...)
	}
	result := append([]byte(nil), record[:position]...)
	result = append(result, byte(len(kept)>>8), byte(len(kept)))
	result = append(result, kept...)
	bodyLen := len(result) - 5
	binary.BigEndian.PutUint16(result[3:5], uint16(bodyLen))
	handshakeLen := bodyLen - 4
	result[6], result[7], result[8] = byte(handshakeLen>>16), byte(handshakeLen>>8), byte(handshakeLen)
	return result, nil
}

func runClientHelloProbe(mode string) {
	started := time.Now()
	report := map[string]any{"mode": mode, "syntheticRoutingOnly": true, "cryptographicEchAcceptanceTested": false, "connected": false, "helloSent": false}
	defer func() {
		report["durationMs"] = time.Since(started).Milliseconds()
		b, _ := json.Marshal(report)
		fmt.Println(string(b))
	}()
	hello, err := captureHello()
	if err != nil {
		report["error"] = "fixture_generation"
		return
	}
	hello, err = mutate(hello, mode == "raw-ech-before", mode == "raw-ech-after", mode == "raw-no-sni")
	if err != nil {
		report["error"] = "fixture_mutation"
		return
	}
	conn, err := net.DialTimeout("tcp4", "1.1.1.1:443", 6*time.Second)
	if err != nil {
		report["error"] = "network"
		return
	}
	defer conn.Close()
	report["connected"] = true
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	n, err := conn.Write(hello)
	report["helloBytes"] = n
	if err != nil {
		report["error"] = "write"
		return
	}
	report["helloSent"] = n == len(hello)
	buf := make([]byte, 1024)
	n, err = conn.Read(buf)
	report["responseBytes"] = n
	report["responseReceived"] = err == nil && n > 0
}

func runFreshDNSProbe(mode string) {
	started := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	resolver := net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, network, "172.31.255.2:53")
	}}
	network := "ip4"
	if mode == "dns-fresh-aaaa" {
		network = "ip6"
	}
	query := fmt.Sprintf("exvpn-sites37-%d.example.com", time.Now().UnixNano())
	addresses, err := resolver.LookupIP(ctx, network, query)
	response := err == nil
	notFound := false
	if dns, ok := err.(*net.DNSError); ok && dns.IsNotFound {
		response = true
		notFound = true
	}
	b, _ := json.Marshal(map[string]any{"mode": mode, "freshNonce": true, "dnsResponse": response, "notFound": notFound, "addressCount": len(addresses), "durationMs": time.Since(started).Milliseconds()})
	fmt.Println(string(b))
}
