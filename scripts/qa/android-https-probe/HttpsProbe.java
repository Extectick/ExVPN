// SPDX-License-Identifier: Apache-2.0
package ru.exvpn.netprobe;

import android.app.Activity;
import android.app.Instrumentation;
import android.net.ConnectivityManager;
import android.net.InetAddresses;
import android.net.NetworkCapabilities;
import android.net.TrafficStats;
import android.os.Bundle;
import android.os.Process;
import android.os.SystemClock;
import java.io.InputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.net.Inet4Address;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.URL;
import java.security.MessageDigest;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import javax.net.ssl.HttpsURLConnection;

/** Separate-UID QA only. Never reads ExVPN credentials or binds around its VPN. */
public final class HttpsProbe extends Instrumentation {
    private String mode;
    private volatile HttpsURLConnection activeConnection;

    @Override public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        mode = arguments == null ? "health" : arguments.getString("mode", "health");
        start();
    }

    @Override public void onStart() {
        final long started = SystemClock.elapsedRealtime();
        final int uid = Process.myUid();
        final long tx = TrafficStats.getUidTxBytes(uid);
        final long rx = TrafficStats.getUidRxBytes(uid);
        Bundle result = new Bundle();
        ExecutorService executor = Executors.newSingleThreadExecutor(task -> {
            Thread thread = new Thread(task, "exvpn-network-probe");
            thread.setDaemon(true);
            return thread;
        });
        Future<Bundle> pending = executor.submit(this::runProbe);
        try {
            result = pending.get(18, TimeUnit.SECONDS);
        } catch (TimeoutException timeout) {
            result.putString("error", "deadline");
        } catch (Exception failure) {
            result.putString("error", "network");
        } finally {
            pending.cancel(true);
            HttpsURLConnection connection = activeConnection;
            if (connection != null) connection.disconnect();
            executor.shutdownNow();
        }
        ConnectivityManager manager = getTargetContext().getSystemService(ConnectivityManager.class);
        NetworkCapabilities capabilities = manager.getNetworkCapabilities(manager.getActiveNetwork());
        result.putBoolean("vpnTransport", capabilities != null && capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN));
        result.putInt("uid", uid);
        result.putLong("durationMs", SystemClock.elapsedRealtime() - started);
        result.putLong("uidTxBytes", delta(tx, TrafficStats.getUidTxBytes(uid)));
        result.putLong("uidRxBytes", delta(rx, TrafficStats.getUidRxBytes(uid)));
        finish(Activity.RESULT_OK, result);
    }

    private static long delta(long start, long end) {
        return start < 0 || end < 0 ? -1 : Math.max(0, end - start);
    }

    private Bundle runProbe() throws Exception {
        Bundle result = new Bundle();
        if ("dns".equals(mode)) {
            int ipv4 = 0;
            int ipv6 = 0;
            for (InetAddress address : InetAddress.getAllByName("example.com")) {
                if (address instanceof Inet4Address) ipv4++;
                if (address instanceof Inet6Address) ipv6++;
            }
            result.putInt("ipv4Answers", ipv4);
            result.putInt("ipv6Answers", ipv6);
            result.putBoolean("success", ipv4 + ipv6 > 0);
            return result;
        }
        String target;
        switch (mode) {
            case "health": target = "https://www.gstatic.com/generate_204"; break;
            case "ip4": target = "https://api.ipify.org"; break;
            case "ip6": target = "https://api6.ipify.org"; break;
            case "numeric":
            case "trace4": target = "https://1.1.1.1/cdn-cgi/trace"; break;
            default:
                result.putString("error", "unsupported_mode");
                return result;
        }
        HttpsURLConnection connection = (HttpsURLConnection) new URL(target).openConnection();
        activeConnection = connection;
        connection.setConnectTimeout(8000);
        connection.setReadTimeout(8000);
        connection.setInstanceFollowRedirects(false);
        connection.setUseCaches(false);
        connection.setRequestProperty("Connection", "close");
        // Platform trust manager and hostname verifier remain unchanged.
        try {
            int status = connection.getResponseCode();
            result.putInt("httpStatus", status);
            if (status < 200 || status >= 300) {
                result.putString("error", "http_status");
                return result;
            }
            int length = 0;
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            ByteArrayOutputStream ipBody = "ip4".equals(mode) || "ip6".equals(mode) || "trace4".equals(mode) ? new ByteArrayOutputStream() : null;
            try (InputStream body = connection.getInputStream()) {
                byte[] buffer = new byte[4096];
                int read;
                while ((read = body.read(buffer)) != -1) {
                    length += read;
                    if (length > 32768) {
                        result.putString("error", "too_large");
                        return result;
                    }
                    digest.update(buffer, 0, read);
                    if (ipBody != null) ipBody.write(buffer, 0, read);
                }
            }
            StringBuilder hash = new StringBuilder();
            for (byte value : digest.digest()) hash.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
            result.putString("bodySha256", hash.toString());
            result.putInt("responseBytes", length);
            if ("trace4".equals(mode)) {
                String value = TraceIpv4.parse(new String(ipBody.toByteArray(), StandardCharsets.US_ASCII));
                if (value == null) {
                    result.putString("error", "invalid_ip_response");
                    return result;
                }
                StringBuilder ipHash = new StringBuilder();
                for (byte b : MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.US_ASCII))) {
                    ipHash.append(String.format(java.util.Locale.ROOT, "%02x", b & 255));
                }
                result.putString("publicIpSha256", ipHash.toString());
                result.putInt("publicIpFamily", 4);
            } else if (ipBody != null) {
                String value = new String(ipBody.toByteArray(), StandardCharsets.US_ASCII).trim();
                if (!InetAddresses.isNumericAddress(value)) {
                    result.putString("error", "invalid_ip_response");
                    return result;
                }
                result.putInt("publicIpFamily", InetAddresses.parseNumericAddress(value) instanceof Inet6Address ? 6 : 4);
            }
            result.putBoolean("success", "health".equals(mode) ? status == 204 : status == 200);
            return result;
        } finally {
            connection.disconnect();
            activeConnection = null;
        }
    }
}

/** Pure bounded parser so response validation can be tested without networking. */
final class TraceIpv4 {
    private TraceIpv4() {}

    static String parse(String trace) {
        if (trace == null || trace.length() > 32768) return null;
        String value = null;
        for (String line : trace.split("\n", -1)) {
            if (!line.startsWith("ip=")) continue;
            if (value != null) return null;
            value = line.substring(3);
            if (value.endsWith("\r")) value = value.substring(0, value.length() - 1);
            if (value.length() < 7 || value.length() > 15) return null;
            String[] parts = value.split("\\.", -1);
            if (parts.length != 4) return null;
            for (String part : parts) {
                if (!part.matches("0|[1-9][0-9]{0,2}") || Integer.parseInt(part) > 255) return null;
            }
        }
        return value;
    }
}
