import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';

import 'src/home_screen.dart';
import 'src/appearance.dart';
import 'src/app_strings.dart';
import 'services/native_vpn_bridge.dart';
import 'services/vpn_controller.dart';
import 'services/subscription_store.dart';
import 'services/subscription_persistence.dart';
import 'services/data_updates.dart';
import 'services/dart_updates.dart';
import 'services/desktop_tray.dart';
import 'services/app_updates.dart';
import 'services/client_logs.dart';
import 'src/app_update_strip.dart';
import 'src/updates_sheet.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final demo =
      Uri.base.queryParameters['demo'] == '1' ||
      const bool.fromEnvironment('EXVPN_DEMO');
  final native =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows);
  var controller = demo ? AppController.demo() : AppController();
  SubscriptionStore? store;
  String? storageWarning;
  if (native && !demo) {
    final candidate = SubscriptionStore();
    try {
      controller.dispose();
      controller = await candidate.load();
      store = candidate;
      if (candidate.recovered) {
        storageWarning =
            'Подписки восстановлены после незавершённого сохранения.';
      }
    } catch (_) {
      controller = AppController();
      storageWarning = 'Не удалось открыть защищённое хранилище. Существующие данные не изменены; новые подписки доступны только в этом сеансе. Перезапустите приложение, чтобы повторить чтение.';
    }
  }
  runApp(
    ExVpnApp(
      controller: controller,
      vpn: native ? VpnController(NativeVpnBridge()) : null,
      store: store,
      storageWarning: storageWarning,
    ),
  );
}

class ExVpnApp extends StatefulWidget {
  const ExVpnApp({
    super.key,
    required this.controller,
    this.vpn,
    this.store,
    this.storageWarning,
    this.updates,
    this.dartUpdates,
    this.appUpdates,
    this.fullUpdatesBackend,
    this.appearanceController,
  });
  final AppController controller;
  final VpnController? vpn;
  final SubscriptionStore? store;
  final String? storageWarning;
  final DataUpdatesController? updates;
  final DartUpdatesController? dartUpdates;
  final AppUpdatesController? appUpdates;

  /// Optional test/embedder backend; the app still owns the lifecycle barrier.
  final FullUpdatesBackend? fullUpdatesBackend;
  final AppearanceController? appearanceController;
  @override
  State<ExVpnApp> createState() => _ExVpnAppState();
}

class _ExVpnAppState extends State<ExVpnApp> with WidgetsBindingObserver {
  late final AppearanceController _appearance;
  SubscriptionPersistence? _persistence;
  DesktopTrayController? _tray;
  final _navigator = GlobalKey<NavigatorState>();
  late final _updateNavigation = UpdatesNavigationObserver(
    onChanged: _onRestartEnvironmentChanged,
  );
  bool _restartEnvironmentReady = false;
  bool _restartOpportunityScheduled = false;
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  late final DataUpdatesController _updates;
  late final DartUpdatesController _dartUpdates;
  late final AppUpdatesController _appUpdates;
  late final ClientLogs _logs;
  static const _windowEvents = MethodChannel('exvpn/window');
  bool get _windows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  @override
  void initState() {
    super.initState();
    _appearance = widget.appearanceController ?? AppearanceController();
    WidgetsBinding.instance.addObserver(this);
    _appearance.initialize();
    if (widget.store != null) {
      _persistence = SubscriptionPersistence(widget.controller, widget.store!);
    }
    widget.vpn?.initialize();
    _updates = widget.updates ?? DataUpdatesController(vpn: widget.vpn);
    _updates.initialize();
    _dartUpdates = widget.dartUpdates ?? DartUpdatesController();
    _appUpdates =
        widget.appUpdates ??
        AppUpdatesController(
          fullBackend: widget.fullUpdatesBackend,
          dartUpdates: _dartUpdates,
          beforeRestart: _beforeRestart,
        );
    _logs = ClientLogs(
      controller: widget.controller,
      vpn: widget.vpn,
      appUpdates: _appUpdates,
      dartUpdates: _dartUpdates,
      persistence: _persistence,
    );
    if (_windows) {
      _windowEvents.setMethodCallHandler((call) async {
        if (call.method != 'shown' || call.arguments != null) {
          throw MissingPluginException();
        }
        _onApplicationVisible();
      });
    }
    widget.vpn?.addListener(_onRestartEnvironmentChanged);
    unawaited(_appUpdates.initialize());
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.windows &&
        widget.vpn != null) {
      _tray = DesktopTrayController(
        app: widget.controller,
        vpn: widget.vpn!,
        tray: WindowsDesktopTray(),
        confirmExit: _confirmExit,
        saveBeforeExit: () async {
          await _persistence?.flush().timeout(const Duration(seconds: 10));
          await _appearance.flush().timeout(const Duration(seconds: 3));
          return _persistence?.pending != true &&
              _persistence?.error == null &&
              _appearance.storageErrorCode == null;
        },
        showNotice: (message) => _messenger.currentState?.showSnackBar(
          SnackBar(
            content: Text(_navigator.currentContext?.tr(message) ?? message),
          ),
        ),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _onApplicationVisible();
      unawaited(widget.vpn?.refreshConnectionProtection());
    } else {
      _appUpdates.onBackground();
    }
    _onRestartEnvironmentChanged();
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (_windows && event.state == ViewFocusState.focused) {
      _onApplicationVisible();
    }
  }

