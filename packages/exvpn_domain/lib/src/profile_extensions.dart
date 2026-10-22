import 'dart:convert';

/// Bounded remote QUIC tuning, never arbitrary FinalMask configuration.
final class QuicOptions {
  QuicOptions._(Map<String, Object?> values)
    : _values = Map.unmodifiable(values);
  final Map<String, Object?> _values;
  static const fields = {
    'congestion',
    'initStreamReceiveWindow',
    'maxStreamReceiveWindow',
    'initConnectionReceiveWindow',
    'maxConnectionReceiveWindow',
    'maxIdleTimeout',
    'keepAlivePeriod',
  };

  factory QuicOptions.fromJson(Map<String, Object?> input) {
    if (input.keys.any((key) => !fields.contains(key)) ||
        input.values.any((value) => value == null)) {
      _invalid();
    }
    final values = <String, Object?>{};
    if (input.containsKey('congestion')) {
      final congestion = input['congestion'];
      if (!{'', 'bbr', 'reno'}.contains(congestion)) _invalid();
      if (congestion != '') values['congestion'] = congestion;
    }
    for (final key in fields.where((key) => key != 'congestion')) {
      if (!input.containsKey(key)) continue;
      final value = input[key];
      if (value is! int) _invalid();
      final timer = key == 'maxIdleTimeout' || key == 'keepAlivePeriod';
      final minimum = key == 'maxIdleTimeout'
          ? 4
          : key == 'keepAlivePeriod'
          ? 2
          : 16384;
      final maximum = timer
          ? (key == 'maxIdleTimeout' ? 120 : 60)
          : (key.contains('Connection') ? 64 * 1024 * 1024 : 16 * 1024 * 1024);
      if (value != 0 && (value < minimum || value > maximum)) _invalid();
      if (value != 0) values[key] = value;
    }
    int resolved(String key, int fallback) => values[key] as int? ?? fallback;
    final streamMax = resolved('maxStreamReceiveWindow', 8388608);
    final connectionMax = resolved('maxConnectionReceiveWindow', 20971520);
    if (resolved('initStreamReceiveWindow', 8388608) > streamMax ||
        resolved('initConnectionReceiveWindow', 20971520) > connectionMax ||
        streamMax > connectionMax ||
        resolved('keepAlivePeriod', 0) >= resolved('maxIdleTimeout', 30)) {
      _invalid();
    }
    return QuicOptions._(values);
  }

  Map<String, Object?> toJson() => Map.of(_values);
}

/// VLESS Encryption is a bounded key/padding grammar, never executable JSON.
/// The value contains peer authentication material and must stay private.
final class VlessEncryption {
  const VlessEncryption._(this.value);
  final String value;

  factory VlessEncryption.parse(String value) {
    if (value.length > 8192) _invalid();
    final parts = value.split('.');
    if (parts.length < 4 ||
        parts[0] != 'mlkem768x25519plus' ||
        !{'native', 'xorpub', 'random'}.contains(parts[1]) ||
        !{'0rtt', '1rtt'}.contains(parts[2])) {
      _invalid();
    }
    var keys = 0;
    var padding = 0;
    var maximumLength = 0;
    for (final part in parts.skip(3)) {
      if (part.length < 20) {
        if (keys != 0 ||
            padding >= 15 ||
            !RegExp(
              r'^(0|[1-9][0-9]*)-(0|[1-9][0-9]*)-(0|[1-9][0-9]*)$',
            ).hasMatch(part)) {
          _invalid();
        }
        final numbers = part.split('-').map(int.parse).toList();
        if (numbers[0] > 100 ||
            numbers[1] > numbers[2] ||
            numbers[2] > (padding.isEven ? 65553 : 1000) ||
            (padding == 0 && (numbers[0] != 100 || numbers[1] < 35))) {
          _invalid();
        }
        if (padding.isEven) maximumLength += numbers[2];
        padding++;
      } else {
        if (++keys > 4 || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(part)) {
          _invalid();
        }
        late final List<int> decoded;
        try {
          decoded = base64Url.decode(base64Url.normalize(part));
        } on FormatException {
          // Base64 errors include their input; authentication keys stay private.
          _invalid();
        }
        if (!{32, 1184}.contains(decoded.length) ||
            base64Url.encode(decoded).replaceAll('=', '') != part ||
            decoded.every((byte) => byte == 0)) {
          _invalid();
        }
        if (decoded.length == 1184) {
          // ML-KEM-768: three encoded polynomials, then a 32-byte seed.
          // Reject noncanonical coefficients at import, as the native SDK does.
          for (var i = 0; i < 1152; i += 3) {
            final first = decoded[i] | ((decoded[i + 1] & 15) << 8);
            final second = (decoded[i + 1] >> 4) | (decoded[i + 2] << 4);
            if (first >= 3329 || second >= 3329) _invalid();
          }
        }
      }
    }
    if (keys == 0 || maximumLength > 65553) _invalid();
    return VlessEncryption._(value);
  }

