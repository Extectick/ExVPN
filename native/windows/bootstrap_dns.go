// SPDX-License-Identifier: Apache-2.0
package service

import (
	"bytes"
	"context"
	"encoding/binary"
	"io"
	"mime"
	"net/http"
	"net/netip"
	"strings"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

const bootstrapURL = "https://cloudflare-dns.com/dns-query"
const bootstrapTLSName = "cloudflare-dns.com"
const maxBootstrapAddresses = 16

var bootstrapResolverIP = netip.MustParseAddr("1.1.1.1")

type endpointResolution struct {
	name      string
	addresses []netip.Addr
	// Informational minimum authoritative TTL. Results are never cached across
	// connection attempts; one core lifetime receives one immutable snapshot.
	ttl uint32
}

func endpointName(name string) (string, error) {
	name = strings.ToLower(strings.TrimSuffix(name, "."))
	if len(name) == 0 || len(name) > 253 {
		return "", Code("bootstrap_name_invalid")
	}
	if _, err := netip.ParseAddr(name); err == nil {
		return "", Code("bootstrap_name_invalid")
	}
	for _, label := range strings.Split(name, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return "", Code("bootstrap_name_invalid")
		}
		for _, ch := range label {
			if !(ch >= 'a' && ch <= 'z' || ch >= '0' && ch <= '9' || ch == '-') {
				return "", Code("bootstrap_name_invalid")
			}
		}
	}
	return name, nil
}

func usableEndpointAddress(address netip.Addr) bool {
	address = address.Unmap()
	return address.IsValid() && address.Zone() == "" && address.IsGlobalUnicast() &&
		!address.IsLoopback() && !address.IsLinkLocalUnicast() &&
		!netip.MustParsePrefix("172.31.255.0/30").Contains(address) &&
		!netip.MustParsePrefix("fd71:6578:7670::/126").Contains(address)
}

