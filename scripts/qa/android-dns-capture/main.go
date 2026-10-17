// SPDX-License-Identifier: Apache-2.0
// Offline QA only. Uses the repository's pinned gopacket; never opens a socket.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/google/gopacket"
	"github.com/google/gopacket/layers"
	"github.com/google/gopacket/pcapgo"
)

const maxCaptureBytes = 32 << 20

type phase struct {
	ID          string `json:"id"`
	Nonce       string `json:"nonce"`
	StartUnixMs int64  `json:"startUnixMs"`
	EndUnixMs   int64  `json:"endUnixMs"`
}

type configuration struct {
	Phases             []phase             `json:"phases"`
	ProtectedIntervals []protectedInterval `json:"protectedIntervals,omitempty"`
}

// Protection spans transitions and gaps between named probe phases. These
// half-open intervals are supplied by the driver's actual VPN-state markers,
// never inferred from a phase name or from successful DNS parsing.
type protectedInterval struct {
	ID                 string `json:"id"`
	StartUnixMs        int64  `json:"startUnixMs"`
	EndExclusiveUnixMs int64  `json:"endExclusiveUnixMs"`
}

type intervalObservation struct {
	ID                         string `json:"id"`
	StartUnixMs                int64  `json:"startUnixMs"`
	EndExclusiveUnixMs         int64  `json:"endExclusiveUnixMs"`
	PacketsInWindow            int    `json:"packetsInWindow"`
	UDP53InWindow              int    `json:"udp53InWindow"`
	TCP53InWindow              int    `json:"tcp53InWindow"`
	TCP53SYNInWindow           int    `json:"tcp53SynInWindow"`
	CaptureBoundsCoverInterval bool   `json:"captureBoundsCoverInterval"`
}

type observation struct {
	ID                  string `json:"id"`
	QuerySHA256         string `json:"querySha256"`
	MarkerQueries       int    `json:"markerQueries"`
	MarkerResponses     int    `json:"markerResponses"`
	MarkerNXDomain      int    `json:"markerNxDomain"`
	MarkerOutsideWindow int    `json:"markerOutsideWindow"`
	PacketsInWindow     int    `json:"packetsInWindow"`
	UDP53InWindow       int    `json:"udp53InWindow"`
	TCP53InWindow       int    `json:"tcp53InWindow"`
	TCP53SYNInWindow    int    `json:"tcp53SynInWindow"`
}

type report struct {
	Status             string                `json:"status"`
	Reason             string                `json:"reason,omitempty"`
	Packets            int                   `json:"packets"`
	IPv4Packets        int                   `json:"ipv4Packets"`
	IPv6Packets        int                   `json:"ipv6Packets"`
	UDP53Packets       int                   `json:"udp53Packets"`
	TCP53Packets       int                   `json:"tcp53Packets"`
	DNSMessages        int                   `json:"dnsMessages"`
	CaptureBytes       int64                 `json:"captureBytes"`
	CaptureSHA256      string                `json:"captureSha256,omitempty"`
	FirstUnixMs        int64                 `json:"firstUnixMs"`
	LastUnixMs         int64                 `json:"lastUnixMs"`
	PhaseObservation   []observation         `json:"phases"`
	ProtectedIntervals []intervalObservation `json:"protectedIntervals,omitempty"`
	DropAccounting     string                `json:"dropAccounting"`
}

