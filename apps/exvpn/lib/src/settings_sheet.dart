import 'dart:async';

import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../build_identity.dart';
import '../services/dart_updates.dart';
import '../services/client_logs.dart';
import '../services/data_updates.dart';
import '../services/safe_diagnostics.dart';
import '../services/subscription_persistence.dart';
import '../services/vpn_controller.dart';
import '../services/vpn_permission_setup.dart';
import 'app_strings.dart';
import 'logs_sheet.dart';
import 'appearance.dart';
import 'exclusions_sheet.dart';
import 'sliding_segments.dart';
import 'theme_editor.dart';
import 'updates_sheet.dart';
import 'settings_navigation_row.dart';
import 'modal_sheet_scroll_behavior.dart';

class SettingsSheet extends StatefulWidget {
  const SettingsSheet({
    super.key,
    required this.controller,
    required this.themeMode,
    required this.onThemeChanged,
    required this.onAdd,
    this.vpn,
    this.persistence,
    this.previewVersion,
    this.previewBuild,
    this.fullscreen = false,
  });
  final AppController controller;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final VoidCallback onAdd;
  final VpnController? vpn;
  final SubscriptionPersistence? persistence;
  final String? previewVersion;
  final int? previewBuild;
  final bool fullscreen;
  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet>
    with WidgetsBindingObserver {
  late final AppearanceController _fallbackAppearance;
  ClientLogs? _fallbackLogs;
  NotificationPermissionState? _notificationPermission;
  bool _notificationReadPending = false;
  bool _notificationSettingsOpening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fallbackAppearance = AppearanceController(persist: false)
      ..setChoice(switch (widget.themeMode) {
        ThemeMode.system => ThemeChoice.system,
        ThemeMode.dark => ThemeChoice.dark,
        ThemeMode.light => ThemeChoice.light,
      });
    widget.vpn?.addListener(_vpnChanged);
    unawaited(widget.vpn?.refreshConnectionProtection());
    unawaited(_refreshNotificationPermission());
  }

