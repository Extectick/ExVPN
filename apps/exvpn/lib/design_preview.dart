// SPDX-License-Identifier: Apache-2.0
// Design-only entry point. Never imported by main.dart or a release target.
import 'dart:async';
import 'dart:math' as math;

import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'services/vpn_controller.dart';
import 'services/native_vpn_bridge.dart' show VpnFailure;
import 'services/client_logs.dart';
import 'services/subscription_loader.dart';
import 'build_identity.dart';
import 'services/app_updates.dart';
import 'services/data_updates.dart';
import 'src/updates_sheet.dart';
import 'src/site_routing_sheet.dart';
import 'src/desktop_layout.dart';
import 'src/home_screen.dart';
import 'src/appearance.dart';
import 'src/app_strings.dart';
import 'src/app_update_strip.dart';

void main() {
  if (!kIsWeb) {
    throw UnsupportedError('Design preview is available only in the browser.');
  }
  runApp(const DesignPreviewApp());
}

class DesignPreviewApp extends StatefulWidget {
  const DesignPreviewApp({super.key});
  @override
  State<DesignPreviewApp> createState() => _DesignPreviewAppState();
}

class _DesignPreviewAppState extends State<DesignPreviewApp> {
  late final AppController _app = AppController.demo()
    ..updateSubscription(
      groupId: 'demo-main',
      raw: 'tuic://demo@example.invalid:443#🇯🇵 Токио',
    );
  late final _DesignOnlyBridge _bridge = _DesignOnlyBridge(
    () => _app.selectedServer?.id,
    initiallyConnected: Uri.base.queryParameters['state'] == 'connected',
  );
  late final VpnController _vpn = VpnController(_bridge)..initialize();
  late final _previewUpdateBackend = _DesignUpdatesBackend();
  late final _previewData = DataUpdatesController(
    vpn: _vpn,
    backend: DisabledDataUpdatesBackend(),
  );
  late AppUpdatesController _previewUpdates = _createPreviewUpdates();
  late final ClientLogs _logs = ClientLogs(controller: _app, vpn: _vpn);
  final _appearance = AppearanceController(preview: true);
  DesktopLayout _layout = DesktopLayout.values.firstWhere(
    (mode) => mode.name == Uri.base.queryParameters['layout'],
    orElse: () => DesktopLayout.medium,
  );
  double _zoom = 1;
  AppUpdatePresentation? _appUpdate =
      Uri.base.queryParameters['update'] == 'none'
      ? null
      : const AppUpdatePresentation();
  Timer? _updateTimer;
  int _homeGeneration = 0;
  String _previewVersion = appVersion;
  bool _restartCurtain = false;
  final _previewLoader = SubscriptionLoader();

