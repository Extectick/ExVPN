// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../services/vpn_permission_setup.dart';
import 'app_strings.dart';

enum VpnPermissionAction { retry }

/// Shown only after an explicit connect could not obtain Android VPN consent.
/// Settings remain optional actions; returning from them never auto-connects.
class VpnPermissionSheet extends StatefulWidget {
  const VpnPermissionSheet({
    super.key,
    required this.setup,
    required this.onVpnSettings,
    required this.onAppSettings,
  });

  final VpnPermissionSetup setup;
  final Future<bool> Function() onVpnSettings;
  final Future<bool> Function() onAppSettings;

  @override
  State<VpnPermissionSheet> createState() => _VpnPermissionSheetState();
}

class _VpnPermissionSheetState extends State<VpnPermissionSheet> {
  bool _opening = false;
  bool _settingsFailed = false;
  bool _openedVpnSettings = false;
  bool _showXiaomiHelp = false;
  late bool _showVpnHelp = widget.setup.vpn == VpnPermissionState.unavailable;

  Future<bool> _open(Future<bool> Function() action) async {
    if (_opening) return false;
    setState(() {
      _opening = true;
      _settingsFailed = false;
    });
    var opened = false;
    try {
      opened = await action();
    } catch (_) {
      // No platform exception details are rendered.
    }
    if (!mounted) return false;
    setState(() {
      _opening = false;
      _settingsFailed = !opened;
    });
    return opened;
  }

  Future<void> _openVpnSettings() async {
    final opened = await _open(widget.onVpnSettings);
    if (mounted && opened) setState(() => _openedVpnSettings = true);
  }

  Widget _step(int number, String text) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 25,
          child: Text(
            '$number.',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.45,
            ),
          ),
        ),
        Expanded(
          child: Text(
            context.tr(text),
            style: const TextStyle(fontSize: 14, height: 1.45),
          ),
        ),
      ],
    ),
  );

  void _retry() {
    Navigator.pop(context, VpnPermissionAction.retry);
  }

  @override
  Widget build(BuildContext context) {
    final setup = widget.setup;
    final restricted = setup.vpn == VpnPermissionState.restricted;
    final primarySettings = restricted || (_showVpnHelp && !_openedVpnSettings);
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const Key('vpn-permission-setup'),
      insetPadding: const EdgeInsets.all(16),
      constraints: const BoxConstraints(maxWidth: 420),
      scrollable: true,
      titlePadding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      title: Row(
        children: [
          Expanded(
            child: Text(
              context.tr(
                restricted ? 'VPN ограничен системой' : 'Разрешение VPN',
              ),
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            key: const Key('vpn-permission-close'),
            tooltip: context.tr('Закрыть'),
            onPressed: () => Navigator.pop(context),
            icon: const Icon(CupertinoIcons.xmark, size: 18),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr(switch (setup.vpn) {
              VpnPermissionState.granted => 'Разрешение VPN уже включено. Нажмите «Подключиться», чтобы продолжить.',
              VpnPermissionState.required => 'Для подключения нужен системный запрос Android. Нажмите «Повторить запрос» и подтвердите разрешение VPN.',
              VpnPermissionState.unavailable => 'Android не открыл запрос VPN. Проверьте настройки VPN и вернитесь в ExVPN.',
              VpnPermissionState.restricted => 'Создание VPN запрещено настройками устройства. Измените ограничение или обратитесь к администратору устройства.',
            }),
            style: const TextStyle(fontSize: 14, height: 1.45),
          ),
          if (_showVpnHelp && !restricted) ...[
            _step(1, 'Откройте настройки VPN.'),
            _step(
              2,
              'Нажмите ⚙ или ⓘ рядом с другим VPN и выключите «Постоянный VPN» (или «Всегда включённый VPN»).',
            ),
            _step(3, 'Вернитесь в ExVPN и нажмите «Повторить запрос».'),
            const SizedBox(height: 8),
            Text(
              context.tr(
                'Этот шаг нужен, только если для другого приложения включён постоянный VPN.',
              ),
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          if (_showXiaomiHelp &&
              setup.vendor == AndroidVendor.xiaomi &&
              !restricted) ...[
            const SizedBox(height: 12),
            Text(
              context.tr(
                'На Xiaomi, если запрос не появляется, проверьте «Другие разрешения» в настройках ExVPN. Названия пунктов могут отличаться.',
              ),
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          if (_settingsFailed) ...[
            const SizedBox(height: 12),
            Text(
              context.tr(
                'Не удалось открыть настройки. Откройте раздел VPN в настройках телефона.',
              ),
              style: TextStyle(fontSize: 13, height: 1.4, color: scheme.error),
            ),
          ],
        ],
      ),
      actions: [
        SizedBox(
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (primarySettings)
                FilledButton.icon(
                  key: const Key('vpn-permission-settings'),
                  onPressed: _opening ? null : _openVpnSettings,
                  icon: const Icon(CupertinoIcons.shield, size: 18),
                  label: Text(context.tr('Открыть настройки VPN')),
                )
              else
                FilledButton(
                  key: const Key('vpn-permission-retry'),
                  onPressed: _opening ? null : _retry,
                  child: Text(
                    context.tr(
                      setup.vpn == VpnPermissionState.granted
                          ? 'Подключиться'
                          : 'Повторить запрос',
                    ),
                  ),
                ),
              if (!restricted &&
                  !_showVpnHelp &&
                  setup.vpn != VpnPermissionState.granted)
                TextButton(
                  key: const Key('vpn-permission-help'),
                  onPressed: _opening
                      ? null
                      : () => setState(() => _showVpnHelp = true),
                  child: Text(context.tr('Запрос не появляется?')),
                ),
              if (_showVpnHelp && !restricted)
                if (primarySettings)
                  TextButton(
                    key: const Key('vpn-permission-retry'),
                    onPressed: _opening ? null : _retry,
                    child: Text(context.tr('Повторить запрос')),
                  )
                else
                  TextButton.icon(
                    key: const Key('vpn-permission-settings'),
                    onPressed: _opening ? null : _openVpnSettings,
                    icon: const Icon(CupertinoIcons.shield, size: 18),
                    label: Text(context.tr('Открыть настройки VPN')),
                  ),
              if (_showVpnHelp &&
                  setup.vendor == AndroidVendor.xiaomi &&
                  !restricted &&
                  !_showXiaomiHelp)
                TextButton(
                  key: const Key('vpn-permission-more-help'),
                  onPressed: _opening
                      ? null
                      : () => setState(() => _showXiaomiHelp = true),
                  child: Text(context.tr('Не помогло')),
                ),
              if (_showXiaomiHelp &&
                  setup.vendor == AndroidVendor.xiaomi &&
                  !restricted)
                TextButton.icon(
                  key: const Key('vpn-permission-app-settings'),
                  onPressed: _opening
                      ? null
                      : () => _open(widget.onAppSettings),
                  icon: const Icon(CupertinoIcons.settings, size: 18),
                  label: Text(context.tr('Настройки ExVPN')),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