  void _vpnChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.vpn?.removeListener(_vpnChanged);
    _fallbackLogs?.dispose();
    _fallbackAppearance.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshNotificationPermission());
    }
  }

  Future<void> _refreshNotificationPermission() async {
    final vpn = widget.vpn;
    if (vpn?.supportsNotificationSettings != true || _notificationReadPending) {
      return;
    }
    _notificationReadPending = true;
    final permission = await vpn!.getNotificationPermission();
    if (!mounted) return;
    setState(() {
      _notificationPermission = permission;
      _notificationReadPending = false;
    });
  }

  Future<void> _openNotificationSettings() async {
    if (_notificationSettingsOpening) return;
    setState(() => _notificationSettingsOpening = true);
    final opened = await widget.vpn?.openNotificationSettings();
    if (!mounted) return;
    setState(() => _notificationSettingsOpening = false);
    if (opened != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('Откройте уведомления ExVPN в настройках телефона.'),
          ),
          showCloseIcon: true,
        ),
      );
    }
  }

  Widget _notifications() => SettingsNavigationRow(
    key: const Key('settings-vpn-notification'),
    icon: Icons.notifications_none_outlined,
    title: context.tr('Уведомление VPN'),
    subtitle: context.tr(switch (_notificationPermission) {
      NotificationPermissionState.granted => 'Включено',
      NotificationPermissionState.required => 'Отключено в Android',
      null => 'Настроить в Android',
    }),
    onTap: _notificationSettingsOpening ? null : _openNotificationSettings,
    trailing: _notificationPermission == NotificationPermissionState.required
        ? TextButton(
            key: const Key('settings-enable-vpn-notification'),
            onPressed: _notificationSettingsOpening
                ? null
                : _openNotificationSettings,
            child: Text(context.tr('Включить')),
          )
        : null,
  );

  void _info(String title, String content) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.tr(title)),
      content: Text(ctx.tr(content)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(ctx.tr('Понятно')),
        ),
      ],
    ),
  );

  void _diagnostics() {
    final updates = DataUpdatesScope.maybeOf(context);
    final dartUpdates = DartUpdatesScope.maybeOf(context);
    final logs =
        ClientLogsScope.maybeOf(context) ??
        (_fallbackLogs ??= ClientLogs(
          controller: widget.controller,
          vpn: widget.vpn,
          persistence: widget.persistence,
        ));
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LogsSheet(
          logs: logs,
          diagnosticsBuilder: () => safeDiagnostics(
            status: widget.vpn?.status,
            platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
            coreVersion: widget.vpn?.core,
            errorCode: widget.vpn?.lastErrorCode,
            secureStorageAvailable: widget.persistence != null,
            dataRevision: updates?.snapshot.revision,
            dataChannel: updates?.channel,
            dartUpdatesAvailable: dartUpdates?.snapshot?.available,
            currentDartPatch: dartUpdates?.snapshot?.current,
            nextDartPatch: dartUpdates?.snapshot?.next,
            dartRestartRequired: dartUpdates?.restartRequired,
            dartUpdateTrack: dartUpdates?.track,
          ),
        ),
      ),
    );
  }

  Future<void> _toggleProtection(bool enabled) async {
    final vpn = widget.vpn;
    if (vpn == null) return;
    await vpn.setConnectionProtection(enabled);
  }

  Widget _protection() {
    final vpn = widget.vpn;
    final protection = vpn?.connectionProtection;
    final enabled = protection?.enabled == true;
    final available = protection?.supported == true;
    final busy = vpn?.protectionBusy == true;
    return SettingsNavigationRow(
      key: const Key('settings-protection'),
      icon: Icons.shield_outlined,
      title: context.tr('Защита соединения'),
      subtitle: context.tr(
        vpn?.protectionError != null
            ? vpn!.protectionError ==
                      'connection_protection_requires_disconnected'
                  ? 'Сначала отключите VPN'
                  : 'Не удалось изменить защиту соединения'
            : !available
            ? 'Недоступно в этой версии'
            : protection!.systemManaged
            ? 'Настраивается в Android'
            : 'Блокировать интернет при обрыве VPN',
      ),
      trailing: Switch.adaptive(
        key: const Key('connection-protection-switch'),
        value: enabled,
        onChanged: available && !busy ? _toggleProtection : null,
      ),
      onTap: available && !busy ? () => _toggleProtection(!enabled) : null,
    );
  }

  void _openThemeEditor(AppearanceController appearance) {
    appearance.setChoice(ThemeChoice.custom);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => ModalSheetScrollScope(
        child: ThemeEditorSheet(appearance: appearance),
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String label) => Text(
    context.tr(label),
    style: TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.4,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scopedAppearance = AppearanceScope.maybeOf(context);
    final appearance = scopedAppearance ?? _fallbackAppearance;
    return ListenableBuilder(
      listenable: appearance,
      builder: (context, _) => SizedBox(
        height:
            MediaQuery.sizeOf(context).height * (widget.fullscreen ? 1 : .85),
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            widget.fullscreen ? 16 : 24,
            widget.fullscreen ? 8 : 0,
            widget.fullscreen ? 16 : 24,
            24,
          ),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.tr('Настройки'),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: context.tr('Закрыть настройки'),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _sectionLabel(context, 'ОФОРМЛЕНИЕ'),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, constraints) => SlidingSegments<ThemeChoice>(
                key: const Key('theme-selector'),
                width: constraints.maxWidth,
                height: 42,
                iconSize: 16,
                items: [
                  SlidingSegment(
                    value: ThemeChoice.dark,
                    label: context.tr('Тёмная'),
                    tooltip: context.tr('Тёмная'),
                    icon: Icons.dark_mode_outlined,
                  ),
                  SlidingSegment(
                    value: ThemeChoice.light,
                    label: context.tr('Светлая'),
                    tooltip: context.tr('Светлая'),
                    icon: Icons.light_mode_outlined,
                  ),
                  SlidingSegment(
                    value: ThemeChoice.custom,
                    label: context.tr('Я дизайнер'),
                    tooltip: context.tr('Я дизайнер'),
                    icon: Icons.palette_outlined,
                  ),
                ],
                value: appearance.choice == ThemeChoice.system
                    ? Theme.of(context).brightness == Brightness.dark
                          ? ThemeChoice.dark
                          : ThemeChoice.light
                    : appearance.choice,
                onChanged: (choice) {
                  appearance.setChoice(choice);
                  if (scopedAppearance == null) {
                    widget.onThemeChanged(appearance.themeMode);
                  }
                },
              ),
            ),
            if (appearance.choice == ThemeChoice.custom) ...[
              const SizedBox(height: 6),
              TextButton.icon(
                key: const Key('custom-theme-editor'),
                onPressed: () => _openThemeEditor(appearance),
                icon: const Icon(Icons.tune, size: 18),
                label: Text(context.tr('Настроить цвета')),
              ),
            ],
            const SizedBox(height: 22),
            _sectionLabel(context, 'ЯЗЫК'),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              key: ValueKey(
                'language-${appearance.locale?.languageCode ?? Localizations.localeOf(context).languageCode}',
              ),
              initialValue:
                  appearance.locale?.languageCode ??
                  Localizations.localeOf(context).languageCode,
              isExpanded: true,
              menuMaxHeight: 360,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.language, size: 20),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                isDense: true,
              ),
              items: [
                for (final language in _languages)
                  DropdownMenuItem(
                    value: language.$1,
                    child: Text(language.$2),
                  ),
              ],
              onChanged: appearance.setLocale,
            ),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 8),
            SettingsNavigationRow(
              icon: Icons.apps_outlined,
              title: context.tr('Исключения приложений'),
              subtitle: context.tr('Где работает VPN'),
              onTap: widget.vpn != null
                  ? () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ExclusionsSheet(vpn: widget.vpn!),
                      ),
                    )
                  : () => _info(
                      'Исключения приложений',
                      'Список приложений и правила обхода VPN будут доступны после подключения и проверки системного модуля.',
                    ),
            ),
            _protection(),
            if (widget.vpn?.supportsNotificationSettings == true)
              _notifications(),
            SettingsNavigationRow(
              icon: Icons.system_update_alt,
              title: context.tr('Версии и обновления'),
              subtitle: context.tr(
                'ExVPN {version} · сборка {build}',
                values: {
                  'version': widget.previewVersion ?? appVersion,
                  'build': '${widget.previewBuild ?? appBuild}',
                },
              ),
              onTap: () {
                final updates = DataUpdatesScope.maybeOf(context);
                final dartUpdates = DartUpdatesScope.maybeOf(context);
                if (updates != null) {
                  unawaited(dartUpdates?.initialize());
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      settings: const RouteSettings(
                        name: UpdatesSheet.routeName,
                      ),
                      builder: (_) => UpdatesSheet(
                        updates: updates,
                        dartUpdates: dartUpdates,
                        previewVersion: widget.previewVersion,
                      ),
                    ),
                  );
                }
              },
            ),
            SettingsNavigationRow(
              icon: Icons.description_outlined,
              title: context.tr('Логи'),
              subtitle: context.tr('Состояние и последние события'),
              onTap: _diagnostics,
            ),
            const SizedBox(height: 20),
            Text(
              context.tr('created by БЕЛКА'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const _languages = [
  ('ru', 'Русский'),
  ('en', 'English'),
  ('kk', 'Қазақша'),
  ('de', 'Deutsch'),
  ('fr', 'Français'),
  ('es', 'Español'),
  ('pt', 'Português'),
  ('tr', 'Türkçe'),
  ('zh', '中文'),
  ('ar', 'العربية'),
];
