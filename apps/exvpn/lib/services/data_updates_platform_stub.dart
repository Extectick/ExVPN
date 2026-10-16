// SPDX-License-Identifier: Apache-2.0
import 'data_updates_types.dart';

DataUpdatesBackend createDataUpdatesBackend() =>
    DisabledDataUpdatesBackend('unsupported_platform');