  @override
  String toString() => 'VlessEncryption(<redacted>)';
}

/// One TCP Sudoku appearance transform. Other FinalMask capabilities cannot
/// cross this schema. Sudoku itself does not authenticate or encrypt the peer.
final class SudokuOptions {
  SudokuOptions._(
    this.password,
    this.ascii,
    this.customTables,
    this.paddingMin,
    this.paddingMax,
  );

  final String password;
  final String ascii;
  final List<String> customTables;
  final int paddingMin;
  final int paddingMax;

  factory SudokuOptions.fromJson(Map<String, Object?> input) {
    const allowed = {
      'password',
      'ascii',
      'customTable',
      'customTables',
      'paddingMin',
      'paddingMax',
      'custom_table',
      'custom_tables',
      'padding_min',
      'padding_max',
    };
    if (input.keys.any((key) => !allowed.contains(key)) ||
        input.values.any((value) => value == null)) {
      _invalid();
    }
    final data = Map<String, Object?>.of(input);
    for (final pair in const [
      ('custom_table', 'customTable'),
      ('custom_tables', 'customTables'),
      ('padding_min', 'paddingMin'),
      ('padding_max', 'paddingMax'),
    ]) {
      if (data.containsKey(pair.$1)) {
        if (data.containsKey(pair.$2)) _invalid();
        data[pair.$2] = data.remove(pair.$1);
      }
    }
    final password = data['password'];
    if (password is! String ||
        password.isEmpty ||
        utf8.encode(password).length > 4096 ||
        password.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      _invalid();
    }
    final requestedAscii = data['ascii'] ?? '';
    if (requestedAscii is! String) _invalid();
    final ascii = switch (requestedAscii.trim().toLowerCase()) {
      '' || 'entropy' || 'prefer_entropy' => 'prefer_entropy',
      'ascii' || 'prefer_ascii' => 'prefer_ascii',
      _ => _invalid(),
    };
    if (data.containsKey('customTable') && data.containsKey('customTables')) {
      _invalid();
    }
    final patterns = data.containsKey('customTable')
        ? [data['customTable']]
        : data['customTables'] ?? <Object?>[];
    if (patterns is! List || patterns.length > 4) _invalid();
    final tables = <String>[];
    for (final pattern in patterns) {
      if (pattern is! String || pattern.length > 64) _invalid();
      final table = pattern.trim().toLowerCase().replaceAll(' ', '');
      if (table.isEmpty) continue;
      if (table.length != 8 ||
          'x'.allMatches(table).length != 2 ||
          'p'.allMatches(table).length != 2 ||
          'v'.allMatches(table).length != 4) {
        _invalid();
      }
      if (!tables.contains(table)) tables.add(table);
    }
    if (ascii == 'prefer_ascii' && tables.isNotEmpty) _invalid();
    final min = data['paddingMin'] ?? 0;
    final max = data['paddingMax'] ?? 0;
    if (min is! int || max is! int || min < 0 || max > 100 || min > max) {
      _invalid();
    }
    return SudokuOptions._(
      password,
      ascii,
      List.unmodifiable(tables),
      min,
      max,
    );
  }

  Map<String, Object?> toJson() => {
    'password': password,
    if (ascii != 'prefer_entropy') 'ascii': ascii,
    if (customTables.isNotEmpty) 'customTables': customTables,
    if (paddingMin != 0) 'paddingMin': paddingMin,
    if (paddingMax != 0) 'paddingMax': paddingMax,
  };

  @override
  String toString() => 'SudokuOptions(<redacted>)';
}

Never _invalid() => throw const FormatException('Invalid profile extension');
