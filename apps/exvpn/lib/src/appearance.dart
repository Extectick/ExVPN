// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:flutter/services.dart' show rootBundle;

import 'app_strings.dart';
import 'appearance_storage_native.dart'
    if (dart.library.js_interop) 'appearance_storage_web.dart'
    as storage;
import 'theme.dart';
export 'theme.dart' show ExVpnPalette;

enum ThemeChoice { system, dark, light, custom }

bool _fontLicensesRegistered = false;
void _registerFontLicenses() {
  if (_fontLicensesRegistered) return;
  _fontLicensesRegistered = true;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'domain-list-community',
    ], await rootBundle.loadString('assets/licenses/DomainListCommunity.txt'));
    for (final name in ['NotoSansSC', 'NotoSansArabic']) {
      yield LicenseEntryWithLineBreaks([
        name,
      ], await rootBundle.loadString('assets/fonts/$name-OFL.txt'));
    }
  });
}

/// UI preferences only. This controller never changes the VPN or native policy.
class AppearanceController extends ChangeNotifier {
  AppearanceController({this.persist = true, this.preview = false}) {
    _registerFontLicenses();
  }

  final bool persist;
  final bool preview;
  ThemeChoice _choice = ThemeChoice.dark;
  Locale? _locale;
  ExVpnPalette _customPalette = ExVpnPalette.dark;
  Future<void> _saveTail = Future<void>.value();
  Timer? _saveTimer;
  String? _pendingSave;
  Future<void>? _initialization;
  int _revision = 0;
  bool _disposed = false;
  String? _storageErrorCode;

  ThemeChoice get choice => _choice;

  /// Null follows the current operating-system language, including changes.
  Locale? get locale => _locale;
  ExVpnPalette get customPalette => _customPalette;
  String? get storageErrorCode => _storageErrorCode;

  ThemeMode get themeMode => switch (_choice) {
    ThemeChoice.system => ThemeMode.system,
    ThemeChoice.dark => ThemeMode.dark,
    ThemeChoice.light => ThemeMode.light,
    ThemeChoice.custom =>
      _customPalette.brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
  };

  ThemeData get lightTheme => _choice == ThemeChoice.custom
      ? exVpnTheme(_customPalette.brightness, palette: _customPalette)
      : exVpnTheme(Brightness.light);
  ThemeData get darkTheme => _choice == ThemeChoice.custom
      ? exVpnTheme(_customPalette.brightness, palette: _customPalette)
      : exVpnTheme(Brightness.dark);

  Future<void> initialize() => _initialization ??= _load();

  Future<void> _load() async {
    if (!persist) return;
    final revision = _revision;
    try {
      final raw = await storage.readAppearance(preview: preview);
      if (raw == null || _disposed || revision != _revision) return;
      if (raw.length > 4096 || utf8.encode(raw).length > 4096) {
        throw const FormatException();
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        throw const FormatException();
      }
      final theme = decoded['theme'];
      final language = decoded['language'];
      final colors = decoded['colors'];
      final selected = ThemeChoice.values
          .where((v) => v.name == theme)
          .firstOrNull;
      if (selected == null ||
          (language != null &&
              (language is! String ||
                  !appSupportedLocales.any(
                    (v) => v.languageCode == language,
                  ))) ||
          colors is! Map<String, dynamic>) {
        throw const FormatException();
      }
      Color color(String name) {
        final value = colors[name];
        if (value is! int || value < 0xff000000 || value > 0xffffffff) {
          throw const FormatException();
        }
        return Color(value);
      }

      final palette = ExVpnPalette(
        background: color('background'),
        surface: color('surface'),
        accent: color('accent'),
        glow: color('glow'),
        text: color('text'),
      );
      _choice = selected;
      _locale = language == null ? null : Locale(language as String);
      _customPalette = palette;
      _storageErrorCode = null;
      notifyListeners();
    } catch (_) {
      if (!_disposed && revision == _revision) {
        _storageErrorCode = 'appearance_storage_unavailable';
        notifyListeners();
      }
    }
  }

  void setChoice(ThemeChoice choice) {
    if (_choice == choice) return;
    _choice = choice;
    _changed();
  }

  void setLocale(String? languageCode) {
    if (languageCode != null &&
        !appSupportedLocales.any((v) => v.languageCode == languageCode)) {
      return;
    }
    final locale = languageCode == null ? null : Locale(languageCode);
    if (_locale == locale) return;
    _locale = locale;
    _changed();
  }

  void updateCustomPalette(ExVpnPalette palette) {
    Color opaque(Color value) => value.withValues(alpha: 1);
    _customPalette = ExVpnPalette(
      background: opaque(palette.background),
      surface: opaque(palette.surface),
      accent: opaque(palette.accent),
      glow: opaque(palette.glow),
      text: opaque(palette.text),
    );
    _choice = ThemeChoice.custom;
    _changed();
  }

  void resetCustomPalette() => updateCustomPalette(ExVpnPalette.dark);

  void _changed() {
    _revision++;
    notifyListeners();
    if (!persist) return;
    final p = _customPalette;
    _pendingSave = jsonEncode({
      'version': 1,
      'theme': _choice.name,
      'language': _locale?.languageCode,
      'colors': {
        'background': p.background.toARGB32(),
        'surface': p.surface.toARGB32(),
        'accent': p.accent.toARGB32(),
        'glow': p.glow.toARGB32(),
        'text': p.text.toARGB32(),
      },
    });
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 250), _queuePendingSave);
  }

  void _queuePendingSave() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final raw = _pendingSave;
    _pendingSave = null;
    if (raw == null) return;
    _saveTail = _saveTail.then((_) async {
      try {
        await storage.writeAppearance(raw, preview: preview);
        if (!_disposed && _storageErrorCode != null) {
          _storageErrorCode = null;
          notifyListeners();
        }
      } catch (_) {
        if (!_disposed) {
          _storageErrorCode = 'appearance_storage_unavailable';
          notifyListeners();
        }
      }
    });
  }

  /// Finish pending preferences before a deliberate full app exit.
  Future<void> flush() {
    _queuePendingSave();
    return _saveTail;
  }

  @override
  void dispose() {
    _queuePendingSave();
    _disposed = true;
    super.dispose();
  }
}

class AppearanceScope extends InheritedNotifier<AppearanceController> {
  const AppearanceScope({
    super.key,
    required AppearanceController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppearanceController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;

  static AppearanceController of(BuildContext context) {
    final controller = maybeOf(context);
    assert(
      controller != null,
      'AppearanceScope is missing above this context.',
    );
    return controller!;
  }
}
