// SPDX-License-Identifier: Apache-2.0
package service

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

func dnsQuestion(kind dnsmessage.Type) dnsmessage.Question {
	return dnsmessage.Question{Name: dnsmessage.MustNewName("vpn.example."), Type: kind, Class: dnsmessage.ClassINET}
}
func dnsAddress(owner, address string, ttl uint32) dnsmessage.Resource {
	addr := netip.MustParseAddr(address)
	resource := dnsmessage.Resource{Header: dnsmessage.ResourceHeader{Name: dnsmessage.MustNewName(owner), Class: dnsmessage.ClassINET, TTL: ttl}}
	if addr.Is4() {
		resource.Header.Type = dnsmessage.TypeA
		resource.Body = &dnsmessage.AResource{A: addr.As4()}
	} else {
		resource.Header.Type = dnsmessage.TypeAAAA
		resource.Body = &dnsmessage.AAAAResource{AAAA: addr.As16()}
	}
	return resource
}
func dnsAlias(owner, target string, ttl uint32) dnsmessage.Resource {
	return dnsmessage.Resource{Header: dnsmessage.ResourceHeader{Name: dnsmessage.MustNewName(owner), Type: dnsmessage.TypeCNAME, Class: dnsmessage.ClassINET, TTL: ttl}, Body: &dnsmessage.CNAMEResource{CNAME: dnsmessage.MustNewName(target)}}
}
func dnsResponse(question dnsmessage.Question, answers ...dnsmessage.Resource) dnsmessage.Message {
	return dnsmessage.Message{Header: dnsmessage.Header{Response: true, RecursionAvailable: true}, Questions: []dnsmessage.Question{question}, Answers: answers}
}
func packDNS(t *testing.T, message dnsmessage.Message) []byte {
	t.Helper()
	wire, err := message.Pack()
	if err != nil {
		t.Fatal(err)
	}
	return wire
}

func TestBootstrapAnswersFollowOnlyBoundedQuestionChain(t *testing.T) {
	question := dnsQuestion(dnsmessage.TypeA)
	message := dnsResponse(question,
		dnsAddress("unrelated.example.", "203.0.113.99", 1),
		dnsAlias("vpn.example.", "edge.example.", 20),
		dnsAddress("edge.example.", "198.51.100.4", 120),
		dnsAddress("edge.example.", "198.51.100.4", 60),
	)
	message.Additionals = []dnsmessage.Resource{dnsAddress("vpn.example.", "127.0.0.1", 0)}
	addresses, ttl, err := parseEndpointAnswer(packDNS(t, message), question)
	if err != nil || len(addresses) != 1 || addresses[0].String() != "198.51.100.4" || ttl != 20 {
		t.Fatalf("Unexpected bound response: %v %d %v", addresses, ttl, err)
	}
	message = dnsResponse(dnsQuestion(dnsmessage.TypeAAAA), dnsAddress("vpn.example.", "::ffff:198.51.100.5", 0))
	addresses, ttl, err = parseEndpointAnswer(packDNS(t, message), message.Questions[0])
	if err != nil || len(addresses) != 1 || !addresses[0].Is4() || ttl != 0 {
		t.Fatal("Mapped IPv4 or zero TTL mishandled")
	}
	message = dnsResponse(question)
	addresses, _, err = parseEndpointAnswer(packDNS(t, message), question)
	if err != nil || len(addresses) != 0 {
		t.Fatal("Valid empty family response rejected")
	}
}

func TestBootstrapRejectsPoisonedAndMalformedAnswers(t *testing.T) {
	question := dnsQuestion(dnsmessage.TypeA)
	mutations := map[string]func(*dnsmessage.Message){
		"request":        func(m *dnsmessage.Message) { m.Response = false },
		"id":             func(m *dnsmessage.Message) { m.ID = 8 },
		"opcode":         func(m *dnsmessage.Message) { m.OpCode = 1 },
		"truncated":      func(m *dnsmessage.Message) { m.Truncated = true },
		"nxdomain":       func(m *dnsmessage.Message) { m.RCode = dnsmessage.RCodeNameError },
		"wrong_question": func(m *dnsmessage.Message) { m.Questions[0].Name = dnsmessage.MustNewName("attacker.example.") },
		"wrong_type":     func(m *dnsmessage.Message) { m.Questions[0].Type = dnsmessage.TypeAAAA },
		"wrong_class":    func(m *dnsmessage.Message) { m.Questions[0].Class = dnsmessage.ClassCHAOS },
		"two_questions":  func(m *dnsmessage.Message) { m.Questions = append(m.Questions, question) },
		"answer_class":   func(m *dnsmessage.Message) { m.Answers[0].Header.Class = dnsmessage.ClassCHAOS },
		"cname_loop": func(m *dnsmessage.Message) {
			m.Answers = []dnsmessage.Resource{dnsAlias("vpn.example.", "edge.example.", 10), dnsAlias("edge.example.", "vpn.example.", 10)}
		},
		"ambiguous_cname": func(m *dnsmessage.Message) {
			m.Answers = []dnsmessage.Resource{dnsAlias("vpn.example.", "one.example.", 10), dnsAlias("vpn.example.", "two.example.", 10)}
		},
		"cname_with_address": func(m *dnsmessage.Message) {
			m.Answers = append(m.Answers, dnsAlias("vpn.example.", "edge.example.", 10))
		},
	}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			m := dnsResponse(question, dnsAddress("vpn.example.", "198.51.100.4", 60))
			mutate(&m)
			if _, _, err := parseEndpointAnswer(packDNS(t, m), question); err == nil {
				t.Fatal("Accepted malformed response")
			}
		})
	}
	for _, address := range []string{"0.0.0.0", "127.0.0.1", "224.0.0.1", "169.254.1.1", "172.31.255.2", "::", "::1", "ff02::1", "fe80::1", "fd71:6578:7670::2"} {
		t.Run(address, func(t *testing.T) {
			q := question
			if netip.MustParseAddr(address).Is6() {
				q.Type = dnsmessage.TypeAAAA
			}
			m := dnsResponse(q, dnsAddress("vpn.example.", address, 60))
			if _, _, err := parseEndpointAnswer(packDNS(t, m), q); err == nil {
				t.Fatal("Unsafe endpoint accepted")
			}
		})
	}
	for _, address := range []string{"10.12.0.8", "fd12:3456::9"} {
		if !usableEndpointAddress(netip.MustParseAddr(address)) {
			t.Fatal("Private unicast endpoint was silently forbidden")
		}
	}
	wire := packDNS(t, dnsResponse(question))
	binary.BigEndian.PutUint16(wire[6:8], 65535)
	if _, _, err := parseEndpointAnswer(wire, question); err == nil {
		t.Fatal("Unbounded record count")
	}
	for _, invalid := range [][]byte{nil, make([]byte, 65536), {0, 1, 2}, packDNS(t, dnsResponse(question, dnsAddress("vpn.example.", "198.51.100.4", 60)))[:20]} {
		if _, _, err := parseEndpointAnswer(invalid, question); err == nil {
			t.Fatal("Malformed wire accepted")
		}
	}
}

