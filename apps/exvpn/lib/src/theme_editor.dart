// SPDX-License-Identifier: Apache-2.0
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_strings.dart';
import 'appearance.dart';

class ThemeEditorSheet extends StatefulWidget {
  const ThemeEditorSheet({super.key, required this.appearance});

  final AppearanceController appearance;

  @override
  State<ThemeEditorSheet> createState() => _ThemeEditorSheetState();
}

enum _ColorField { background, surface, accent, glow, text }

class _ThemeEditorSheetState extends State<ThemeEditorSheet> {
  final _hex = TextEditingController();
  final _hexFocus = FocusNode();
  _ColorField _selected = _ColorField.accent;
  bool _invalidHex = false;

  ExVpnPalette get _palette => widget.appearance.customPalette;
  Color get _color => _fieldColor(_palette, _selected);

  @override
  void initState() {
    super.initState();
    _writeHex();
    widget.appearance.addListener(_paletteChanged);
  }

  @override
  void dispose() {
    widget.appearance.removeListener(_paletteChanged);
    _hex.dispose();
    _hexFocus.dispose();
    super.dispose();
  }

  String _hexValue(Color color) =>
      color.toARGB32().toRadixString(16).substring(2).toUpperCase();

  void _writeHex() {
    final value = _hexValue(_color);
    if (_hex.text.replaceFirst('#', '').toUpperCase() == value) return;
    _hex.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _paletteChanged() {
    if (!mounted) return;
    setState(() {
      _invalidHex = false;
      _writeHex();
    });
  }

  void _selectField(_ColorField field) {
    _hexFocus.unfocus();
    setState(() {
      _selected = field;
      _invalidHex = false;
      _writeHex();
    });
  }

  void _setColor(Color color) {
    final palette = switch (_selected) {
      _ColorField.background => _palette.copyWith(background: color),
      _ColorField.surface => _palette.copyWith(surface: color),
      _ColorField.accent => _palette.copyWith(accent: color),
      _ColorField.glow => _palette.copyWith(glow: color),
      _ColorField.text => _palette.copyWith(text: color),
    };
    widget.appearance.updateCustomPalette(palette);
  }

  bool _applyHex(String value) {
    final digits = value.replaceFirst('#', '');
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(digits)) return false;
    _setColor(Color(0xff000000 | int.parse(digits, radix: 16)));
    return true;
  }

  String _fieldLabel(BuildContext context, _ColorField field) =>
      context.tr(switch (field) {
        _ColorField.background => 'Фон',
        _ColorField.surface => 'Поверхность',
        _ColorField.accent => 'Акцент',
        _ColorField.glow => 'Свечение',
        _ColorField.text => 'Текст',
      });

