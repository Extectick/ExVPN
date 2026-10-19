// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';

import '../build_identity.dart';
import '../services/app_updates.dart';
import '../services/data_updates.dart';
import '../services/dart_updates.dart';
import 'app_strings.dart';
import 'app_update_strip.dart';

/// A single entry point for full releases and compatible interface patches.
class UpdatesSheet extends StatefulWidget {
  const UpdatesSheet({
    super.key,
    required this.updates,
    this.dartUpdates,
    this.appUpdates,
    this.previewVersion,
  });
  static const routeName = '/updates';
  final DataUpdatesController updates;
  final DartUpdatesController? dartUpdates;
  final AppUpdatesController? appUpdates;
  final String? previewVersion;

  @override
  State<UpdatesSheet> createState() => _UpdatesSheetState();
}

class _UpdatesSheetState extends State<UpdatesSheet> {
  static const _actionHeight = 40.0;
  AppUpdatesController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = widget.appUpdates ?? AppUpdatesScope.maybeOf(context);
    if (identical(controller, _controller)) return;
    _controller = controller;
    // An already running startup check is shared, never duplicated.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          identical(controller, _controller) &&
          (controller?.canCheck == true || controller?.canRestart == true)) {
        unawaited(controller!.check());
      }
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.updates, _controller]),
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(context.tr('Версии и обновления'))),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            children: [
              _updateButton(context),
              if (_controller?.phase
                  case AppUpdateStatePhase.failed ||
                      AppUpdateStatePhase.blocked)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      context.tr(
                        _controller!.phase == AppUpdateStatePhase.blocked
                            ? 'Не удалось перезапустить приложение.'
                            : _controller!.errorCode == 'network_failed' ||
                                  _controller!.errorCode == 'patch_check_failed'
                            ? 'Не удалось проверить обновления.'
                            : 'Не удалось обновить приложение.',
                      ),
                      key: const Key('updates-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 6,
                  ),
                  child: Column(
                    children: [
                      _version(
                        context,
                        'Приложение',
                        'ExVPN ${widget.previewVersion ?? appVersion}',
                      ),
                      Divider(
                        height: 1,
                        color: Theme.of(context).dividerColor
                            .withValues(alpha: .2),
                      ),
                      _version(
                        context,
                        'Ядро',
                        widget.updates.vpn?.core ?? 'Не удалось определить',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _updateButton(BuildContext context) {
    final controller = _controller;
    final phase = controller?.phase ?? AppUpdateStatePhase.hidden;
    final busy =
        controller?.busy == true || phase == AppUpdateStatePhase.restarting;
    final label = switch (phase) {
      AppUpdateStatePhase.checking => 'Проверяем обновления…',
      AppUpdateStatePhase.available => 'Скачать и установить',
      AppUpdateStatePhase.downloading => 'Загружаем обновление…',
      AppUpdateStatePhase.restartReady ||
      AppUpdateStatePhase.blocked => 'Установить и перезапустить',
      AppUpdateStatePhase.restarting => 'Установка и перезапуск…',
      AppUpdateStatePhase.failed => 'Повторить',
      AppUpdateStatePhase.hidden => 'Проверить',
    };
    final progress = controller?.progress;
    final fraction = progress != null && progress.isFinite
        ? progress.clamp(0.0, 1.0)
        : null;
    final scheme = Theme.of(context).colorScheme;
    final downloading = phase == AppUpdateStatePhase.downloading;
    return Semantics(
      liveRegion: true,
      label: busy ? context.tr(label) : null,
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          key: const Key('updates-primary'),
          clipBehavior: Clip.antiAlias,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(_actionHeight),
            fixedSize: const Size.fromHeight(_actionHeight),
            visualDensity: VisualDensity.standard,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: busy
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            disabledBackgroundColor: busy
                ? Colors.transparent
                : scheme.primary.withValues(alpha: .72),
            disabledForegroundColor: scheme.onPrimary,
          ),
          onPressed: controller == null || busy
              ? null
              : () {
                  if (controller.canRestart) {
                    unawaited(controller.restart());
                  } else if (phase == AppUpdateStatePhase.failed) {
                    unawaited(controller.retry());
                  } else if (controller.canDownload) {
                    unawaited(controller.download());
                  } else if (controller.canCheck) {
                    unawaited(controller.check());
                  }
                },
          child: busy
              ? AppUpdateProgress(
                  key: const Key('updates-progress'),
                  progress: downloading ? fraction : null,
                  height: _actionHeight,
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      phase == AppUpdateStatePhase.available
                          ? Icons.download_rounded
                          : controller?.canRestart == true
                          ? Icons.restart_alt_rounded
                          : Icons.refresh_rounded,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        context.tr(label),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _version(BuildContext context, String title, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Row(
      children: [
        Text(
          context.tr(title),
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            context.tr(value),
            textAlign: TextAlign.end,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    ),
  );
}

/// Only the read-only updater page may bypass the open-dialog restart guard.
class UpdatesNavigationObserver extends NavigatorObserver {
  Route<dynamic>? _top;
  bool get showingUpdates => _top?.settings.name == UpdatesSheet.routeName;
  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    _top = topRoute;
  }
}