// Only the endpoint of the selected, validated profile reaches this helper.
// IPC exposes neither a resolver URL nor a generic DNS query method.
func resolveEndpointHTTPS(ctx context.Context, client *http.Client, endpoint, name string) (endpointResolution, error) {
	canonical, err := endpointName(name)
	if err != nil {
		return endpointResolution{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	result := endpointResolution{name: canonical, ttl: ^uint32(0)}
	seen := map[netip.Addr]bool{}
	for _, kind := range []dnsmessage.Type{dnsmessage.TypeA, dnsmessage.TypeAAAA} {
		question := dnsmessage.Question{Name: dnsmessage.MustNewName(canonical + "."), Type: kind, Class: dnsmessage.ClassINET}
		wire, err := (&dnsmessage.Message{Header: dnsmessage.Header{RecursionDesired: true}, Questions: []dnsmessage.Question{question}}).Pack()
		if err != nil {
			return endpointResolution{}, Code("bootstrap_query_invalid")
		}
		request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(wire))
		if err != nil {
			return endpointResolution{}, Code("bootstrap_query_invalid")
		}
		request.Header.Set("Content-Type", "application/dns-message")
		request.Header.Set("Accept", "application/dns-message")
		response, err := client.Do(request)
		if err != nil {
			return endpointResolution{}, Code("bootstrap_https_failed")
		}
		body, readErr := io.ReadAll(io.LimitReader(response.Body, 65536))
		_ = response.Body.Close()
		media, _, mediaErr := mime.ParseMediaType(response.Header.Get("Content-Type"))
		if response.StatusCode != http.StatusOK || mediaErr != nil || media != "application/dns-message" || response.Header.Get("Content-Encoding") != "" || readErr != nil || len(body) > 65535 {
			return endpointResolution{}, Code("bootstrap_response_invalid")
		}
		addresses, ttl, err := parseEndpointAnswer(body, question)
		if err != nil {
			return endpointResolution{}, err
		}
		for _, address := range addresses {
			if !seen[address] {
				seen[address] = true
				result.addresses = append(result.addresses, address)
			}
		}
		if len(result.addresses) > maxBootstrapAddresses {
			return endpointResolution{}, Code("bootstrap_address_limit")
		}
		if len(addresses) > 0 && ttl < result.ttl {
			result.ttl = ttl
		}
	}
	if ctx.Err() != nil {
		return endpointResolution{}, Code("cancelled")
	}
	if len(result.addresses) == 0 {
		return endpointResolution{}, Code("bootstrap_no_addresses")
	}
	return result, nil
}

func parseEndpointAnswer(wire []byte, question dnsmessage.Question) ([]netip.Addr, uint32, error) {
	invalid := Code("bootstrap_dns_invalid")
	if len(wire) < 12 || len(wire) > 65535 || binary.BigEndian.Uint16(wire[4:6]) != 1 {
		return nil, 0, invalid
	}
	answers, authorities, additional := int(binary.BigEndian.Uint16(wire[6:8])), int(binary.BigEndian.Uint16(wire[8:10])), int(binary.BigEndian.Uint16(wire[10:12]))
	if answers > 48 || authorities > 16 || additional > 16 || answers+authorities+additional > 64 {
		return nil, 0, invalid
	}
	var message dnsmessage.Message
	if message.Unpack(wire) != nil || !message.Response || message.ID != 0 || message.OpCode != 0 || message.Truncated || message.RCode != dnsmessage.RCodeSuccess || len(message.Questions) != 1 {
		return nil, 0, invalid
	}
	q := message.Questions[0]
	if !strings.EqualFold(q.Name.String(), question.Name.String()) || q.Type != question.Type || q.Class != dnsmessage.ClassINET {
		return nil, 0, invalid
	}
	aliases := map[string]string{}
	aliasTTLs := map[string]uint32{}
	type addressRecord struct {
		value netip.Addr
		ttl   uint32
	}
	records := map[string][]addressRecord{}
	for _, answer := range message.Answers {
		if answer.Header.Class != dnsmessage.ClassINET {
			return nil, 0, invalid
		}
		owner, err := endpointName(answer.Header.Name.String())
		if err != nil {
			return nil, 0, invalid
		}
		switch value := answer.Body.(type) {
		case *dnsmessage.CNAMEResource:
			target, err := endpointName(value.CNAME.String())
			if err != nil {
				return nil, 0, invalid
			}
			if previous, exists := aliases[owner]; exists && previous != target {
				return nil, 0, invalid
			}
			if ttl, exists := aliasTTLs[owner]; !exists || answer.Header.TTL < ttl {
				aliasTTLs[owner] = answer.Header.TTL
			}
			aliases[owner] = target
		case *dnsmessage.AResource:
			if question.Type == dnsmessage.TypeA {
				records[owner] = append(records[owner], addressRecord{netip.AddrFrom4(value.A), answer.Header.TTL})
			}
		case *dnsmessage.AAAAResource:
			if question.Type == dnsmessage.TypeAAAA {
				records[owner] = append(records[owner], addressRecord{netip.AddrFrom16(value.AAAA).Unmap(), answer.Header.TTL})
			}
		}
	}
	name, _ := endpointName(question.Name.String())
	ttl := ^uint32(0)
	visited := map[string]bool{}
	for depth := 0; ; depth++ {
		if visited[name] || depth > 8 {
			return nil, 0, invalid
		}
		visited[name] = true
		target, alias := aliases[name]
		if !alias {
			break
		}
		if len(records[name]) > 0 {
			return nil, 0, invalid
		}
		if aliasTTLs[name] < ttl {
			ttl = aliasTTLs[name]
		}
		name = target
	}
	var addresses []netip.Addr
	seen := map[netip.Addr]bool{}
	for _, record := range records[name] {
		if !usableEndpointAddress(record.value) {
			return nil, 0, Code("bootstrap_address_rejected")
		}
		if record.ttl < ttl {
			ttl = record.ttl
		}
		if !seen[record.value] {
			seen[record.value] = true
			addresses = append(addresses, record.value)
		}
		if len(addresses) > maxBootstrapAddresses {
			return nil, 0, Code("bootstrap_address_limit")
		}
	}
	// Only answers connected to the original question are used. Additional and
	// unrelated answer records cannot inject endpoint addresses or host mappings.
	return addresses, ttl, nil
}