  Widget _slider({
    required BuildContext context,
    required String label,
    required double value,
    required double max,
    required String displayValue,
    required ValueChanged<double> onChanged,
    Color? color,
  }) => Row(
    children: [
      SizedBox(
        width: 94,
        child: Text(context.tr(label), style: const TextStyle(fontSize: 12)),
      ),
      Expanded(
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Semantics(
            label: context.tr(label),
            child: Slider(
              value: value,
              max: max,
              activeColor: color,
              semanticFormatterCallback: (_) => displayValue,
              onChanged: onChanged,
            ),
          ),
        ),
      ),
      SizedBox(
        width: 38,
        child: Text(
          displayValue,
          textAlign: TextAlign.end,
          style: const TextStyle(fontSize: 11),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final hsv = HSVColor.fromColor(_color);
    return Theme(
      data: widget.appearance.lightTheme,
      child: Builder(
        builder: (context) => Material(
          color: Theme.of(context).colorScheme.surface,
          child: SizedBox(
            height: math.min(MediaQuery.sizeOf(context).height * 0.8, 680),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                24,
                0,
                24,
                24 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.tr('ЦВЕТА ТЕМЫ'),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: context.tr('Закрыть редактор'),
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _PalettePreview(palette: _palette),
                const SizedBox(height: 20),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final field in _ColorField.values)
                      Expanded(
                        child: Semantics(
                          selected: field == _selected,
                          button: true,
                          label: _fieldLabel(context, field),
                          child: InkWell(
                            key: ValueKey('palette-field-${field.name}'),
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => _selectField(field),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Column(
                                children: [
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 120),
                                    width: 34,
                                    height: 34,
                                    decoration: BoxDecoration(
                                      color: _fieldColor(_palette, field),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: field == _selected
                                            ? Theme.of(context)
                                                  .colorScheme
                                                  .onSurface
                                            : Theme.of(context)
                                                  .colorScheme
                                                  .outlineVariant,
                                        width: field == _selected ? 2 : 1,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    _fieldLabel(context, field),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: field == _selected
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('palette-hex'),
                  controller: _hex,
                  focusNode: _hexFocus,
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  enableSuggestions: false,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F#]')),
                    LengthLimitingTextInputFormatter(7),
                  ],
                  decoration: InputDecoration(
                    labelText: context.tr('Цвет в формате HEX'),
                    prefixText: '# ',
                    suffixIcon: Padding(
                      padding: const EdgeInsets.all(12),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: _color,
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                        child: const SizedBox(width: 22, height: 22),
                      ),
                    ),
                    errorText: _invalidHex
                        ? context.tr('Введите 6 символов HEX')
                        : null,
                  ),
                  onChanged: (value) {
                    if (_invalidHex) setState(() => _invalidHex = false);
                    _applyHex(value);
                  },
                  onSubmitted: (value) {
                    if (!_applyHex(value)) setState(() => _invalidHex = true);
                  },
                ),
                const SizedBox(height: 12),
                _slider(
                  context: context,
                  label: 'Оттенок',
                  value: hsv.hue,
                  max: 360,
                  displayValue: '${hsv.hue.round()}°',
                  color: HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor(),
                  onChanged: (value) => _setColor(hsv.withHue(value).toColor()),
                ),
                _slider(
                  context: context,
                  label: 'Насыщенность',
                  value: hsv.saturation,
                  max: 1,
                  displayValue: '${(hsv.saturation * 100).round()}%',
                  onChanged: (value) =>
                      _setColor(hsv.withSaturation(value).toColor()),
                ),
                _slider(
                  context: context,
                  label: 'Яркость',
                  value: hsv.value,
                  max: 1,
                  displayValue: '${(hsv.value * 100).round()}%',
                  onChanged: (value) =>
                      _setColor(hsv.withValue(value).toColor()),
                ),
                const SizedBox(height: 16),
                Text(
                  context.tr('Готовые палитры'),
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final preset in _presets)
                      ActionChip(
                        avatar: CircleAvatar(
                          backgroundColor: preset.$2.accent,
                          radius: 7,
                        ),
                        label: Text(context.tr(preset.$1)),
                        onPressed: () =>
                            widget.appearance.updateCustomPalette(preset.$2),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const Key('reset-custom-palette'),
                    onPressed: widget.appearance.resetCustomPalette,
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: Text(context.tr('Сбросить цвета')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Color _fieldColor(ExVpnPalette palette, _ColorField field) => switch (field) {
  _ColorField.background => palette.background,
  _ColorField.surface => palette.surface,
  _ColorField.accent => palette.accent,
  _ColorField.glow => palette.glow,
  _ColorField.text => palette.text,
};

class _PalettePreview extends StatelessWidget {
  const _PalettePreview({required this.palette});
  final ExVpnPalette palette;

  @override
  Widget build(BuildContext context) => Container(
    height: 88,
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
    decoration: BoxDecoration(
      color: palette.background,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: palette.text.withValues(alpha: 0.12)),
    ),
    child: Row(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: palette.surface,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: palette.glow.withValues(alpha: 0.3),
                blurRadius: 18,
                spreadRadius: 3,
              ),
            ],
          ),
          child: Icon(
            Icons.power_settings_new,
            color: palette.accent,
            size: 26,
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Text(
            'ExVPN',
            style: TextStyle(
              color: palette.text,
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Icon(Icons.palette_outlined, color: palette.accent, size: 20),
      ],
    ),
  );
}

const _presets = [
  (
    'Графит',
    ExVpnPalette(
      background: Color(0xff141617),
      surface: Color(0xff1a1d1f),
      accent: Color(0xffffbd51),
      glow: Color(0xffffbd51),
      text: Color(0xfff7f6f3),
    ),
  ),
  (
    'Светлая',
    ExVpnPalette(
      background: Color(0xfff7fbff),
      surface: Color(0xffffffff),
      accent: Color(0xff147fbf),
      glow: Color(0xff6cc8ff),
      text: Color(0xff294354),
    ),
  ),
  (
    'Океан',
    ExVpnPalette(
      background: Color(0xff0b1820),
      surface: Color(0xff132832),
      accent: Color(0xff67dccb),
      glow: Color(0xff31c6c3),
      text: Color(0xffe7f7f7),
    ),
  ),
  (
    'Лаванда',
    ExVpnPalette(
      background: Color(0xff191720),
      surface: Color(0xff272332),
      accent: Color(0xffc2a3ff),
      glow: Color(0xffae86f4),
      text: Color(0xfff4edff),
    ),
  ),
];
