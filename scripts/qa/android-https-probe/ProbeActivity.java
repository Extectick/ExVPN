// SPDX-License-Identifier: Apache-2.0
package ru.exvpn.netprobe;

import android.app.Activity;
import android.os.Bundle;
import android.widget.TextView;

/** Launcher entry makes this QA package selectable in the exclusion picker. */
public final class ProbeActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView label = new TextView(this);
        label.setText("ExVPN network QA probe. Requests run only through explicit instrumentation.");
        label.setPadding(32, 32, 32, 32);
        setContentView(label);
    }
}
