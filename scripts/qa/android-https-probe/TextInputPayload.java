// SPDX-License-Identifier: Apache-2.0
package ru.exvpn.netprobe;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

/** Bounded, strict UTF-8 input for a QA-only focused-field action. */
final class TextInputPayload {
    static final String FILE_NAME = "qa-text-input.txt";
    static final int MAX_BYTES = 512 * 1024;
    final String text;
    final int length;
    final String sha256;

    static final class Rejected extends Exception {
        final String code;
        Rejected(String code) { super(code); this.code = code; }
    }

    private TextInputPayload(String text, byte[] bytes) {
        this.text = text;
        this.length = bytes.length;
        this.sha256 = hash(bytes);
    }

    static TextInputPayload read(InputStream stream) throws IOException, Rejected {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        byte[] buffer = new byte[4096];
        int count;
        while ((count = stream.read(buffer)) != -1) {
            if (bytes.size() + count > MAX_BYTES) throw new Rejected("payload_too_large");
            bytes.write(buffer, 0, count);
        }
        if (bytes.size() == 0) throw new Rejected("payload_empty");
        byte[] input = bytes.toByteArray();
        String text;
        try {
            text = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(input)).toString();
        } catch (CharacterCodingException invalid) {
            throw new Rejected("payload_invalid_utf8");
        }
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if ((c < 32 && c != '\t' && c != '\r' && c != '\n') || c == 127) {
                throw new Rejected("payload_control_character");
            }
        }
        return new TextInputPayload(text, input);
    }

    static String hash(byte[] bytes) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
            char[] hex = new char[digest.length * 2];
            final char[] alphabet = "0123456789abcdef".toCharArray();
            for (int i = 0; i < digest.length; i++) {
                hex[i * 2] = alphabet[(digest[i] >>> 4) & 15];
                hex[i * 2 + 1] = alphabet[digest[i] & 15];
            }
            return new String(hex);
        } catch (NoSuchAlgorithmException unavailable) {
            throw new IllegalStateException("sha256_unavailable");
        }
    }
}
