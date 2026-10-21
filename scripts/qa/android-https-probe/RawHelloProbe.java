// SPDX-License-Identifier: Apache-2.0
package ru.exvpn.netprobe;

import android.app.Activity;
import android.app.Instrumentation;
import android.net.ConnectivityManager;
import android.net.NetworkCapabilities;
import android.os.Bundle;
import android.os.Process;
import android.os.SystemClock;
import java.io.File;
import java.io.FileInputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.SocketTimeoutException;

/** QA routing observation only; never validates a cryptographic ECH handshake. */
public final class RawHelloProbe extends Instrumentation {
    private String mode;

    @Override public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        mode = arguments == null ? "" : arguments.getString("mode", "");
        start();
    }

    @Override public void onStart() {
        long started = SystemClock.elapsedRealtime();
        Bundle result = new Bundle();
        result.putString("mode", mode);
        result.putBoolean("syntheticRoutingOnly", true);
        result.putBoolean("cryptographicEchAcceptanceTested", false);
        result.putBoolean("explicitNetworkBinding", false);
        result.putBoolean("connected", false);
        result.putBoolean("helloSent", false);
        try {
            if (!mode.equals("control") && !mode.equals("ech-before") &&
                    !mode.equals("ech-after") && !mode.equals("no-sni")) {
                throw new IllegalArgumentException();
            }
            // A fixed private file installed with run-as; no arbitrary input path,
            // host, resolver, protected-network binding or VPN bypass is accepted.
            File fixture = new File(getTargetContext().getFilesDir(), "routing-clienthello.bin");
            long size = fixture.length();
            if (size < 50 || size > 8192) throw new IllegalArgumentException();
            byte[] hello = new byte[(int) size];
            try (FileInputStream input = new FileInputStream(fixture)) {
                int offset = 0;
                while (offset < hello.length) {
                    int count = input.read(hello, offset, hello.length - offset);
                    if (count <= 0) throw new IllegalArgumentException();
                    offset += count;
                }
                if (input.read() != -1) throw new IllegalArgumentException();
            }
            int recordLength = ((hello[3] & 255) << 8) | (hello[4] & 255);
            if (hello[0] != 22 || hello[1] != 3 || hello[5] != 1 ||
                    recordLength != hello.length - 5) throw new IllegalArgumentException();
            try (Socket socket = new Socket()) {
                socket.connect(new InetSocketAddress("1.1.1.1", 443), 6000);
                socket.setSoTimeout(3000);
                result.putBoolean("connected", true);
                socket.getOutputStream().write(hello);
                socket.getOutputStream().flush();
                result.putBoolean("helloSent", true);
                result.putInt("helloBytes", hello.length);
                byte[] response = new byte[1024];
                int count = socket.getInputStream().read(response);
                result.putInt("responseBytes", Math.max(0, count));
                result.putBoolean("responseReceived", count > 0);
            }
        } catch (IllegalArgumentException invalid) {
            result.putString("error", "invalid_fixture");
        } catch (SocketTimeoutException timeout) {
            result.putString("error", "deadline");
        } catch (Exception failure) {
            result.putString("error", "network");
        }
        ConnectivityManager manager = getTargetContext().getSystemService(ConnectivityManager.class);
        NetworkCapabilities capabilities = manager.getNetworkCapabilities(manager.getActiveNetwork());
        result.putBoolean("vpnTransport", capabilities != null && capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN));
        result.putInt("uid", Process.myUid());
        result.putLong("durationMs", SystemClock.elapsedRealtime() - started);
        finish(Activity.RESULT_OK, result);
    }
}
