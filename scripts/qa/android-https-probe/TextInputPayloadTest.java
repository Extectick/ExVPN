// SPDX-License-Identifier: Apache-2.0
package ru.exvpn.netprobe;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** Synthetic host JVM tests; never opens a device or a private input file. */
public final class TextInputPayloadTest {
    private static int checked;

    public static void main(String[] args) throws Exception {
        accept("VExTOi8vc3ludGhldGlj", "VExTOi8vc3ludGhldGlj");
        accept("Тест 🐿\nстрока\r\n\t", "Тест 🐿\nстрока\r\n\t");
        byte[] maximum = new byte[TextInputPayload.MAX_BYTES];
        Arrays.fill(maximum, (byte)'A');
        TextInputPayload full = TextInputPayload.read(new ByteArrayInputStream(maximum));
        if (full.length != maximum.length || !full.sha256.equals(TextInputPayload.hash(maximum))) {
            throw new AssertionError("maximum payload corrupted");
        }
        checked++;
        reject(new byte[0], "payload_empty");
        byte[] tooLarge = Arrays.copyOf(maximum, maximum.length + 1);
        reject(tooLarge, "payload_too_large");
        reject(new byte[] {(byte)0xc0, (byte)0xaf}, "payload_invalid_utf8");
        reject(new byte[] {(byte)0xe2, (byte)0x82}, "payload_invalid_utf8");
        reject(new byte[] {(byte)0xed, (byte)0xa0, (byte)0x80}, "payload_invalid_utf8");
        reject(new byte[] {(byte)0x80}, "payload_invalid_utf8");
        reject(new byte[] {'a', 0, 'b'}, "payload_control_character");
        reject(new byte[] {'a', 27, 'b'}, "payload_control_character");
        reject(new byte[] {'a', 127, 'b'}, "payload_control_character");
        // A streaming producer cannot evade the limit with small reads.
        final int[] reads = {0};
        InputStream endless = new InputStream() {
            @Override public int read() { reads[0]++; return 'A'; }
        };
        try {
            TextInputPayload.read(endless);
            throw new AssertionError("unbounded stream accepted");
        } catch (TextInputPayload.Rejected rejected) {
            if (!"payload_too_large".equals(rejected.code) || reads[0] > maximum.length + 4096) {
                throw new AssertionError("stream limit not enforced");
            }
        }
        checked++;
        if (!TextInputPayload.hash("abc".getBytes(StandardCharsets.UTF_8)).equals(
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")) {
            throw new AssertionError("SHA-256 mismatch");
        }
        checked++;
        System.out.println("TextInputPayload synthetic checks passed: " + checked);
    }

    private static void accept(String input, String expected) throws Exception {
        byte[] bytes = input.getBytes(StandardCharsets.UTF_8);
        TextInputPayload value = TextInputPayload.read(new ByteArrayInputStream(bytes));
        if (!value.text.equals(expected) || value.length != bytes.length || value.sha256.length() != 64) {
            throw new AssertionError("valid UTF-8 input changed");
        }
        checked++;
    }

    private static void reject(byte[] input, String code) throws Exception {
        try {
            TextInputPayload.read(new ByteArrayInputStream(input));
            throw new AssertionError("invalid input accepted");
        } catch (TextInputPayload.Rejected rejected) {
            if (!code.equals(rejected.code)) throw new AssertionError("wrong rejection code");
        }
        checked++;
    }
}
