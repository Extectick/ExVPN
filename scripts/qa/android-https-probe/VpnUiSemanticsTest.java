// SPDX-License-Identifier: Apache-2.0
package ru.exvpn.netprobe;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Host JVM fixtures: no emulator, network, or Android stubs are executed. */
public final class VpnUiSemanticsTest {
    private static int checks, scenarios;
    private static final String APP = VpnUiSemantics.PACKAGE;
    private static final String CONNECT = "Подключить VPN", DISCONNECT = "Отключить VPN";
    private static final String OFF = "Не подключено", ON = "Подключено · 00:00:01";

    private static final class Clock implements VpnUiSemantics.Clock {
        long time;
        public long now() { return time; }
        public void pause(long millis) { time += millis; }
    }

    private static final class Snapshot extends VpnUiSemantics.Snapshot {
        boolean refresh = true, accepted = true, throwClick, closed;
        int clicks;
        long refreshDelay;
        VpnUiSemantics.Node replacement;
        final Clock clock;
        Snapshot(String pkg, int window, List<VpnUiSemantics.Node> nodes, Clock clock) {
            super(pkg, window, new ArrayList<>(nodes)); this.clock = clock;
        }
        Snapshot copy(Clock clock) {
            Snapshot copy = new Snapshot(rootPackage, windowId, nodes, clock);
            copy.refresh = refresh; copy.accepted = accepted; copy.throwClick = throwClick;
            copy.refreshDelay = refreshDelay; copy.replacement = replacement;
            return copy;
        }
        boolean refreshTarget(int index) {
            clock.time += refreshDelay;
            if (replacement != null) nodes.set(index, replacement);
            return refresh;
        }
        boolean clickTarget(int index) throws Exception {
            clicks++;
            if (throwClick) throw new Exception("synthetic-secret-must-not-be-emitted");
            return accepted;
        }
        public void close() {
            if (closed) throw new AssertionError("double close");
            closed = true;
        }
    }

    private static final class Reader implements VpnUiSemantics.Reader {
        final Clock clock = new Clock();
        final Snapshot[] sequence;
        final List<Snapshot> issued = new ArrayList<>();
        int reads, delayedRead = -1;
        long delay;
        boolean throwRead;
        Reader(Snapshot... sequence) { this.sequence = sequence; }
        public VpnUiSemantics.Snapshot read(long deadline) throws Exception {
            if (throwRead) throw new Exception("synthetic-secret-must-not-be-emitted");
            int index = reads++;
            if (index == delayedRead) clock.time += delay;
            Snapshot template = sequence[Math.min(index, sequence.length - 1)];
            if (template == null) return null;
            Snapshot copy = template.copy(clock);
            issued.add(copy);
            return copy;
        }
        int clicks() { return issued.stream().mapToInt(s -> s.clicks).sum(); }
        void released() {
            for (Snapshot snapshot : issued) check(snapshot.closed, "snapshot leaked");
        }
    }

