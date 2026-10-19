import 'dart:async';

import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../build_identity.dart';
import '../services/dart_updates.dart';
import '../services/data_updates.dart';
import '../services/safe_diagnostics.dart';
import '../services/subscription_persistence.dart';
import '../services/vpn_controller.dart';
import 'app_strings.dart';
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

class _SettingsSheetState extends State<SettingsSheet> {
  late final AppearanceController _fallbackAppearance;

  @override
  void initState() {
    super.initState();
    _fallbackAppearance = AppearanceController(persist: false)
      ..setChoice(switch (widget.themeMode) {
        ThemeMode.system => ThemeChoice.system,
        ThemeMode.dark => ThemeChoice.dark,
        ThemeMode.light => ThemeChoice.light,
      });
    widget.vpn?.addListener(_vpnChanged);
  }

  void _vpnChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.vpn?.removeListener(_vpnChanged);
    _fallbackAppearance.dispose();
    super.dispose();
  }

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
    final report = safeDiagnostics(
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
    );
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.tr('Обезличенная диагностика')),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                ctx.tr(
                  'Отчёт содержит только версии и состояние приложения. Подписки, ключи, адреса и история трафика не включены.',
                ),
              ),
              const SizedBox(height: 16),
              SelectableText(
                report,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(ctx.tr('Закрыть')),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: Text(ctx.tr('Копировать')),
            onPressed: () async {
              try {
                await Clipboard.setData(ClipboardData(text: report));
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.tr('Отчёт скопирован'))),
                  );
                }
              } catch (_) {
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) {
                  _info(
                    'Буфер обмена недоступен',
                    'Выделите текст отчёта и скопируйте его вручную.',
                  );
                }
              }
            },
          ),
        ],
      ),
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
            SettingsNavigationRow(
              icon: Icons.shield_outlined,
              title: context.tr('Защита соединения'),
              subtitle: context.tr(
                widget.vpn?.status.processCrashProtection == true
                    ? 'Системная защита подтверждена'
                    : 'Защита соединения ещё не подтверждена.',
              ),
              onTap: () => showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(ctx.tr('Защита соединения')),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ctx.tr(
                            'На Android включите Always-on VPN и «Блокировать соединения без VPN» в настройках системы. Блокировка может оставаться включённой после отключения VPN. На Windows защитой управляет ExVPN.',
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          ctx.tr(
                            DataUpdatesScope.maybeOf(ctx)?.snapshot.help ??
                                bundledConnectionHelp,
                          ),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    if (widget.vpn != null)
                      TextButton(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          try {
                            await widget.vpn!.bridge
                                .openSystemProtectionSettings();
                          } catch (_) {
                            if (mounted) {
                              _info(
                                'Системные настройки',
                                'Откройте настройки VPN в вашей системе.',
                              );
                            }
                          }
                        },
                        child: Text(ctx.tr('Настройки системы')),
                      ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(ctx.tr('Понятно')),
                    ),
                  ],
                ),
              ),
            ),
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
                      builder: (_) => UpdatesSheet(
                        updates: updates,
                        dartUpdates: dartUpdates,
                      ),
                    ),
                  );
                }
              },
            ),
            SettingsNavigationRow(
              icon: Icons.description_outlined,
              title: context.tr('Обезличенная диагностика'),
              subtitle: context.tr('Посмотреть и скопировать отчёт'),
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
