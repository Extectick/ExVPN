import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';

enum SubscriptionReviewOutcome { keptCurrent, applied, stale }

/// Only fixed codes and record indices enter this view. Provider names, URLs,
/// credentials, exception messages and raw records are intentionally absent.
String importIssueMessage(ImportIssue issue) {
  final reason = switch (issue.code) {
    ImportIssueCode.empty => 'Список подключений пуст.',
    ImportIssueCode.tooLarge => 'Превышен допустимый размер подписки.',
    ImportIssueCode.tooManyProfiles => 'Слишком много подключений.',
    ImportIssueCode.unsupportedProtocol => 'Протокол пока не поддерживается.',
    ImportIssueCode.unsupportedFeature =>
      'Параметры подключения пока не поддерживаются.',
    ImportIssueCode.invalidProfile =>
      'Некорректные или неполные параметры подключения.',
    ImportIssueCode.unsupportedFormat => 'Формат подписки не распознан.',
    ImportIssueCode.ignoredLocalConfiguration =>
      'Локальные настройки провайдера пропущены; используются настройки ExVPN.',
  };
  return '${issue.index == 0 ? 'Подписка' : 'Запись ${issue.index}'}: $reason';
}

Future<SubscriptionReviewOutcome> showSubscriptionIssues(
  BuildContext context, {
  required AppController controller,
  required String groupId,
}) async {
  final group = controller.groups.where((g) => g.id == groupId).firstOrNull;
  if (group == null) return SubscriptionReviewOutcome.stale;
  final candidate = controller.pendingUpdate(groupId);
  final issues = candidate?.issues ?? group.issues;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        candidate == null ? 'Замечания к подписке' : 'Обновить часть подписки?',
      ),
      content: SizedBox(
        width: 440,
        child: ListView.separated(
          key: const Key('subscription-issues-list'),
          shrinkWrap: true,
          itemCount: issues.length + (candidate == null ? 0 : 2),
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (_, index) {
            if (candidate != null && index == 0) {
              return Text(
                'Сейчас подключений: ${candidate.previousCount}. '
                'В новом списке поддерживаются: ${candidate.supportedCount}. '
                'Остальные записи не будут добавлены.',
              );
            }
            if (candidate != null && index == 1) {
              return const Text(
                'При подтверждении текущий список будет заменён. '
                'Активное VPN-соединение не перезапускается.',
              );
            }
            return Text(
              importIssueMessage(issues[index - (candidate == null ? 0 : 2)]),
              style: const TextStyle(fontSize: 13, height: 1.4),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          key: const Key('keep-subscription'),
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(
            candidate == null ? 'Закрыть' : 'Оставить текущий список',
          ),
        ),
        if (candidate != null)
          FilledButton(
            key: const Key('accept-partial-subscription'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Заменить поддерживаемыми'),
          ),
      ],
    ),
  );
  if (accepted != true || !context.mounted || candidate == null) {
    return SubscriptionReviewOutcome.keptCurrent;
  }
  return controller.acceptPartialUpdate(candidate)
      ? SubscriptionReviewOutcome.applied
      : SubscriptionReviewOutcome.stale;
}
