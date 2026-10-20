// SPDX-License-Identifier: Apache-2.0
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';

import '../services/native_vpn_bridge.dart';
import '../services/vpn_controller.dart';
import 'app_strings.dart';
import 'site_routing_presets.dart';
import 'sliding_segments.dart';

class SiteRoutingSheet extends StatefulWidget {
  const SiteRoutingSheet({super.key, required this.vpn});
  final VpnController vpn;
  @override
  State<SiteRoutingSheet> createState() => _SiteRoutingSheetState();
}

class _SiteRoutingSheetState extends State<SiteRoutingSheet> {
  final _search = TextEditingController();
  SiteRoutingState? _stored;
  List<SiteRoutingPreset> _saved = [];
  final _rules = <String>[];
  SiteRoutingMode _mode = SiteRoutingMode.disabled;
  String _preset = 'russia-basic';
  String? _error;
  bool _loading = true, _saving = false, _dirty = false;
  bool get _canEdit =>
      !_loading &&
      !_saving &&
      !widget.vpn.canDisconnect &&
      !widget.vpn.commandPending;
  List<SiteRoutingPreset> get _presets => [
    ...builtInSitePresets.where((b) => !_saved.any((s) => s.id == b.id)),
    ..._saved,
  ];

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
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final state = await widget.vpn.loadSiteRouting();
      if (!mounted) return;
      setState(() {
        _stored = state;
        _saved = state.savedPresets.toList();
        _preset = _presets.any((p) => p.id == state.selectedPreset)
            ? state.selectedPreset
            : '';
        _mode = state.policy.mode;
        _rules
          ..clear()
          ..addAll(state.policy.rules);
        if (_rules.isEmpty &&
            _mode == SiteRoutingMode.disabled &&
            _preset == 'russia-basic') {
          final russia = builtInSitePresets.first;
          _mode = russia.policy.mode;
          _rules.addAll(russia.policy.rules);
          _dirty = true;
        } else {
          _dirty = false;
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _errorText(Object error) => error is VpnFailure
      ? vpnErrorText(error.code)
      : error is FormatException
      ? 'Проверьте список доменов и IP-адресов.'
      : 'Не удалось сохранить правила сайтов.';

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.tr(title)),
          content: Text(context.tr(message)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.tr('Отмена')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.tr('Продолжить')),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _choosePreset(String? id) async {
    if (!_canEdit || id == null || id == _preset) return;
    if (id.isEmpty) {
      setState(() => _preset = '');
      return;
    }
    final preset = _presets.where((p) => p.id == id).firstOrNull;
    if (preset == null) return;
    if (_dirty &&
        !await _confirm(
          'Заменить список?',
          'Текущие изменения будут заменены пресетом.',
        )) {
      return;
    }
    if (!mounted || !_canEdit) return;
    setState(() {
      _preset = id;
      _mode = preset.policy.mode;
      _rules
        ..clear()
        ..addAll(preset.policy.rules);
      _dirty = true;
      _error = null;
      _search.clear();
    });
  }

  Future<void> _add() async {
    if (!_canEdit) return;
    final input = TextEditingController(text: _search.text);
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('Добавить адреса')),
        content: SizedBox(
          width: 360,
          child: TextField(
            key: const Key('site-address-input'),
            controller: input,
            autofocus: true,
            minLines: 2,
            maxLines: 5,
            maxLength: 16384,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              hintText: context.tr(
                'example.com или 203.0.113.1\nПо одному адресу в строке',
              ),
              counterText: '',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('Отмена')),
          ),
          FilledButton(
            key: const Key('site-add-confirm'),
            onPressed: () => Navigator.pop(context, input.text),
            child: Text(context.tr('Добавить')),
          ),
        ],
      ),
    );
    // A dialog can still be animating out when its future resolves.
    await Future<void>.delayed(const Duration(milliseconds: 220));
    input.dispose();
    if (!mounted || !_canEdit || text == null) return;
    try {
      final added = text
          .split(RegExp(r'[\s,;]+'))
          .where((s) => s.isNotEmpty)
          .map(normalizeSiteRule)
          .toSet();
      if (added.isEmpty || {..._rules, ...added}.length > maxSiteRules) {
        throw const FormatException();
      }
      setState(() {
        _rules.addAll(added.where((r) => !_rules.contains(r)));
        _preset = '';
        _dirty = true;
        _error = null;
        _search.clear();
      });
    } on FormatException {
      setState(
        () => _error = 'Укажите домен, IP или подсеть. Для международных доменов используйте Punycode.',
      );
    }
  }

  Future<void> _clear() async {
    if (!_canEdit || _rules.isEmpty) return;
    if (!await _confirm(
      'Очистить список?',
      'Все адреса будут удалены из текущего списка.',
    )) {
      return;
    }
    if (mounted && _canEdit) {
      setState(() {
        _rules.clear();
        _preset = '';
        _dirty = true;
      });
    }
  }

  Future<void> _savePreset() async {
    if (!_canEdit || _stored == null || _rules.isEmpty) return;
    final existing = _saved.where((p) => p.id == _preset).firstOrNull;
    if (existing == null && _saved.length >= maxSavedSitePresets) {
      setState(() => _error = 'Можно сохранить до 8 своих пресетов.');
      return;
    }
    final name = TextEditingController(text: existing?.name ?? '');
    final label = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('Сохранить пресет')),
        content: TextField(
          key: const Key('site-preset-name'),
          controller: name,
          autofocus: true,
          maxLength: 80,
          decoration: InputDecoration(
            hintText: context.tr('Название пресета'),
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('Отмена')),
          ),
          FilledButton(
            key: const Key('site-preset-confirm'),
            onPressed: () => Navigator.pop(context, name.text.trim()),
            child: Text(context.tr('Сохранить')),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 220));
    name.dispose();
    if (!mounted || !_canEdit || label == null) return;
    try {
      final id =
          existing?.id ??
          'user-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
      final preset = SiteRoutingPreset(
        id: id,
        name: label,
        policy: SiteRoutingPolicy(mode: _mode, rules: _rules),
      );
      final updated = [
        for (final p in _saved)
          if (p.id != id) p,
        preset,
      ];
      final state = SiteRoutingState(
        policy: _stored!.policy,
        savedPresets: updated,
        selectedPreset: _stored!.selectedPreset,
      );
      setState(() {
        _saving = true;
        _error = null;
      });
      await widget.vpn.setSiteRouting(state);
      if (mounted) {
        setState(() {
          _stored = state;
          _saved = updated;
          _preset = id;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deletePreset() async {
    final preset = _saved.where((p) => p.id == _preset).firstOrNull;
    if (!_canEdit || _stored == null || preset == null) return;
    if (!await _confirm(
      'Удалить пресет?',
      'Текущий список адресов останется.',
    )) {
      return;
    }
    if (!mounted || !_canEdit) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = _saved.where((p) => p.id != preset.id).toList();
      final state = SiteRoutingState(
        policy: _stored!.policy,
        savedPresets: saved,
        selectedPreset: _stored!.selectedPreset == preset.id
            ? ''
            : _stored!.selectedPreset,
      );
      await widget.vpn.setSiteRouting(state);
      if (mounted) {
        setState(() {
          _stored = state;
          _saved = saved;
          _preset = '';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    if (!_canEdit || _stored == null) return;
    if (_mode == SiteRoutingMode.include && _rules.isEmpty) {
      setState(() => _error = 'Добавьте хотя бы один адрес.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.vpn.setSiteRouting(
        SiteRoutingState(
          policy: SiteRoutingPolicy(mode: _mode, rules: _rules),
          savedPresets: _saved,
          selectedPreset: _preset,
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final visible = _rules.where((r) => r.contains(query)).toList();
    final scheme = Theme.of(context).colorScheme;
    final custom = _saved.any((p) => p.id == _preset);
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('Сайты и IP'))),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LayoutBuilder(
                      builder: (context, box) =>
                          SlidingSegments<SiteRoutingMode>(
                            key: const Key('site-routing-mode'),
                            width: box.maxWidth,
                            height: 38,
                            value: _mode,
                            onChanged: _canEdit
                                ? (v) => setState(() {
                                    _mode = v;
                                    _dirty = true;
                                  })
                                : null,
                            items: [
                              SlidingSegment(
                                value: SiteRoutingMode.disabled,
                                label: context.tr('Выключено'),
                              ),
                              SlidingSegment(
                                value: SiteRoutingMode.exclude,
                                label: context.tr('Исключения'),
                                tooltip: context.tr(
                                  'VPN для всех, кроме выбранных сайтов',
                                ),
                              ),
                              SlidingSegment(
                                value: SiteRoutingMode.include,
                                label: context.tr('Только эти'),
                                tooltip: context.tr(
                                  'VPN только для выбранных сайтов',
                                ),
                              ),
                            ],
                          ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            key: ValueKey('site-preset-$_preset'),
                            initialValue: _preset,
                            isExpanded: true,
                            menuMaxHeight: 320,
                            decoration: InputDecoration(
                              isDense: true,
                              prefixIcon: const Icon(Icons.tune, size: 19),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 9,
                              ),
                            ),
                            items: [
                              DropdownMenuItem(
                                value: '',
                                child: Text(context.tr('Свой список')),
                              ),
                              for (final p in _presets)
                                DropdownMenuItem(
                                  value: p.id,
                                  child: Text(
                                    builtInSitePresets.any((b) => b.id == p.id)
                                        ? context.tr(p.name)
                                        : p.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: _canEdit ? _choosePreset : null,
                          ),
                        ),
                        IconButton(
                          key: const Key('site-save-preset'),
                          tooltip: context.tr('Сохранить пресет'),
                          onPressed: _canEdit && _rules.isNotEmpty
                              ? _savePreset
                              : null,
                          icon: const Icon(Icons.save_outlined, size: 21),
                        ),
                        if (custom)
                          IconButton(
                            key: const Key('site-delete-preset'),
                            tooltip: context.tr('Удалить пресет'),
                            onPressed: _canEdit ? _deletePreset : null,
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 21,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key('site-search'),
                            controller: _search,
                            autocorrect: false,
                            enableSuggestions: false,
                            decoration: InputDecoration(
                              hintText: context.tr('Поиск адресов'),
                              isDense: true,
                              prefixIcon: const Icon(Icons.search, size: 20),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        IconButton(
                          key: const Key('site-add'),
                          tooltip: context.tr('Добавить адреса'),
                          onPressed: _canEdit ? _add : null,
                          icon: const Icon(Icons.add, size: 22),
                        ),
                        IconButton(
                          key: const Key('site-clear'),
                          tooltip: context.tr('Очистить список'),
                          onPressed: _canEdit && _rules.isNotEmpty
                              ? _clear
                              : null,
                          icon: const Icon(Icons.deselect_outlined, size: 21),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      context.tr(
                        _loading
                            ? 'Загрузка…'
                            : widget.vpn.canDisconnect ||
                                  widget.vpn.commandPending
                            ? 'Сначала отключите VPN'
                            : 'Правила применяются в режиме VPN',
                      ),
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (_preset == 'russia-basic')
                      Text(
                        context.tr(
                          'Стартовый список сервисов. Его можно изменить.',
                        ),
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    if (_error != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        context.tr(_error!),
                        style: TextStyle(fontSize: 12, color: scheme.error),
                      ),
                      if (_stored == null)
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton(
                            onPressed: _loading ? null : _load,
                            child: Text(context.tr('Повторить чтение')),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _stored == null
                    ? Center(child: Text(context.tr('Список недоступен')))
                    : visible.isEmpty
                    ? Center(
                        child: Text(
                          context.tr(
                            query.isEmpty
                                ? 'Добавьте домен или IP-адрес'
                                : 'Ничего не найдено',
                          ),
                        ),
                      )
                    : ListView.builder(
                        key: const Key('site-rule-list'),
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final rule = visible[index];
                          return ListTile(
                            key: ValueKey('site-rule-$rule'),
                            dense: true,
                            minTileHeight: 38,
                            minLeadingWidth: 20,
                            horizontalTitleGap: 10,
                            contentPadding: const EdgeInsetsDirectional.only(
                              start: 6,
                            ),
                            leading: Icon(
                              rule.contains(':') ||
                                      RegExp(r'^[0-9.]+(?:/\d+)?$')
                                          .hasMatch(rule)
                                  ? Icons.dns_outlined
                                  : Icons.language,
                              size: 18,
                            ),
                            title: Text(
                              rule,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                            trailing: IconButton(
                              tooltip: context.tr('Удалить'),
                              onPressed: _canEdit
                                  ? () => setState(() {
                                      _rules.remove(rule);
                                      _dirty = true;
                                    })
                                  : null,
                              icon: const Icon(Icons.close, size: 17),
                              visualDensity: VisualDensity.compact,
                            ),
                          );
                        },
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: FilledButton(
                    key: const Key('site-routing-save'),
                    onPressed: _canEdit && _stored != null ? _save : null,
                    child: Text(
                      context.tr(_saving ? 'Сохранение…' : 'Сохранить'),
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