var noncePattern = regexp.MustCompile(`^[a-f0-9]{32}$`)
var idPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,30}$`)

func queryName(nonce string) string { return "exvpn-" + nonce + ".example.com" }

func validate(config configuration) error {
	if len(config.Phases) < 1 || len(config.Phases) > 8 {
		return errors.New("phase_count")
	}
	ids, nonces := map[string]bool{}, map[string]bool{}
	var previousEnd int64
	for _, p := range config.Phases {
		if !idPattern.MatchString(p.ID) || !noncePattern.MatchString(p.Nonce) || ids[p.ID] || nonces[p.Nonce] ||
			p.StartUnixMs < 1 || p.EndUnixMs <= p.StartUnixMs || p.EndUnixMs-p.StartUnixMs > 90000 || p.StartUnixMs <= previousEnd {
			return errors.New("phase_schema")
		}
		ids[p.ID], nonces[p.Nonce], previousEnd = true, true, p.EndUnixMs
	}
	if len(config.ProtectedIntervals) > 8 {
		return errors.New("protected_interval_count")
	}
	ids, previousEnd = map[string]bool{}, 0
	for _, p := range config.ProtectedIntervals {
		if !idPattern.MatchString(p.ID) || ids[p.ID] || p.StartUnixMs < 1 ||
			p.EndExclusiveUnixMs <= p.StartUnixMs || p.EndExclusiveUnixMs-p.StartUnixMs > 360000 ||
			p.StartUnixMs < previousEnd {
			return errors.New("protected_interval_schema")
		}
		ids[p.ID], previousEnd = true, p.EndExclusiveUnixMs
	}
	return nil
}

func analyze(reader io.Reader, config configuration) report {
	r := report{Status: "INDETERMINATE", DropAccounting: "classic_pcap_has_no_drop_counter"}
	fail := func(reason string) report { r.Reason = reason; return r }
	if validate(config) != nil {
		return fail("phase_schema")
	}
	for _, p := range config.Phases {
		digest := sha256.Sum256([]byte(queryName(p.Nonce)))
		r.PhaseObservation = append(r.PhaseObservation, observation{ID: p.ID, QuerySHA256: hex.EncodeToString(digest[:])})
	}
	for _, p := range config.ProtectedIntervals {
		r.ProtectedIntervals = append(r.ProtectedIntervals, intervalObservation{
			ID: p.ID, StartUnixMs: p.StartUnixMs, EndExclusiveUnixMs: p.EndExclusiveUnixMs,
		})
	}
	pcap, err := pcapgo.NewReader(io.LimitReader(reader, maxCaptureBytes+1))
	if err != nil || pcap.LinkType() != layers.LinkTypeEthernet || pcap.Snaplen() < 65535 || pcap.Snaplen() > 1<<20 {
		return fail("pcap_format_or_link_type")
	}
	r.CaptureBytes = 24
	for {
		data, capture, err := pcap.ReadPacketData()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fail("incomplete_or_malformed_pcap")
		}
		r.CaptureBytes += int64(16 + len(data))
		r.Packets++
		if r.Packets > 100000 || r.CaptureBytes > maxCaptureBytes {
			return fail("capture_limit")
		}
		if capture.CaptureLength != capture.Length || capture.CaptureLength != len(data) {
			return fail("truncated_packet")
		}
		at := capture.Timestamp.UnixMilli()
		if at <= 0 || (r.LastUnixMs != 0 && at < r.LastUnixMs) {
			return fail("capture_clock_order")
		}
		if r.FirstUnixMs == 0 {
			r.FirstUnixMs = at
		}
		r.LastUnixMs = at
		window := -1
		for i, p := range config.Phases {
			if at >= p.StartUnixMs && at <= p.EndUnixMs {
				r.PhaseObservation[i].PacketsInWindow++
				window = i
			}
		}
		protectedWindow := -1
		for i, p := range config.ProtectedIntervals {
			if at >= p.StartUnixMs && at < p.EndExclusiveUnixMs {
				r.ProtectedIntervals[i].PacketsInWindow++
				protectedWindow = i
			}
		}
		packet := gopacket.NewPacket(data, layers.LayerTypeEthernet, gopacket.DecodeOptions{Lazy: true})
		// Check network truncation before unrelated application decoders (such
		// as a TLS record split across TCP segments) can set the same flag.
		_ = packet.NetworkLayer()
		if packet.Metadata().Truncated && !completeIPv6HopByHop(packet) {
			return fail("truncated_network_packet")
		}
		if packet.Layer(layers.LayerTypeIPv6Fragment) != nil {
			return fail("fragmented_ip_requires_reassembly")
		}
		if layer := packet.Layer(layers.LayerTypeIPv4); layer != nil {
			ip := layer.(*layers.IPv4)
			r.IPv4Packets++
			if ip.FragOffset != 0 || ip.Flags&layers.IPv4MoreFragments != 0 {
				return fail("fragmented_ip_requires_reassembly")
			}
		} else if packet.Layer(layers.LayerTypeIPv6) != nil {
			r.IPv6Packets++
		} else if packet.Layer(layers.LayerTypeARP) != nil {
			continue
		} else {
			return fail("unsupported_or_malformed_network_packet")
		}
		var messages [][]byte
		if layer := packet.Layer(layers.LayerTypeUDP); layer != nil {
			raw := transportBytes(packet, layers.LayerTypeUDP)
			var udp layers.UDP
			if udp.DecodeFromBytes(raw, gopacket.NilDecodeFeedback) != nil || int(udp.Length) != len(raw) || udp.Length < 8 {
				return fail("malformed_udp_transport")
			}
			if udp.SrcPort != 53 && udp.DstPort != 53 {
				continue
			}
			r.UDP53Packets++
			if window >= 0 {
				r.PhaseObservation[window].UDP53InWindow++
			}
			if protectedWindow >= 0 {
				r.ProtectedIntervals[protectedWindow].UDP53InWindow++
			}
			messages = append(messages, udp.Payload)
		} else if layer := packet.Layer(layers.LayerTypeTCP); layer != nil {
			var tcp layers.TCP
			if tcp.DecodeFromBytes(transportBytes(packet, layers.LayerTypeTCP), gopacket.NilDecodeFeedback) != nil {
				return fail("malformed_tcp_transport")
			}
			if tcp.SrcPort != 53 && tcp.DstPort != 53 {
				continue
			}
			r.TCP53Packets++
			if window >= 0 {
				r.PhaseObservation[window].TCP53InWindow++
				if tcp.SYN {
					r.PhaseObservation[window].TCP53SYNInWindow++
				}
			}
			if protectedWindow >= 0 {
				observation := &r.ProtectedIntervals[protectedWindow]
				observation.TCP53InWindow++
				if tcp.SYN {
					observation.TCP53SYNInWindow++
				}
			}
			// DNS-over-TCP is length framed. A segmented payload is deliberately
			// indeterminate; never infer absence from an unparsed stream.
			payload := tcp.Payload
			for len(payload) > 0 {
				if len(payload) < 2 {
					return fail("tcp_dns_requires_reassembly")
				}
				length := int(binary.BigEndian.Uint16(payload[:2]))
				if length < 12 || length > len(payload)-2 {
					return fail("tcp_dns_requires_reassembly")
				}
				messages = append(messages, payload[2:2+length])
				payload = payload[2+length:]
			}
		} else if packet.ErrorLayer() != nil {
			return fail("malformed_network_packet")
		}
		for _, message := range messages {
			var dns layers.DNS
			if dns.DecodeFromBytes(message, gopacket.NilDecodeFeedback) != nil {
				return fail("malformed_dns_message")
			}
			r.DNSMessages++
			for _, question := range dns.Questions {
				for i, p := range config.Phases {
					if !strings.EqualFold(strings.TrimSuffix(string(question.Name), "."), queryName(p.Nonce)) {
						continue
					}
					observation := &r.PhaseObservation[i]
					if at < p.StartUnixMs || at > p.EndUnixMs {
						observation.MarkerOutsideWindow++
					}
					if dns.QR {
						observation.MarkerResponses++
						if dns.ResponseCode == layers.DNSResponseCodeNXDomain {
							observation.MarkerNXDomain++
						}
					} else {
						observation.MarkerQueries++
					}
				}
			}
		}
	}
	if r.Packets == 0 {
		return fail("empty_capture")
	}
	for _, p := range r.PhaseObservation {
		if p.MarkerOutsideWindow != 0 {
			return fail("marker_outside_phase_clock_window")
		}
	}
	for i := range r.ProtectedIntervals {
		p := &r.ProtectedIntervals[i]
		// Bounds coverage is only an observation, not proof of no packet drops,
		// correct state markers, UID ownership or a complete no-leak result.
		p.CaptureBoundsCoverInterval = r.FirstUnixMs <= p.StartUnixMs && r.LastUnixMs >= p.EndExclusiveUnixMs
	}
	// Parsing is not a leak PASS. The driver must also require independent
	// query/egress controls, actual VPN state and phase-specific expectations.
	r.Status = "PARSED"
	return r
}

// Pinned gopacket v1.1.19 subtracts HopByHop.ActualLength from IPv6.Payload
// before comparing it with the original IPv6.Length, falsely setting Truncated.
// Accept that one bookkeeping case only when every original byte and decoded
// boundary agrees. The metadata flag is not cleared; other truncation, jumbo
// packets, malformed extensions and capture/original length failures remain
// failures. Additional extension chains are unsupported by this narrow QA
// exception. Fragment and raw transport validation still run afterwards.
func completeIPv6HopByHop(packet gopacket.Packet) bool {
	ip, ok := packet.NetworkLayer().(*layers.IPv6)
	if !ok || ip.Version != 6 || ip.Length == 0 || ip.NextHeader != layers.IPProtocolIPv6HopByHop || ip.HopByHop == nil {
		return false
	}
	ethernet, ok := packet.LinkLayer().(*layers.Ethernet)
	if !ok || ethernet.EthernetType != layers.EthernetTypeIPv6 {
		return false
	}
	raw := ethernet.LayerPayload()
	if len(raw) != 40+int(ip.Length) || len(ip.LayerContents()) != 40 || !bytes.Equal(ip.LayerContents(), raw[:40]) {
		return false
	}
	hop := ip.HopByHop
	if hop.ActualLength < 8 || hop.ActualLength > int(ip.Length) {
		return false
	}
	switch hop.NextHeader {
	case layers.IPProtocolTCP, layers.IPProtocolUDP, layers.IPProtocolICMPv6, layers.IPProtocolIPv6Fragment:
		// A fragment is allowed only as far as the explicit rejection in analyze.
	default:
		return false
	}
	end := 40 + hop.ActualLength
	if !completeIPv6HopByHopOptions(raw[42:end]) {
		return false
	}
	return len(hop.LayerContents()) == hop.ActualLength &&
		bytes.Equal(hop.LayerContents(), raw[40:end]) &&
		bytes.Equal(hop.LayerPayload(), raw[end:]) &&
		bytes.Equal(ip.LayerPayload(), raw[end:])
}

// gopacket v1.1.19 bounds an option against the remaining IPv6 payload, so a
// malformed TLV can cross the extension boundary into the transport header.
// Inspect only the extension's own option bytes, including single-byte Pad1.
func completeIPv6HopByHopOptions(options []byte) bool {
	if len(options) == 0 {
		return false
	}
	for offset := 0; offset < len(options); {
		if options[offset] == 0 {
			offset++
			continue
		}
		if len(options)-offset < 2 {
			return false
		}
		length := 2 + int(options[offset+1])
		if length > len(options)-offset {
			return false
		}
		offset += length
	}
	return true
}

// The preceding IP/extension decoder owns the original transport bytes. Re-
// decoding those bytes detects a partial TCP/UDP layer even when gopacket has
// already published it alongside ErrorLayer, without rejecting unrelated TLS.
func transportBytes(packet gopacket.Packet, target gopacket.LayerType) []byte {
	var previous gopacket.Layer
	for _, layer := range packet.Layers() {
		if layer.LayerType() == target && previous != nil {
			return previous.LayerPayload()
		}
		previous = layer
	}
	return nil
}

func privatePath(path string) bool {
	abs, err := filepath.Abs(path)
	if err != nil {
		return false
	}
	for _, part := range strings.Split(filepath.ToSlash(abs), "/") {
		if part == ".private" {
			return true
		}
	}
	return false
}

func run(pcapPath, phasesPath string) report {
	failure := func(code string) report { return report{Status: "INDETERMINATE", Reason: code} }
	if !privatePath(pcapPath) || !privatePath(phasesPath) {
		return failure("private_input_paths_required")
	}
	settings, err := os.Open(phasesPath)
	if err != nil {
		return failure("phase_input_unavailable")
	}
	defer settings.Close()
	phaseBytes, err := io.ReadAll(io.LimitReader(settings, (1<<20)+1))
	if err != nil || len(phaseBytes) > 1<<20 {
		return failure("phase_input_limit")
	}
	var config configuration
	decoder := json.NewDecoder(bytes.NewReader(phaseBytes))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&config) != nil || decoder.Decode(new(any)) != io.EOF || validate(config) != nil {
		return failure("phase_schema")
	}
	file, err := os.Open(pcapPath)
	if err != nil {
		return failure("capture_unavailable")
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || info.Size() > maxCaptureBytes {
		return failure("capture_size")
	}
	// One bounded, immutable memory snapshot supplies both parsing and digest;
	// never hash a second file pass that could contain different bytes.
	snapshot, err := io.ReadAll(io.LimitReader(file, maxCaptureBytes+1))
	if err != nil || len(snapshot) > maxCaptureBytes {
		return failure("capture_size_or_read")
	}
	finalInfo, err := file.Stat()
	if err != nil || int64(len(snapshot)) != info.Size() || finalInfo.Size() != info.Size() || !finalInfo.ModTime().Equal(info.ModTime()) {
		return failure("capture_changed_during_read")
	}
	r := analyze(bytes.NewReader(snapshot), config)
	hash := sha256.Sum256(snapshot)
	r.CaptureSHA256 = hex.EncodeToString(hash[:])
	return r
}

func main() {
	pcap := flag.String("pcap", "", "Private classic PCAP file")
	phases := flag.String("phases", "", "Private phase/nonce JSON")
	flag.Parse()
	r := run(*pcap, *phases)
	if flag.NArg() != 0 {
		r = report{Status: "INDETERMINATE", Reason: "unexpected_arguments"}
	}
	encoded, _ := json.Marshal(r)
	fmt.Println(string(encoded))
	if r.Status != "PARSED" {
		os.Exit(1)
	}
}
