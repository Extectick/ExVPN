// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../services/dart_updates.dart';
import '../services/app_updates.dart';
import 'app_strings.dart';

class DartUpdatesSection extends StatelessWidget {
  const DartUpdatesSection({super.key, required this.controller});
  final DartUpdatesController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final appUpdates = AppUpdatesScope.maybeOf(context);
    final appUpdateBusy = appUpdates?.busy == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr('Обновления интерфейса'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        if (c.snapshot?.available == false)
          Text(
            context.tr('Обновления интерфейса недоступны в этой сборке.'),
            key: const Key('dart-updates-unavailable'),
          ),
        if (c.available) ...[
          Text(
            context.tr('Небольшие исправления без переустановки приложения.'),
          ),
        ],
        if (c.busy) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(key: Key('dart-updates-progress')),
          const SizedBox(height: 12),
          Text(
            context.tr(switch (c.operation) {
              DartUpdateOperation.reading => 'Проверяем версию…',
              DartUpdateOperation.checking => 'Проверяем обновления…',
              DartUpdateOperation.downloading => 'Загружаем обновление…',
              DartUpdateOperation.idle => '',
            }),
          ),
          if (c.slow) ...[
            const SizedBox(height: 12),
            Text(
              context.tr(
                'Проверка продолжается. Можно вернуться на главный экран.',
              ),
              key: const Key('dart-updates-slow'),
            ),
          ],
        ],
        if (c.error != null) ...[
          const SizedBox(height: 16),
          Text(
            context.tr(switch (c.error!) {
              DartUpdateError.readFailed =>
                'Не удалось проверить версию. Повторите попытку.',
              DartUpdateError.checkFailed => 'Не удалось проверить обновления.',
              DartUpdateError.downloadFailed || DartUpdateError.installFailed =>
                'Не удалось загрузить обновление.',
              DartUpdateError.noUpdate =>
                'Обновление больше недоступно. Проверьте ещё раз.',
              DartUpdateError.operationFailed =>
                'Не удалось завершить обновление.',
            }),
            key: const Key('dart-updates-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (c.restartRequired) ...[
          const SizedBox(height: 16),
          Text(
            context.tr(
              c.snapshot?.restartRequired == true
                  ? c.snapshot!.next == null
                        ? 'Подготовлен возврат к исходной версии интерфейса.'
                        : 'Обновление готово к перезапуску.'
                  : 'Обновление готово к перезапуску.',
            ),
            key: const Key('dart-updates-pending'),
          ),
          const SizedBox(height: 8),
          Text(
            context.tr(
              'Выберите «Выйти» в меню ExVPN, затем откройте приложение.',
            ),
          ),
        ] else if (c.status == DartUpdateStatus.upToDate) ...[
          const SizedBox(height: 16),
          Text(
            context.tr('Новых исправлений нет.'),
            key: const Key('dart-updates-current'),
          ),
        ] else if (c.status == DartUpdateStatus.outdated) ...[
          const SizedBox(height: 16),
          Text(
            context.tr('Доступно обновление интерфейса.'),
            key: const Key('dart-updates-available'),
          ),
        ],
        if (c.downloadUnconfirmed) ...[
          const SizedBox(height: 16),
          Text(
            context.tr('Загрузка не подтверждена. Проверьте ещё раз.'),
            key: const Key('dart-updates-unconfirmed'),
          ),
        ],
        if (c.available) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              OutlinedButton.icon(
                key: const Key('dart-updates-check'),
                onPressed: c.canCheck && !appUpdateBusy ? c.check : null,
                icon: const Icon(Icons.refresh),
                label: Text(context.tr('Проверить')),
              ),
              if (c.status == DartUpdateStatus.outdated && !c.restartRequired)
                FilledButton(
                  key: const Key('dart-updates-download'),
                  onPressed:
                      c.canDownload &&
                          !appUpdateBusy &&
                          appUpdates?.kind != AppUpdateKind.full
                      ? c.download
                      : null,
                  child: Text(context.tr('Загрузить')),
                ),
            ],
          ),
        ],
        if (!c.busy && c.snapshot == null) ...[
          const SizedBox(height: 12),
          TextButton(
            key: const Key('dart-updates-read'),
            onPressed: !appUpdateBusy ? c.refresh : null,
            child: Text(context.tr('Повторить')),
          ),
        ],
      ],
    );
  }
}