  void _onApplicationVisible() {
    if (!mounted) return;
    unawaited(_appUpdates.onResume());
    _onRestartEnvironmentChanged();
  }

  bool get _restartEnvironmentSafe {
    final vpn = widget.vpn;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return mounted &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        vpn != null &&
        vpn.initialized &&
        !vpn.commandPending &&
        (defaultTargetPlatform != TargetPlatform.android ||
            vpn.canApplyDataUpdate) &&
        !(_navigator.currentState?.canPop() == true &&
            !_updateNavigation.showingUpdates);
  }

  void _onRestartEnvironmentChanged() {
    // The restart's own reservation/flush notifications are not a new chance.
    if (!mounted || widget.vpn?.applicationRestartPending == true) return;
    final ready = _restartEnvironmentSafe;
    final wasReady = _restartEnvironmentReady;
    _restartEnvironmentReady = ready;
    if (!ready || wasReady || _restartOpportunityScheduled) return;
    _restartOpportunityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restartOpportunityScheduled = false;
      if (mounted && _restartEnvironmentSafe) {
        unawaited(_appUpdates.onRestartOpportunity());
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<bool> _beforeRestart(
    AppUpdateKind kind,
    Future<void> Function() handoff,
  ) async {
    // Android's native broker replaces its VM only while its same-process VPN
    // is idle. Windows replaces just the UI; its separate service stays alive.
    final vpn = widget.vpn;
    final androidFull =
        defaultTargetPlatform == TargetPlatform.android &&
        kind == AppUpdateKind.full;
    if (!mounted ||
        kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.windows &&
            defaultTargetPlatform != TargetPlatform.android) ||
        vpn == null ||
        (WidgetsBinding.instance.lifecycleState != null &&
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed) ||
        (_navigator.currentState?.canPop() == true &&
            !_updateNavigation.showingUpdates)) {
      return false;
    }
    return vpn.runForApplicationRestart(
      (stillSafe) async {
        await _persistence?.flush().timeout(const Duration(seconds: 10));
        await _appearance.flush().timeout(const Duration(seconds: 3));
        if (!mounted ||
            (WidgetsBinding.instance.lifecycleState != null &&
                WidgetsBinding.instance.lifecycleState !=
                    AppLifecycleState.resumed) ||
            !stillSafe() ||
            (_navigator.currentState?.canPop() == true &&
                !_updateNavigation.showingUpdates) ||
            _persistence?.pending == true ||
            _persistence?.error != null ||
            _appearance.storageErrorCode != null) {
          return false;
        }
        await handoff();
        if (androidFull) return true;
        vpn.commitApplicationRestart();
        if (defaultTargetPlatform == TargetPlatform.windows) {
          await WindowsDesktopTray().exitApplication();
        }
        return true;
      },
      requireDisconnected:
          kind == AppUpdateKind.full ||
          defaultTargetPlatform == TargetPlatform.android,
    );
  }

  AppUpdatePresentation? get _updatePresentation => switch (_appUpdates.phase) {
    AppUpdateStatePhase.available => const AppUpdatePresentation(),
    AppUpdateStatePhase.downloading => AppUpdatePresentation(
      phase: AppUpdatePhase.downloading,
      progress: _appUpdates.progress,
    ),
    AppUpdateStatePhase.restartReady => AppUpdatePresentation(
      phase: AppUpdatePhase.ready,
      label: _androidFullUpdate ? 'Установить обновление' : null,
    ),
    AppUpdateStatePhase.restarting => AppUpdatePresentation(
      phase: AppUpdatePhase.restarting,
      label: _androidFullUpdate ? 'Открываем установщик…' : null,
    ),
    AppUpdateStatePhase.blocked => AppUpdatePresentation(
      phase: AppUpdatePhase.blocked,
      label: _updateBlockedLabel,
    ),
    AppUpdateStatePhase.failed => AppUpdatePresentation(
      phase: AppUpdatePhase.failed,
      label: _updateFailureLabel,
    ),
    _ => null,
  };

  bool get _androidFullUpdate =>
      defaultTargetPlatform == TargetPlatform.android &&
      _appUpdates.kind == AppUpdateKind.full;

  String? get _updateFailureLabel => switch (_appUpdates.errorCode) {
    'install_permission_required' => 'Разрешите установку обновлений',
    'install_cancelled' => 'Установка отменена — повторить',
    'install_failed' => 'Не удалось установить — повторить',
    'handoff_failed' => 'Не удалось запустить установку',
    'apk_invalid' || 'apk_incompatible' => 'Обновление не подходит устройству',
    _ => null,
  };

  String get _updateBlockedLabel {
    if ((_appUpdates.kind == AppUpdateKind.full ||
            defaultTargetPlatform == TargetPlatform.android) &&
        widget.vpn?.canDisconnect == true) {
      return 'Для установки отключите VPN';
    }
    if (_persistence?.error != null || _appearance.storageErrorCode != null) {
      return 'Не удалось сохранить настройки — повторить';
    }
    return 'Закройте диалоги и повторите установку';
  }

  void _activateUpdate() {
    if (_appUpdates.canRestart) {
      unawaited(_appUpdates.restart());
    } else if (_appUpdates.canDownload) {
      unawaited(_appUpdates.download());
    } else {
      unawaited(_appUpdates.retry());
    }
  }

  Future<bool> _confirmExit() async {
    final context = _navigator.currentContext;
    if (context == null || !mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(context.tr('Выйти из ExVPN?')),
            content: Text(
              '${context.tr('Работа VPN-службы не изменится. Чтобы отключить VPN, '
              'используйте «Отключить VPN» в трее или кнопку подключения в окне.')}'
              '${widget.storageWarning != null ? '\n\n${context.tr(widget.storageWarning!)}' : ''}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(context.tr('Отмена')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(context.tr('Выйти')),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) => ClientLogsScope(
    logs: _logs,
    child: AppUpdatesScope(
      controller: _appUpdates,
      child: DartUpdatesScope(
        controller: _dartUpdates,
        child: DataUpdatesScope(
          controller: _updates,
          child: AppearanceScope(
            controller: _appearance,
            child: AnimatedBuilder(
              animation: Listenable.merge([_appearance, _appUpdates]),
              builder: (context, _) => MaterialApp(
                navigatorKey: _navigator,
                navigatorObservers: [_updateNavigation],
                scaffoldMessengerKey: _messenger,
                title: 'ExVPN',
                debugShowCheckedModeBanner: false,
                theme: _appearance.lightTheme,
                darkTheme: _appearance.darkTheme,
                themeMode: _appearance.themeMode,
                locale: _appearance.locale,
                localeListResolutionCallback: resolveAppLocale,
                supportedLocales: appSupportedLocales,
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                builder: (context, child) => AnimatedBuilder(
                  animation: widget.vpn ?? _appUpdates,
                  builder: (context, _) => AbsorbPointer(
                    absorbing: widget.vpn?.applicationRestartPending == true,
                    child: child,
                  ),
                ),
                home: HomeScreen(
                  controller: widget.controller,
                  vpn: widget.vpn,
                  persistence: _persistence,
                  storageWarning: widget.storageWarning,
                  appUpdate: _updatePresentation,
                  onAppUpdate: _activateUpdate,
                  themeMode: _appearance.themeMode,
                  onThemeChanged: (mode) =>
                      _appearance.setChoice(switch (mode) {
                        ThemeMode.system => ThemeChoice.system,
                        ThemeMode.dark => ThemeChoice.dark,
                        ThemeMode.light => ThemeChoice.light,
                      }),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  @override
  void dispose() {
    if (_windows) _windowEvents.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    widget.vpn?.removeListener(_onRestartEnvironmentChanged);
    _logs.dispose();
    _appUpdates.dispose();
    _tray?.dispose();
    _persistence?.dispose();
    _updates.dispose();
    _dartUpdates.dispose();
    _appearance.dispose();
    widget.controller.dispose();
    widget.vpn?.dispose();
    super.dispose();
  }
}
