import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/foundation.dart';

import 'subscription_loader.dart';

/// Refreshes data only. It never reconnects or changes the active native tunnel.
final class SubscriptionRefresh extends ChangeNotifier {
  SubscriptionRefresh(
    this.controller, {
    SubscriptionLoader? loader,
    this.canApply,
  }) : _loader = loader ?? SubscriptionLoader();
  final AppController controller;
  final SubscriptionLoader _loader;

  /// A restart reservation prevents a late HTTP response mutating saved state.
  final bool Function()? canApply;
  bool get _allowed => !_disposed && (canApply?.call() ?? true);
  final Map<String, Future<bool>> _running = {};
  final Map<String, int> _failedRevisions = {};
  final Map<String, SubscriptionLoadErrorCode> _failureCodes = {};
  SubscriptionLoadErrorCode? errorCode(String id) =>
      failed.contains(id) ? _failureCodes[id] : null;
  Set<String> get failed => {
    for (final group in controller.groups)
      if (_failedRevisions[group.id] == group.contentRevision) group.id,
  };
  bool _disposed = false;
  bool get busy => _running.isNotEmpty;

  Future<bool> refresh(String id) {
    if (!_allowed) return Future.value(false);
    return _running[id] ??= _load(id).whenComplete(() {
      _running.remove(id);
      if (!_disposed) notifyListeners();
    });
  }

  Future<bool> _load(String id) async {
    final group = controller.groups
        .where((group) => group.id == id)
        .firstOrNull;
    if (group?.sourceUrl == null) return false;
    controller.discardPendingUpdate(id);
    try {
      final raw = await _loader.load(group!.sourceUrl!);
      if (!_allowed) return false;
      final current = controller.groups
          .where((item) => item.id == id)
          .firstOrNull;
      // A manual replacement while HTTP was pending has priority over old data.
      if (current == null ||
          current.sourceUrl != group.sourceUrl ||
          current.contentRevision != group.contentRevision) {
        return false;
      }
      final applied = controller
          .updateSubscription(groupId: id, raw: raw, sourceUrl: group.sourceUrl)
          .applied;
      if (applied) {
        _failedRevisions.remove(id);
        _failureCodes.remove(id);
      } else {
        _failedRevisions[id] = group.contentRevision;
        _failureCodes.remove(id);
      }
      return applied;
    } catch (error) {
      if (_allowed) {
        final current = controller.groups
            .where((item) => item.id == id)
            .firstOrNull;
        if (current != null &&
            current.sourceUrl == group!.sourceUrl &&
            current.contentRevision == group.contentRevision) {
          _failedRevisions[id] = group.contentRevision;
          if (error is SubscriptionLoadException) {
            _failureCodes[id] = error.code;
          } else {
            _failureCodes.remove(id);
          }
        }
      }
      return false;
    }
  }

  Future<void> refreshStale({DateTime? now}) async {
    final time = now ?? DateTime.now().toUtc();
    final groups = controller.groups
        .where(
          (group) =>
              group.sourceUrl != null &&
              (group.updatedAt == null ||
                  time.difference(group.updatedAt!).inHours >= 6),
        )
        .toList();
    for (final group in groups) {
      if (!_allowed) return;
      await refresh(group.id);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _loader.close();
    super.dispose();
  }
}
