import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';

import '../services/vpn_controller.dart';
import '../services/native_vpn_bridge.dart';

class ExclusionsSheet extends StatefulWidget {
  const ExclusionsSheet({super.key, required this.vpn});
  final VpnController vpn;
  @override
  State<ExclusionsSheet> createState() => _ExclusionsSheetState();
}

class _ExclusionsSheetState extends State<ExclusionsSheet> {
  List<ApplicationIdentity>? _apps;
  final Set<String> _selected = {};
  String? _error;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await widget.vpn.loadExclusions();
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Исключения приложений')),
    body: Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Выбранные приложения выходят в интернет напрямую. Изменения доступны при отключённом VPN. Приложения с общей системной учётной записью исключить нельзя.',
          ),
        ),
        if (widget.vpn.canDisconnect)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Сначала отключите VPN.'),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: _apps == null
              ? Center(
                  child: _error == null
                      ? const CircularProgressIndicator()
                      : const Text('Список недоступен'),
                )
              : ListView(
                  children: [
                    for (final app in _apps!)
                      CheckboxListTile(
                        title: Text(app.displayName),
                        subtitle: Text(
                          app.sharedIdentityGroup == null
                              ? app.id
                              : 'Общий системный UID · исключение недоступно',
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
              child: Text(_saving ? 'Сохранение…' : 'Сохранить'),
            ),
          ),
        ),
      ],
    ),
  );
}
