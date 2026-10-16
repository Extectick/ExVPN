import 'profile.dart';
import 'subscription_parser.dart';

/// Immutable refresh boundary; failed/empty imports cannot erase working nodes.
/// Persistence and credential encryption belong to the platform storage layer.
final class SubscriptionSnapshot {
  SubscriptionSnapshot({
    required this.id,
    required List<ConnectionProfile> profiles,
    this.lastSuccessfulRefresh,
    this.lastAttempt,
    List<ImportIssue> issues = const [],
  }) : profiles = List.unmodifiable(profiles),
       issues = List.unmodifiable(issues);
  final String id;
  final List<ConnectionProfile> profiles;
  final DateTime? lastSuccessfulRefresh;
  final DateTime? lastAttempt;
  final List<ImportIssue> issues;

  bool needsRefresh(DateTime now) =>
      lastSuccessfulRefresh == null ||
      now.isBefore(lastSuccessfulRefresh!) ||
      now.difference(lastSuccessfulRefresh!) >= const Duration(hours: 6);

  /// [now] is the refresh attempt's start time, captured before network I/O.
  /// An older in-flight response must not overwrite a newer attempt.
  SubscriptionSnapshot apply(ImportResult result, DateTime now) {
    if (lastAttempt != null && now.isBefore(lastAttempt!)) return this;
    final hasErrors = result.issues.any(
      (issue) => issue.code != ImportIssueCode.ignoredLocalConfiguration,
    );
    final preserve =
        result.profiles.isEmpty || (profiles.isNotEmpty && hasErrors);
    return SubscriptionSnapshot(
      id: id,
      profiles: preserve ? profiles : result.profiles,
      lastSuccessfulRefresh: preserve ? lastSuccessfulRefresh : now,
      lastAttempt: now,
      issues: result.issues,
    );
  }
}
