// SPDX-License-Identifier: Apache-2.0
import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;

import '../services/subscription_persistence.dart';
import 'app_strings.dart';

class SubscriptionEditDialog extends StatefulWidget {
  const SubscriptionEditDialog({
    super.key,
    required this.controller,
    required this.group,
    this.persistence,
    this.fullscreen = false,
  });
  final AppController controller;
  final SubscriptionGroup group;
  final SubscriptionPersistence? persistence;
  final bool fullscreen;
  @override
  State<SubscriptionEditDialog> createState() => _SubscriptionEditDialogState();
}

class _SubscriptionEditDialogState extends State<SubscriptionEditDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.group.name);
  late final _source = TextEditingController(
    text: widget.group.sourceUrl ?? '',
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _source.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final source = _source.text.trim();
      final applied = widget.controller.editSubscription(
        groupId: widget.group.id,
        name: _name.text,
        sourceUrl: source.isEmpty ? null : source,
      );
      if (!applied) throw StateError('Subscription removed');
      await widget.persistence?.flush();
      if (widget.persistence?.error != null) {
        throw StateError('Storage unavailable');
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Не удалось сохранить подписку';
        });
      }
    }
  }

  Widget _fields() => Form(
    key: _form,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextFormField(
          key: const Key('edit-subscription-name'),
          controller: _name,
          enabled: !_saving,
          maxLength: 80,
          decoration: InputDecoration(
            labelText: context.tr('Название подписки'),
            prefixIcon: const Icon(CupertinoIcons.tag, size: 18),
            counterText: '',
          ),
          validator: (value) =>
              value!.trim().isNotEmpty &&
                  safeSubscriptionName(value, sourceUrl: _source.text.trim()) ==
                      null
              ? context.tr('Проверьте название подписки')
              : null,
        ),
        const SizedBox(height: 14),
        TextFormField(
          key: const Key('edit-subscription-source'),
          controller: _source,
          enabled: !_saving,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          maxLength: 8192,
          decoration: InputDecoration(
            labelText: context.tr('Ссылка HTTPS'),
            prefixIcon: const Icon(CupertinoIcons.link, size: 18),
            counterText: '',
          ),
          validator: (value) {
            final text = value!.trim();
            if (text.isEmpty) return null;
            final uri = Uri.tryParse(text);
            return text.length <= 8192 &&
                    !RegExp(r'[\x00-\x20\x7f]').hasMatch(text) &&
                    uri != null &&
                    uri.scheme == 'https' &&
                    uri.host.isNotEmpty &&
                    !uri.authority.contains('@') &&
                    !uri.hasFragment &&
                    uri.port > 0 &&
                    uri.port <= 65535
                ? null
                : context.tr('Укажите ссылку HTTPS');
          },
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              context.tr(_error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    ),
  );

  Widget _saveButton() => FilledButton(
    key: const Key('edit-subscription-save'),
    onPressed: _saving ? null : _save,
    child: Text(context.tr('Сохранить')),
  );

  @override
  Widget build(BuildContext context) {
    if (widget.fullscreen) {
      return Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(context.tr('Редактировать подписку')),
            leading: IconButton(
              tooltip: context.tr('Закрыть'),
              icon: const Icon(Icons.close),
              onPressed: _saving ? null : () => Navigator.pop(context),
            ),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: _fields(),
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _saveButton(),
            ),
          ),
        ),
      );
    }
    return AlertDialog(
      title: Text(context.tr('Редактировать подписку')),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(child: _fields()),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(context.tr('Отмена')),
        ),
        _saveButton(),
      ],
    );
  }
}
