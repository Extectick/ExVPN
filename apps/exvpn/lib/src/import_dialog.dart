import 'dart:async';

import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart';

import '../services/subscription_loader.dart';
import '../services/subscription_persistence.dart';
import '../services/qr_import.dart';
import '../services/qr_sources.dart';
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
    this.documentLoader,
  });
  final AppController controller;
  final SubscriptionGroup? group;
  final SubscriptionPersistence? persistence;
  final Future<String?> Function()? qrReader;
  final SubscriptionLoader? loader;
  final bool fullscreen;
  final Future<SubscriptionDocument> Function(String)? documentLoader;
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
  bool _nameEdited = false;
  bool _nameLoading = false;
  Timer? _nameDebounce;
  int _sourceRevision = 0;
  String _observedInput = '';
  String? _cachedSource;
  SubscriptionDocument? _cachedDocument;
  @override
  void initState() {
    super.initState();
    _loader = widget.loader ?? SubscriptionLoader();
    _name.text = widget.group?.name ?? '';
    _input.addListener(_sourceChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _pasteInitialLink());
  }

  @override
  void dispose() {
    _nameDebounce?.cancel();
    _input.removeListener(_sourceChanged);
    _name.dispose();
    _input.dispose();
    _loader.close();
    super.dispose();
  }

  bool _isSubscriptionLink(String value) {
    if (value.length > 8192 || RegExp(r'[\x00-\x20\x7f]').hasMatch(value)) {
      return false;
    }
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasFragment;
  }

  Future<void> _pasteInitialLink() async {
    if (!mounted || widget.group != null) return;
    try {
      final value = (await Clipboard.getData(Clipboard.kTextPlain))?.text
          ?.trim();
      if (!mounted ||
          _loading ||
          _input.text.isNotEmpty ||
          value == null ||
          !_isSubscriptionLink(value)) {
        return;
      }
      _input.text = value;
    } catch (_) {
      // Browser clipboard access may require a user gesture. Manual paste stays available.
    }
  }

  Future<SubscriptionDocument> _loadDocument(String value) =>
      (widget.documentLoader ?? _loader.loadDocument)(value);

  void _sourceChanged() {
    // Selection/focus notifications are not edits and must not refetch metadata.
    if (_observedInput == _input.text) return;
    _observedInput = _input.text;
    _nameDebounce?.cancel();
    final revision = ++_sourceRevision;
    _cachedSource = null;
    _cachedDocument = null;
    _nameLoading = false;
    if (!_nameEdited && widget.group == null) _name.clear();
    if (!_link) {
      final document = SubscriptionDocument.fromText(_input.text);
      _useProviderName(document.providerName);
    } else if (_isSubscriptionLink(_input.text.trim())) {
      _nameDebounce = Timer(
        const Duration(milliseconds: 500),
        () => _resolveName(revision),
      );
    }
    if (mounted) setState(() {});
  }

  void _useProviderName(String? name) {
    if (!_nameEdited && widget.group == null) _name.text = name ?? '';
  }

  Future<void> _resolveName(int revision) async {
    if (!mounted || _loading || revision != _sourceRevision) return;
    final source = _input.text.trim();
    setState(() => _nameLoading = true);
    try {
      final document = await _loadDocument(source);
      if (!mounted || revision != _sourceRevision || _loading) return;
      _cachedSource = source;
      _cachedDocument = document;
      _useProviderName(document.providerName);
    } catch (_) {
      // Optional metadata must not turn a name lookup into an import error.
    } finally {
      if (mounted && revision == _sourceRevision) {
        setState(() => _nameLoading = false);
      }
    }
  }

  void _useQrValue(String value) {
    if (!mounted) return;
    setState(() {
      _link = _isSubscriptionLink(value.trim());
      _qrMode = false;
      _qrRead = true;
      _input.text = value;
    });
  }

  Future<void> _openCamera() => showDialog<void>(
    context: context,
    useRootNavigator: false,
    builder: (cameraContext) => Dialog(
      insetPadding: widget.fullscreen
          ? EdgeInsets.zero
          : const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(widget.fullscreen ? 0 : 20),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 440,
        height: widget.fullscreen ? MediaQuery.sizeOf(context).height : 360,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr('Сканировать QR'),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr('Закрыть'),
                    onPressed: () => Navigator.pop(cameraContext),
                    icon: const Icon(CupertinoIcons.xmark, size: 18),
                  ),
                ],
              ),
            ),
            Expanded(
              child: qrCameraView(
                onDetected: (value) {
                  Navigator.pop(cameraContext);
                  _useQrValue(value);
                },
                onClose: () => Navigator.pop(cameraContext),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _readQr({bool clipboard = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final value = widget.qrReader != null
          ? await widget.qrReader!()
          : clipboard
          ? await readQrClipboard()
          : await pickQrText();
      if (!mounted) return;
      if (value == null) {
        if (clipboard) {
          setState(() => _error = 'В буфере нет изображения с QR-кодом.');
        }
        return;
      }
      _useQrValue(value);
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
    _nameDebounce?.cancel();
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
          ? _cachedSource == _input.text.trim() && _cachedDocument != null
                ? _cachedDocument!
                : await _loadDocument(_input.text.trim())
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
              name: _nameEdited ? _name.text.trim() : '',
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
                      TextField(
                        key: const Key('subscription-name'),
                        controller: _name,
                        enabled: !_loading && widget.group == null,
                        maxLength: 80,
                        onChanged: (value) {
                          _nameEdited = value.trim().isNotEmpty;
                          if (!_nameEdited && _cachedDocument != null) {
                            _useProviderName(_cachedDocument!.providerName);
                          }
                        },
                        decoration: InputDecoration(
                          labelText: context.tr('Название подписки'),
                          hintText: context.tr('Необязательно'),
                          prefixIcon: const Icon(CupertinoIcons.tag, size: 18),
                          suffixIcon: _nameLoading
                              ? const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.5,
                                    ),
                                  ),
                                )
                              : null,
                          counterText: '',
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 14,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
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
                                      if (!_qrMode &&
                                          _link &&
                                          _cachedSource != _input.text.trim() &&
                                          _isSubscriptionLink(
                                            _input.text.trim(),
                                          )) {
                                        _nameDebounce?.cancel();
                                        final revision = _sourceRevision;
                                        _nameDebounce = Timer(
                                          const Duration(milliseconds: 500),
                                          () => _resolveName(revision),
                                        );
                                      }
                                    }),
                            ),
                      ),
                      const SizedBox(height: 16),
                      if (_qrMode)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              PopupMenuButton<String>(
                                key: const Key('qr-import-button'),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                tooltip: context.tr('QR из изображения'),
                                enabled: !_loading,
                                onSelected: (source) =>
                                    _readQr(clipboard: source == 'clipboard'),
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: 'file',
                                    child: Text(context.tr('Выбрать файл')),
                                  ),
                                  PopupMenuItem(
                                    value: 'clipboard',
                                    child: Text(context.tr('Из буфера обмена')),
                                  ),
                                ],
                                child: Container(
                                  width: 64,
                                  height: 64,
                                  decoration: BoxDecoration(
                                    color: scheme.primary.withValues(
                                      alpha: .08,
                                    ),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Icon(
                                    CupertinoIcons.photo,
                                    size: 27,
                                    color: scheme.primary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              IconButton.filledTonal(
                                key: const Key('qr-camera-button'),
                                tooltip: context.tr('Сканировать QR'),
                                onPressed: _loading ? null : _openCamera,
                                constraints: const BoxConstraints.tightFor(
                                  width: 64,
                                  height: 64,
                                ),
                                style: IconButton.styleFrom(
                                  backgroundColor: scheme.primary.withValues(
                                    alpha: .08,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                icon: Icon(
                                  CupertinoIcons.camera,
                                  size: 27,
                                  color: scheme.primary,
                                ),
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
