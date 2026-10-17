// SPDX-License-Identifier: Apache-2.0
package ru.exvpn.netprobe;

import java.util.List;

/** Pure policy and one-action state machine for the ordinary ExVPN UI. */
final class VpnUiSemantics {
    static final String MECHANISM = "instrumentation_semantics_v1";
    static final String PACKAGE = "ru.exvpn.exvpn";
    static final int MAX_NODES = 2048;
    static final long TOTAL_MS = 30000, READY_MS = 3000, READBACK_MS = 20000;

    interface Clock { long now(); void pause(long millis); }
    interface Reader { Snapshot read(long deadline) throws Exception; }

    static final class Node {
        final String packageName, className, description, text;
        final boolean visible, enabled, clickable, clickAction, editable, password;
        Node(String packageName, String className, String description, String text,
                boolean visible, boolean enabled, boolean clickable, boolean clickAction,
                boolean editable, boolean password) {
            this.packageName = packageName; this.className = className;
            this.description = description; this.text = text;
            this.visible = visible; this.enabled = enabled; this.clickable = clickable;
            this.clickAction = clickAction; this.editable = editable; this.password = password;
        }
        boolean has(String label) { return label.equals(description) || label.equals(text); }
        boolean isButton() {
            return PACKAGE.equals(packageName) && "android.widget.Button".equals(className) &&
                    visible && enabled && clickable && clickAction && !editable && !password;
        }
    }

    abstract static class Snapshot implements AutoCloseable {
        final String rootPackage;
        final int windowId;
        final List<Node> nodes;
        Snapshot(String rootPackage, int windowId, List<Node> nodes) {
            this.rootPackage = rootPackage; this.windowId = windowId; this.nodes = nodes;
        }
        // The implementation replaces nodes[index] with the refreshed attributes.
        abstract boolean refreshTarget(int index) throws Exception;
        abstract boolean clickTarget(int index) throws Exception;
        @Override public abstract void close();
    }

    static final class Rejected extends Exception {
        final String code;
        Rejected(String code) { super(code); this.code = code; }
    }

    static final class Selection {
        final String phase, button;
        final int index;
        Selection(String phase, String button, int index) {
            this.phase = phase; this.button = button; this.index = index;
        }
    }

    static final class Result {
        final String command;
        String status = "accessibility_error", beforePhase = "unknown", afterPhase = "unknown";
        boolean actionAttempted, actionAccepted;
        int targetCount, nodesVisited;
        long durationMs;
        Result(String command) {
            this.command = validCommand(command) ? command : "invalid";
        }
    }

    static boolean validCommand(String command) {
        return "observe".equals(command) || "connect".equals(command) || "disconnect".equals(command);
    }

    static boolean validRunId(String value) {
        return value != null && value.matches("[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}") &&
                !"00000000-0000-0000-0000-000000000000".equals(value);
    }

    static String processStartTicks(String stat) {
        int end = stat.lastIndexOf(')');
        if (end < 0 || stat.length() > 4096) throw new IllegalArgumentException();
        String[] fields = stat.substring(end + 1).trim().split("\\s+");
        if (fields.length <= 19 || !fields[19].matches("[1-9][0-9]{0,18}")) throw new IllegalArgumentException();
        return fields[19];
    }

    static Selection select(Snapshot snapshot) throws Rejected {
        if (snapshot == null) throw new Rejected("window_unavailable");
        if (!PACKAGE.equals(snapshot.rootPackage)) throw new Rejected("wrong_window_package");
        if (snapshot.nodes.size() > MAX_NODES) throw new Rejected("tree_too_large");
        String phase = null, button = null;
        int index = -1, count = 0;
        for (int i = 0; i < snapshot.nodes.size(); i++) {
            Node node = snapshot.nodes.get(i);
            if (!PACKAGE.equals(node.packageName)) continue;
            if (node.visible) {
                if (node.editable || node.password || node.has("Закрыть настройки") ||
                        node.has("Оставить текущий список") || node.has("Закрыть") ||
                        node.has("Отмена")) throw new Rejected("edit_or_dialog_visible");
                String observed = phase(node);
                if (observed != null) {
                    if (phase != null && !phase.equals(observed)) throw new Rejected("phase_conflict");
                    phase = observed;
                }
            }
            String power = power(node);
            if (power != null) { count++; index = i; button = power; }
        }
        if (count > 1) throw new Rejected("ambiguous_target");
        if (count == 0) throw new Rejected("target_missing");
        if (!snapshot.nodes.get(index).isButton()) throw new Rejected("invalid_target");
        if (phase == null) throw new Rejected("phase_unavailable");
        if (("disconnected".equals(phase) && !"connect".equals(button)) ||
                (("connected".equals(phase) || "reconnecting".equals(phase) ||
                  "blocked".equals(phase)) && !"disconnect".equals(button)) ||
                (("connecting".equals(phase) || "requesting_permission".equals(phase)) &&
                 !"cancel".equals(button))) throw new Rejected("phase_conflict");
        return new Selection(phase, button, index);
    }

    private static String power(Node node) throws Rejected {
        return consistent(powerLabel(node.description), powerLabel(node.text));
    }

    private static String powerLabel(String label) {
        if ("Подключить VPN".equals(label)) return "connect";
        if ("Отключить VPN".equals(label)) return "disconnect";
        if ("Отменить VPN".equals(label)) return "cancel";
        return null;
    }

