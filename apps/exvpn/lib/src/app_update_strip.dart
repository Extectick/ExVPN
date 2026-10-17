import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import 'app_strings.dart';

enum AppUpdatePhase {
  available,
  downloading,
  ready,
  restarting,
  blocked,
  failed,
}

@immutable
class AppUpdatePresentation {
  const AppUpdatePresentation({
    this.phase = AppUpdatePhase.available,
    this.progress,
    this.label,
  });

  final AppUpdatePhase phase;

  /// Download fraction from zero to one; this view never starts a download.
  final double? progress;
  final String? label;
}

/// A fixed-height presentation surface. The owner supplies every state change.
class AppUpdateStrip extends StatelessWidget {
  const AppUpdateStrip({
    super.key,
    required this.state,
    required this.onPressed,
  });

  final AppUpdatePresentation state;
  final VoidCallback onPressed;
  static const double height = 24;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final downloading = state.phase == AppUpdatePhase.downloading;
    final restarting = state.phase == AppUpdatePhase.restarting;
    final failed = state.phase == AppUpdatePhase.failed;
    final actionable = !downloading && !restarting;
    final fraction = state.progress;
    final progress = fraction != null && fraction.isFinite
        ? fraction.clamp(0.0, 1.0)
        : null;
    final label = context.tr(
      state.label ??
          switch (state.phase) {
            AppUpdatePhase.available => 'Доступно обновление',
            AppUpdatePhase.downloading => 'Загрузка обновления',
            AppUpdatePhase.ready => 'Обновление готово — перезапустить',
            AppUpdatePhase.restarting => 'Перезапуск…',
            AppUpdatePhase.blocked =>
              'Для установки отключите VPN и закройте диалоги',
            AppUpdatePhase.failed => 'Не удалось обновить — повторить',
          },
    );
    final color = failed ? scheme.error : scheme.primary;
    return SizedBox(
      width: double.infinity,
      height: height,
      child: Semantics(
        button: actionable,
        enabled: actionable,
        liveRegion: restarting || failed,
        label: label,
        value: downloading && progress != null
            ? '${(progress * 100).round()}%'
            : null,
        onTap: actionable ? onPressed : null,
        child: ExcludeSemantics(
          child: Material(
            color: color.withValues(alpha: .1),
            borderRadius: BorderRadius.zero,
            child: InkWell(
              onTap: actionable ? onPressed : null,
              borderRadius: BorderRadius.zero,
              focusColor: color.withValues(alpha: .16),
              hoverColor: color.withValues(alpha: .06),
              child: downloading
                  ? LinearProgressIndicator(
                      value: progress,
                      minHeight: height,
                      color: scheme.primary.withValues(alpha: .38),
                      backgroundColor: scheme.primary.withValues(alpha: .06),
                      borderRadius: BorderRadius.zero,
                      stopIndicatorRadius: 0,
                      trackGap: 0,
                    )
                  : Stack(
                      children: [
                        Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!restarting) ...[
                                Icon(
                                  failed
                                      ? CupertinoIcons.refresh_circled
                                      : CupertinoIcons.arrow_down_circle,
                                  size: 13,
                                  color: color,
                                ),
                                const SizedBox(width: 5),
                              ],
                              Flexible(
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    color: color,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (restarting)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: LinearProgressIndicator(
                              value: MediaQuery.disableAnimationsOf(context)
                                  ? 1
                                  : null,
                              minHeight: 1.5,
                              color: color.withValues(alpha: .45),
                              backgroundColor: Colors.transparent,
                              borderRadius: BorderRadius.zero,
                              stopIndicatorRadius: 0,
                              trackGap: 0,
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
