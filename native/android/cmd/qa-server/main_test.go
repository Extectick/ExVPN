// SPDX-License-Identifier: Apache-2.0
package main

import (
	"bytes"
	"encoding/json"
	"net/url"
	"testing"

	"github.com/xtls/xray-core/core"
)

func TestFixtureBindingRejectsWildcardRemoteAndMismatchedAddress(t *testing.T) {
	for _, pair := range [][2]string{
		{"0.0.0.0", "0.0.0.0"}, {"::", "::"}, {"::1", "::1"},
		{"224.0.0.1", "224.0.0.1"}, {"169.254.1.2", "169.254.1.2"},
		{"203.0.113.10", "203.0.113.10"}, {"127.0.0.1", "203.0.113.10"},
		{"localhost", "localhost"}, {"", ""},
	} {
		if validFixtureAddress(pair[0], pair[1]) {
			t.Errorf("unsafe fixture binding accepted: %q / %q", pair[0], pair[1])
		}
	}
}

func TestFixtureBindingRetainsAndroidDefaultAndExactLoopback(t *testing.T) {
	if !validFixtureAddress("127.0.0.1", "10.0.2.2") || !validFixtureAddress("127.0.0.1", "127.0.0.1") {
		t.Fatal("local fixture bindings rejected")
	}
}

func TestGRPCH2CFixtureProducesMatchingLocalConfigAndImportURI(t *testing.T) {
	fixture, err := makeFixture("VLESS gRPC", "", "127.0.0.1", "127.0.0.1")
	if err != nil {
		t.Fatal("fixture generation failed")
	}
	link, err := url.Parse(fixture.Link)
	if err != nil || link.Scheme != "vless" || link.Hostname() != "127.0.0.1" || link.User.Username() == "" {
		t.Fatal("invalid local import URI")
	}
	query := link.Query()
	if query.Get("type") != "grpc" || query.Get("serviceName") != "exvpn-qa" || query.Get("security") != "none" {
		t.Fatal("import URI does not describe the h2c fixture")
	}
	stream := fixture.Inbound["streamSettings"].(object)
	if fixture.Inbound["listen"] != "127.0.0.1" || stream["network"] != "grpc" ||
		stream["security"] != "none" || stream["grpcSettings"].(object)["serviceName"] != query.Get("serviceName") {
		t.Fatal("fixture transport and import parameters disagree")
	}
	encoded, err := json.Marshal(object{"inbounds": []any{fixture.Inbound}, "outbounds": []any{object{"protocol": "freedom"}}})
	if err != nil {
		t.Fatal("fixture config encoding failed")
	}
	if _, err = core.LoadConfig("json", bytes.NewReader(encoded)); err != nil {
		t.Fatal("pinned core rejected synthetic gRPC config")
	}
}
