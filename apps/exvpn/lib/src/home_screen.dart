import 'dart:async';

import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;

import 'import_dialog.dart';
import 'settings_sheet.dart';
import 'theme.dart';
import 'power_button.dart';
import '../services/vpn_controller.dart';
import '../services/subscription_persistence.dart';
import '../services/subscription_refresh.dart';
import '../services/subscription_loader.dart';
import '../build_identity.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.themeMode,
    required this.onThemeChanged,
    this.vpn,
    this.persistence,
    this.storageWarning,
  });
  final AppController controller;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final VpnController? vpn;
  final SubscriptionPersistence? persistence;
  final String? storageWarning;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late final StreamSubscription<void> _changes;
  Timer? _clock;
  late final SubscriptionRefresh _refreshes;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.vpn?.addListener(_vpnChanged);
    widget.persistence?.addListener(_storageChanged);
    _refreshes = SubscriptionRefresh(widget.controller)
      ..addListener(_storageChanged);
    unawaited(_refreshes.refreshStale());
    _changes = widget.controller.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  void _storageChanged() {
    if (mounted) setState(() {});
  }

  void _vpnChanged() {
    if (!mounted) return;
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.vpn?.refresh();
  }

  @override
  void dispose() {
    _changes.cancel();
    _clock?.cancel();
    widget.vpn?.removeListener(_vpnChanged);
    widget.persistence?.removeListener(_storageChanged);
    _refreshes.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _add({SubscriptionGroup? group}) => showDialog<void>(
    context: context,
    builder: (_) => ImportDialog(
      controller: widget.controller,
      group: group,
      persistence: widget.persistence,
    ),
  );

  Future<void> _connect() async {
    final vpn = widget.vpn;
    if (vpn != null && !vpn.initialized) return;
    if (vpn != null && vpn.canDisconnect) {
      await vpn.disconnect();
      if (mounted && vpn.status.processCrashProtection) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Системная блокировка может оставаться включённой. Проверьте настройки VPN в системе.',
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
      await vpn.connect(widget.controller.selectedServer!.profile);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('VPN пока недоступен'),
        content: const Text(
          'Интерфейс готов к подключению системного VPN-модуля. '
          'В этой сборке туннель не запускается и защита трафика не включается.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Понятно'),
          ),
        ],
      ),
    );
  }

  void _refresh() {
    final groups = widget.controller.groups;
    if (groups.isEmpty) {
      _add();
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Обновить подписку'),
        children: [
          for (final group in groups)
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(ctx);
                if (group.sourceUrl == null) {
                  _add(group: group);
                } else {
                  _refreshGroup(group);
                }
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(group.name, style: const TextStyle(fontSize: 16)),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _refreshGroup(SubscriptionGroup group) async {
    final success = await _refreshes.refresh(group.id);
    await widget.persistence?.flush();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'Подписка обновлена'
                : switch (_refreshes.errorCode(group.id)) {
                    SubscriptionLoadErrorCode.deviceLimitReached => 'Достигнут лимит устройств у провайдера. Последний рабочий список сохранён.',
                    SubscriptionLoadErrorCode.deviceIdentityUnavailable => 'Не удалось открыть идентификатор устройства. Перезапустите приложение. Рабочий список сохранён.',
                    SubscriptionLoadErrorCode.deviceIdentityRejected => 'Провайдер не принял идентификатор ExVPN. Рабочий список сохранён.',
                    _ => 'Обновление не удалось. Последний рабочий список сохранён.',
                  },
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 900;
          final compact = box.maxHeight < 780 || box.maxWidth < 380;
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1180),
              child: SingleChildScrollView(
                key: const PageStorageKey('home-scroll'),
                padding: EdgeInsets.fromLTRB(
                  wide ? 44 : 16,
                  wide ? 32 : 28,
                  wide ? 44 : 16,
                  32,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(wide),
                    if (widget.storageWarning != null ||
                        widget.persistence?.error != null)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            Text(
                              widget.persistence?.error != null
                                  ? 'Не удалось сохранить изменения. Последний сохранённый список остаётся доступным.'
                                  : widget.storageWarning!,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                                fontSize: 13,
                              ),
                            ),
                            if (widget.persistence?.error != null)
                              TextButton(
                                onPressed: widget.persistence!.flush,
                                child: const Text('Повторить сохранение'),
                              ),
                          ],
                        ),
                      ),
                    if (wide) ...[
                      const SizedBox(height: 58),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 5, child: _connection(false, true)),
                          const SizedBox(width: 64),
                          Expanded(flex: 6, child: _servers()),
                        ],
                      ),
                    ] else ...[
                      SizedBox(height: compact ? 16 : 44),
                      _connection(compact, false),
                      SizedBox(height: compact ? 22 : 28),
                      _servers(),
                    ],
                    if (widget.controller.isDemo)
                      Padding(
                        padding: const EdgeInsets.only(top: 42),
                        child: Text(
                          'Макетные серверы · VPN не подключён',
                          textAlign: TextAlign.center,
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
            ),
          );
        },
      ),
    ),
  );

  Widget _header(bool wide) => SizedBox(
    height: 48,
    child: Row(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ColorFiltered(
                // A clean luminance mask avoids noisy generated transparency.
                colorFilter: const ColorFilter.matrix([
                  0,
                  0,
                  0,
                  0,
                  255,
                  0,
                  0,
                  0,
                  0,
                  189,
                  0,
                  0,
                  0,
                  0,
                  81,
                  1.04,
                  0,
                  0,
                  0,
                  -5,
                ]),
                child: Image.asset(
                  'assets/images/squirrel-mask.png',
                  width: 40,
                  height: 40,
                  // Mipmapped minification keeps the 26 px contour continuous.
                  filterQuality: FilterQuality.medium,
                  cacheWidth: 160,
                  cacheHeight: 160,
                  excludeFromSemantics: true,
                ),
              ),
              Transform.translate(
                offset: const Offset(-3, 0),
                child: const Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Text(
                    'ExVPN',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.7,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        if (wide)
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Text(
              '$appVersion · предварительная версия',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        IconButton(
          tooltip: 'Настройки',
          key: const Key('settings-button'),
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            showDragHandle: true,
            useSafeArea: true,
            constraints: const BoxConstraints(maxWidth: 600),
            builder: (_) => SettingsSheet(
              controller: widget.controller,
              vpn: widget.vpn,
              persistence: widget.persistence,
              themeMode: widget.themeMode,
              onThemeChanged: widget.onThemeChanged,
              onAdd: () => _add(),
            ),
          ),
          icon: const Icon(CupertinoIcons.gear_alt, size: 25),
        ),
      ],
    ),
  );

  Widget _connection(bool compact, bool wide) {
    final vpn = widget.vpn;
    final phase = vpn?.status.phase ?? VpnPhase.disconnected;
    final activeId = vpn?.status.activeProfileId;
    final active = [
      for (final group in widget.controller.groups) ...group.servers,
    ].where((server) => server.profile.id == activeId).firstOrNull;
    final displayed = activeId == null
        ? widget.controller.selectedServer
        : active;
    final stop = vpn?.canDisconnect ?? false;
    final checking = vpn != null && !vpn.initialized;
    final label = checking
        ? 'Проверка'
        : stop
        ? switch (phase) {
            VpnPhase.connected ||
            VpnPhase.reconnecting ||
            VpnPhase.blocked => 'Отключить',
            _ => 'Отменить',
          }
        : 'Подключить';
    final stateText = checking
        ? 'Проверка состояния VPN…'
        : switch (phase) {
            VpnPhase.disconnected =>
              vpn?.commandPending == true ? 'Запуск VPN…' : 'Не подключено',
            VpnPhase.requestingPermission => 'Ожидание разрешения',
            VpnPhase.connecting => 'Подключение…',
            VpnPhase.connected =>
              'Подключено · ${_elapsed(vpn?.status.connectedAt)}',
            VpnPhase.reconnecting => 'Восстановление соединения…',
            VpnPhase.blocked => 'Трафик заблокирован',
            VpnPhase.error => 'Ошибка подключения',
          };
    final size = wide
        ? 252.0
        : compact
        ? 176.0
        : 212.0;
    return Column(
      children: [
        PowerButton(
          key: const Key('connect-button'),
          size: size,
          onPressed: _connect,
          enabled: !checking,
          label: '$label VPN',
          active: phase == VpnPhase.connected,
          connecting: vpn?.connecting ?? false,
        ),
        const SizedBox(height: 16),
        Text(
          label,
          style: const TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.6,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          stateText,
          style: TextStyle(
            fontSize: 16,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        if (vpn?.lastErrorCode != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              '${vpnErrorText(vpn!.lastErrorCode)}\nКод: ${vpn.lastErrorCode}',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 13,
              ),
            ),
          ),
        if (phase == VpnPhase.connected) ...[
          const SizedBox(height: 8),
          Text(
            vpn!.statisticsAvailable
                ? '↑ ${_bytes(vpn.stats.uploadBytes)}   ↓ ${_bytes(vpn.stats.downloadBytes)}'
                : 'Статистика недоступна',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            vpn.status.processCrashProtection
                ? 'Системная защита подтверждена'
                : 'Защита при сбое процесса не подтверждена',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if ((wide || vpn != null) &&
            (displayed != null || activeId != null)) ...[
          SizedBox(height: wide ? 36 : 16),
          Text(
            displayed?.name ?? 'Активный сервер',
            style: const TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 5),
          Text(
            displayed?.protocolLabel ?? 'Сеанс системного VPN',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  String _elapsed(DateTime? start) {
    final seconds = start == null
        ? 0
        : DateTime.now().difference(start).inSeconds.clamp(0, 999999999);
    return '${(seconds ~/ 3600).toString().padLeft(2, '0')}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  String _bytes(int bytes) => bytes < 1024
      ? '$bytes Б'
      : bytes < 1048576
      ? '${(bytes / 1024).toStringAsFixed(1)} КБ'
      : '${(bytes / 1048576).toStringAsFixed(1)} МБ';

  Widget _servers() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Серверы',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Обновить подписки',
              key: const Key('refresh-button'),
              onPressed: _refresh,
              icon: const Icon(Icons.sync_rounded, size: 25),
            ),
            const SizedBox(width: 2),
            IconButton(
              tooltip: 'Добавить подписку',
              key: const Key('add-button'),
              onPressed: _add,
              icon: const Icon(Icons.add_rounded, size: 29),
            ),
          ],
        ),
      ),
      const SizedBox(height: 3),
      if (_refreshes.failed.isNotEmpty)
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Некоторые подписки не обновились. Используется последний рабочий список.',
            textAlign: TextAlign.center,
          ),
        ),
      if (widget.controller.showAddSubscriptionButton) _empty(),
      for (final group in widget.controller.groups) _group(group),
    ],
  );

  Widget _empty() => Padding(
    padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
    child: Column(
      children: [
        Text(
          'Ваши серверы появятся здесь',
          style: TextStyle(
            fontSize: 17,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Добавьте подписку своего VPN-провайдера',
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
            icon: const Icon(Icons.add),
            label: const Text('Добавить подписку'),
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

  Widget _group(SubscriptionGroup group) => Column(
    children: [
      Semantics(
        expanded: group.expanded,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('group-${group.id}'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => widget.controller.toggleGroup(group.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    group.expanded
                        ? Icons.expand_more_rounded
                        : Icons.chevron_right_rounded,
                    size: 25,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      group.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.4,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _count(group.servers.length),
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      if (group.expanded) ...[
        if (group.issues.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text(
              '${group.issues.length} записей не удалось импортировать. Проверьте данные подписки.',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        if (group.servers.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'В подписке пока нет доступных подключений',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        for (final server in group.servers) _server(group, server),
      ],
      const SizedBox(height: 10),
      const Divider(),
    ],
  );

  Widget _server(SubscriptionGroup group, ServerEntry server) {
    final selected =
        widget.controller.selectedGroupId == group.id &&
        widget.controller.selectedServerId == server.id;
    final scheme = Theme.of(context).colorScheme;
    final flag = server.countryCode?.toLowerCase();
    final known = const ['nl', 'de', 'fi', 'pl', 'se', 'fr'].contains(flag);
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: Semantics(
        selected: selected,
        button: true,
        label: '${server.name}, ${server.protocolLabel}',
        child: Material(
          color: selected ? amber : Colors.transparent,
          borderRadius: BorderRadius.circular(13),
          child: InkWell(
            key: ValueKey('server-${group.id}-${server.id}'),
            borderRadius: BorderRadius.circular(13),
            onTap: () => widget.controller.selectServer(
              groupId: group.id,
              serverId: server.id,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: known
                          ? Image.asset(
                              'assets/flags/$flag.png',
                              width: 34,
                              height: 28,
                              fit: BoxFit.fill,
                              excludeFromSemantics: true,
                            )
                          : Icon(
                              Icons.language_rounded,
                              size: 30,
                              color: selected
                                  ? darkInk
                                  : scheme.onSurfaceVariant,
                            ),
                    ),
                    const SizedBox(width: 26),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            server.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              height: 1.2,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.45,
                              color: selected ? darkInk : scheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            server.protocolLabel,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.2,
                              color: selected
                                  ? const Color(0xff5e4b2c)
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      server.latencyMs == null ? '—' : '${server.latencyMs} мс',
                      style: TextStyle(
                        fontSize: 14,
                        color: selected ? darkInk : scheme.onSurface,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    SizedBox(
                      width: 38,
                      child: selected
                          ? const Align(
                              alignment: Alignment.centerRight,
                              child: Icon(
                                Icons.check_rounded,
                                color: darkInk,
                                size: 24,
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

  String _count(int n) {
    final form = n % 100 >= 11 && n % 100 <= 14
        ? 'подключений'
        : switch (n % 10) {
            1 => 'подключение',
            2 || 3 || 4 => 'подключения',
            _ => 'подключений',
          };
    return '$n $form';
  }
}
