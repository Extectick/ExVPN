// SPDX-License-Identifier: Apache-2.0
package ru.exvpn.netprobe;

/** Pure host fixtures: never issues a DNS query or prints a runtime nonce. */
public final class DnsNonceTest {
    public static void main(String[] args) {
        int checked = 0;
        String first = DnsNonce.name("0123456789abcdef0123456789abcdef");
        String second = DnsNonce.name("fedcba9876543210fedcba9876543210");
        if (!"exvpn-0123456789abcdef0123456789abcdef.example.com".equals(first)
                || first.equals(second) || first.length() > 253 || first.split("\\.")[0].length() > 63) {
            throw new AssertionError("fixed nonce domain contract failed");
        }
        checked++;
        if (!"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad".equals(DnsNonce.sha256("abc"))
                || DnsNonce.sha256(first).equals(DnsNonce.sha256(second))) {
            throw new AssertionError("nonce digest contract failed");
        }
        checked++;
        for (String invalid : new String[] {null, "", "0123456789abcdef0123456789abcde", "0123456789abcdef0123456789abcdef0",
                "0123456789ABCDEF0123456789ABCDEF", "0123456789abcdef0123456789abcdef.example.com", "../0123456789abcdef0123456789abcde",
                "0123456789abcdef0123456789abcdeg", "0123456789abcdef0123456789abcde\n", "0123456789abcdef0123456789abcde\0"}) {
            if (DnsNonce.name(invalid) != null) throw new AssertionError("invalid nonce accepted");
            checked++;
        }
        System.out.println("DnsNonce synthetic fixtures passed: " + checked);
    }
}
