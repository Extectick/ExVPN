// SPDX-License-Identifier: Apache-2.0
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

import 'dart_updates_shorebird.dart';
import 'dart_updates_types.dart';

DartUpdatesBackend createDartUpdatesBackend(String track) {
  if (track != 'beta' && track != 'stable') {
    return const DisabledDartUpdatesBackend(
      disabledReason: 'invalid_configuration',
    );
  }
  if (defaultTargetPlatform != TargetPlatform.android &&
      defaultTargetPlatform != TargetPlatform.windows) {
    return DisabledDartUpdatesBackend(track: track);
  }
  return _IsolatedShorebirdBackend(track);
}

class _IsolatedShorebirdBackend implements DartUpdatesBackend {
  const _IsolatedShorebirdBackend(this.track);
  @override
  final String track;
  @override
  String? get disabledReason => null;

  // Even SDK construction reads a synchronous engine lock. Keep it off the UI
  // isolate, as well as the network operations. No engine access during startup.
  @override
  Future<DartPatchSnapshot> read() {
    final selectedTrack = track;
    return Isolate.run(
      () => ShorebirdDartUpdatesBackend(
        ShorebirdUpdater(),
        track: selectedTrack,
      ).read(),
    );
  }

  @override
  Future<DartUpdateCheck> check() {
    final selectedTrack = track;
    return Isolate.run(
      () => ShorebirdDartUpdatesBackend(
        ShorebirdUpdater(),
        track: selectedTrack,
      ).check(),
    );
  }

  @override
  Future<DartPatchSnapshot> download() {
    final selectedTrack = track;
    return Isolate.run(
      () => ShorebirdDartUpdatesBackend(
        ShorebirdUpdater(),
        track: selectedTrack,
      ).download(),
    );
  }
}
