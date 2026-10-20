import 'dart:async';

import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/rendering.dart' show RenderAbstractViewport;

import 'import_dialog.dart';
import 'subscription_issues_dialog.dart';
import 'settings_sheet.dart';
import 'power_button.dart';
import '../services/vpn_controller.dart';
import '../services/subscription_persistence.dart';
import '../services/subscription_refresh.dart';
import '../services/subscription_loader.dart' show SubscriptionDocument;
import '../services/server_latency.dart';
import 'desktop_layout.dart';
import 'sliding_segments.dart';
import 'app_strings.dart';
import 'country_flag.dart';
import 'desktop_window_controls.dart';
import 'app_update_strip.dart';
import 'subscription_tree.dart';
import 'subscription_edit_dialog.dart';
import 'modal_sheet_scroll_behavior.dart';

enum _SubscriptionMenuAction { edit, delete }

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.themeMode,
    required this.onThemeChanged,
    this.vpn,
    this.persistence,
    this.storageWarning,
    this.previewPowerAction,
    this.onDesktopLayoutChanged,
    this.previewRefreshAction,
    this.latencyProbe,
    this.appUpdate,
    this.onAppUpdate,
    this.initialDesktopLayout,
    this.previewVersion,
    this.previewBuild,
    this.previewDocumentLoader,
  });
  final AppController controller;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final VpnController? vpn;
  final SubscriptionPersistence? persistence;
  final String? storageWarning;
  final VoidCallback? previewPowerAction;
  final ValueChanged<DesktopLayout>? onDesktopLayoutChanged;
  final Future<List<String>> Function()? previewRefreshAction;
  final LatencyProbe? latencyProbe;

  /// Optional presentation; download/install ownership stays outside this view.
  final AppUpdatePresentation? appUpdate;
  final VoidCallback? onAppUpdate;
  final DesktopLayout? initialDesktopLayout;
  final String? previewVersion;
  final int? previewBuild;
  final Future<SubscriptionDocument> Function(String)? previewDocumentLoader;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late final StreamSubscription<void> _changes;
  Timer? _clock;
  Timer? _toastTimer;
  final _toastQueue = <({String message, bool error})>[];
  final _manualRefreshFailures = <String, int>{};
  bool _refreshing = false;
  bool _serverPickerOpen = false;
  int _selectionRevision = 0;
  final _serversScroll = ScrollController();
  final _pickerScroll = ScrollController();
  final _latencyRows = <String, ({GlobalKey key, ConnectionProfile profile})>{};
  final _pickerLatencyRows =
      <String, ({GlobalKey key, ConnectionProfile profile})>{};
  Timer? _autoPingDebounce;
  bool _foreground = false;
  VpnPhase? _latencyVpnPhase;
  final _layoutControlKey = GlobalKey(debugLabel: 'desktop-layout-control');
  final _modeControlKey = GlobalKey(debugLabel: 'connection-mode-control');
  final _pickerFocus = FocusScopeNode(
    debugLabel: 'Connection picker',
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    directionalTraversalEdgeBehavior: TraversalEdgeBehavior.stop,
  );
  late DesktopLayout _layout =
      widget.initialDesktopLayout ??
      switch (Uri.base.queryParameters['layout']) {
        'minimal' => DesktopLayout.minimal,
        'large' => DesktopLayout.large,
        _ => DesktopLayout.medium,
      };
  late final SubscriptionRefresh _refreshes;
  late final ServerLatencyController _latencies;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.vpn?.addListener(_vpnChanged);
    widget.persistence?.addListener(_storageChanged);
    _refreshes = SubscriptionRefresh(
      widget.controller,
      canApply: () => widget.vpn?.applicationRestartPending != true,
    )..addListener(_storageChanged);
    _foreground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _latencies = ServerLatencyController(
      probe: widget.latencyProbe,
      canProbe: () =>
          mounted &&
          _foreground &&
          ModalRoute.of(context)?.isCurrent != false &&
          widget.vpn?.connecting != true,
    )..addListener(_storageChanged);
    unawaited(_refreshes.refreshStale());
    _changes = widget.controller.changes.listen((_) {
      final vpn = widget.vpn;
      if (vpn != null && vpn.automaticSelectionEnabled) {
        final group = widget.controller.groups
            .where((g) => g.id == widget.controller.selectedAutomaticGroupId)
            .firstOrNull;
        if (group == null) {
          unawaited(vpn.disableAutomaticSelection());
        } else {
          vpn.updateAutomaticCandidates([
            for (final server in group.servers) server.profile,
          ]);
        }
      }
      if (mounted) setState(() {});
      _scheduleAutoPing();
    });
    _adoptAutomaticGroup();
    _scheduleAutoPing();
  }

  void _scheduleAutoPing() {
    _autoPingDebounce?.cancel();
    if (!_foreground || !mounted) return;
    _autoPingDebounce = Timer(const Duration(milliseconds: 180), () {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pingVisible());
      WidgetsBinding.instance.ensureVisualUpdate();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleAutoPing();
  }

  void _pingVisible() {
    if (!mounted || !_foreground) return;
    if (widget.vpn?.connecting == true ||
        ModalRoute.of(context)?.isCurrent == false) {
      _latencies.pause();
      return;
    }
    final rows = _serverPickerOpen ? _pickerLatencyRows : _latencyRows;
    rows.removeWhere((_, row) => row.key.currentContext == null);
    final visible = <ConnectionProfile>[];
    for (final row in rows.values) {
      final box = row.key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final abstractViewport = RenderAbstractViewport.maybeOf(box);
      if (abstractViewport is! RenderBox) continue;
      final viewport = abstractViewport as RenderBox;
      if (!viewport.hasSize) continue;
      final rect = Rect.fromPoints(
        box.localToGlobal(Offset.zero),
        box.localToGlobal(Offset(box.size.width, box.size.height)),
      );
      final bounds = Rect.fromPoints(
        viewport.localToGlobal(Offset.zero),
        viewport.localToGlobal(
          Offset(viewport.size.width, viewport.size.height),
        ),
      );
      if (rect.overlaps(bounds)) visible.add(row.profile);
    }
    unawaited(_latencies.checkVisible(visible));
  }

  void _storageChanged() {
    if (mounted) setState(() {});
  }

  void _vpnChanged() {
    if (!mounted) return;
    _adoptAutomaticGroup();
    final phase = widget.vpn?.status.phase;
    if (phase != _latencyVpnPhase) {
      _latencyVpnPhase = phase;
      if (widget.vpn?.connecting == true) {
        _latencies.pause();
      } else {
        _scheduleAutoPing();
      }
    }
    if (widget.vpn?.status.phase == VpnPhase.connected) {
      _clock ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _clock?.cancel();
      _clock = null;
    }
    setState(() {});
  }

  void _adoptAutomaticGroup() {
    final vpn = widget.vpn;
    if (vpn == null ||
        !vpn.status.automaticSelection ||
        vpn.automaticProfileIds.isNotEmpty) {
      return;
    }
    final group = widget.controller.groups
        .where((g) => g.id == widget.controller.selectedAutomaticGroupId)
        .firstOrNull;
    if (group != null) {
      vpn.adoptAutomaticSelection([
        for (final server in group.servers) server.profile,
      ]);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _scheduleAutoPing();
    } else {
      _autoPingDebounce?.cancel();
      _latencies.pause();
    }
    if (state == AppLifecycleState.resumed) widget.vpn?.refresh();
  }

  @override
  void dispose() {
    _changes.cancel();
    _clock?.cancel();
    _toastTimer?.cancel();
    _autoPingDebounce?.cancel();
    widget.vpn?.removeListener(_vpnChanged);
    widget.persistence?.removeListener(_storageChanged);
    _refreshes.dispose();
    _latencies.dispose();
    _serversScroll.dispose();
    _pickerScroll.dispose();
    _pickerFocus.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _add({SubscriptionGroup? group}) => showDialog<void>(
    context: context,
    useRootNavigator: false,
    builder: (_) => ImportDialog(
      controller: widget.controller,
      group: group,
      persistence: widget.persistence,
      fullscreen: _desktop && _layout == DesktopLayout.minimal,
      documentLoader: widget.previewDocumentLoader,
    ),
  );

  Future<void> _connect() async {
    if (widget.previewPowerAction case final action?) {
      action();
      return;
    }
    final vpn = widget.vpn;
    if (vpn != null && !vpn.canChangeConnection) return;
    if (vpn != null && vpn.canDisconnect) {
      _selectionRevision++;
      await vpn.disconnect();
      if (mounted && vpn.status.processCrashProtection) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr(
                'Системная блокировка может оставаться включённой. Проверьте настройки VPN в системе.',
              ),
            ),
          ),
        );
      }
      return;
    }
    if (widget.controller.selectedServer == null) {
      _add();
      return;
    }
    if (vpn != null && !widget.controller.selectedServer!.isDemo) {
      final automatic = widget.controller.groups
          .where((g) => g.id == widget.controller.selectedAutomaticGroupId)
          .firstOrNull;
      if (automatic != null && automatic.servers.length >= 2) {
        await vpn.startAutomaticSelection([
          for (final server in automatic.servers) server.profile,
        ]);
        return;
      }
      await vpn.connect(widget.controller.selectedServer!.profile);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('VPN пока недоступен')),
        content: Text(context.tr('В этой сборке VPN пока недоступен.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.tr('Понятно')),
          ),
        ],
      ),
    );
  }

  bool get _refreshBusy => _refreshing || _refreshes.busy;

  Future<void> _refresh({String? groupId}) async {
    if (_refreshBusy || widget.vpn?.applicationRestartPending == true) return;
    final groups = widget.controller.groups
        .where(
          (group) =>
              (widget.previewRefreshAction != null ||
                  group.sourceUrl != null) &&
              (groupId == null || group.id == groupId),
        )
        .toList();
    if (widget.previewRefreshAction == null && groups.isEmpty) {
      _queueToasts(['Нет подписок для обновления'], error: false);
      return;
    }
    setState(() {
      _refreshing = true;
      for (final group in groups) {
        _manualRefreshFailures.remove(group.id);
      }
    });
    final failed = <String>[];
    try {
      if (widget.previewRefreshAction case final refresh?) {
        failed.addAll(await refresh());
      } else {
        var next = 0;
        Future<void> worker() async {
          while (mounted && next < groups.length) {
            final group = groups[next++];
            if (!await _refreshes.refresh(group.id)) {
              final current = widget.controller.groups
                  .where((item) => item.id == group.id)
                  .firstOrNull;
              if (current?.sourceUrl == group.sourceUrl &&
                  current?.contentRevision == group.contentRevision) {
                failed.add(group.name);
              }
            }
          }
        }

        await Future.wait([
          for (var i = 0; i < groups.length && i < 3; i++) worker(),
        ]);
        await widget.persistence?.flush();
      }
      if (!mounted) return;
      if (failed.isEmpty) {
        _queueToasts(['Подписки обновлены'], error: false);
      } else {
        if (widget.previewRefreshAction != null) {
          setState(() {
            for (final group in groups) {
              if (failed.contains(group.id) || failed.contains(group.name)) {
                _manualRefreshFailures[group.id] = group.contentRevision;
              }
            }
          });
        }
      }
      if (widget.persistence?.error != null) {
        _queueToasts(['Не удалось сохранить обновлённые подписки']);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          for (final group in groups) {
            _manualRefreshFailures[group.id] = group.contentRevision;
          }
        });
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _queueToasts(List<String> messages, {bool error = true}) {
    if (!mounted || messages.isEmpty) return;
    final wasEmpty = _toastQueue.isEmpty;
    setState(() {
      _toastQueue.addAll([
        for (final message in messages)
          (message: context.tr(message), error: error),
      ]);
    });
    if (wasEmpty) _armToastTimer();
  }

  void _armToastTimer() {
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 6), _dismissToast);
  }

  void _dismissToast() {
    _toastTimer?.cancel();
    if (!mounted || _toastQueue.isEmpty) return;
    setState(() => _toastQueue.removeAt(0));
    if (_toastQueue.isNotEmpty) _armToastTimer();
  }

  Future<void> _pingAll() => _latencies.checkAll([
    for (final group in widget.controller.groups)
      for (final server in group.servers) server.profile,
  ]);

  bool get _connectionBusy =>
      widget.vpn != null && !widget.vpn!.canChangeConnection;

  Future<void> _selectAutomatic(
    SubscriptionGroup group, {
    VoidCallback? onSelected,
  }) async {
    if (_connectionBusy ||
        group.isDemo ||
        group.servers.length < 2 ||
        group.servers.length > 32) {
      return;
    }
    final revision = ++_selectionRevision;
    final vpn = widget.vpn;
    // Save the explicit user intent before native notifications. No subscription
    // content may activate automatic mode by itself.
    widget.controller.selectAutomaticGroup(group.id);
    onSelected?.call();
    if (vpn != null && (vpn.canDisconnect || vpn.connectionChangePending)) {
      await vpn.startAutomaticSelection([
        for (final server in group.servers) server.profile,
      ]);
      if (!mounted || revision != _selectionRevision) return;
    }
  }

  Future<void> _selectServer(
    SubscriptionGroup group,
    ServerEntry server, {
    VoidCallback? onSelected,
  }) async {
    if (_connectionBusy) return;
    final revision = ++_selectionRevision;
    final vpn = widget.vpn;
    var pickerClosed = false;
    if (vpn != null && (vpn.canDisconnect || vpn.connectionChangePending)) {
      final bool accepted;
      try {
        final request = vpn.requestConnection(server.profile);
        // The controller serializes/coalesces native requests. Let the user
        // choose again or cancel while this acknowledgement is outstanding.
        onSelected?.call();
        pickerClosed = true;
        accepted = await request;
      } catch (_) {
        return;
      }
      if (!mounted || !accepted || revision != _selectionRevision) return;
    }
    widget.controller.selectServer(groupId: group.id, serverId: server.id);
    if (!pickerClosed) onSelected?.call();
  }

  Future<void> _changeConnectionMode(VpnMode mode) async {
    final vpn = widget.vpn;
    if (vpn == null ||
        _connectionBusy ||
        !vpn.modeSwitchSupported ||
        vpn.mode == mode) {
      return;
    }
    final changingConnection = vpn.canDisconnect || vpn.connectionChangePending;
    final profile = changingConnection
        ? _displayedServer?.profile
        : widget.controller.selectedServer?.profile;
    final revision = ++_selectionRevision;
    final accepted = await vpn.changeMode(mode, profile: profile);
    if (!mounted ||
        !accepted ||
        !changingConnection ||
        revision != _selectionRevision ||
        profile == null) {
      return;
    }
    // A mode change can supersede a queued server choice. Persist the same
    // acknowledged profile so disconnecting does not restore an older choice.
    for (final group in widget.controller.groups) {
      for (final server in group.servers) {
        if (server.profile.id == profile.id) {
          if (widget.controller.selectedAutomaticGroupId == group.id) {
            widget.controller.selectAutomaticGroup(group.id);
            return;
          }
          widget.controller.selectServer(
            groupId: group.id,
            serverId: server.id,
          );
          return;
        }
      }
    }
  }

  Future<void> _reviewSubscription(String groupId) async {
    final group = widget.controller.groups
        .where((g) => g.id == groupId)
        .firstOrNull;
    await showSubscriptionIssues(
      context,
      controller: widget.controller,
      groupId: groupId,
      refreshFailure:
          group != null &&
              _manualRefreshFailures[group.id] == group.contentRevision
          ? widget.previewRefreshAction != null
                ? 'Нет соединения с сервером подписки. Последний список сохранён.'
                : 'Не удалось обновить подписку'
          : _refreshes.errorCode(groupId) != null
          ? 'Не удалось обновить подписку'
          : null,
      onRetry: () => unawaited(_refresh(groupId: groupId)),
    );
  }

  Future<void> _editSubscription(SubscriptionGroup group) async {
    final saved = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (_) => SubscriptionEditDialog(
        controller: widget.controller,
        group: group,
        persistence: widget.persistence,
        fullscreen: _desktop && _layout == DesktopLayout.minimal,
      ),
    );
    if (!mounted || saved != true) return;
    final current = widget.controller.groups
        .where((g) => g.id == group.id)
        .firstOrNull;
    if (current?.sourceUrl != null && current!.sourceUrl != group.sourceUrl) {
      unawaited(_refresh(groupId: group.id));
    }
  }

  Future<void> _deleteSubscription(SubscriptionGroup group) async {
    final accepted = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.tr('Удалить подписку?')),
        content: Text(
          ctx.tr(
            '«{name}» и её подключения будут удалены.',
            values: {'name': group.name},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.tr('Удалить')),
          ),
        ],
      ),
    );
    if (!mounted || accepted != true) return;
    _selectionRevision++;
    widget.controller.removeSubscription(group.id);
    await widget.persistence?.flush();
    if (mounted && widget.persistence?.error != null) {
      _queueToasts(['Не удалось сохранить подписку']);
    }
  }

  bool get _desktop => kIsWeb
      ? Uri.base.queryParameters['desktop'] == '1'
      : defaultTargetPlatform == TargetPlatform.windows;

  ServerEntry? get _displayedServer {
    final activeId =
        widget.vpn?.desiredProfileId ?? widget.vpn?.status.activeProfileId;
    if (activeId == null) return widget.controller.selectedServer;
    return [for (final group in widget.controller.groups) ...group.servers]
        .where((server) => server.profile.id == activeId)
        .firstOrNull;
  }

  void _changeLayout(DesktopLayout value) {
    if (_layout == value) return;
    setState(() => _layout = value);
    widget.onDesktopLayoutChanged?.call(value);
    unawaited(applyDesktopLayout(value));
    _scheduleAutoPing();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: NotificationListener<ScrollEndNotification>(
      onNotification: (_) {
        _scheduleAutoPing();
        return false;
      },
      child: SafeArea(
        child: _desktop ? _desktopView() : _withToast(_mobileView()),
      ),
    ),
  );

  Widget _desktopView() => LayoutBuilder(
    builder: (context, constraints) {
      final canvas = _layout.canvasSize;
      final width = constraints.maxWidth;
      final height = canvas.height * width / canvas.width;
      return ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minWidth: width,
            maxWidth: width,
            minHeight: height,
            maxHeight: height,
            child: SizedBox(
              width: width,
              height: height,
              child: FittedBox(
                fit: BoxFit.fill,
                alignment: Alignment.topCenter,
                child: SizedBox.fromSize(
                  size: canvas,
                  child: _withToast(
                    Column(
                      children: [
                        if (widget.appUpdate case final update?)
                          AppUpdateStrip(
                            state: update,
                            onPressed: widget.onAppUpdate ?? () {},
                          ),
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              20,
                              widget.appUpdate == null ? 12 : 6,
                              20,
                              20,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _header(desktop: true),
                                Expanded(
                                  child: switch (_layout) {
                                    DesktopLayout.minimal => _minimalView(),
                                    DesktopLayout.medium => _mediumView(),
                                    DesktopLayout.large => _largeView(),
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
  Widget _withToast(Widget child) => Stack(
    fit: StackFit.expand,
    children: [
      ExcludeFocus(
        excluding: _serverPickerOpen,
        child: ExcludeSemantics(excluding: _serverPickerOpen, child: child),
      ),
      if (_serverPickerOpen) Positioned.fill(child: _serverPickerOverlay()),
      if (_toastQueue.isNotEmpty)
        Positioned(
          left: 16,
          right: 16,
          top: widget.appUpdate == null ? 10 : 34,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Semantics(
                liveRegion: true,
                child: Material(
                  key: const Key('subscription-toast'),
                  elevation: 6,
                  shadowColor: Colors.black.withValues(alpha: .25),
                  color: Theme.of(context).colorScheme.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                    side: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(13, 11, 6, 11),
                    child: Row(
                      children: [
                        Icon(
                          _toastQueue.first.error
                              ? CupertinoIcons.exclamationmark_circle
                              : CupertinoIcons.check_mark_circled,
                          size: 21,
                          color: _toastQueue.first.error
                              ? Theme.of(context).colorScheme.error
                              : const Color(0xff59d98e),
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Tooltip(
                                message: _toastQueue.first.message,
                                child: Text(
                                  _toastQueue.first.message,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                              if (_toastQueue.length > 1)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    context.tr(
                                      'Ещё {count}',
                                      values: {'count': _toastQueue.length - 1},
                                    ),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          key: const Key('dismiss-subscription-toast'),
                          tooltip: context.tr('Закрыть уведомление'),
                          onPressed: _dismissToast,
                          icon: const Icon(CupertinoIcons.xmark, size: 15),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 30,
                            height: 34,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );

  Widget _mobileView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (widget.appUpdate case final update?)
        AppUpdateStrip(state: update, onPressed: widget.onAppUpdate ?? () {}),
      Expanded(
        child: SingleChildScrollView(
          key: const PageStorageKey('home-scroll'),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(desktop: false),
              const SizedBox(height: 30),
              Center(child: _connection(230)),
              const SizedBox(height: 34),
              _servers(),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _minimalView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) {
            const topGap = 24.0;
            const bottomGap = 8.0;
            const selectorHeight = 36.0;
            const selectorGap = 8.0;
            final diameter =
                (constraints.maxHeight -
                        topGap -
                        bottomGap -
                        selectorHeight -
                        selectorGap)
                    .clamp(1.0, 232.0);
            return Padding(
              padding: const EdgeInsets.only(top: topGap, bottom: bottomGap),
              child: Center(child: _powerControls(diameter)),
            );
          },
        ),
      ),
      _currentConnection(),
    ],
  );

  Widget _mediumView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        height: 322,
        child: Padding(
          padding: const EdgeInsets.only(top: 24),
          child: Center(child: _powerControls(254)),
        ),
      ),
      Expanded(child: _scrollingServers()),
    ],
  );

  Widget _largeView() => Padding(
    padding: const EdgeInsets.only(top: 22),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Center(child: _powerControls(282)),
                ),
              ),
              _connectionDetails(),
            ],
          ),
        ),
        const SizedBox(width: 28),
        VerticalDivider(
          width: 1,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        const SizedBox(width: 28),
        Expanded(flex: 5, child: _scrollingServers()),
      ],
    ),
  );

  Widget _scrollingServers({
    ScrollController? scrollController,
    VoidCallback? onSelected,
    VoidCallback? onClose,
  }) {
    final scroll = scrollController ?? _serversScroll;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _serversHeader(onClose: onClose),
        const SizedBox(height: 7),
        Expanded(
          child: Scrollbar(
            controller: scroll,
            child: SingleChildScrollView(
              key: PageStorageKey(
                'servers-${onClose == null ? _layout.name : 'picker'}',
              ),
              controller: scroll,
              primary: false,
              padding: const EdgeInsets.only(bottom: 8),
              child: _serverGroups(onSelected: onSelected),
            ),
          ),
        ),
      ],
    );
  }

  void _showServerPicker() {
    setState(() => _serverPickerOpen = true);
    _scheduleAutoPing();
  }

  void _closeServerPicker() {
    if (mounted) setState(() => _serverPickerOpen = false);
    _scheduleAutoPing();
  }

  Widget _serverPickerOverlay() => Stack(
    children: [
      ModalBarrier(
        color: Colors.black.withValues(alpha: .45),
        dismissible: true,
        onDismiss: _closeServerPicker,
        semanticsLabel: context.tr('Закрыть выбор подключения'),
      ),
      CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _closeServerPicker,
        },
        child: FocusScope(
          node: _pickerFocus,
          autofocus: true,
          child: LayoutBuilder(
            builder: (context, constraints) => Dialog(
              key: const Key('connection-picker-dialog'),
              insetPadding: _layout == DesktopLayout.minimal
                  ? EdgeInsets.zero
                  : const EdgeInsets.all(16),
              shape: _layout == DesktopLayout.minimal
                  ? const RoundedRectangleBorder()
                  : null,
              child: SizedBox(
                width: _layout == DesktopLayout.minimal
                    ? constraints.maxWidth
                    : (constraints.maxWidth - 32).clamp(0.0, 520.0),
                height: _layout == DesktopLayout.minimal
                    ? constraints.maxHeight
                    : (constraints.maxHeight - 32).clamp(0.0, 600.0),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _scrollingServers(
                    scrollController: _pickerScroll,
                    onSelected: _closeServerPicker,
                    onClose: _closeServerPicker,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _header({required bool desktop}) => SizedBox(
    height: 44,
    child: Stack(
      alignment: Alignment.center,
      children: [
        if (desktop)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) {
                startDesktopWindowDrag();
              },
              child: const SizedBox.expand(),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: GestureDetector(
            onPanStart: desktop
                ? (_) {
                    startDesktopWindowDrag();
                  }
                : null,
            child: _brand(),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_hasNotice)
                HeaderIconButton(
                  tooltip: context.tr('Сообщения приложения'),
                  key: const Key('connection-notice'),
                  onPressed: _showNotice,
                  icon: CupertinoIcons.exclamationmark_circle,
                  color: Theme.of(context).colorScheme.error,
                ),
              HeaderIconButton(
                tooltip: context.tr('Настройки'),
                key: const Key('settings-button'),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle:
                      !(_desktop && _layout == DesktopLayout.minimal),
                  useSafeArea: true,
                  shape: _desktop && _layout == DesktopLayout.minimal
                      ? const RoundedRectangleBorder()
                      : null,
                  constraints: BoxConstraints(
                    maxWidth: _desktop && _layout == DesktopLayout.minimal
                        ? double.infinity
                        : 600,
                  ),
                  builder: (_) => ModalSheetScrollScope(
                    child: SettingsSheet(
                      controller: widget.controller,
                      vpn: widget.vpn,
                      persistence: widget.persistence,
                      themeMode: widget.themeMode,
                      onThemeChanged: widget.onThemeChanged,
                      onAdd: () => _add(),
                      previewVersion: widget.previewVersion,
                      previewBuild: widget.previewBuild,
                      fullscreen: _desktop && _layout == DesktopLayout.minimal,
                    ),
                  ),
                ),
                icon: CupertinoIcons.gear_alt,
              ),
              if (desktop) const DesktopWindowControls(),
            ],
          ),
        ),
      ],
    ),
  );
  Widget _brand() => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      ColorFiltered(
        colorFilter: ColorFilter.matrix([
          0,
          0,
          0,
          0,
          Theme.of(context).colorScheme.primary.r * 255,
          0,
          0,
          0,
          0,
          Theme.of(context).colorScheme.primary.g * 255,
          0,
          0,
          0,
          0,
          Theme.of(context).colorScheme.primary.b * 255,
          1.04,
          0,
          0,
          0,
          -5,
        ]),
        child: Image.asset(
          'assets/images/squirrel-mask.png',
          width: 34,
          height: 34,
          filterQuality: FilterQuality.high,
          cacheWidth: 204,
          cacheHeight: 204,
          excludeFromSemantics: true,
        ),
      ),
      Transform.translate(
        offset: const Offset(-3, 0),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Semantics(
            header: true,
            child: const Text(
              'ExVPN',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w500,
                letterSpacing: -.7,
              ),
            ),
          ),
        ),
      ),
    ],
  );

  bool get _hasNotice =>
      widget.storageWarning != null ||
      widget.persistence?.error != null ||
      widget.vpn?.lastErrorCode != null ||
      widget.vpn?.status.phase == VpnPhase.blocked;

  Future<void> _showNotice() {
    final error = widget.vpn?.lastErrorCode;
    final messages = <String>[
      if (error != null)
        switch (error) {
          'service_not_installed' ||
          'service_unavailable' ||
          'ipc_unavailable' => 'Служба ExVPN недоступна.',
          'system_testing_required' =>
            'Системное подключение VPN пока недоступно.',
          'native_storage_unavailable' =>
            'Не удалось открыть защищённые настройки VPN.',
          'exclusions_unavailable' =>
            'Не удалось прочитать исключения приложений.',
          _ => vpnErrorText(error),
        },
      if (widget.vpn?.status.phase == VpnPhase.blocked)
        'Трафик заблокирован. Восстановите или отключите VPN.',
      if (widget.persistence?.error != null)
        'Изменения не сохранены. Повторите сохранение.',
      if (widget.storageWarning != null && widget.persistence?.error == null)
        widget.storageWarning!.contains('восстановлены')
            ? 'Подписки восстановлены после прерванного сохранения.'
            : 'Не удалось открыть сохранённые подписки.',
    ];
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        insetPadding: const EdgeInsets.all(16),
        constraints: const BoxConstraints(maxWidth: 420),
        titlePadding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
        title: Row(
          children: [
            Expanded(
              child: Text(
                context.tr('Сообщения'),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              tooltip: context.tr('Закрыть'),
              onPressed: () => Navigator.pop(dialogContext),
              icon: const Icon(CupertinoIcons.xmark, size: 18),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < messages.length; i++)
                Padding(
                  padding: EdgeInsets.only(
                    bottom: i == messages.length - 1 ? 0 : 12,
                  ),
                  child: Text(
                    context.tr(messages[i]),
                    style: const TextStyle(fontSize: 14, height: 1.45),
                  ),
                ),
              if (widget.persistence?.error != null)
                TextButton(
                  onPressed: () async {
                    await widget.persistence!.flush();
                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                  },
                  child: Text(context.tr('Повторить сохранение')),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _powerControls(double size) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _connection(size),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        height: 36,
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              Positioned(
                left: (constraints.maxWidth - 170) / 2 - 90,
                top: 2,
                child: _layoutSelector(),
              ),
              Align(alignment: Alignment.center, child: _modeSelector()),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _layoutSelector() => SlidingSegments<DesktopLayout>(
    key: _layoutControlKey,
    width: 82,
    height: 32,
    showBackground: false,
    iconSize: 20,
    items: [
      for (final mode in DesktopLayout.values)
        SlidingSegment(
          value: mode,
          icon: switch (mode) {
            DesktopLayout.minimal => CupertinoIcons.square,
            DesktopLayout.medium => CupertinoIcons.square_list,
            DesktopLayout.large => CupertinoIcons.sidebar_left,
          },
          tooltip: context.tr(mode.label),
        ),
    ],
    value: _layout,
    onChanged: _changeLayout,
  );

  Widget _modeSelector() {
    final vpn = widget.vpn;
    final supported = vpn?.modeSwitchSupported == true;
    return SlidingSegments<VpnMode>(
      key: _modeControlKey,
      width: 170,
      height: 36,
      items: [
        for (final mode in VpnMode.values)
          SlidingSegment(
            value: mode,
            label: mode.name.toUpperCase(),
            tooltip: !supported
                ? context.tr('Смена режима недоступна на этом устройстве')
                : context.tr(
                    mode == VpnMode.proxy
                        ? 'Приложения, использующие прокси Windows'
                        : 'Весь трафик через VPN',
                  ),
          ),
      ],
      value: vpn?.mode ?? VpnMode.vpn,
      onChanged: supported && !_connectionBusy ? _changeConnectionMode : null,
    );
  }

  Widget _connection(double size) {
    final vpn = widget.vpn;
    final phase = vpn?.status.phase ?? VpnPhase.disconnected;
    final checking = vpn != null && !vpn.initialized;
    final modeLabel = vpn?.mode == VpnMode.proxy ? 'PROXY' : 'VPN';
    final action = checking
        ? context.tr('Проверка состояния VPN')
        : vpn?.canDisconnect == true
        ? context.tr('Отключить {mode}', values: {'mode': modeLabel})
        : context.tr('Подключить {mode}', values: {'mode': modeLabel});
    return PowerButton(
      key: const Key('connect-button'),
      size: size,
      onPressed: _connect,
      enabled: !checking && (vpn == null || vpn.canChangeConnection),
      label: action,
      active: phase == VpnPhase.connected,
      connecting: vpn?.connecting ?? false,
      failed:
          phase == VpnPhase.blocked ||
          phase == VpnPhase.error ||
          (phase == VpnPhase.disconnected && vpn?.lastErrorCode != null),
      elapsedLabel: phase == VpnPhase.connected
          ? _elapsed(vpn?.status.connectedAt)
          : null,
    );
  }

  Widget _currentConnection() {
    final server = _displayedServer;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.onSurface.withValues(alpha: .035),
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        key: const Key('current-connection'),
        borderRadius: BorderRadius.circular(13),
        onTap: _showServerPicker,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              if (server != null) ...[
                _flag(server, selected: false),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      server?.name ?? context.tr('Выбрать подключение'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (server != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        server.protocolLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                CupertinoIcons.chevron_right,
                size: 15,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _connectionDetails() {
    final server = _displayedServer;
    final vpn = widget.vpn;
    final phase = vpn?.status.phase ?? VpnPhase.disconnected;
    final state = switch (phase) {
      VpnPhase.disconnected => 'Не подключено',
      VpnPhase.requestingPermission => 'Ожидание разрешения',
      VpnPhase.connecting => 'Подключение',
      VpnPhase.connected => 'Подключено',
      VpnPhase.reconnecting => 'Восстановление',
      VpnPhase.blocked => 'Трафик заблокирован',
      VpnPhase.error => 'Ошибка подключения',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (server != null) ...[
            Row(
              children: [
                _flag(server, selected: false),
                const SizedBox(width: 13),
                Expanded(
                  child: Text(
                    server.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -.5,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
          ],
          _detailRow('Состояние', context.tr(state)),
          _detailRow('Протокол', server?.protocolLabel ?? '—'),
          _detailRow(
            'Трафик',
            vpn?.statisticsAvailable == true
                ? '↑ ${_bytes(vpn!.stats.uploadBytes)}  ↓ ${_bytes(vpn.stats.downloadBytes)}'
                : '—',
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr(label),
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    ),
  );

  String _elapsed(DateTime? start) {
    final seconds = start == null
        ? 0
        : DateTime.now().difference(start).inSeconds.clamp(0, 999999999);
    return '${(seconds ~/ 3600).toString().padLeft(2, '0')}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  String _bytes(int bytes) => bytes < 1024
      ? context.tr('{value} Б', values: {'value': bytes})
      : bytes < 1048576
      ? context.tr(
          '{value} КБ',
          values: {'value': (bytes / 1024).toStringAsFixed(1)},
        )
      : context.tr(
          '{value} МБ',
          values: {'value': (bytes / 1048576).toStringAsFixed(1)},
        );

  Widget _servers() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [_serversHeader(), const SizedBox(height: 7), _serverGroups()],
  );

  Widget _serverGroups({VoidCallback? onSelected}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (widget.controller.showAddSubscriptionButton) _empty(),
      for (final group in widget.controller.groups)
        _group(group, onSelected: onSelected),
    ],
  );
  Widget _serversHeader({VoidCallback? onClose}) => SizedBox(
    height: 46,
    child: Row(
      children: [
        Expanded(
          child: Text(
            context.tr('Серверы'),
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              letterSpacing: -.5,
            ),
          ),
        ),
        IconButton(
          tooltip: context.tr('Проверить пинг всех подключений'),
          key: const Key('ping-all-button'),
          onPressed:
              _latencies.busy ||
                  widget.controller.groups.every(
                    (group) => group.servers.isEmpty,
                  )
              ? null
              : _pingAll,
          icon: _latencies.busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                )
              : const Icon(CupertinoIcons.speedometer, size: 22),
        ),
        IconButton(
          tooltip: context.tr('Обновить подписки'),
          key: const Key('refresh-button'),
          onPressed: _refreshBusy ? null : _refresh,
          icon: _refreshBusy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                )
              : const Icon(CupertinoIcons.arrow_2_circlepath, size: 22),
        ),
        IconButton(
          tooltip: context.tr('Добавить подписку'),
          key: const Key('add-button'),
          onPressed: _add,
          icon: const Icon(CupertinoIcons.plus, size: 24),
        ),
        if (onClose != null)
          IconButton(
            key: const Key('close-connection-picker'),
            tooltip: context.tr('Закрыть'),
            onPressed: onClose,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 40),
            icon: const Icon(CupertinoIcons.xmark, size: 18),
          ),
      ],
    ),
  );

  Widget _empty() => Padding(
    padding: const EdgeInsets.fromLTRB(8, 28, 8, 8),
    child: Column(
      children: [
        Text(
          context.tr('Ваши серверы появятся здесь'),
          style: TextStyle(
            fontSize: 17,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          context.tr('Добавьте подписку своего VPN-провайдера'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const Key('empty-add-button'),
            onPressed: _add,
            icon: const Icon(CupertinoIcons.plus, size: 19),
            label: Text(context.tr('Добавить подписку')),
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.onSurface,
              padding: const EdgeInsets.all(17),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  bool _groupRefreshFailed(SubscriptionGroup group) =>
      (_refreshes.failed.contains(group.id) &&
          (_refreshes.errorCode(group.id) != null ||
              (widget.controller.pendingUpdate(group.id)?.issues ??
                      group.issues)
                  .any(
                    (issue) =>
                        issue.code != ImportIssueCode.unsupportedProtocol &&
                        issue.code != ImportIssueCode.unsupportedFeature &&
                        issue.code != ImportIssueCode.ignoredLocalConfiguration,
                  ))) ||
      _manualRefreshFailures[group.id] == group.contentRevision;

  Widget _group(SubscriptionGroup group, {VoidCallback? onSelected}) => Column(
    children: [
      const SizedBox(height: 4),
      Semantics(
        expanded: group.expanded,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('group-${group.id}'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => widget.controller.toggleGroup(group.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 7),
              child: Row(
                children: [
                  SizedBox(
                    height: 30,
                    child: Icon(
                      group.expanded
                          ? CupertinoIcons.chevron_down
                          : CupertinoIcons.chevron_right,
                      size: 16,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      group.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -.4,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_groupRefreshFailed(group))
                    SizedBox.square(
                      dimension: 30,
                      child: IconButton(
                        key: ValueKey('subscription-issues-${group.id}'),
                        tooltip: context.tr('Не удалось обновить подписку'),
                        onPressed: () => _reviewSubscription(group.id),
                        constraints: const BoxConstraints.tightFor(
                          width: 30,
                          height: 30,
                        ),
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          CupertinoIcons.exclamationmark_circle,
                          size: 17,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  PopupMenuButton<_SubscriptionMenuAction>(
                    key: ValueKey('subscription-menu-${group.id}'),
                    tooltip: context.tr('Действия с подпиской'),
                    position: PopupMenuPosition.under,
                    padding: EdgeInsets.zero,
                    style: IconButton.styleFrom(
                      minimumSize: const Size.square(30),
                      fixedSize: const Size.square(30),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onCanceled: _scheduleAutoPing,
                    constraints: const BoxConstraints(minWidth: 176),
                    icon: SizedBox.square(
                      dimension: 20,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          for (var i = 0; i < 3; i++)
                            DecoratedBox(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                              child: const SizedBox.square(dimension: 3),
                            ),
                        ],
                      ),
                    ),
                    onSelected: (action) => switch (action) {
                      _SubscriptionMenuAction.edit => unawaited(
                        _editSubscription(group),
                      ),
                      _SubscriptionMenuAction.delete => unawaited(
                        _deleteSubscription(group),
                      ),
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: _SubscriptionMenuAction.edit,
                        child: Row(
                          children: [
                            const Icon(CupertinoIcons.tag, size: 18),
                            const SizedBox(width: 10),
                            Text(context.tr('Редактировать')),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: _SubscriptionMenuAction.delete,
                        child: Row(
                          children: [
                            Icon(
                              Icons.delete_outline_rounded,
                              size: 18,
                              color: Theme.of(context).colorScheme.error,
                            ),
                            const SizedBox(width: 10),
                            Text(context.tr('Удалить')),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      if (group.expanded) ...[
        if (group.servers.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              context.tr('В подписке пока нет доступных подключений'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        SubscriptionTree(
          children: [
            if (!group.isDemo && group.servers.length >= 2)
              _automaticServer(group, onSelected: onSelected),
            for (final server in group.servers)
              _server(group, server, onSelected: onSelected),
          ],
        ),
      ],
      const SizedBox(height: 6),
    ],
  );

  Widget _flag(ServerEntry server, {required bool selected}) =>
      CountryFlag(countryCode: server.countryCode, size: 24);

  Widget _automaticServer(SubscriptionGroup group, {VoidCallback? onSelected}) {
    final selected = widget.controller.selectedAutomaticGroupId == group.id;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: .13)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        child: ListTile(
          key: ValueKey('automatic-${group.id}'),
          dense: true,
          minTileHeight: 48,
          minLeadingWidth: 24,
          horizontalTitleGap: 10,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: Icon(
            CupertinoIcons.arrow_2_circlepath,
            color: scheme.primary,
            size: 24,
          ),
          title: Text(
            context.tr('Авто · основной и резерв'),
            style: const TextStyle(fontSize: 14),
          ),
          subtitle: Text(
            context.tr(
              group.servers.length > 32
                  ? 'Авто доступно для групп до 32 серверов'
                  : 'Проверка HTTPS · резерв при обрыве',
            ),
            style: const TextStyle(fontSize: 11.5),
          ),
          trailing: selected
              ? Icon(CupertinoIcons.check_mark, size: 20, color: scheme.primary)
              : null,
          selected: selected,
          enabled: !_connectionBusy && group.servers.length <= 32,
          onTap: () => _selectAutomatic(group, onSelected: onSelected),
        ),
      ),
    );
  }

  Widget _latency(ServerEntry server, {required bool selected}) {
    final sample = _latencies.results[server.profile.id];
    final checking = _latencies.checking.contains(server.profile.id);
    final milliseconds =
        sample?.milliseconds ??
        (sample == null && server.isDemo ? server.latencyMs : null);
    final error = sample?.errorCode;
    final unsupported =
        error == 'latency_transport_unsupported' ||
        error == 'latency_platform_unsupported';
    final scheme = Theme.of(context).colorScheme;
    final darkVariant =
        selected || Theme.of(context).brightness == Brightness.light;
    final neutral = selected
        ? scheme.onPrimaryContainer.withValues(alpha: .6)
        : scheme.onSurfaceVariant;
    final Color color;
    if (checking || unsupported || (milliseconds == null && error == null)) {
      color = neutral;
    } else if (error != null || milliseconds! > 250) {
      color = darkVariant ? const Color(0xff9b2323) : const Color(0xffff7178);
    } else if (milliseconds > 100) {
      color = darkVariant ? const Color(0xff755100) : const Color(0xffffd166);
    } else {
      color = darkVariant ? const Color(0xff175c35) : const Color(0xff59d98e);
    }
    final hint = checking
        ? 'Проверка пинга…'
        : switch (error) {
            'latency_transport_unsupported' =>
              'Пинг для этого протокола недоступен',
            'latency_platform_unsupported' =>
              'Пинг недоступен на этой платформе',
            'latency_timeout' => 'Сервер не ответил вовремя',
            'latency_unreachable' => 'Нет ответа на TCP-проверку',
            'latency_invalid_profile' =>
              'Не удалось проверить параметры сервера',
            'latency_failed' => 'Не удалось проверить пинг',
            _ =>
              milliseconds == null
                  ? 'Пинг ещё не проверен'
                  : 'Задержка соединения с сервером (TCP)',
          };
    return Tooltip(
      message: context.tr(hint),
      child: Text(
        checking
            ? '…'
            : milliseconds == null || error != null
            ? '—'
            : context.tr('{value} мс', values: {'value': milliseconds}),
        style: TextStyle(
          fontSize: 14,
          color: color,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
  }

  Widget _server(
    SubscriptionGroup group,
    ServerEntry server, {
    VoidCallback? onSelected,
  }) {
    final rows = onSelected == null ? _latencyRows : _pickerLatencyRows;
    final rowId = '${group.id}/${server.id}';
    final rowKey = rows[rowId]?.key ?? GlobalKey();
    rows[rowId] = (key: rowKey, profile: server.profile);
    final desired = widget.vpn?.desiredProfileId;
    final selected = desired != null
        ? desired == server.profile.id
        : widget.controller.selectedGroupId == group.id &&
              widget.controller.selectedServerId == server.id;
    final scheme = Theme.of(context).colorScheme;
    final light = Theme.of(context).brightness == Brightness.light;
    final foreground = selected && light
        ? scheme.onPrimaryContainer
        : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Semantics(
        selected: selected,
        button: true,
        enabled: !_connectionBusy,
        label: '${server.name}, ${server.protocolLabel}',
        child: Material(
          color: selected
              ? light
                    ? scheme.primaryContainer
                    : scheme.primary.withValues(alpha: .13)
              : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
            side: selected && Theme.of(context).brightness == Brightness.light
                ? BorderSide(
                    color: scheme.primary.withValues(alpha: .25),
                    width: .7,
                  )
                : BorderSide.none,
          ),
          child: InkWell(
            key: ValueKey('server-${group.id}-${server.id}'),
            borderRadius: BorderRadius.circular(11),
            onTap: _connectionBusy
                ? null
                : () => _selectServer(group, server, onSelected: onSelected),
            child: ConstrainedBox(
              key: rowKey,
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                child: Row(
                  children: [
                    _flag(server, selected: selected),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            server.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              height: 1.2,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.45,
                              color: foreground,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            server.protocolLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.2,
                              color: selected && light
                                  ? foreground.withValues(alpha: .72)
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _latency(server, selected: selected && light),
                    SizedBox(
                      width: 26,
                      child: selected
                          ? Align(
                              alignment: Alignment.centerRight,
                              child: Icon(
                                Icons.check_rounded,
                                color: light
                                    ? scheme.onPrimaryContainer
                                    : scheme.primary,
                                size: 20,
                              ),
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
