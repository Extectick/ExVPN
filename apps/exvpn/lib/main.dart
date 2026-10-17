import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'src/home_screen.dart';
import 'src/theme.dart';
import 'services/native_vpn_bridge.dart';
import 'services/vpn_controller.dart';
import 'services/subscription_store.dart';
import 'services/subscription_persistence.dart';
import 'services/data_updates.dart';
import 'services/dart_updates.dart';
import 'services/desktop_tray.dart';

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
  });
  final AppController controller;
  final VpnController? vpn;
  final SubscriptionStore? store;
  final String? storageWarning;
  final DataUpdatesController? updates;
  final DartUpdatesController? dartUpdates;
  @override
  State<ExVpnApp> createState() => _ExVpnAppState();
}

class _ExVpnAppState extends State<ExVpnApp> {
  ThemeMode _themeMode = ThemeMode.dark;
  SubscriptionPersistence? _persistence;
  DesktopTrayController? _tray;
  final _navigator = GlobalKey<NavigatorState>();
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  late final DataUpdatesController _updates;
  late final DartUpdatesController _dartUpdates;
  @override
  void initState() {
    super.initState();
    if (widget.store != null) {
      _persistence = SubscriptionPersistence(widget.controller, widget.store!);
    }
    widget.vpn?.initialize();
    _updates = widget.updates ?? DataUpdatesController(vpn: widget.vpn);
    _updates.initialize();
    _dartUpdates = widget.dartUpdates ?? DartUpdatesController();
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
          return _persistence?.pending != true && _persistence?.error == null;
        },
        showNotice: (message) => _messenger.currentState?.showSnackBar(
          SnackBar(content: Text(message)),
        ),
      );
    }
  }

  Future<bool> _confirmExit() async {
    final context = _navigator.currentContext;
    if (context == null || !mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Выйти из ExVPN?'),
            content: Text(
              'Работа VPN-службы не изменится. Чтобы отключить VPN, '
              'используйте «Отключить VPN» в трее или кнопку подключения в окне.'
              '${widget.storageWarning != null ? '\n\n${widget.storageWarning}' : ''}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Выйти'),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) => DartUpdatesScope(
    controller: _dartUpdates,
    child: DataUpdatesScope(
      controller: _updates,
      child: MaterialApp(
        navigatorKey: _navigator,
        scaffoldMessengerKey: _messenger,
        title: 'ExVPN',
        debugShowCheckedModeBanner: false,
        theme: exVpnTheme(Brightness.light),
        darkTheme: exVpnTheme(Brightness.dark),
        themeMode: _themeMode,
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: HomeScreen(
          controller: widget.controller,
          vpn: widget.vpn,
          persistence: _persistence,
          storageWarning: widget.storageWarning,
          themeMode: _themeMode,
          onThemeChanged: (mode) => setState(() => _themeMode = mode),
        ),
      ),
    ),
  );
  @override
  void dispose() {
    _tray?.dispose();
    _persistence?.dispose();
    _updates.dispose();
    _dartUpdates.dispose();
    widget.controller.dispose();
    widget.vpn?.dispose();
    super.dispose();
  }
}