func TestBootstrapBoundsNamesAndAddressCount(t *testing.T) {
	for _, bad := range []string{"", ".", "a..b", "-bad.example", "bad-.example", "localhost/secret", "a\x00b", "*.example", "127.0.0.1", strings.Repeat("x", 64) + ".example", strings.Repeat("a.", 128)} {
		if _, err := endpointName(bad); err == nil {
			t.Fatalf("Accepted invalid name %q", bad)
		}
	}
	if value, err := endpointName("VPN.Example."); err != nil || value != "vpn.example" {
		t.Fatal("Canonical name rejected")
	}
	question := dnsQuestion(dnsmessage.TypeA)
	message := dnsResponse(question)
	for i := byte(1); i <= 17; i++ {
		address := netip.AddrFrom4([4]byte{198, 51, 100, i})
		message.Answers = append(message.Answers, dnsAddress("vpn.example.", address.String(), 60))
	}
	if _, _, err := parseEndpointAnswer(packDNS(t, message), question); err != Code("bootstrap_address_limit") {
		t.Fatal("Address limit not enforced")
	}
}

func TestBootstrapHTTPSAndFailureModes(t *testing.T) {
	for _, mode := range []string{"ok", "wrong_type", "redirect", "oversize", "wrong_question", "empty", "untrusted_tls", "cancelled"} {
		t.Run(mode, func(t *testing.T) {
			var calls atomic.Int32
			server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				if r.Method != "POST" || r.URL.RawQuery != "" || r.Header.Get("Content-Type") != "application/dns-message" || r.Header.Get("Accept") != "application/dns-message" {
					t.Error("Wrong DNS request contract")
					w.WriteHeader(400)
					return
				}
				if mode == "cancelled" {
					select {
					case <-r.Context().Done():
					case <-time.After(time.Second):
					}
					return
				}
				if mode == "redirect" {
					w.Header().Set("Location", "https://unrelated.invalid/")
					w.WriteHeader(302)
					return
				}
				w.Header().Set("Content-Type", "application/dns-message")
				if mode == "wrong_type" {
					w.Header().Set("Content-Type", "application/json")
				}
				if mode == "oversize" {
					_, _ = w.Write(make([]byte, 65536))
					return
				}
				body, _ := io.ReadAll(io.LimitReader(r.Body, 4096))
				var query dnsmessage.Message
				if query.Unpack(body) != nil || len(query.Questions) != 1 {
					w.WriteHeader(400)
					return
				}
				q := query.Questions[0]
				answer := dnsResponse(q)
				if mode != "empty" {
					address := "198.51.100.4"
					if q.Type == dnsmessage.TypeAAAA {
						address = "2001:db8::4"
					}
					answer.Answers = []dnsmessage.Resource{dnsAddress(q.Name.String(), address, 90)}
				}
				if mode == "wrong_question" {
					answer.Questions[0].Name = dnsmessage.MustNewName("attacker.example.")
				}
				_, _ = w.Write(packDNS(t, answer))
			}))
			server.Config.ErrorLog = log.New(io.Discard, "", 0)
			server.StartTLS()
			defer server.Close()
			client := server.Client()
			client.CheckRedirect = func(*http.Request, []*http.Request) error { return Code("bootstrap_redirect_rejected") }
			if mode == "untrusted_tls" {
				client = &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: x509.NewCertPool()}}, Timeout: time.Second}
			}
			ctx := context.Background()
			if mode == "cancelled" {
				var cancel context.CancelFunc
				ctx, cancel = context.WithTimeout(ctx, 30*time.Millisecond)
				defer cancel()
			}
			result, err := resolveEndpointHTTPS(ctx, client, server.URL, "vpn.example")
			if mode == "ok" {
				if err != nil || len(result.addresses) != 2 || result.ttl != 90 || calls.Load() != 2 {
					t.Fatalf("Unexpected valid result: %v", err)
				}
			} else if err == nil {
				t.Fatal("Unsafe response accepted")
			}
		})
	}
}
