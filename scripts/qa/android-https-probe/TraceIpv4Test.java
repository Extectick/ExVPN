// SPDX-License-Identifier: Apache-2.0
package ru.exvpn.netprobe;

/** Runs on the host JVM against synthetic values; performs no network requests. */
public final class TraceIpv4Test {
    public static void main(String[] args) {
        int checked = 0;
        String[] valid = {
            "ip=192.0.2.1",
            "fl=test\nip=192.0.2.1\nloc=ZZ\n",
            "fl=test\r\nip=192.0.2.1\r\nloc=ZZ\r\n",
        };
        for (String trace : valid) {
            if (!"192.0.2.1".equals(TraceIpv4.parse(trace))) throw new AssertionError("valid fixture rejected");
            checked++;
        }
        String[] invalid = {
            null, "", "xip=192.0.2.1", "ip=", "ip=192.0.2.1\nip=192.0.2.1",
            "ip=192.0.2.1\nip=198.51.100.2", "ip=::1", "ip=::ffff:192.0.2.1",
            "ip=192.0.2.256", "ip=192.0.2.-1", "ip=192.0.2.+1", "ip=192.00.2.1",
            "ip=192.0.2", "ip=192.0.2.1.", "ip=192.0.2.1 ", "ip= 192.0.2.1",
            "ip=192.0.2.1\r\r", "ip=192.0.2.1\u0000", "ip=example.invalid", "ip=١٩٢.0.2.1",
            "ip=192.0.2.1\n" + repeat('x', 32768),
        };
        for (String trace : invalid) {
            if (TraceIpv4.parse(trace) != null) throw new AssertionError("invalid fixture accepted");
            checked++;
        }
        System.out.println("TraceIpv4 synthetic fixtures passed: " + checked);
    }

    private static String repeat(char value, int length) {
        char[] chars = new char[length];
        java.util.Arrays.fill(chars, value);
        return new String(chars);
    }
}
