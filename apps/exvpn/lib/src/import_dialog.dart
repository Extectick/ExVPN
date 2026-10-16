import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../services/subscription_loader.dart';
import '../services/subscription_persistence.dart';
import '../services/qr_import.dart';

class ImportDialog extends StatefulWidget {
  const ImportDialog({
    super.key,
    required this.controller,
    this.group,
    this.persistence,
    this.qrReader,
  });
  final AppController controller;
  final SubscriptionGroup? group;
  final SubscriptionPersistence? persistence;
  final Future<String?> Function()? qrReader;
  @override
  State<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<ImportDialog> {
  final _name = TextEditingController();
  final _input = TextEditingController();
  final _loader = SubscriptionLoader();
  bool _link = true;
  bool _loading = false;
  String? _error;
  bool _qrRead = false;
  @override
  void initState() {
    super.initState();
    _name.text = widget.group?.name ?? '';
  }

  @override
  void dispose() {
    _name.dispose();
    _input.dispose();
    _loader.close();
    super.dispose();
  }

  Future<void> _readQr() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final value = await (widget.qrReader ?? pickQrText)();
      if (!mounted || value == null) return;
      setState(() {
        _input.text = value;
        _link = Uri.tryParse(value)?.scheme.toLowerCase() == 'https';
        _qrRead = true;
      });
    } on QrImportException catch (error) {
      if (!mounted) return;
      setState(
        () => _error = switch (error.code) {
          QrImportError.tooLarge =>
            'Изображение слишком большое: максимум 5 МБ и 4 млн пикселей.',
          QrImportError.tooComplex =>
            'Изображение слишком сложное. Обрежьте его до одного QR-кода.',
          QrImportError.unsupportedImage =>
            'Выберите обычное изображение PNG или JPEG с QR-кодом.',
          QrImportError.notFound =>
            'QR-код не найден. Выберите чёткое изображение с одним кодом.',
          QrImportError.unreadable =>
            'Не удалось прочитать изображение. Выберите другой файл.',
        },
      );
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось открыть изображение.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    if (_input.text.trim().isEmpty || _name.text.trim().isEmpty) {
      setState(() => _error = 'Укажите название и данные подписки.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = _link ? await _loader.load(_input.text.trim()) : _input.text;
      if (!mounted) return;
      final group = widget.group;
      final result = group == null
          ? widget.controller.addSubscription(
              name: _name.text.trim(),
              raw: raw,
              sourceUrl: _link ? _input.text.trim() : null,
            )
          : widget.controller.updateSubscription(
              groupId: group.id,
              raw: raw,
              sourceUrl: _link ? _input.text.trim() : null,
              clearSourceUrl: !_link,
            );
      await widget.persistence?.flush();
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.persistence?.error != null
                ? 'Подписка применена в этом сеансе, но не сохранена. Повторите сохранение на главном экране.'
                : result.applied
                ? result.issues.isEmpty
                      ? 'Подписка ${group == null ? 'добавлена' : 'обновлена'}'
                      : 'Подписка импортирована с замечаниями'
                : 'Не удалось импортировать подключения. Проверьте данные подписки.',
          ),
        ),
      );
    } on SubscriptionLoadException catch (error) {
      if (!mounted) return;
      setState(
        () => _error = switch (error.code) {
          SubscriptionLoadErrorCode.invalidUrl =>
            'Нужна корректная ссылка HTTPS без логина и пароля в адресе.',
          SubscriptionLoadErrorCode.redirect => 'Ссылка перенаправляет на другой адрес. Укажите конечную HTTPS-ссылку.',
          SubscriptionLoadErrorCode.tooLarge =>
            'Размер подписки превышает 2 МБ.',
          SubscriptionLoadErrorCode.invalidEncoding =>
            'Сервер вернул неподдерживаемый формат текста.',
          SubscriptionLoadErrorCode.timeout =>
            'Сервер не ответил вовремя. Попробуйте ещё раз.',
          _ =>
            kIsWeb
                ? 'Не удалось загрузить подписку. Сервер должен разрешать загрузку из браузера (CORS). Можно вставить текст.'
                : 'Не удалось загрузить подписку. Проверьте сеть и ссылку или вставьте текст подписки.',
        },
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Не удалось применить подписку. Рабочие данные сохранены.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_loading,
    child: AlertDialog(
      title: Text(
        widget.group == null ? 'Добавить подписку' : 'Обновить подписку',
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                enabled: !_loading && widget.group == null,
                maxLength: 80,
                key: const Key('subscription-name'),
                decoration: const InputDecoration(
                  labelText: 'Название подписки',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 18),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: true,
                    label: Text('Ссылка'),
                    icon: Icon(Icons.link),
                  ),
                  ButtonSegment(
                    value: false,
                    label: Text('Текст'),
                    icon: Icon(Icons.notes_rounded),
                  ),
                ],
                selected: {_link},
                onSelectionChanged: _loading
                    ? null
                    : (value) => setState(() {
                        _link = value.single;
                        _error = null;
                      }),
              ),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                key: const Key('qr-import-button'),
                onPressed: _loading ? null : _readQr,
                icon: const Icon(Icons.qr_code, size: 20),
                label: const Text('QR из изображения'),
              ),
              if (_qrRead)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'QR-код прочитан. Проверьте данные и подтвердите импорт.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('subscription-input'),
                controller: _input,
                enabled: !_loading,
                minLines: _link ? 2 : 4,
                maxLines: 6,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: _link
                    ? TextInputType.url
                    : TextInputType.multiline,
                decoration: InputDecoration(
                  labelText: _link
                      ? 'Ссылка HTTPS'
                      : 'Ссылки подключений или JSON',
                  hintText: _link
                      ? 'https://…'
                      : 'VLESS, VMess, Trojan, Shadowsocks, Hysteria2',
                ),
              ),
              const SizedBox(height: 16),
              Text(
                widget.persistence == null
                    ? 'В этой сборке подписки хранятся только до закрытия приложения.'
                    : 'Подписки сохраняются в защищённом хранилище устройства.',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const Key('import-submit'),
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(widget.group == null ? 'Добавить' : 'Обновить'),
        ),
      ],
    ),
  );
}