    private static String phase(Node node) throws Rejected {
        return consistent(phaseLabel(node.description), phaseLabel(node.text));
    }

    private static String phaseLabel(String label) {
        if ("Не подключено".equals(label)) return "disconnected";
        if (connectedText(label)) return "connected";
        if ("Подключение…".equals(label)) return "connecting";
        if ("Ожидание разрешения".equals(label)) return "requesting_permission";
        if ("Восстановление соединения…".equals(label)) return "reconnecting";
        if ("Трафик заблокирован".equals(label)) return "blocked";
        if ("Ошибка подключения".equals(label)) return "error";
        return null;
    }

    private static String consistent(String first, String second) throws Rejected {
        if (first != null && second != null && !first.equals(second)) throw new Rejected("phase_conflict");
        return first == null ? second : first;
    }

    private static boolean connectedText(String text) {
        return text != null && text.matches("Подключено · [0-9]{2,6}:[0-5][0-9]:[0-5][0-9]");
    }

    private static boolean transientRead(String code) {
        return "window_unavailable".equals(code) || "target_missing".equals(code) ||
                "phase_unavailable".equals(code);
    }

    private static void observe(Result result, Snapshot snapshot, Selection selection, boolean before) {
        result.nodesVisited = Math.max(result.nodesVisited, snapshot.nodes.size());
        result.targetCount = 1;
        if (before) result.beforePhase = selection.phase;
        else result.afterPhase = selection.phase;
    }

    static Result execute(String command, Reader reader, Clock clock) {
        Result result = new Result(command);
        long started = clock.now(), deadline = started + TOTAL_MS;
        try {
            if (!validCommand(command)) throw new Rejected("invalid_command");
            long readyDeadline = Math.min(deadline, started + READY_MS);
            String initialPhase = null;
            String unavailableCode = "window_unavailable";
            int initialWindow = -1;
            do {
                try (Snapshot snapshot = reader.read(deadline)) {
                    if (clock.now() >= deadline) throw new Rejected("deadline");
                    Selection selection = select(snapshot);
                    observe(result, snapshot, selection, true);
                    initialPhase = selection.phase;
                    initialWindow = snapshot.windowId;
                    break;
                } catch (Rejected unavailable) {
                    if (!transientRead(unavailable.code) || clock.now() >= readyDeadline) throw unavailable;
                    unavailableCode = unavailable.code;
                }
                clock.pause(50);
            } while (clock.now() < readyDeadline);
            if (initialPhase == null) throw new Rejected(unavailableCode);
            if ("observe".equals(command)) {
                result.afterPhase = initialPhase;
                result.status = "observed";
                return result;
            }
            if (("connect".equals(command) && !"disconnected".equals(initialPhase)) ||
                    ("disconnect".equals(command) && !"connected".equals(initialPhase) &&
                     !"reconnecting".equals(initialPhase) && !"blocked".equals(initialPhase))) {
                throw new Rejected("precondition_failed");
            }

            // Never act on the readiness snapshot. Obtain a second root, require
            // the same active window/phase, then refresh the unique target.
            try (Snapshot fresh = reader.read(deadline)) {
                if (clock.now() >= deadline) throw new Rejected("deadline");
                Selection selection = select(fresh);
                if (fresh.windowId != initialWindow || !selection.phase.equals(initialPhase) ||
                        !selection.button.equals(command)) throw new Rejected("stale_target");
                if (!fresh.refreshTarget(selection.index)) throw new Rejected("stale_target");
                Selection refreshed = select(fresh);
                if (refreshed.index != selection.index || !refreshed.phase.equals(initialPhase) ||
                        !refreshed.button.equals(command)) throw new Rejected("stale_target");
                if (clock.now() >= deadline) throw new Rejected("deadline");
                observe(result, fresh, refreshed, true);
                result.actionAttempted = true;
                result.actionAccepted = fresh.clickTarget(refreshed.index);
                if (!result.actionAccepted) throw new Rejected("action_rejected");
            }

            // ACTION_CLICK acceptance is not a completed connection or stop.
            // Only a fresh UI phase is returned here; the host separately checks
            // real HTTPS, native service/PID, tunnel transport and peer closure.
            result.status = "accepted_unconfirmed";
            String expected = "connect".equals(command) ? "connected" : "disconnected";
            long readbackDeadline = Math.min(deadline, clock.now() + READBACK_MS);
            do {
                try (Snapshot snapshot = reader.read(readbackDeadline)) {
                    if (clock.now() >= readbackDeadline) break;
                    Selection selection = select(snapshot);
                    observe(result, snapshot, selection, false);
                    if (expected.equals(selection.phase)) { result.status = "completed"; return result; }
                    if ("error".equals(selection.phase) ||
                            ("connect".equals(command) && "blocked".equals(selection.phase))) {
                        result.status = "terminal_state";
                        return result;
                    }
                } catch (Rejected unavailable) {
                    if (!transientRead(unavailable.code)) throw unavailable;
                }
                clock.pause(50);
            } while (clock.now() < readbackDeadline);
            return result;
        } catch (Rejected rejected) {
            result.status = rejected.code;
        } catch (Exception failure) {
            // Exception strings, node text and provider labels never leave this API.
            result.status = result.actionAttempted ? "action_error" : "accessibility_error";
        } finally {
            result.durationMs = Math.max(0, clock.now() - started);
        }
        return result;
    }
}
