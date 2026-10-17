// SPDX-License-Identifier: Apache-2.0
import 'dart_updates_types.dart';

DartUpdatesBackend createDartUpdatesBackend(String track) =>
    DisabledDartUpdatesBackend(track: track);
