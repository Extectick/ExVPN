import 'dart:async';

import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../services/vpn_controller.dart';
import 'exclusions_sheet.dart';
import '../services/subscription_persistence.dart';
import '../services/safe_diagnostics.dart';
import '../build_identity.dart';
import '../services/data_updates.dart';
import 'updates_sheet.dart';

class SettingsSheet extends StatefulWidget {
  const SettingsSheet({
    super.key,
    required this.controller,
    required this.themeMode,
    required this.onThemeChanged,
    required this.onAdd,
    this.vpn,
    this.persistence,
  });
  final AppController controller;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final VoidCallback onAdd;
  final VpnController? vpn;
  final SubscriptionPersistence? persistence;
  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late ThemeMode _mode = widget.themeMode;
  late StreamSubscription<void> _changes;
  @override
  void initState() {
    super.initState();
    widget.vpn?.addListener(_vpnChanged);
    _changes = widget.controller.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  void _vpnChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _changes.cancel();
    widget.vpn?.removeListener(_vpnChanged);
    super.dispose();
  }

  Future<void> _remove(SubscriptionGroup group) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить подписку?'),
        content: Text('«${group.name}» и её подключения будут удалены.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (result == true && mounted) {
      widget.controller.removeSubscription(group.id);
      await widget.persistence?.flush();
      if (mounted && widget.persistence?.error != null) {
        _info(
          'Сохранение не завершено',
          'Не удалось сохранить удаление. Повторите сохранение на главном экране.',
        );
      }
    }
  }

  void _info(String title, String content) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Понятно'),
        ),
      ],
    ),
  );

  void _diagnostics() {
    final report = safeDiagnostics(
      status: widget.vpn?.status,
      platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
      coreVersion: widget.vpn?.core,
      errorCode: widget.vpn?.lastErrorCode,
      secureStorageAvailable: widget.persistence != null,
    );
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Обезличенная диагностика'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Отчёт содержит только версии и состояние приложения. Подписки, ключи, адреса и история трафика не включены.',
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
            child: const Text('Закрыть'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Копировать'),
            onPressed: () async {
              try {
                await Clipboard.setData(ClipboardData(text: report));
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Отчёт скопирован')),
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

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * 0.85,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Настройки',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: 'Закрыть настройки',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        const SizedBox(height: 28),
        const Text(
          'ОФОРМЛЕНИЕ',
          style: TextStyle(fontSize: 11, letterSpacing: 1.5),
        ),
        const SizedBox(height: 14),
        SegmentedButton<ThemeMode>(
          key: const Key('theme-selector'),
          segments: const [
            ButtonSegment(
              value: ThemeMode.dark,
              label: Text('Тёмная'),
              icon: Icon(Icons.dark_mode_outlined),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              label: Text('Светлая'),
              icon: Icon(Icons.light_mode_outlined),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (value) {
            setState(() => _mode = value.single);
            widget.onThemeChanged(_mode);
          },
        ),
        const SizedBox(height: 30),
        Row(
          children: [
            const Expanded(
              child: Text(
                'ПОДПИСКИ',
                style: TextStyle(fontSize: 11, letterSpacing: 1.5),
              ),
            ),
            IconButton(
              tooltip: 'Добавить подписку',
              onPressed: () {
                Navigator.pop(context);
                widget.onAdd();
              },
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        if (widget.controller.groups.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Подписок пока нет'),
          ),
        for (final group in widget.controller.groups)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(group.name),
            subtitle: Text(
              'Подключения: ${group.servers.length}${group.isDemo ? ' · пример' : ''}',
            ),
            trailing: IconButton(
              tooltip: 'Удалить ${group.name}',
              onPressed: () => _remove(group),
              icon: const Icon(Icons.delete_outline),
            ),
          ),
        const SizedBox(height: 20),
        const Divider(),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.apps_outlined),
          title: const Text('Исключения приложений'),
          subtitle: Text(
            widget.vpn == null
                ? 'Требуется системный VPN-модуль'
                : 'Прямой доступ для выбранных приложений',
          ),
          trailing: const Icon(Icons.chevron_right),
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
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.shield_outlined),
          title: const Text('Защита соединения'),
          subtitle: Text(
            widget.vpn?.status.processCrashProtection == true
                ? 'Системная защита подтверждена'
                : 'Защита при сбое процесса не подтверждена',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Защита соединения'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'На Android защита при аварии процесса требует Always-on VPN и «Блокировать соединения без VPN» в настройках системы. Эта блокировка может оставаться включённой после отключения в приложении. На Windows защитой управляет служба ExVPN.',
                    ),
                    const SizedBox(height: 20),
                    Text(
                      DataUpdatesScope.maybeOf(ctx)?.snapshot.help ??
                          bundledConnectionHelp,
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
                        await widget.vpn!.bridge.openSystemProtectionSettings();
                      } catch (_) {
                        if (mounted) {
                          _info(
                            'Системные настройки',
                            'Откройте настройки VPN в вашей системе.',
                          );
                        }
                      }
                    },
                    child: const Text('Настройки системы'),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Понятно'),
                ),
              ],
            ),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.system_update_alt),
          title: const Text('Версии и обновления'),
          subtitle: const Text('ExVPN $appVersion · сборка $appBuild'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            final updates = DataUpdatesScope.maybeOf(context);
            if (updates != null) {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => UpdatesSheet(updates: updates),
                ),
              );
            }
          },
        ),
        const SizedBox(height: 24),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.description_outlined),
          title: const Text('Обезличенная диагностика'),
          subtitle: const Text('Посмотреть и скопировать отчёт'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _diagnostics,
        ),
        const SizedBox(height: 24),
        Text(
          'Предварительная версия\n${widget.persistence == null ? 'Подписки не сохраняются после закрытия.' : 'Подписки хранятся с системным шифрованием.'} '
          '${widget.vpn == null ? 'В браузере системный VPN недоступен.' : 'Состояние соединения поступает от системного VPN-модуля.'}',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            height: 1.6,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}