    private static VpnUiSemantics.Node node(String label, boolean button) {
        return new VpnUiSemantics.Node(APP, button ? "android.widget.Button" : "android.view.View",
                label, "", true, true, button, button, false, false);
    }
    private static Snapshot state(String power, String phase) {
        return new Snapshot(APP, 7, Arrays.asList(node(power, true), node(phase, false)), null);
    }
    private static Snapshot badButton(String pkg, String cls, boolean visible, boolean enabled,
            boolean clickable, boolean action, boolean editable, boolean password) {
        return new Snapshot(APP, 7, Arrays.asList(new VpnUiSemantics.Node(pkg, cls, CONNECT, "",
                visible, enabled, clickable, action, editable, password), node(OFF, false)), null);
    }
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
        checks++;
    }
    private static VpnUiSemantics.Result run(String command, String status, int clicks, Reader reader) {
        VpnUiSemantics.Result result = VpnUiSemantics.execute(command, reader, reader.clock);
        scenarios++;
        check(status.equals(result.status), "expected " + status + ", got " + result.status);
        check(reader.clicks() == clicks, "unexpected action count");
        check(!result.actionAccepted || result.actionAttempted, "accepted without action");
        reader.released();
        return result;
    }
    private static void reject(String status, Snapshot snapshot) {
        run("connect", status, 0, new Reader(snapshot));
    }

    public static void main(String[] args) {
        check(VpnUiSemantics.validRunId("12345678-1234-1234-1234-123456789abc"), "canonical run");
        for (String run : Arrays.asList(null, "", "00000000-0000-0000-0000-000000000000",
                "12345678-1234-1234-1234-123456789ABC", "12345678-1234-1234-1234-123456789abc\n")) {
            check(!VpnUiSemantics.validRunId(run), "invalid owner run accepted");
        }
        String stat = "123 (name with spaces) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 12345 20";
        check("12345".equals(VpnUiSemantics.processStartTicks(stat)), "process lifetime field");
        for (String bad : Arrays.asList("", "1 (x) S 1 2", stat.replace("12345", "-1"))) {
            boolean refused = false;
            try { VpnUiSemantics.processStartTicks(bad); } catch (IllegalArgumentException expected) { refused = true; }
            check(refused, "malformed process identity");
        }
        Snapshot off = state(CONNECT, OFF), on = state(DISCONNECT, ON);
        VpnUiSemantics.Result observed = run("observe", "observed", 0, new Reader(on));
        check("connected".equals(observed.beforePhase) && "connected".equals(observed.afterPhase), "observation phase");
        check(!observed.actionAttempted, "observe clicked");
        VpnUiSemantics.Result connected = run("connect", "completed", 1,
                new Reader(off, off, state("Отменить VPN", "Подключение…"), on));
        check(connected.actionAccepted && "disconnected".equals(connected.beforePhase) &&
                "connected".equals(connected.afterPhase), "connect evidence");
        run("disconnect", "completed", 1, new Reader(on, on, off));
        for (String phase : Arrays.asList("Подключение…", "Ожидание разрешения")) {
            Snapshot pendingCancel = state("Отменить VPN", phase);
            VpnUiSemantics.Result canceled = run("cancel", "completed", 1,
                    new Reader(pendingCancel, pendingCancel, off));
            check(canceled.actionAccepted && "disconnected".equals(canceled.afterPhase), "cancel readback");
            run("cancel", "accepted_unconfirmed", 1,
                    new Reader(pendingCancel, pendingCancel, pendingCancel));
            run("cancel", "stale_target", 0, new Reader(pendingCancel, on));
            Snapshot refusedCancel = state("Отменить VPN", phase);
            refusedCancel.accepted = false;
            run("cancel", "action_rejected", 1, new Reader(pendingCancel, refusedCancel));
            Snapshot pendingDisconnect = state(DISCONNECT, phase);
            run("observe", "observed", 0, new Reader(pendingDisconnect));
            run("cancel", "completed", 1, new Reader(pendingDisconnect, pendingDisconnect, off));
            run("cancel", "stale_target", 0, new Reader(pendingDisconnect, on));
        }
        run("cancel", "precondition_failed", 0, new Reader(off));
        run("cancel", "precondition_failed", 0, new Reader(on));
        run("disconnect", "precondition_failed", 0,
                new Reader(state("Отменить VPN", "Подключение…")));
        for (String phase : Arrays.asList("Восстановление соединения…", "Трафик заблокирован")) {
            Snapshot recovering = state(DISCONNECT, phase);
            run("disconnect", "completed", 1, new Reader(recovering, recovering, off));
        }
        run("connect", "precondition_failed", 0, new Reader(on));
        run("disconnect", "precondition_failed", 0, new Reader(off));
        run("connect", "precondition_failed", 0, new Reader(state("Отменить VPN", "Подключение…")));
        run("connect", "precondition_failed", 0, new Reader(state(CONNECT, "Ошибка подключения")));
        Reader invalid = new Reader(off);
        run("toggle", "invalid_command", 0, invalid);
        check(invalid.reads == 0, "invalid command read UI");
        run(null, "invalid_command", 0, new Reader(off));

        reject("wrong_window_package", new Snapshot("another.package", 7, off.nodes, null));
        reject("target_missing", badButton("another.package", "android.widget.Button", true, true, true, true, false, false));
        reject("invalid_target", badButton(APP, "android.view.View", true, true, true, true, false, false));
        reject("invalid_target", badButton(APP, "android.widget.Button", false, true, true, true, false, false));
        reject("invalid_target", badButton(APP, "android.widget.Button", true, false, true, true, false, false));
        reject("invalid_target", badButton(APP, "android.widget.Button", true, true, false, true, false, false));
        reject("invalid_target", badButton(APP, "android.widget.Button", true, true, true, false, false, false));
        reject("edit_or_dialog_visible", badButton(APP, "android.widget.Button", true, true, true, true, true, false));
        reject("edit_or_dialog_visible", badButton(APP, "android.widget.Button", true, true, true, true, false, true));
        Snapshot duplicate = state(CONNECT, OFF);
        duplicate.nodes.add(node(CONNECT, true));
        reject("ambiguous_target", duplicate);
        Snapshot hiddenDuplicate = state(CONNECT, OFF);
        hiddenDuplicate.nodes.add(badButton(APP, "android.widget.Button", false, true, true, true, false, false).nodes.get(0));
        reject("ambiguous_target", hiddenDuplicate);
        Snapshot large = state(CONNECT, OFF);
        for (int i = 0; i < VpnUiSemantics.MAX_NODES; i++) large.nodes.add(node("neutral", false));
        reject("tree_too_large", large);
        reject("phase_conflict", state(DISCONNECT, OFF));
        reject("phase_conflict", state(CONNECT, ON));
        reject("phase_conflict", state(CONNECT, "Подключение…"));
        Snapshot conflict = state(CONNECT, OFF);
        conflict.nodes.add(node(ON, false));
        reject("phase_conflict", conflict);
        Snapshot sameNodeConflict = state(CONNECT, OFF);
        sameNodeConflict.nodes.set(0, new VpnUiSemantics.Node(APP, "android.widget.Button", CONNECT,
                DISCONNECT, true, true, true, true, false, false));
        reject("phase_conflict", sameNodeConflict);
        Snapshot sameStatusConflict = state(CONNECT, OFF);
        sameStatusConflict.nodes.set(1, new VpnUiSemantics.Node(APP, "android.view.View", OFF,
                ON, true, true, false, false, false, false));
        reject("phase_conflict", sameStatusConflict);
        for (String label : Arrays.asList("Закрыть настройки", "Оставить текущий список", "Закрыть", "Отмена")) {
            Snapshot dialog = state(CONNECT, OFF); dialog.nodes.add(node(label, true));
            reject("edit_or_dialog_visible", dialog);
        }
        reject("phase_unavailable", state(CONNECT, "Подключено · 00:99:00"));
        reject("phase_unavailable", state(CONNECT, "private arbitrary provider label"));

        run("connect", "stale_target", 0, new Reader(off, new Snapshot(APP, 8, off.nodes, null)));
        run("connect", "stale_target", 0, new Reader(off, on));
        Snapshot stale = state(CONNECT, OFF); stale.refresh = false;
        run("connect", "stale_target", 0, new Reader(off, stale));
        Snapshot changed = state(CONNECT, OFF); changed.replacement = node(DISCONNECT, true);
        run("connect", "phase_conflict", 0, new Reader(off, changed));
        Snapshot disabled = state(CONNECT, OFF);
        disabled.replacement = badButton(APP, "android.widget.Button", true, false, true, true, false, false).nodes.get(0);
        run("connect", "invalid_target", 0, new Reader(off, disabled));
        Snapshot denied = state(CONNECT, OFF); denied.accepted = false;
        VpnUiSemantics.Result denial = run("connect", "action_rejected", 1, new Reader(off, denied));
        check(denial.actionAttempted && !denial.actionAccepted, "rejection evidence");
        Snapshot throwing = state(CONNECT, OFF); throwing.throwClick = true;
        run("connect", "action_error", 1, new Reader(off, throwing));
        Reader broken = new Reader(off); broken.throwRead = true;
        run("connect", "accessibility_error", 0, broken);
        VpnUiSemantics.Result pending = run("connect", "accepted_unconfirmed", 1,
                new Reader(off, off, state("Отменить VPN", "Подключение…")));
        check(pending.durationMs == VpnUiSemantics.READBACK_MS && pending.actionAccepted, "bounded unconfirmed result");
        run("connect", "terminal_state", 1, new Reader(off, off, state(CONNECT, "Ошибка подключения")));
        run("connect", "terminal_state", 1, new Reader(off, off, state(DISCONNECT, "Трафик заблокирован")));
        run("connect", "wrong_window_package", 1,
                new Reader(off, off, new Snapshot("another.package", 8, on.nodes, null)));
        run("connect", "completed", 1, new Reader(null, off, off, on));
        Reader noWindow = new Reader((Snapshot) null);
        VpnUiSemantics.Result absent = run("observe", "window_unavailable", 0, noWindow);
        check(absent.durationMs == VpnUiSemantics.READY_MS, "readiness bound");
        Reader slow = new Reader(off); slow.delayedRead = 0; slow.delay = VpnUiSemantics.TOTAL_MS;
        run("connect", "deadline", 0, slow);
        Snapshot slowRefresh = state(CONNECT, OFF); slowRefresh.refreshDelay = VpnUiSemantics.TOTAL_MS;
        run("connect", "deadline", 0, new Reader(off, slowRefresh));
        Reader late = new Reader(off, off, on); late.delayedRead = 2; late.delay = VpnUiSemantics.READBACK_MS;
        run("connect", "accepted_unconfirmed", 1, late);
        System.out.println("VpnUiSemanticsTest PASS " + scenarios + " scenarios / " + checks + " assertions; no ADB/network");
    }
}
