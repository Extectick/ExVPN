import 'dart:async';

import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/services.dart';

import 'vpn_controller.dart';

/// Only fixed state labels cross this channel. Profiles and subscription names
/// never enter the shell tooltip, menu, or command payload.
typedef TrayState = ({String phase, bool canConnect, bool canDisconnect});

abstract interface class DesktopTray {
  void onCommand(Future<void> Function(String command)? handler);
  Future<void> update(TrayState state);
  Future<void> showWindow();
  Future<void> exitApplication();
}

final class WindowsDesktopTray implements DesktopTray {
  static const _channel = MethodChannel('exvpn/tray');

  @override
  void onCommand(Future<void> Function(String command)? handler) {
    _channel.setMethodCallHandler(
      handler == null
          ? null
          : (call) async {
              if (call.method != 'command' || call.arguments is! String) {
                throw MissingPluginException();
              }
              await handler(call.arguments as String);
            },
    );
  }

  @override
  Future<void> update(TrayState state) =>
      _channel.invokeMethod<void>('update', {
        'phase': state.phase,
        'canConnect': state.canConnect,
        'canDisconnect': state.canDisconnect,
      });

  @override
  Future<void> showWindow() => _channel.invokeMethod<void>('show');

  @override
  Future<void> exitApplication() => _channel.invokeMethod<void>('exit');
}

/// Uses the same authoritative controller as the window. A stale menu command
/// is rechecked after a native refresh; it can never become the opposite action.
final class DesktopTrayController {
  DesktopTrayController({
    required this.app,
    required this.vpn,
    required this.tray,
    required this.confirmExit,
    required this.saveBeforeExit,
    required this.showNotice,
  }) {
    tray.onCommand(handleCommand);
    vpn.addListener(_changed);
    _changes = app.changes.listen((_) => _changed());
    _changed();
  }

  final AppController app;
  final VpnController vpn;
  final DesktopTray tray;
  final Future<bool> Function() confirmExit;
  final Future<bool> Function() saveBeforeExit;
  final void Function(String message) showNotice;
  late final StreamSubscription<void> _changes;
  TrayState? _sent;
  bool _publishing = false;
  bool _handling = false;
  bool _disposed = false;

  TrayState get state {
    final ready = vpn.initialized && !vpn.commandPending && !_handling;
    return (
      phase: vpn.initialized ? vpn.status.phase.name : 'initializing',
      canConnect:
          ready &&
          vpn.status.phase == VpnPhase.disconnected &&
          !vpn.canDisconnect &&
          app.selectedServer != null &&
          !app.selectedServer!.isDemo,
      canDisconnect: ready && vpn.canDisconnect,
    );
  }

  void _changed() {
    if (!_disposed && !_publishing) unawaited(_publish());
  }

  Future<void> _publish() async {
    _publishing = true;
    try {
      // Coalesce traffic notifications, but never let an older in-flight write
      // overwrite the latest phase or enabled commands.
      while (!_disposed && _sent != state) {
        final next = state;
        await tray.update(next);
        _sent = next;
      }
    } catch (_) {
      // A missing shell must not affect the VPN. Native WM_CLOSE remains
      // accessible when adding the icon failed. A later event retries the icon.
      _sent = null;
    } finally {
      _publishing = false;
    }
  }

  Future<void> handleCommand(String command) async {
    if (_disposed ||
        _handling ||
        vpn.applicationRestartPending ||
        !const {'connect', 'disconnect', 'exit'}.contains(command)) {
      return;
    }
    _handling = true;
    _changed();
    try {
      if (command == 'exit') {
        await tray.showWindow();
        if (_disposed ||
            !await confirmExit() ||
            _disposed ||
            vpn.applicationRestartPending) {
          return;
        }
        if (!await saveBeforeExit()) {
          if (!_disposed) {
            showNotice(
              'Не удалось сохранить подписки. Приложение осталось открытым; повторите выход после сохранения.',
            );
          }
          return;
        }
        if (!_disposed && !vpn.applicationRestartPending) {
          await tray.exitApplication();
        }
        return;
      }

      if (!vpn.initialized || vpn.commandPending) return;
      final selected = app.selectedServer;
      await vpn.refresh();
      if (_disposed || vpn.commandPending) return;
      if (command == 'connect') {
        if (vpn.canDisconnect ||
            selected == null ||
            selected.isDemo ||
            !identical(selected, app.selectedServer)) {
          return;
        }
        if (vpn.status.phase == VpnPhase.disconnected) {
          await vpn.connect(selected.profile);
        }
      } else if (vpn.canDisconnect) {
        await vpn.disconnect();
      }
      if (!_disposed && vpn.lastErrorCode != null) {
        await tray.showWindow();
        if (!_disposed) showNotice(vpnErrorText(vpn.lastErrorCode));
      }
    } catch (_) {
      if (!_disposed) {
        try {
          await tray.showWindow();
        } catch (_) {
          /* Shell unavailable. */
        }
        if (!_disposed) {
          showNotice(
            'Действие не завершено. Проверьте состояние VPN в приложении.',
          );
        }
      }
    } finally {
      _handling = false;
      _changed();
    }
  }

  void dispose() {
    _disposed = true;
    tray.onCommand(null);
    vpn.removeListener(_changed);
    unawaited(_changes.cancel());
  }
}
