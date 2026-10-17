// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

const amber = Color(0xffffbd51);
const graphite = Color(0xff141617);
const darkInk = Color(0xff111314);
const softBlue = Color(0xff147fbf);

/// The five editable colors. Other UI colors are derived from these roles.
@immutable
class ExVpnPalette {
  const ExVpnPalette({
    required this.background,
    required this.surface,
    required this.accent,
    required this.glow,
    required this.text,
  });

  static const dark = ExVpnPalette(
    background: graphite,
    surface: Color(0xff1a1d1f),
    accent: amber,
    glow: amber,
    text: Color(0xfff7f6f3),
  );
  static const light = ExVpnPalette(
    background: Color(0xfff7fbff),
    surface: Colors.white,
    accent: softBlue,
    glow: Color(0xff74bfff),
    text: Color(0xff294354),
  );

  final Color background;
  final Color surface;
  final Color accent;
  final Color glow;
  final Color text;

  Brightness get brightness => ThemeData.estimateBrightnessForColor(background);

  ExVpnPalette copyWith({
    Color? background,
    Color? surface,
    Color? accent,
    Color? glow,
    Color? text,
  }) => ExVpnPalette(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    accent: accent ?? this.accent,
    glow: glow ?? this.glow,
    text: text ?? this.text,
  );
}

@immutable
class ExVpnVisuals extends ThemeExtension<ExVpnVisuals> {
  const ExVpnVisuals({required this.glowColor, required this.buttonColor});
  final Color glowColor;
  final Color buttonColor;

  @override
  ExVpnVisuals copyWith({Color? glowColor, Color? buttonColor}) => ExVpnVisuals(
    glowColor: glowColor ?? this.glowColor,
    buttonColor: buttonColor ?? this.buttonColor,
  );

  @override
  ExVpnVisuals lerp(covariant ExVpnVisuals? other, double t) => other == null
      ? this
      : ExVpnVisuals(
          glowColor: Color.lerp(glowColor, other.glowColor, t)!,
          buttonColor: Color.lerp(buttonColor, other.buttonColor, t)!,
        );
}

ThemeData exVpnTheme(Brightness brightness, {ExVpnPalette? palette}) {
  final p =
      palette ??
      (brightness == Brightness.dark ? ExVpnPalette.dark : ExVpnPalette.light);
  final dark = brightness == Brightness.dark;
  Color blend(Color from, Color to, double amount) =>
      Color.lerp(from, to, amount)!;
  final onAccent =
      ThemeData.estimateBrightnessForColor(p.accent) == Brightness.dark
      ? Colors.white
      : darkInk;
  final mutedText = blend(p.background, p.text, dark ? .61 : .67);
  final outline = blend(p.surface, p.text, .14);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: p.accent,
        brightness: brightness,
      ).copyWith(
        primary: p.accent,
        onPrimary: onAccent,
        primaryContainer: dark ? p.accent : blend(p.surface, p.accent, .13),
        onPrimaryContainer: dark ? onAccent : blend(p.text, p.accent, .3),
        secondary: p.accent,
        onSecondary: onAccent,
        secondaryContainer: blend(p.surface, p.accent, .14),
        onSecondaryContainer: p.text,
        tertiary: p.glow,
        onTertiary:
            ThemeData.estimateBrightnessForColor(p.glow) == Brightness.dark
            ? Colors.white
            : darkInk,
        surface: p.background,
        surfaceDim: blend(p.background, p.text, .035),
        surfaceBright: blend(p.surface, p.text, dark ? .07 : 0),
        surfaceContainerLowest: p.background,
        surfaceContainerLow: p.surface,
        surfaceContainer: blend(p.surface, p.text, .035),
        surfaceContainerHigh: blend(p.surface, p.text, .07),
        surfaceContainerHighest: blend(p.surface, p.text, .11),
        onSurface: p.text,
        onSurfaceVariant: mutedText,
        outline: blend(p.surface, p.text, .35),
        outlineVariant: outline,
        inverseSurface: p.text,
        onInverseSurface: p.background,
        inversePrimary: p.accent,
        surfaceTint: p.accent,
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'Inter',
    fontFamilyFallback: const ['NotoSansSC', 'NotoSansArabic'],
    scaffoldBackgroundColor: p.background,
    canvasColor: p.surface,
    extensions: [
      ExVpnVisuals(
        glowColor: p.glow,
        buttonColor: palette == null
            ? (dark ? const Color(0xff25282a) : const Color(0xfff5f9fc))
            : blend(p.surface, p.text, dark ? .05 : .02),
      ),
    ],
    iconTheme: IconThemeData(color: p.text, size: 24),
    dividerTheme: DividerThemeData(color: outline, thickness: .6, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      foregroundColor: p.text,
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: p.background),
    dialogTheme: DialogThemeData(
      backgroundColor: p.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
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
        borderSide: BorderSide(color: p.accent),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: onAccent,
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}
