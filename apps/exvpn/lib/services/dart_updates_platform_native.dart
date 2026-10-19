// SPDX-License-Identifier: Apache-2.0
import 'dart:isolate';
import 'dart:ffi';

import 'package:flutter/foundation.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

import 'dart_updates_shorebird.dart';
import 'dart_updates_types.dart';
import '../build_identity.dart';
import 'dart_updates_independent.dart';
import 'independent_ota_bridge.dart';

DartUpdatesBackend? _independentBackend;

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
  final delegate = _IsolatedShorebirdBackend(track);
  const provider = String.fromEnvironment('EXVPN_OTA_PROVIDER');
  if (provider == 'exvpn') {
    const fingerprint = String.fromEnvironment('EXVPN_OTA_BASE_FINGERPRINT');
    final target = switch (Abi.current()) {
      Abi.windowsX64 => 'windows/x86_64',
      Abi.androidArm64 => 'android/aarch64',
      Abi.androidX64 => 'android/x86_64',
      _ => '',
    };
    if (target.isEmpty || !RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint)) {
      return DisabledDartUpdatesBackend(
        track: track,
        disabledReason: 'invalid_configuration',
      );
    }
    return _independentBackend ??= IndependentDartUpdatesBackend(
      delegate,
      IndependentOtaBridge.forProcess(appVersionLabel, fingerprint, target),
    );
  }
  return delegate;
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
