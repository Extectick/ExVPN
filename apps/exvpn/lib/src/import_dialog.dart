import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;

import '../services/subscription_loader.dart';
import '../services/subscription_persistence.dart';
import '../services/qr_import.dart';
import 'app_strings.dart';
import 'subscription_issues_dialog.dart';
import 'sliding_segments.dart';

class ImportDialog extends StatefulWidget {
  const ImportDialog({
    super.key,
    required this.controller,
    this.group,
    this.persistence,
    this.qrReader,
    this.loader,
    this.fullscreen = false,
  });
  final AppController controller;
  final SubscriptionGroup? group;
  final SubscriptionPersistence? persistence;
  final Future<String?> Function()? qrReader;
  final SubscriptionLoader? loader;
  final bool fullscreen;
  @override
  State<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<ImportDialog> {
  final _name = TextEditingController();
  final _input = TextEditingController();
  late final SubscriptionLoader _loader;
  bool _link = true;
  bool _loading = false;
  bool _reviewing = false;
  String? _error;
  bool _qrRead = false;
  bool _qrMode = false;
  bool _showName = false;
  @override
  void initState() {
    super.initState();
    _loader = widget.loader ?? SubscriptionLoader();
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
        _qrMode = false;
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
    if (_input.text.trim().isEmpty) {
      setState(() => _error = 'Укажите данные подписки.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final group = widget.group == null
          ? null
          : widget.controller.groups
                .where((current) => current.id == widget.group!.id)
                .firstOrNull;
      if (widget.group != null && group == null) {
        setState(() => _error = 'Подписка изменилась. Повторите обновление.');
        return;
      }
      if (group != null) widget.controller.discardPendingUpdate(group.id);
      final document = _link
          ? await _loader.loadDocument(_input.text.trim())
          : SubscriptionDocument.fromText(_input.text);
      if (!mounted) return;
      if (group != null &&
          !widget.controller.groups.any(
            (current) =>
                current.id == group.id &&
                current.contentRevision == group.contentRevision,
          )) {
        setState(() => _error = 'Подписка изменилась. Повторите обновление.');
        return;
      }
      final result = group == null
          ? widget.controller.addSubscription(
              name: _name.text.trim(),
              raw: document.body,
              providerName: document.providerName,
              sourceUrl: _link ? _input.text.trim() : null,
            )
          : widget.controller.updateSubscription(
              groupId: group.id,
              raw: document.body,
              providerName: document.providerName,
              sourceUrl: _link ? _input.text.trim() : null,
              clearSourceUrl: !_link,
            );
      var applied = result.applied;
      if (!applied && widget.controller.pendingUpdate(result.groupId) != null) {
        setState(() => _reviewing = true);
        final decision = await showSubscriptionIssues(
          context,
          controller: widget.controller,
          groupId: result.groupId,
        );
        if (!mounted) return;
        applied = decision == SubscriptionReviewOutcome.applied;
        if (!applied) {
          await widget.persistence?.flush();
          if (!mounted) return;
          setState(
            () => _error = decision == SubscriptionReviewOutcome.stale
                ? 'Подписка изменилась. Повторите обновление.'
                : 'Частичное обновление не применено. Рабочий список сохранён.',
          );
          return;
        }
      }
      await widget.persistence?.flush();
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              widget.persistence?.error != null
                  ? 'Подписка применена в этом сеансе, но не сохранена. Повторите сохранение на главном экране.'
                  : applied
                  ? result.issues.isEmpty
                        ? group == null
                              ? 'Подписка добавлена'
                              : 'Подписка обновлена'
                        : 'Подписка импортирована с замечаниями'
                  : 'Не удалось импортировать подключения. Проверьте данные подписки.',
            ),
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
          SubscriptionLoadErrorCode.deviceLimitReached => 'Достигнут лимит устройств подписки. Удалите ненужное устройство в личном кабинете провайдера и повторите загрузку.',
          SubscriptionLoadErrorCode.deviceIdentityUnavailable => 'Провайдер требует идентификатор устройства. Не удалось открыть его защищённое хранилище. Перезапустите приложение.',
          SubscriptionLoadErrorCode.deviceIdentityRejected => 'Провайдер не принял идентификатор этой установки ExVPN. Проверьте поддержку клиента у провайдера.',
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
      if (mounted) {
        setState(() {
          _loading = false;
          _reviewing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fullscreen = widget.fullscreen;
    return PopScope(
      canPop: !_loading,
      child: Dialog(
        key: const Key('subscription-import-dialog'),
        insetPadding: fullscreen ? EdgeInsets.zero : const EdgeInsets.all(20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(fullscreen ? 0 : 20),
        ),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 440,
          height: fullscreen ? MediaQuery.sizeOf(context).height : null,
          child: Column(
            mainAxisSize: fullscreen ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.tr(
                          widget.group == null
                              ? 'Добавить подписку'
                              : 'Обновить подписку',
                        ),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: context.tr('Закрыть'),
                      onPressed: _loading ? null : () => Navigator.pop(context),
                      icon: const Icon(CupertinoIcons.xmark, size: 18),
                    ),
                  ],
                ),
              ),
              Flexible(
                fit: fullscreen ? FlexFit.tight : FlexFit.loose,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) =>
                            SlidingSegments<String>(
                              width: constraints.maxWidth,
                              height: 38,
                              items: [
                                SlidingSegment(
                                  value: 'link',
                                  label: context.tr('Ссылка'),
                                  icon: CupertinoIcons.link,
                                ),
                                SlidingSegment(
                                  value: 'text',
                                  label: context.tr('Текст'),
                                  icon: CupertinoIcons.text_alignleft,
                                ),
                                const SlidingSegment(
                                  value: 'qr',
                                  label: 'QR',
                                  icon: CupertinoIcons.qrcode,
                                ),
                              ],
                              value: _qrMode
                                  ? 'qr'
                                  : _link
                                  ? 'link'
                                  : 'text',
                              onChanged: _loading
                                  ? null
                                  : (value) => setState(() {
                                      _qrMode = value == 'qr';
                                      if (!_qrMode) _link = value == 'link';
                                      _error = null;
                                    }),
                            ),
                      ),
                      const SizedBox(height: 16),
                      if (_qrMode)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 22,
                            horizontal: 12,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest.withValues(
                              alpha: .35,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            children: [
                              Icon(
                                CupertinoIcons.qrcode,
                                size: 36,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(height: 12),
                              TextButton.icon(
                                key: const Key('qr-import-button'),
                                onPressed: _loading ? null : _readQr,
                                icon: const Icon(
                                  CupertinoIcons.photo,
                                  size: 18,
                                ),
                                label: Text(context.tr('QR из изображения')),
                              ),
                            ],
                          ),
                        )
                      else
                        TextField(
                          key: const Key('subscription-input'),
                          controller: _input,
                          enabled: !_loading,
                          minLines: _link ? 1 : 4,
                          maxLines: _link ? 2 : 5,
                          autocorrect: false,
                          enableSuggestions: false,
                          keyboardType: _link
                              ? TextInputType.url
                              : TextInputType.multiline,
                          decoration: InputDecoration(
                            labelText: context.tr(
                              _link
                                  ? 'Ссылка HTTPS'
                                  : 'Ссылки подключений или JSON',
                            ),
                            hintText: _link
                                ? 'https://…'
                                : 'VLESS, VMess, Trojan…',
                            prefixIcon: _link
                                ? const Icon(CupertinoIcons.link, size: 18)
                                : null,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 14,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      if (_qrRead)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            context.tr(
                              'QR-код прочитан. Проверьте данные и подтвердите импорт.',
                            ),
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                      if (widget.group == null)
                        if (_showName)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: TextField(
                              controller: _name,
                              enabled: !_loading,
                              maxLength: 80,
                              key: const Key('subscription-name'),
                              decoration: InputDecoration(
                                labelText: context.tr('Название подписки'),
                                hintText: context.tr('Необязательно'),
                                counterText: '',
                                isDense: true,
                              ),
                            ),
                          )
                        else
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: TextButton.icon(
                              onPressed: _loading
                                  ? null
                                  : () => setState(() => _showName = true),
                              icon: const Icon(CupertinoIcons.pencil, size: 15),
                              label: Text(
                                context.tr('Название подписки'),
                                style: const TextStyle(fontSize: 12),
                              ),
                              style: TextButton.styleFrom(
                                foregroundColor: scheme.onSurfaceVariant,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                ),
                              ),
                            ),
                          ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            context.tr(_error!),
                            style: TextStyle(fontSize: 13, color: scheme.error),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: SizedBox(
                  height: 42,
                  child: FilledButton(
                    key: const Key('import-submit'),
                    onPressed: _loading || _qrMode ? null : _submit,
                    child: _loading && !_reviewing
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            context.tr(
                              widget.group == null ? 'Добавить' : 'Обновить',
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