  AppUpdatesController _createPreviewUpdates() => AppUpdatesController(
    fullBackend: _previewUpdateBackend,
    beforeRestart: (_, handoff) async {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!mounted) return false;
      await handoff();
      setState(() => _restartCurtain = true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!mounted) return false;
      final previous = _previewUpdates;
      setState(() {
        _homeGeneration++;
        _previewVersion = _DesignUpdatesBackend.offer.version.split('+').first;
        _previewUpdates = _createPreviewUpdates();
        _restartCurtain = false;
      });
      previous.dispose();
      return true;
    },
  );

  Future<SubscriptionDocument> _previewDocument(String source) async {
    if (Uri.tryParse(source)?.host != 'demo.exvpn.invalid') {
      return _previewLoader.loadDocument(source);
    }
    await Future<void>.delayed(const Duration(milliseconds: 180));
    return SubscriptionDocument.fromText(
      '#profile-title: ExVPN Demo\n'
      'vless://00000000-0000-4000-8000-000000000001@node.example.invalid:443?security=tls&type=ws#Demo',
    );
  }

  void _startAppUpdate() {
    if (_appUpdate?.phase == AppUpdatePhase.downloading ||
        _appUpdate?.phase == AppUpdatePhase.restarting) {
      return;
    }
    var ticks = 0;
    setState(
      () => _appUpdate = const AppUpdatePresentation(
        phase: AppUpdatePhase.downloading,
      ),
    );
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(const Duration(milliseconds: 80), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final progress = (++ticks / 64).clamp(0.0, 1.0);
      if (progress < 1) {
        setState(
          () => _appUpdate = AppUpdatePresentation(
            phase: AppUpdatePhase.downloading,
            progress: progress,
          ),
        );
      } else {
        timer.cancel();
        setState(
          () => _appUpdate = const AppUpdatePresentation(
            phase: AppUpdatePhase.restarting,
            progress: 1,
          ),
        );
        unawaited(_finishPreviewUpdate());
      }
    });
  }

  Future<void> _finishPreviewUpdate() async {
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    setState(() => _restartCurtain = true);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;
    setState(() {
      _homeGeneration++;
      _previewVersion = '0.1.1';
      _appUpdate = null;
      _restartCurtain = false;
    });
  }

  @override
  void initState() {
    super.initState();
    _loadAppearance();
  }

  Future<void> _loadAppearance() async {
    await _appearance.initialize();
    if (!mounted) return;
    final theme = Uri.base.queryParameters['theme'];
    if (theme == 'light') _appearance.setChoice(ThemeChoice.light);
    if (theme == 'dark') _appearance.setChoice(ThemeChoice.dark);
    final language = Uri.base.queryParameters['lang'];
    if (language != null) _appearance.setLocale(language);
  }

  void _togglePreviewPower() {
    if (_vpn.canDisconnect) {
      unawaited(_vpn.disconnect());
    } else if (_app.selectedServer case final server?) {
      unawaited(_vpn.connect(server.profile));
    }
  }

  Future<List<String>> _previewRefreshAll() async {
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (Uri.base.queryParameters['refreshError'] == '1') {
      return [_app.groups.first.id];
    }
    return [];
  }

  Future<ProbeResult> _previewLatency(ConnectionProfile profile) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final milliseconds = switch (profile.id) {
      'demo-amsterdam' => 42,
      'demo-frankfurt' => 168,
      'demo-helsinki' => 73,
      'demo-warsaw' => 342,
      'demo-paris' => 192,
      _ => 307,
    };
    return ProbeResult(
      reachable: true,
      latency: Duration(milliseconds: milliseconds),
    );
  }

  @override
  void dispose() {
    _logs.dispose();
    _previewUpdates.dispose();
    _previewData.dispose();
    _previewLoader.close();
    _updateTimer?.cancel();
    _vpn.dispose();
    _bridge.dispose();
    _app.dispose();
    _appearance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppearanceScope(
    controller: _appearance,
    child: AnimatedBuilder(
      animation: _appearance,
      builder: (context, _) => MaterialApp(
        title: 'ExVPN · предпросмотр дизайна Windows',
        debugShowCheckedModeBanner: false,
        theme: _appearance.lightTheme,
        darkTheme: _appearance.darkTheme,
        themeMode: _appearance.themeMode,
        locale: _appearance.locale,
        supportedLocales: appSupportedLocales,
        localeListResolutionCallback: resolveAppLocale,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          backgroundColor: const Color(0xff0c0e0f),
          body: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(24, 14, 24, 8),
                  child: Row(
                    children: [
                      const Text(
                        'Предпросмотр Windows',
                        style: TextStyle(
                          color: Color(0xffc4c6c8),
                          fontSize: 12,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'Макет $_previewVersion · сеть не меняется',
                        style: const TextStyle(
                          color: Color(0xff777c81),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final canvas = _layout.canvasSize;
                      final fit = math
                          .min(
                            (constraints.maxWidth - 48) / canvas.width,
                            (constraints.maxHeight - 32) / canvas.height,
                          )
                          .clamp(0.1, 1.6);
                      final scale = math.min(_zoom, fit);
                      return Center(
                        child: Container(
                          width: canvas.width * scale,
                          height: canvas.height * scale,
                          decoration: BoxDecoration(
                            border: Border.all(color: const Color(0xff303438)),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x66000000),
                                blurRadius: 36,
                                offset: Offset(0, 14),
                              ),
                            ],
                          ),
                          child: AnimatedOpacity(
                            opacity: _restartCurtain ? 0 : 1,
                            duration: const Duration(milliseconds: 180),
                            child: _previewCanvas(
                              canvas,
                              HomeScreen(
                                key: ValueKey(_homeGeneration),
                                initialDesktopLayout: _layout,
                                previewVersion: _previewVersion,
                                previewBuild: appBuild,
                                controller: _app,
                                vpn: _vpn,
                                themeMode: _appearance.themeMode,
                                onThemeChanged: (mode) => _appearance.setChoice(
                                  mode == ThemeMode.light
                                      ? ThemeChoice.light
                                      : mode == ThemeMode.dark
                                      ? ThemeChoice.dark
                                      : ThemeChoice.system,
                                ),
                                previewPowerAction: _togglePreviewPower,
                                previewRefreshAction: _previewRefreshAll,
                                previewDocumentLoader: _previewDocument,
                                latencyProbe: _previewLatency,
                                appUpdate: _appUpdate,
                                onAppUpdate: _startAppUpdate,
                                onDesktopLayoutChanged: (mode) =>
                                    setState(() => _layout = mode),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.zoom_out_rounded,
                        size: 16,
                        color: Color(0xff777c81),
                      ),
                      SizedBox(
                        width: 140,
                        child: Slider(
                          min: .7,
                          max: 1.4,
                          value: _zoom,
                          onChanged: (value) => setState(() => _zoom = value),
                        ),
                      ),
                      const Icon(
                        Icons.zoom_in_rounded,
                        size: 16,
                        color: Color(0xff777c81),
                      ),
                      const SizedBox(width: 20),
                      Flexible(
                        child: Text(
                          _previewVersion == '0.1.1'
                              ? 'Макет обновлён до 0.1.1'
                              : 'Нажмите верхнюю полоску, чтобы посмотреть обновление',
                          style: const TextStyle(
                            color: Color(0xff777c81),
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  // Dialogs belong to the logical app window, not to the surrounding browser.
  Widget _previewCanvas(Size canvas, Widget child) => ClipRect(
    child: FittedBox(
      fit: BoxFit.contain,
      child: SizedBox.fromSize(
        size: canvas,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(size: canvas),
          child: ClientLogsScope(
            logs: _logs,
            child: AppUpdatesScope(
              controller: _previewUpdates,
              child: DataUpdatesScope(
                controller: _previewData,
                child: Navigator(
                  key: ValueKey(_homeGeneration),
                  pages: [
                    MaterialPage<void>(
                      name: Uri.base.queryParameters['page'] == 'updates'
                          ? UpdatesSheet.routeName
                          : null,
                      child: Uri.base.queryParameters['page'] == 'updates'
                          ? UpdatesSheet(
                              updates: _previewData,
                              appUpdates: _previewUpdates,
                              previewVersion: _previewVersion,
                            )
                          : Uri.base.queryParameters['page'] == 'sites'
                          ? SiteRoutingSheet(vpn: _vpn)
                          : child,
                    ),
                  ],
                  onDidRemovePage: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Timed visual simulation only; never downloads, installs or exits a process.
class _DesignUpdatesBackend implements FullUpdatesBackend {
  static const offer = FullUpdateOffer(version: '0.1.9+30');
  bool installed = false;
  @override
  bool get supported => true;
  @override
  Future<FullUpdateOffer?> check() async {
    await Future<void>.delayed(const Duration(milliseconds: 650));
    if (Uri.base.queryParameters['updateState'] == 'error') {
      throw AppUpdatesFailure('network_failed');
    }
    return installed || Uri.base.queryParameters['updateState'] == 'current'
        ? null
        : offer;
  }

  @override
  Future<FullUpdateOffer> download(
    FullUpdateOffer offer, {
    required FullUpdateProgressCallback onProgress,
  }) async {
    for (var i = 1; i <= 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      onProgress(FullUpdateProgress(received: i, total: 30));
    }
    return offer;
  }

  @override
  Future<FullUpdateHandoff> handoff(FullUpdateOffer offer) async {
    installed = true;
    return FullUpdateHandoff.exitUi;
  }

  @override
  Future<void> restartUi() async {}
  @override
  Future<void> cancel() async {}
  @override
  void dispose() {}
}

/// Explicit visual simulation, isolated from the product entry point.
/// Contains no native bridge, HTTP client, subscription URL or subscription
/// persistence. Visual preferences use their own isolated preview storage.
class _DesignOnlyBridge
    implements
        VpnBridge,
        ConnectionModeBridge,
        ApplicationRoutingBridge,
        SiteRoutingBridge,
        ConnectionProtectionBridge {
  _DesignOnlyBridge(this.selectedId, {required bool initiallyConnected}) {
    _mode = Uri.base.queryParameters['mode'] == 'proxy'
        ? VpnMode.proxy
        : VpnMode.vpn;
    _status = VpnStatus(
      phase: VpnPhase.disconnected,
      processCrashProtection: false,
      mode: _mode,
      systemProxySupported: true,
    );
    if (initiallyConnected) {
      _status = VpnStatus(
        phase: VpnPhase.connected,
        processCrashProtection: false,
        mode: _mode,
        systemProxySupported: true,
        activeProfileId: selectedId(),
        connectedAt: DateTime.now().subtract(
          const Duration(minutes: 12, seconds: 34),
        ),
      );
      _startSamples();
    } else if (Uri.base.queryParameters['state'] == 'blocked' ||
        Uri.base.queryParameters['state'] == 'error') {
      _status = VpnStatus(
        phase: Uri.base.queryParameters['state'] == 'blocked'
            ? VpnPhase.blocked
            : VpnPhase.error,
        processCrashProtection: false,
        mode: _mode,
        systemProxySupported: true,
        activeProfileId: selectedId(),
        errorCode: 'tunnel_unreachable',
      );
    }
  }
  final String? Function() selectedId;
  final _states = StreamController<VpnStatus>.broadcast();
  final _traffic = StreamController<TrafficStats>.broadcast();
  VpnMode _mode = VpnMode.vpn;
  VpnStatus _status = const VpnStatus(
    phase: VpnPhase.disconnected,
    processCrashProtection: false,
    systemProxySupported: true,
  );
  Timer? _transition;
  Timer? _sample;
  ApplicationRoutingPolicy _routing = ApplicationRoutingPolicy(
    mode: ApplicationRoutingMode.exclude,
    applicationIds: {'C:/Preview/Discord/Discord.exe'},
  );
  void _simulateConnect(
    String? targetId,
    VpnMode mode, {
    bool reconnecting = false,
  }) {
    _mode = mode;
    _transition?.cancel();
    _sample?.cancel();
    _publish(
      VpnStatus(
        phase: reconnecting ? VpnPhase.reconnecting : VpnPhase.connecting,
        processCrashProtection: false,
        mode: mode,
        systemProxySupported: true,
        activeProfileId: reconnecting ? _status.activeProfileId : targetId,
      ),
    );
    _transition = Timer(const Duration(milliseconds: 1800), () {
      final failed = Uri.base.queryParameters['connectError'] == '1';
      _publish(
        VpnStatus(
          phase: failed ? VpnPhase.blocked : VpnPhase.connected,
          processCrashProtection: false,
          mode: mode,
          systemProxySupported: true,
          activeProfileId: targetId,
          connectedAt: failed ? null : DateTime.now(),
          errorCode: failed ? 'tunnel_unreachable' : null,
        ),
      );
      if (!failed) _startSamples();
    });
  }

  void _startSamples() {
    _sample?.cancel();
    _sample = Timer.periodic(const Duration(seconds: 1), (timer) {
      _traffic.add(
        TrafficStats(
          uploadBytes: timer.tick * 12800,
          downloadBytes: timer.tick * 192000,
        ),
      );
    });
  }

  void _publish(VpnStatus status) {
    _status = status;
    _states.add(status);
  }

  @override
  Stream<VpnStatus> get statuses => _states.stream;
  @override
  Stream<TrafficStats> get traffic => _traffic.stream;
  @override
  Future<VpnStatus> getStatus() async => _status;
  @override
  Future<void> connect(ConnectionProfile profile) async =>
      _simulateConnect(profile.id, VpnMode.vpn);
  @override
  bool get supportsConnectionModes => true;
  @override
  Future<void> connectInMode(ConnectionProfile profile, VpnMode mode) async =>
      _simulateConnect(profile.id, mode);
  @override
  Future<void> reconnect(ConnectionProfile profile, VpnMode mode) async =>
      _simulateConnect(profile.id, mode, reconnecting: true);
  @override
  Future<void> disconnect() async {
    _transition?.cancel();
    _sample?.cancel();
    _publish(
      VpnStatus(
        phase: VpnPhase.disconnected,
        processCrashProtection: false,
        mode: _mode,
        systemProxySupported: true,
      ),
    );
  }

  @override
  Future<String> coreVersion() async => '26.10.10-exvpn.5';
  bool _protectionEnabled = true;
  @override
  Future<ConnectionProtection> getConnectionProtection() async =>
      ConnectionProtection(
        supported: true,
        enabled: _protectionEnabled,
        active:
            _protectionEnabled &&
            _mode == VpnMode.vpn &&
            _status.phase == VpnPhase.connected,
        systemManaged: false,
      );
  @override
  Future<ConnectionProtection> setConnectionProtection(bool enabled) async {
    _protectionEnabled = enabled;
    return getConnectionProtection();
  }

  @override
  Future<Set<String>> getExclusions() async =>
      _routing.mode == ApplicationRoutingMode.exclude
      ? _routing.applicationIds
      : {};
  @override
  Future<List<ApplicationIdentity>> listApplications() async => [
    for (final name in const [
      'Discord',
      'Browser',
      'Telegram',
      'Music',
      'Video',
      'Mail',
      'Calendar',
      'Notes',
      'Games',
      'Terminal',
      'Reader',
      'Cloud',
    ])
      ApplicationIdentity(id: 'C:/Preview/$name/$name.exe', displayName: name),
  ];
  @override
  Future<void> setExclusions(Set<String> applicationIds) async {
    _routing = ApplicationRoutingPolicy(
      mode: applicationIds.isEmpty
          ? ApplicationRoutingMode.disabled
          : ApplicationRoutingMode.exclude,
      applicationIds: applicationIds,
    );
  }

  @override
  Future<ApplicationRoutingPolicy> getApplicationRouting() async => _routing;
  SiteRoutingState _sites = SiteRoutingState.disabled();
  @override
  Future<SiteRoutingState> getSiteRouting() async => _sites;
  @override
  Future<void> setSiteRouting(SiteRoutingState state) async {
    if (_status.phase != VpnPhase.disconnected) {
      throw const VpnFailure('site_routing_requires_disconnected');
    }
    _sites = SiteRoutingState.fromJson(state.toJson());
  }

  @override
  Future<void> setApplicationRouting(ApplicationRoutingPolicy policy) async {
    _routing = policy;
  }

  @override
  Future<ProbeResult> probe(ConnectionProfile profile) async =>
      const ProbeResult(reachable: false);
  @override
  Future<void> openSystemProtectionSettings() async {}
  void dispose() {
    _transition?.cancel();
    _sample?.cancel();
    _states.close();
    _traffic.close();
  }
}
