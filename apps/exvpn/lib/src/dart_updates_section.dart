// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../services/dart_updates.dart';

String dartPatchVersionText(DartUpdatesController? controller) {
  if (controller == null) return 'Недоступен в этой сборке';
  final snapshot = controller.snapshot;
  if (snapshot == null) {
    return controller.busy ? 'Определяем версию…' : 'Не удалось определить';
  }
  if (!snapshot.available) return 'Недоступен в этой сборке';
  return snapshot.current == null
      ? 'Базовый выпуск'
      : 'Патч ${snapshot.current}';
}

class DartUpdatesSection extends StatelessWidget {
  const DartUpdatesSection({super.key, required this.controller});
  final DartUpdatesController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Обновления интерфейса',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        if (c.snapshot?.available == false)
          Text(switch (c.disabledReason) {
            'unsupported_platform' =>
              'Dart-обновления недоступны на этой платформе.',
            'invalid_configuration' =>
              'Канал Dart-обновлений в этой сборке настроен неверно.',
            _ => 'В этой сборке нет поддержки Dart-обновлений. Для неё нужен полный выпуск ExVPN с Shorebird.',
          }, key: const Key('dart-updates-unavailable')),
        if (c.available) ...[
          Text(
            'Канал Dart-патчей: ${c.track}',
            key: const Key('dart-updates-track'),
          ),
          const SizedBox(height: 12),
          const Text(
            'Исправления интерфейса загружаются отдельно. Ядро VPN и системные компоненты требуют полного обновления приложения.',
          ),
        ],
        if (c.busy) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(key: Key('dart-updates-progress')),
          const SizedBox(height: 12),
          Text(switch (c.operation) {
            DartUpdateOperation.reading => 'Определяем версию Dart-патча…',
            DartUpdateOperation.checking => 'Проверяем Dart-обновления…',
            DartUpdateOperation.downloading => 'Загружаем Dart-патч…',
            DartUpdateOperation.idle => '',
          }),
          if (c.slow) ...[
            const SizedBox(height: 12),
            const Text(
              'Операция занимает больше времени. Можно вернуться к VPN; проверка продолжится. Новый запрос станет доступен после её завершения.',
              key: Key('dart-updates-slow'),
            ),
          ],
        ],
        if (c.error != null) ...[
          const SizedBox(height: 16),
          Text(
            dartUpdatesErrorText(c.error!),
            key: const Key('dart-updates-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (c.restartRequired) ...[
          const SizedBox(height: 16),
          Text(
            c.snapshot?.restartRequired == true
                ? c.snapshot!.next == null
                      ? 'Подготовлен возврат к базовому выпуску.'
                      : 'Для следующего запуска подготовлен патч ${c.snapshot!.next}.'
                : 'Движок сообщает о необходимости перезапуска.',
            key: const Key('dart-updates-pending'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Изменения применятся при следующем полном запуске ExVPN. Автоматического перезапуска нет. Закрытие окна в трей не перезапускает приложение.',
          ),
        ] else if (c.status == DartUpdateStatus.upToDate) ...[
          const SizedBox(height: 16),
          const Text(
            'Доступных Dart-патчей нет.',
            key: Key('dart-updates-current'),
          ),
        ] else if (c.status == DartUpdateStatus.outdated) ...[
          const SizedBox(height: 16),
          const Text('Доступен Dart-патч.', key: Key('dart-updates-available')),
        ],
        if (c.downloadUnconfirmed) ...[
          const SizedBox(height: 16),
          const Text(
            'Новый патч для следующего запуска пока не подтверждён. Повторите проверку.',
            key: Key('dart-updates-unconfirmed'),
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
                onPressed: c.canCheck ? c.check : null,
                icon: const Icon(Icons.refresh),
                label: const Text('Проверить Dart-патчи'),
              ),
              if (c.status == DartUpdateStatus.outdated && !c.restartRequired)
                FilledButton(
                  key: const Key('dart-updates-download'),
                  onPressed: c.canDownload ? c.download : null,
                  child: const Text('Загрузить патч'),
                ),
            ],
          ),
        ],
        if (!c.busy && c.snapshot == null) ...[
          const SizedBox(height: 12),
          TextButton(
            key: const Key('dart-updates-read'),
            onPressed: c.refresh,
            child: const Text('Повторить чтение версии патча'),
          ),
        ],
      ],
    );
  }
}
