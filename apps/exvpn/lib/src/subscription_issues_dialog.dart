import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;

import 'app_strings.dart';

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

/// Short, read-only feedback. A partial provider update never replaces the
/// last working list from this view.
Future<SubscriptionReviewOutcome> showSubscriptionIssues(
  BuildContext context, {
  required AppController controller,
  required String groupId,
  String? refreshFailure,
  VoidCallback? onRetry,
}) async {
  final group = controller.groups.where((g) => g.id == groupId).firstOrNull;
  if (group == null) return SubscriptionReviewOutcome.stale;
  final candidate = controller.pendingUpdate(groupId);
  final summary =
      refreshFailure ??
      subscriptionIssueSummary(candidate?.issues ?? group.issues);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const Key('subscription-issues-dialog'),
      insetPadding: const EdgeInsets.all(16),
      constraints: const BoxConstraints(maxWidth: 420),
      titlePadding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
      title: Row(
        children: [
          Expanded(
            child: Text(
              group.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            key: const Key('keep-subscription'),
            tooltip: dialogContext.tr('Закрыть'),
            onPressed: () => Navigator.pop(dialogContext),
            icon: const Icon(CupertinoIcons.xmark, size: 18),
          ),
        ],
      ),
      content: Text(
        refreshFailure != null
            ? dialogContext.tr(summary)
            : '${dialogContext.tr(summary)}\n\n${dialogContext.tr(candidate == null ? 'Рабочий список не изменён.' : 'Последний рабочий список сохранён.')}',
        style: const TextStyle(fontSize: 14, height: 1.45),
      ),
      actions: refreshFailure != null && onRetry != null
          ? [
              TextButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  onRetry();
                },
                child: Text(dialogContext.tr('Повторить')),
              ),
            ]
          : null,
    ),
  );
  return SubscriptionReviewOutcome.keptCurrent;
}

String subscriptionIssueSummary(Iterable<ImportIssue> issues) {
  final codes = issues.map((issue) => issue.code).toSet();
  if (codes.contains(ImportIssueCode.empty)) {
    return 'В подписке нет доступных подключений.';
  }
  if (codes.contains(ImportIssueCode.tooLarge)) {
    return 'Подписка превышает допустимый размер.';
  }
  if (codes.contains(ImportIssueCode.tooManyProfiles)) {
    return 'В подписке слишком много подключений.';
  }
  if (codes.contains(ImportIssueCode.unsupportedFormat)) {
    return 'Формат подписки не распознан.';
  }
  if (codes.contains(ImportIssueCode.invalidProfile)) {
    return 'В части подключений есть ошибки параметров.';
  }
  if (codes.contains(ImportIssueCode.unsupportedProtocol) ||
      codes.contains(ImportIssueCode.unsupportedFeature)) {
    return 'Часть подключений пока не поддерживается.';
  }
  if (codes.contains(ImportIssueCode.ignoredLocalConfiguration)) {
    return 'Дополнительные настройки провайдера пропущены.';
  }
  return 'Не удалось обновить подключения.';
}
