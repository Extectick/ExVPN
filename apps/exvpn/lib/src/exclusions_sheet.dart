import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../services/vpn_controller.dart';
import '../services/native_vpn_bridge.dart';
import 'app_strings.dart';
import 'application_icon.dart';
import 'sliding_segments.dart';

class ExclusionsSheet extends StatefulWidget {
  const ExclusionsSheet({super.key, required this.vpn});
  final VpnController vpn;
  @override
  State<ExclusionsSheet> createState() => _ExclusionsSheetState();
}

class _ExclusionsSheetState extends State<ExclusionsSheet> {
  List<ApplicationIdentity>? _apps;
  final Set<String> _selected = {};
  final Set<String> _unavailable = {};
  final _searchController = TextEditingController();
  late final _icons = ApplicationIconCache(widget.vpn.bridge);
  ApplicationRoutingMode _mode = ApplicationRoutingMode.disabled;
  String? _error;
  bool _saving = false;
  bool _policyReadFailed = false;

  bool get _canEdit =>
      !_saving && !widget.vpn.canDisconnect && !widget.vpn.commandPending;

  @override
  void initState() {
    super.initState();
    widget.vpn.addListener(_vpnChanged);
    _load();
  }

  void _vpnChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.vpn.removeListener(_vpnChanged);
    _searchController.dispose();
    _icons.dispose();
    super.dispose();
  }

  String _name(String value) {
    final normal = value.replaceAll(r'\', '/');
    final name = normal.split('/').where((part) => part.isNotEmpty).lastOrNull;
    return name == null || name.isEmpty ? context.tr('Приложение') : name;
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _error = null;
      _apps = null;
      _selected.clear();
      _unavailable.clear();
      _policyReadFailed = false;
    });
    try {
      try {
        await widget.vpn.loadApplicationRouting();
      } catch (_) {
        _policyReadFailed = true;
        rethrow;
      }
      final apps = await widget.vpn.bridge.listApplications();
      if (!mounted) return;
      setState(() {
        _mode = widget.vpn.applicationRouting.mode;
        _selected.addAll(widget.vpn.applicationRouting.applicationIds);
        final known = apps.map((app) => app.id).toSet();
        _unavailable.addAll(_selected.difference(known));
        _apps = [
          ...apps,
          for (final id in _unavailable)
            ApplicationIdentity(id: id, displayName: _name(id)),
        ];
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is VpnFailure
              ? vpnErrorText(error.code)
              : 'Не удалось прочитать исключения.',
        );
      }
    }
  }

  Future<void> _reset() async {
    if (!_canEdit) return;
    setState(() => _saving = true);
    try {
      // Only deliberate recovery writes an empty policy after a failed read.
      await widget.vpn.setApplicationRouting(
        ApplicationRoutingPolicy(mode: ApplicationRoutingMode.disabled),
      );
      await _load();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is VpnFailure
              ? vpnErrorText(error.code)
              : 'Не удалось сбросить исключения.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clearSelection() async {
    if (!_canEdit || _selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('Очистить выбор?')),
        content: Text(context.tr('Все приложения будут сняты с выбора.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.tr('Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.tr('Очистить')),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted && _canEdit) setState(_selected.clear);
  }

  Future<void> _save() async {
    if (!_canEdit || _apps == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.vpn.setApplicationRouting(
        ApplicationRoutingPolicy(mode: _mode, applicationIds: _selected),
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is VpnFailure
              ? vpnErrorText(error.code)
              : 'Не удалось применить исключения.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim().toLowerCase();
    final visible = _apps
        ?.where(
          (app) =>
              app.displayName.toLowerCase().contains(query) ||
              app.id.toLowerCase().contains(query),
        )
        .toList(growable: false);
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('Исключения приложений'))),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) =>
                          SlidingSegments<ApplicationRoutingMode>(
                            key: const Key('application-routing-mode'),
                            width: constraints.maxWidth,
                            height: 38,
                            items: [
                              for (final item in const [
                                (
                                  ApplicationRoutingMode.disabled,
                                  'Выключено',
                                  'Выключено',
                                  'Выключено',
                                ),
                                (
                                  ApplicationRoutingMode.exclude,
                                  'Кроме выбранных',
                                  'Исключения',
                                  'VPN для всех, кроме выбранных приложений',
                                ),
                                (
                                  ApplicationRoutingMode.include,
                                  'Только выбранные',
                                  'Только эти',
                                  'VPN только для выбранных приложений',
                                ),
                              ])
                                SlidingSegment(
                                  value: item.$1,
                                  label: context.tr(
                                    constraints.maxWidth < 440
                                        ? item.$3
                                        : item.$2,
                                  ),
                                  tooltip: context.tr(item.$4),
                                ),
                            ],
                            value: _mode,
                            onChanged: _apps != null && _canEdit
                                ? (mode) => setState(() => _mode = mode)
                                : null,
                          ),
                    ),
                    if (_apps != null) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              key: const Key('exclusions-search'),
                              controller: _searchController,
                              enabled: !_saving,
                              textInputAction: TextInputAction.search,
                              decoration: InputDecoration(
                                hintText: context.tr('Поиск приложений'),
                                prefixIcon: const Icon(Icons.search, size: 20),
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 11,
                                ),
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            key: const Key('exclusions-clear-all'),
                            tooltip: context.tr('Очистить выбор'),
                            onPressed: _canEdit && _selected.isNotEmpty
                                ? _clearSelection
                                : null,
                            icon: const Icon(Icons.deselect_outlined, size: 22),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                      const SizedBox(height: 7),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          context.tr(
                            'Выбрано всего: {count}',
                            values: {'count': _selected.length},
                          ),
                          key: const Key('exclusions-selected-count'),
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                    if (widget.vpn.canDisconnect)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          context.tr('Сначала отключите VPN.'),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          context.tr(_error!),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    if (_policyReadFailed)
                      Wrap(
                        alignment: WrapAlignment.center,
                        children: [
                          TextButton(
                            onPressed: _saving ? null : _load,
                            child: Text(context.tr('Повторить чтение')),
                          ),
                          TextButton(
                            key: const Key('reset-exclusions'),
                            onPressed: _canEdit ? _reset : null,
                            child: Text(
                              context.tr(
                                _saving ? 'Сброс…' : 'Сбросить исключения',
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              Expanded(
                child: _apps == null
                    ? Center(
                        child: _error == null
                            ? const CircularProgressIndicator()
                            : Text(context.tr('Список недоступен')),
                      )
                    : visible!.isEmpty
                    ? Center(
                        child: Text(
                          context.tr(
                            query.isEmpty
                                ? 'Список приложений пуст'
                                : 'Ничего не найдено',
                          ),
                        ),
                      )
                    : ListView.builder(
                        key: const Key('exclusions-app-list'),
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                        scrollCacheExtent: const ScrollCacheExtent.pixels(96),
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final app = visible[index];
                          final unavailable = _unavailable.contains(app.id);
                          final subtitle = app.sharedIdentityGroup != null
                              ? context.tr(
                                  'Общий системный UID · исключение недоступно',
                                )
                              : unavailable
                              ? context.tr('Приложение недоступно')
                              : null;
                          return CheckboxListTile(
                            key: ValueKey('application-${app.id}'),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            dense: true,
                            controlAffinity: ListTileControlAffinity.trailing,
                            secondary: ApplicationIcon(
                              icon: unavailable
                                  ? Future.value()
                                  : _icons.load(app.id),
                            ),
                            title: Text(
                              _name(app.displayName),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: subtitle == null
                                ? null
                                : Text(
                                    subtitle,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                            value: _selected.contains(app.id),
                            onChanged:
                                !_canEdit || app.sharedIdentityGroup != null
                                ? null
                                : (value) => setState(() {
                                    if (value == true) {
                                      _selected.add(app.id);
                                    } else {
                                      _selected.remove(app.id);
                                    }
                                  }),
                          );
                        },
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const Key('application-routing-save'),
                      onPressed: _apps != null && _canEdit ? _save : null,
                      child: Text(
                        context.tr(_saving ? 'Сохранение…' : 'Сохранить'),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
