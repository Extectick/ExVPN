// SPDX-License-Identifier: Apache-2.0
import 'dart:js_interop';

@JS('globalThis.localStorage')
external _LocalStorage get _storage;

extension type _LocalStorage(JSObject _) implements JSObject {
  external JSString? getItem(JSString key);
  external void setItem(JSString key, JSString value);
}

String _key(bool preview) =>
    preview ? 'exvpn_design_appearance_v1' : 'exvpn_appearance_v1';

Future<String?> readAppearance({required bool preview}) async {
  final raw = _storage.getItem(_key(preview).toJS)?.toDart;
  if (raw != null && raw.length > 4096) throw const FormatException();
  return raw;
}

Future<void> writeAppearance(String raw, {required bool preview}) async {
  if (raw.length > 4096) throw const FormatException();
  _storage.setItem(_key(preview).toJS, raw.toJS);
}
