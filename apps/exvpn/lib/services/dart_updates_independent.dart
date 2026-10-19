// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'dart_updates_types.dart';
import 'independent_ota_bridge.dart';
import 'independent_ota_catalog.dart';

/// Serialize native updater calls. A native FFI timeout cannot be cancelled:
/// keep its loopback listener owned and prohibit any further engine access.
class IndependentDartUpdatesBackend implements DartUpdatesBackend {
  IndependentDartUpdatesBackend(
    this.delegate,
    this.bridge, {
    this.nativeTimeout = const Duration(seconds: 90),
  });
  final DartUpdatesBackend delegate;
  final IndependentOtaBridge bridge;
  final Duration nativeTimeout;
  Future<void> _tail = Future<void>.value();
  bool _fatal = false;

  @override
  String get track => delegate.track;
  @override
  String? get disabledReason => _fatal ? 'adapter_unavailable' : null;

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _tail.then((_) async {
      if (_fatal) {
        throw const DartUpdatesFailure(DartUpdateError.operationFailed);
      }
      return operation();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<T> _native<T>(Future<T> Function() operation) async {
    try {
      return await operation().timeout(nativeTimeout);
    } on TimeoutException {
      _fatal = true;
      bridge.disable();
      throw const DartUpdatesFailure(DartUpdateError.operationFailed);
    }
  }

  @override
  Future<DartPatchSnapshot> read() => _serialized(() async {
    try {
      await bridge.start();
      return await _native(delegate.read);
    } on IndependentOtaFailure {
      throw const DartUpdatesFailure(DartUpdateError.readFailed);
    }
  });

  @override
  Future<DartUpdateCheck> check() => _serialized(() async {
    try {
      final snapshot = await _native(delegate.read);
      if (!snapshot.available) {
        return DartUpdateCheck(DartUpdateStatus.unavailable, snapshot);
      }
      await bridge.prepare(track, download: false);
      return await _native(delegate.check);
    } on IndependentOtaFailure {
      throw const DartUpdatesFailure(DartUpdateError.checkFailed);
    }
  });

  @override
  Future<DartPatchSnapshot> download() => _serialized(() async {
    try {
      await bridge.prepare(track, download: true);
      return await _native(delegate.download);
    } on IndependentOtaFailure {
      throw const DartUpdatesFailure(DartUpdateError.downloadFailed);
    }
  });
}
