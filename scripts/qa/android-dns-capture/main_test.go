// SPDX-License-Identifier: Apache-2.0
package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/gopacket"
	"github.com/google/gopacket/layers"
	"github.com/google/gopacket/pcapgo"
)

func fixtureConfig() configuration {
	return configuration{Phases: []phase{{ID: "baseline", Nonce: "0123456789abcdef0123456789abcdef", StartUnixMs: 1700000000000, EndUnixMs: 1700000002000}}}
}

func dnsPayload(t *testing.T, name string, reply bool) []byte {
	t.Helper()
	dns := &layers.DNS{ID: 123, QR: reply, RD: true, Questions: []layers.DNSQuestion{{Name: []byte(name), Type: layers.DNSTypeA, Class: layers.DNSClassIN}}}
	if reply {
		dns.ResponseCode = layers.DNSResponseCodeNXDomain
	}
	buffer := gopacket.NewSerializeBuffer()
	if err := dns.SerializeTo(buffer, gopacket.SerializeOptions{FixLengths: true}); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

func networkPacket(t *testing.T, v6, tcp, reply, syn bool, payload []byte) []byte {
	t.Helper()
	ethernet := &layers.Ethernet{SrcMAC: net.HardwareAddr{0, 1, 2, 3, 4, 5}, DstMAC: net.HardwareAddr{0, 6, 7, 8, 9, 10}, EthernetType: layers.EthernetTypeIPv4}
	var network gopacket.NetworkLayer
	var serial gopacket.SerializableLayer
	protocol := layers.IPProtocolUDP
	if tcp {
		protocol = layers.IPProtocolTCP
	}
	if v6 {
		ethernet.EthernetType = layers.EthernetTypeIPv6
		ip := &layers.IPv6{Version: 6, NextHeader: protocol, HopLimit: 64, SrcIP: net.ParseIP("2001:db8::1"), DstIP: net.ParseIP("2001:db8::2")}
		network, serial = ip, ip
	} else {
		ip := &layers.IPv4{Version: 4, IHL: 5, TTL: 64, Protocol: protocol, SrcIP: net.ParseIP("192.0.2.1"), DstIP: net.ParseIP("192.0.2.2")}
		network, serial = ip, ip
	}
	var transport gopacket.SerializableLayer
	if tcp {
		tcpLayer := &layers.TCP{SrcPort: 53000, DstPort: 53, Seq: 1234, SYN: syn, ACK: reply, Window: 1024}
		if reply {
			tcpLayer.SrcPort, tcpLayer.DstPort = 53, 53000
		}
		if err := tcpLayer.SetNetworkLayerForChecksum(network); err != nil {
			t.Fatal(err)
		}
		transport = tcpLayer
	} else {
		udp := &layers.UDP{SrcPort: 53000, DstPort: 53}
		if reply {
			udp.SrcPort, udp.DstPort = 53, 53000
		}
		if err := udp.SetNetworkLayerForChecksum(network); err != nil {
			t.Fatal(err)
		}
		transport = udp
	}
	buffer := gopacket.NewSerializeBuffer()
	if err := gopacket.SerializeLayers(buffer, gopacket.SerializeOptions{FixLengths: true, ComputeChecksums: true}, ethernet, serial, transport, gopacket.Payload(payload)); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

func framed(payload []byte) []byte {
	result := make([]byte, 2, len(payload)+2)
	binary.BigEndian.PutUint16(result, uint16(len(payload)))
	return append(result, payload...)
}

func capture(t *testing.T, packets ...[]byte) []byte {
	t.Helper()
	var output bytes.Buffer
	writer := pcapgo.NewWriter(&output)
	if err := writer.WriteFileHeader(65535, layers.LinkTypeEthernet); err != nil {
		t.Fatal(err)
	}
	for i, packet := range packets {
		info := gopacket.CaptureInfo{Timestamp: time.UnixMilli(1700000000100 + int64(i)), CaptureLength: len(packet), Length: len(packet)}
		if err := writer.WritePacket(info, packet); err != nil {
			t.Fatal(err)
		}
	}
	return output.Bytes()
}

func TestDNSCaptureIPv4IPv6UDPTCPAndRedaction(t *testing.T) {
	config := fixtureConfig()
	name := queryName(config.Phases[0].Nonce)
	for _, v6 := range []bool{false, true} {
		for _, tcp := range []bool{false, true} {
			query, reply := dnsPayload(t, name, false), dnsPayload(t, name, true)
			if tcp {
				query, reply = framed(query), framed(reply)
			}
			r := analyze(bytes.NewReader(capture(t, networkPacket(t, v6, tcp, false, false, query), networkPacket(t, v6, tcp, true, false, reply))), config)
			if r.Status != "PARSED" || r.DNSMessages != 2 || r.PhaseObservation[0].MarkerQueries != 1 || r.PhaseObservation[0].MarkerNXDomain != 1 || r.PhaseObservation[0].PacketsInWindow != 2 {
				t.Fatalf("valid query/reply was not observed: %s", r.Reason)
			}
			encoded, _ := json.Marshal(r)
			for _, forbidden := range []string{config.Phases[0].Nonce, name, "192.0.2.1", "2001:db8"} {
				if strings.Contains(string(encoded), forbidden) {
					t.Fatal("raw address or nonce escaped report")
				}
			}
		}
	}
}

func TestDNSCaptureControlsAndBoundaries(t *testing.T) {
	config := fixtureConfig()
	name := queryName(config.Phases[0].Nonce)
	syn := networkPacket(t, false, true, false, true, nil)
	r := analyze(bytes.NewReader(capture(t, syn)), config)
	if r.Status != "PARSED" || r.TCP53Packets != 1 || r.DNSMessages != 0 || r.PhaseObservation[0].TCP53SYNInWindow != 1 {
		t.Fatal("TCP SYN is visibility control, not DNS payload proof")
	}
	unrelated := networkPacket(t, false, false, false, false, dnsPayload(t, "unrelated.example.com", false))
	r = analyze(bytes.NewReader(capture(t, unrelated)), config)
	if r.Status != "PARSED" || r.PhaseObservation[0].MarkerQueries != 0 {
		t.Fatal("unrelated DNS was attributed to nonce")
	}
	config.Phases[0].EndUnixMs = 1700000000050
	r = analyze(bytes.NewReader(capture(t, networkPacket(t, false, false, false, false, dnsPayload(t, name, false)))), config)
	if r.Status != "INDETERMINATE" || r.Reason != "marker_outside_phase_clock_window" {
		t.Fatal("clock mismatch was accepted")
	}
	config = fixtureConfig()
	config.Phases = append(config.Phases, config.Phases[0])
	if validate(config) == nil {
		t.Fatal("reused nonce or overlapping phases accepted")
	}
	config = fixtureConfig()
	config.Phases = append(config.Phases, phase{ID: "normal", Nonce: strings.Repeat("f", 32), StartUnixMs: config.Phases[0].EndUnixMs, EndUnixMs: config.Phases[0].EndUnixMs + 1000})
	if validate(config) == nil {
		t.Fatal("inclusive phase boundaries must not share a timestamp")
	}
}

func TestDNSCaptureMalformedTransportAndBoundedPhaseFile(t *testing.T) {
	config := fixtureConfig()
	name := queryName(config.Phases[0].Nonce)
	udp := networkPacket(t, false, false, false, false, dnsPayload(t, name, false))
	for _, length := range []uint16{7, 8, 65535} {
		packet := append([]byte(nil), udp...)
		binary.BigEndian.PutUint16(packet[14+20+4:14+20+6], length)
		if result := analyze(bytes.NewReader(capture(t, packet)), config); result.Status != "INDETERMINATE" || (result.Reason != "malformed_udp_transport" && result.Reason != "truncated_network_packet") {
			t.Fatalf("malformed UDP length classification: %s/%s", result.Status, result.Reason)
		}
	}
	tcp := networkPacket(t, false, true, false, true, nil)
	tcp[14+20+12] = 0xf0 // Data offset claims more TCP header than is captured.
	if result := analyze(bytes.NewReader(capture(t, tcp)), config); result.Status != "INDETERMINATE" || (result.Reason != "malformed_tcp_transport" && result.Reason != "truncated_network_packet") {
		t.Fatalf("malformed TCP header classification: %s/%s", result.Status, result.Reason)
	}
	for _, ipv6 := range []bool{false, true} {
		packet := networkPacket(t, ipv6, false, false, false, dnsPayload(t, name, false))
		offset := 14 + 2 // IPv4 total length.
		if ipv6 {
			offset = 14 + 4 // IPv6 payload length.
		}
		binary.BigEndian.PutUint16(packet[offset:offset+2], binary.BigEndian.Uint16(packet[offset:offset+2])+100)
		if result := analyze(bytes.NewReader(capture(t, packet)), config); result.Status != "INDETERMINATE" || result.Reason != "truncated_network_packet" {
			t.Fatalf("advertised IP length classification: %s/%s", result.Status, result.Reason)
		}
	}
	unrelatedTLS := networkPacket(t, false, true, false, false, []byte{0x16, 0x03, 0x03, 0x00, 0x10, 0x01})
	binary.BigEndian.PutUint16(unrelatedTLS[14+20:14+20+2], 35000)
	binary.BigEndian.PutUint16(unrelatedTLS[14+20+2:14+20+4], 443)
	if result := analyze(bytes.NewReader(capture(t, unrelatedTLS)), config); result.Status != "PARSED" || result.DNSMessages != 0 {
		t.Fatalf("unrelated split TLS record affected DNS decoding: %s/%s", result.Status, result.Reason)
	}
	directory := filepath.Join(t.TempDir(), ".private")
	if err := os.Mkdir(directory, 0700); err != nil {
		t.Fatal(err)
	}
	pcapPath, phasesPath := filepath.Join(directory, "fixture.pcap"), filepath.Join(directory, "phases.json")
	data := capture(t, udp)
	configData, _ := json.Marshal(config)
	if err := os.WriteFile(pcapPath, data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(phasesPath, configData, 0600); err != nil {
		t.Fatal(err)
	}
	r := run(pcapPath, phasesPath)
	if r.Status != "PARSED" || len(r.CaptureSHA256) != 64 {
		t.Fatal("bounded immutable capture snapshot failed")
	}
	if err := os.WriteFile(phasesPath, append(configData, bytes.Repeat([]byte{' '}, 1<<20)...), 0600); err != nil {
		t.Fatal(err)
	}
	if run(pcapPath, phasesPath).Reason != "phase_input_limit" {
		t.Fatal("valid JSON prefix hid an oversized phase file")
	}
}

func TestDNSCaptureRejectsIncompleteAmbiguousInputs(t *testing.T) {
	config := fixtureConfig()
	payload := framed(dnsPayload(t, queryName(config.Phases[0].Nonce), false))
	valid := capture(t, networkPacket(t, false, true, false, false, payload))
	for _, input := range [][]byte{nil, valid[:12], valid[:len(valid)-1], capture(t)} {
		if analyze(bytes.NewReader(input), config).Status != "INDETERMINATE" {
			t.Fatal("incomplete capture accepted")
		}
	}
	for _, part := range [][]byte{payload[:1], payload[:len(payload)-1], payload[5:]} {
		r := analyze(bytes.NewReader(capture(t, networkPacket(t, false, true, false, false, part))), config)
		if r.Status != "INDETERMINATE" || r.Reason != "tcp_dns_requires_reassembly" {
			t.Fatal("segmented TCP must not become zero leaks")
		}
	}
	r := analyze(bytes.NewReader(capture(t, networkPacket(t, false, false, false, false, []byte{1, 2, 3}))), config)
	if r.Status != "INDETERMINATE" || r.Reason != "malformed_dns_message" {
		t.Fatal("malformed DNS accepted")
	}
	// A clipped frame retains a larger original packet length in its header.
	clipped := append([]byte(nil), valid...)
	binary.LittleEndian.PutUint32(clipped[36:40], binary.LittleEndian.Uint32(clipped[36:40])+1)
	if analyze(bytes.NewReader(clipped), config).Reason != "truncated_packet" {
		t.Fatal("truncated frame accepted")
	}
}
