// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../build_identity.dart';
import '../services/data_updates.dart';
import '../services/dart_updates.dart';
import 'app_strings.dart';
import 'dart_updates_section.dart';

class UpdatesSheet extends StatelessWidget {
  const UpdatesSheet({super.key, required this.updates, this.dartUpdates});
  final DataUpdatesController updates;
  final DartUpdatesController? dartUpdates;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([updates, dartUpdates]),
    builder: (context, _) {
      final proposal = updates.proposal;
      return Scaffold(
        appBar: AppBar(title: Text(context.tr('Версии и обновления'))),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
              children: [
                _version(context, 'Приложение', 'ExVPN $appVersion'),
                _version(context, 'Сборка', '$appBuild'),
                _version(
                  context,
                  'Ядро',
                  updates.vpn?.core ?? 'Не удалось определить',
                ),
                _version(
                  context,
                  'Данные',
                  updates.snapshot.revision == null
                      ? 'Встроенные'
                      : context.tr(
                          'Ревизия {revision}',
                          values: {'revision': updates.snapshot.revision},
                        ),
                ),
                _version(
                  context,
                  'Dart-патч',
                  dartPatchVersionText(dartUpdates),
                ),
                _version(context, 'Канал данных', updates.channel),
                if (dartUpdates != null) ...[
                  const SizedBox(height: 24),
                  DartUpdatesSection(controller: dartUpdates!),
                ],
                const SizedBox(height: 24),
                Text(
                  context.tr('Обновления данных'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  context.tr(
                    'Подписанный пакет обновляет справку без загрузки всего приложения. '
                    'Ядро и системные компоненты обновляются вместе с приложением.',
                  ),
                ),
                const SizedBox(height: 20),
                if (!updates.enabled)
                  Text(
                    context.tr(switch (updates.disabledReason) {
                      'unsupported_platform' =>
                        'OTA данных недоступны в браузере и на этой платформе.',
                      'invalid_configuration' => 'Конфигурация доверенной доставки в этой сборке неверна. Используется встроенная справка.',
                      _ => 'Доставка данных ещё не настроена. В этой сборке нет доверенного адреса и ключа обновлений.',
                    }),
                    key: const Key('updates-disabled'),
                  ),
                if (updates.busy) ...[
                  const LinearProgressIndicator(key: Key('updates-progress')),
                  const SizedBox(height: 12),
                  Text(context.tr('Проверяем и подготавливаем данные…')),
                ],
                if (updates.errorCode != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    context.tr(dataUpdatesErrorText(updates.errorCode)),
                    key: const Key('updates-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                if (updates.notice != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    context.tr(updates.notice!),
                    key: const Key('updates-notice'),
                  ),
                ],
                if (proposal != null) ...[
                  const SizedBox(height: 24),
                  Text(
                    context.tr(
                      'Подготовлена ревизия {revision}',
                      values: {'revision': proposal.revision},
                    ),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.tr(
                      'Загружено файлов: {downloaded}. Повторно использовано: {reused}.',
                      values: {
                        'downloaded': proposal.downloadedFiles,
                        'reused': proposal.reusedFiles,
                      },
                    ),
                  ),
                  if (!updates.canApply && !updates.busy) ...[
                    const SizedBox(height: 12),
                    Text(
                      context.tr(
                        'Для применения отключите VPN и дождитесь подтверждения от службы. '
                        'Приложение не отключает соединение автоматически.',
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton(
                        key: const Key('updates-apply'),
                        onPressed: updates.canApply ? updates.apply : null,
                        child: Text(context.tr('Применить')),
                      ),
                      OutlinedButton(
                        key: const Key('updates-cancel'),
                        onPressed: updates.busy ? null : updates.cancel,
                        child: Text(context.tr('Отменить')),
                      ),
                    ],
                  ),
                ],
                if (updates.enabled && proposal == null) ...[
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    key: const Key('updates-check'),
                    onPressed: updates.busy ? null : updates.check,
                    icon: const Icon(Icons.refresh),
                    label: Text(context.tr('Проверить обновления')),
                  ),
                ],
                if (updates.enabled && proposal == null && !updates.busy) ...[
                  const SizedBox(height: 12),
                  TextButton(
                    key: const Key('updates-recover'),
                    onPressed: updates.recover,
                    child: Text(
                      context.tr(
                        updates.initialized
                            ? 'Перечитать сохранённые данные'
                            : 'Повторить чтение сохранённых данных',
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 28),
                Text(
                  context.tr('Справка о подключении'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  context.tr(updates.snapshot.help),
                  key: const Key('updates-help'),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _version(BuildContext context, String title, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.tr(title), style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 4),
        Text(context.tr(value), style: const TextStyle(fontSize: 16)),
      ],
    ),
  );
}
