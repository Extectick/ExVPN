// SPDX-License-Identifier: Apache-2.0
package ru.exvpn.netprobe;

import android.app.Activity;
import android.app.Instrumentation;
import android.app.UiAutomation;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.accessibility.AccessibilityNodeInfo;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;

/** QA-only semantic control of the ordinary APK. No shell dump or app hook. */
public final class VpnUiProbe extends Instrumentation {
    private String command;
    private String runId;

    @Override public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        command = arguments == null ? null : arguments.getString("command");
        runId = arguments == null ? null : arguments.getString("runId");
        start();
    }

    @Override public void onStart() {
        VpnUiSemantics.Clock clock = new VpnUiSemantics.Clock() {
            public long now() { return SystemClock.elapsedRealtime(); }
            public void pause(long millis) { SystemClock.sleep(millis); }
        };
        // Lazy initialization counts UiAutomation connection time in the total
        // deadline and leaves existing accessibility services running.
        VpnUiSemantics.Reader reader = new VpnUiSemantics.Reader() {
            private UiAutomation automation;
            public VpnUiSemantics.Snapshot read(long deadline) throws Exception {
                if (automation == null) automation = getUiAutomation(
                        UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
                if (automation == null) throw new VpnUiSemantics.Rejected("window_unavailable");
                return readSnapshot(automation, deadline);
            }
        };
        VpnUiSemantics.Result observed = new VpnUiSemantics.Result(command);
        Path owner = null;
        try {
            if (!VpnUiSemantics.validRunId(runId)) {
                observed.status = "invalid_run";
            } else {
                String stat = new String(Files.readAllBytes(Paths.get("/proc/self/stat")), StandardCharsets.US_ASCII);
                String identity = runId + "\n" + android.os.Process.myPid() + "\n" +
                        VpnUiSemantics.processStartTicks(stat) + "\n";
                owner = getTargetContext().getFilesDir().toPath().resolve("qa-vpn-ui-owner.txt");
                Files.write(owner, identity.getBytes(StandardCharsets.US_ASCII));
                observed = VpnUiSemantics.execute(command, reader, clock);
            }
        } catch (Exception ownershipFailure) {
            observed.status = "ownership_error";
        } finally {
            if (owner != null) {
                try { Files.deleteIfExists(owner); }
                catch (Exception cleanupFailure) { observed.status = "ownership_cleanup_failed"; }
            }
        }
        Bundle result = new Bundle();
        result.putString("mechanism", VpnUiSemantics.MECHANISM);
        result.putString("runId", VpnUiSemantics.validRunId(runId) ? runId : "invalid");
        result.putString("command", observed.command);
        result.putString("status", observed.status);
        result.putString("beforePhase", observed.beforePhase);
        result.putString("afterPhase", observed.afterPhase);
        result.putBoolean("actionAttempted", observed.actionAttempted);
        result.putBoolean("actionAccepted", observed.actionAccepted);
        result.putInt("targetCount", observed.targetCount);
        result.putInt("nodesVisited", observed.nodesVisited);
        result.putLong("durationMs", observed.durationMs);
        // Instrumentation finish releases its UiAutomation connection. Nothing
        // is persisted and no lifecycle operation is sent to ExVPN directly.
        finish(Activity.RESULT_OK, result);
    }

    private static VpnUiSemantics.Snapshot readSnapshot(UiAutomation automation, long deadline)
            throws Exception {
        List<AccessibilityNodeInfo> nodes = new ArrayList<>();
        boolean transferred = false;
        try {
            if (SystemClock.elapsedRealtime() >= deadline) throw new VpnUiSemantics.Rejected("deadline");
            AccessibilityNodeInfo root = automation.getRootInActiveWindow();
            if (root == null) return null;
            nodes.add(root);
            String rootPackage = string(root.getPackageName());
            if (!VpnUiSemantics.PACKAGE.equals(rootPackage)) {
                throw new VpnUiSemantics.Rejected("wrong_window_package");
            }
            List<VpnUiSemantics.Node> semantic = new ArrayList<>();
            for (int index = 0; index < nodes.size(); index++) {
                if (SystemClock.elapsedRealtime() >= deadline) throw new VpnUiSemantics.Rejected("deadline");
                AccessibilityNodeInfo node = nodes.get(index);
                semantic.add(describe(node));
                int count = node.getChildCount();
                if (count < 0 || nodes.size() + count > VpnUiSemantics.MAX_NODES) {
                    throw new VpnUiSemantics.Rejected("tree_too_large");
                }
                for (int child = 0; child < count; child++) {
                    if (SystemClock.elapsedRealtime() >= deadline) throw new VpnUiSemantics.Rejected("deadline");
                    AccessibilityNodeInfo next = node.getChild(child);
                    if (next != null) nodes.add(next);
                }
            }
            NativeSnapshot snapshot = new NativeSnapshot(rootPackage, root.getWindowId(), semantic, nodes);
            transferred = true;
            return snapshot;
        } finally {
            if (!transferred) recycle(nodes);
        }
    }

    private static VpnUiSemantics.Node describe(AccessibilityNodeInfo node) {
        boolean click = false;
        for (AccessibilityNodeInfo.AccessibilityAction action : node.getActionList()) {
            if (action.getId() == AccessibilityNodeInfo.ACTION_CLICK) click = true;
        }
        return new VpnUiSemantics.Node(string(node.getPackageName()), string(node.getClassName()),
                string(node.getContentDescription()), string(node.getText()),
                node.isVisibleToUser(), node.isEnabled(), node.isClickable(), click,
                node.isEditable(), node.isPassword());
    }

    private static final class NativeSnapshot extends VpnUiSemantics.Snapshot {
        private final List<AccessibilityNodeInfo> owned;
        NativeSnapshot(String rootPackage, int windowId, List<VpnUiSemantics.Node> semantic,
                List<AccessibilityNodeInfo> owned) {
            super(rootPackage, windowId, semantic);
            this.owned = owned;
        }
        @Override boolean refreshTarget(int index) {
            AccessibilityNodeInfo node = owned.get(index);
            if (!node.refresh() || node.getWindowId() != windowId) return false;
            nodes.set(index, describe(node));
            return true;
        }
        @Override boolean clickTarget(int index) {
            return owned.get(index).performAction(AccessibilityNodeInfo.ACTION_CLICK);
        }
        @Override public void close() { recycle(owned); }
    }

    private static void recycle(List<AccessibilityNodeInfo> nodes) {
        for (AccessibilityNodeInfo node : nodes) node.recycle();
        nodes.clear();
    }
    private static String string(CharSequence value) { return value == null ? "" : value.toString(); }
}
