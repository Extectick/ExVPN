import 'package:flutter/material.dart';

const amber = Color(0xffffbd51);
const graphite = Color(0xff141617);
const darkInk = Color(0xff111314);

ThemeData exVpnTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: amber, brightness: brightness)
      .copyWith(
        primary: dark ? amber : const Color(0xff8a4c00),
        surface: dark ? graphite : const Color(0xfff6f5f1),
        onSurface: dark ? const Color(0xfff7f6f3) : darkInk,
        onSurfaceVariant: dark
            ? const Color(0xffa0a3a7)
            : const Color(0xff61656a),
        outlineVariant: dark
            ? const Color(0xff303336)
            : const Color(0xffdddcd6),
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: scheme.surface,
    iconTheme: IconThemeData(color: scheme.onSurface, size: 24),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 0.6,
      space: 1,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xff202326) : Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: amber,
        foregroundColor: darkInk,
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}
