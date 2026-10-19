// SPDX-License-Identifier: Apache-2.0
export 'qr_sources_native.dart'
    if (dart.library.js_interop) 'qr_sources_web.dart';
