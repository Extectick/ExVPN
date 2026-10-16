import 'dart:async';

import 'package:exvpn_client_state/exvpn_client_state.dart';
import 'package:flutter/foundation.dart';

import 'subscription_store.dart';

/// Serial coalesced writes; a failed write remains visible and retryable.
final class SubscriptionPersistence extends ChangeNotifier {
  SubscriptionPersistence(this.controller, this.store) {
    _changes = controller.changes.listen((_) {
      _requested++;
      unawaited(flush());
    });
  }
  final AppController controller;
  final SubscriptionStore store;
  late final StreamSubscription<void> _changes;
  Future<void>? _running;
  int _requested = 0;
  int _saved = 0;
  bool _disposed = false;
  SubscriptionStoreErrorCode? error;
  bool get saving => _running != null;
  bool get pending => _requested != _saved;

  Future<void> flush() {
    if (_disposed) return Future.value();
    return _running ??= _drain().whenComplete(() {
      _running = null;
      if (!_disposed) notifyListeners();
      if (!_disposed && pending && error == null) unawaited(flush());
    });
  }

  Future<void> _drain() async {
    while (!_disposed && _saved < _requested) {
      final revision = _requested;
      try {
        await store.save(controller);
        _saved = revision;
        error = null;
      } on SubscriptionStoreException catch (failure) {
        error = failure.code;
        break;
      } catch (_) {
        error = SubscriptionStoreErrorCode.writeFailed;
        break;
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _changes.cancel();
    super.dispose();
  }
}
