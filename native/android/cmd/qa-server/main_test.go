// SPDX-License-Identifier: Apache-2.0
package main

import "testing"

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
