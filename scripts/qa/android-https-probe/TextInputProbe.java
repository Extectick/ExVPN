// SPDX-License-Identifier: Apache-2.0
package ru.exvpn.netprobe;

import android.app.Activity;
import android.app.Instrumentation;
import android.app.UiAutomation;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.accessibility.AccessibilityNodeInfo;
import java.io.File;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.List;

/** QA-only paste into one already-focused ExVPN field; no taps or app hooks. */
public final class TextInputProbe extends Instrumentation {
    private static final String TARGET_PACKAGE = "ru.exvpn.exvpn";
    private static final int MAX_NODES = 2048;
    private String requestedFile;

    @Override public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        requestedFile = arguments == null ? null : arguments.getString("payloadFile");
        start();
    }

    @Override public void onStart() {
        Bundle result = new Bundle();
        result.putString("status", "input_unavailable");
        result.putBoolean("actionAccepted", false);
        File payloadFile = new File(getTargetContext().getFilesDir(), TextInputPayload.FILE_NAME);
        List<AccessibilityNodeInfo> ownedNodes = new ArrayList<>();
        try {
            if (!TextInputPayload.FILE_NAME.equals(requestedFile)) {
                result.putString("status", "invalid_payload_file");
                return;
            }
            TextInputPayload payload;
            // NOFOLLOW_LINKS prevents a staged symlink from selecting another
            // file. There is no caller-controlled path, URI or file descriptor.
            try (InputStream stream = Files.newInputStream(payloadFile.toPath(),
                    StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)) {
                payload = TextInputPayload.read(stream);
            }
            result.putInt("inputLength", payload.length); // UTF-8 bytes, not chars.
            result.putString("inputSha256", payload.sha256);
            UiAutomation automation = getUiAutomation();
            AccessibilityNodeInfo target = waitForFocusedTarget(automation, ownedNodes, result);
            if (target == null) {
                return;
            }
            if (!target.refresh() || !TARGET_PACKAGE.contentEquals(nonNull(target.getPackageName())) ||
                    !target.isFocused() || !target.isEditable() || !target.isEnabled() ||
                    !target.isVisibleToUser() || target.isPassword()) {
                result.putString("status", "target_not_editable");
                return;
            }
            boolean setTextSupported = false;
            for (AccessibilityNodeInfo.AccessibilityAction action : target.getActionList()) {
                if (action.getId() == AccessibilityNodeInfo.ACTION_SET_TEXT) setTextSupported = true;
            }
            if (!setTextSupported) {
                result.putString("status", "set_text_unsupported");
                return;
            }
            Bundle action = new Bundle();
            action.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, payload.text);
            boolean accepted = target.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, action);
            result.putBoolean("actionAccepted", accepted);
            if (!accepted) {
                result.putString("status", "action_rejected");
                return;
            }
            // Acceptance is not equality. Flutter/accessibility may truncate
            // long text or publish semantics asynchronously; never claim a
            // complete paste without an exact byte count and digest readback.
            result.putString("status", "accepted_unverified");
            long readbackDeadline = SystemClock.elapsedRealtime() + 2000;
            do {
                if (!target.refresh() || !TARGET_PACKAGE.contentEquals(nonNull(target.getPackageName())) ||
                        !target.isEditable()) break;
                CharSequence applied = target.getText();
                if (applied != null && applied.length() <= TextInputPayload.MAX_BYTES) {
                    byte[] bytes = applied.toString().getBytes(StandardCharsets.UTF_8);
                    if (bytes.length <= TextInputPayload.MAX_BYTES) {
                        String actualHash = TextInputPayload.hash(bytes);
                        result.putString("appliedSha256", actualHash);
                        if (bytes.length == payload.length && actualHash.equals(payload.sha256)) {
                            result.putString("status", "verified");
                            return;
                        }
                    }
                }
                SystemClock.sleep(50);
            } while (SystemClock.elapsedRealtime() < readbackDeadline);
        } catch (TextInputPayload.Rejected rejected) {
            result.putString("status", rejected.code);
        } catch (Exception failure) {
            // Exceptions can contain paths or text. They are never serialized.
            result.putString("status", "input_or_accessibility_error");
        } finally {
            recycleNodes(ownedNodes);
            // Only this exact QA-owned file is removed, including failed attempts.
            try {
                Files.deleteIfExists(payloadFile.toPath());
            } catch (Exception cleanupFailure) {
                result.putString("status", "payload_cleanup_failed");
            }
            finish(Activity.RESULT_OK, result);
        }
    }

    private AccessibilityNodeInfo waitForFocusedTarget(UiAutomation automation,
            List<AccessibilityNodeInfo> ownedNodes, Bundle result) {
        long deadline = SystemClock.elapsedRealtime() + 2000;
        boolean sawWindow = false;
        // Connecting UiAutomation enables Flutter semantics asynchronously. The
        // first root may exist before its focused editable descendants. Fetch a
        // new snapshot each time; never keep querying an incomplete old root.
        do {
            recycleNodes(ownedNodes);
            AccessibilityNodeInfo root = automation.getRootInActiveWindow();
            if (root != null) {
                ownedNodes.add(root);
                sawWindow = true;
                if (!TARGET_PACKAGE.contentEquals(nonNull(root.getPackageName()))) {
                    result.putString("status", "wrong_window_package");
                    return null;
                }
                AccessibilityNodeInfo target = null;
                for (int index = 0; index < ownedNodes.size(); index++) {
                    AccessibilityNodeInfo node = ownedNodes.get(index);
                    if (node.isFocused() && node.isEditable()) {
                        if (target != null) {
                            result.putString("status", "ambiguous_focus");
                            return null;
                        }
                        target = node;
                    }
                    if (ownedNodes.size() + node.getChildCount() > MAX_NODES) {
                        result.putString("status", "tree_too_large");
                        return null;
                    }
                    for (int child = 0; child < node.getChildCount(); child++) {
                        AccessibilityNodeInfo item = node.getChild(child);
                        if (item != null) ownedNodes.add(item);
                    }
                }
                if (target != null) return target;
            }
            SystemClock.sleep(50);
        } while (SystemClock.elapsedRealtime() < deadline);
        result.putString("status", sawWindow ? "focused_editable_missing" : "window_unavailable");
        return null;
    }

    private static void recycleNodes(List<AccessibilityNodeInfo> nodes) {
        for (AccessibilityNodeInfo node : nodes) node.recycle();
        nodes.clear();
    }

    private static CharSequence nonNull(CharSequence value) {
        return value == null ? "" : value;
    }
}
