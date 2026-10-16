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
  });
  final AppController controller;
  final VpnController? vpn;
  final SubscriptionStore? store;
  final String? storageWarning;
  final DataUpdatesController? updates;
  @override
  State<ExVpnApp> createState() => _ExVpnAppState();
}

class _ExVpnAppState extends State<ExVpnApp> {
  ThemeMode _themeMode = ThemeMode.dark;
  SubscriptionPersistence? _persistence;
  late final DataUpdatesController _updates;
  @override
  void initState() {
    super.initState();
    if (widget.store != null) {
      _persistence = SubscriptionPersistence(widget.controller, widget.store!);
    }
    widget.vpn?.initialize();
    _updates = widget.updates ?? DataUpdatesController(vpn: widget.vpn);
    _updates.initialize();
  }

  @override
  Widget build(BuildContext context) => DataUpdatesScope(
    controller: _updates,
    child: MaterialApp(
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
  );
  @override
  void dispose() {
    _persistence?.dispose();
    _updates.dispose();
    widget.controller.dispose();
    widget.vpn?.dispose();
    super.dispose();
  }
}
