import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';

import '../services/vpn_controller.dart';
import '../services/native_vpn_bridge.dart';
import 'app_strings.dart';

class ExclusionsSheet extends StatefulWidget {
  const ExclusionsSheet({super.key, required this.vpn});
  final VpnController vpn;
  @override
  State<ExclusionsSheet> createState() => _ExclusionsSheetState();
}

class _ExclusionsSheetState extends State<ExclusionsSheet> {
  List<ApplicationIdentity>? _apps;
  final Set<String> _selected = {};
  final _searchController = TextEditingController();
  String? _error;
  bool _saving = false;
  bool _policyReadFailed = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _error = null;
      _apps = null;
      _selected.clear();
      _policyReadFailed = false;
    });
    try {
      try {
        await widget.vpn.loadExclusions();
      } catch (_) {
        _policyReadFailed = true;
        rethrow;
      }
      final apps = await widget.vpn.bridge.listApplications();
      if (!mounted) return;
      setState(() {
        _selected.addAll(widget.vpn.exclusions);
        final known = apps.map((app) => app.id).toSet();
        _apps = [
          ...apps,
          for (final id in _selected.difference(known))
            ApplicationIdentity(id: id, displayName: id),
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
    setState(() => _saving = true);
    try {
      // Recovery is a deliberate user action; a failed read never writes an
      // empty list automatically or silently replaces confirmed preferences.
      await widget.vpn.setExclusions({});
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

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.vpn.setExclusions(_selected);
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
    final visibleApps = _apps
        ?.where(
          (app) =>
              app.displayName.toLowerCase().contains(query) ||
              app.id.toLowerCase().contains(query),
        )
        .toList(growable: false);
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('Исключения приложений'))),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    context.tr(
                      'Выбранные приложения выходят в интернет напрямую. Изменения доступны при отключённом VPN. Приложения с общей системной учётной записью исключить нельзя.',
                    ),
                  ),
                ),
                if (widget.vpn.canDisconnect)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(context.tr('Сначала отключите VPN.')),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      context.tr(_error!),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
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
                        onPressed:
                            _saving ||
                                widget.vpn.canDisconnect ||
                                widget.vpn.commandPending
                            ? null
                            : _reset,
                        child: Text(
                          context.tr(
                            _saving ? 'Сброс…' : 'Сбросить исключения',
                          ),
                        ),
                      ),
                    ],
                  ),
                if (_apps != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      key: const Key('exclusions-search'),
                      controller: _searchController,
                      enabled: !_saving,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        labelText: context.tr('Поиск приложений'),
                        hintText: context.tr('Название, пакет или путь'),
                        prefixIcon: const Icon(Icons.search),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                if (_apps != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        context.tr(
                          'Выбрано всего: {count}',
                          values: {'count': _selected.length},
                        ),
                        key: const Key('exclusions-selected-count'),
                      ),
                    ),
                  ),
                if (_apps == null)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: _error == null
                          ? const CircularProgressIndicator()
                          : Text(context.tr('Список недоступен')),
                    ),
                  )
                else if (visibleApps!.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Text(
                        context.tr(
                          query.isEmpty
                              ? 'Список приложений пуст'
                              : 'Ничего не найдено',
                        ),
                      ),
                    ),
                  )
                else
                  for (final app in visibleApps)
                    CheckboxListTile(
                      title: Text(app.displayName),
                      subtitle: Text(
                        app.sharedIdentityGroup == null
                            ? app.id
                            : context.tr(
                                'Общий системный UID · исключение недоступно',
                              ),
                      ),
                      value: _selected.contains(app.id),
                      onChanged:
                          _saving ||
                              widget.vpn.canDisconnect ||
                              app.sharedIdentityGroup != null
                          ? null
                          : (value) => setState(() {
                              if (value == true) {
                                _selected.add(app.id);
                              } else {
                                _selected.remove(app.id);
                              }
                            }),
                    ),
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed: _apps == null || _saving || widget.vpn.canDisconnect
                    ? null
                    : _save,
                child: Text(context.tr(_saving ? 'Сохранение…' : 'Сохранить')),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
