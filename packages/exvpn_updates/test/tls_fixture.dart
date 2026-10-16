// SPDX-License-Identifier: Apache-2.0
// Test-only X.509 envelope. PointyCastle generates/signs a fresh RSA key in
// memory; no CA/key is written to disk or installed in the OS.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

List<int> _der(int tag, List<int> bytes) {
  final length = bytes.length < 128
      ? [bytes.length]
      : bytes.length < 256
      ? [0x81, bytes.length]
      : [0x82, bytes.length >> 8, bytes.length & 255];
  return [tag, ...length, ...bytes];
}

List<int> _sequence(List<List<int>> values) =>
    _der(0x30, values.expand((v) => v).toList());
List<int> _integer(BigInt value) {
  var hex = value.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final bytes = [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
  return _der(0x02, [if (bytes.first & 128 != 0) 0, ...bytes]);
}

List<int> _pem(String label, List<int> bytes) => ascii.encode(
  '-----BEGIN $label-----\n${base64.encode(bytes)}\n-----END $label-----\n',
);

Future<(SecurityContext, SecurityContext)> localTLSContexts() async {
  final entropy = Random.secure();
  final random = FortunaRandom()
    ..seed(
      KeyParameter(
        Uint8List.fromList(List.generate(32, (_) => entropy.nextInt(256))),
      ),
    );
  final generator = RSAKeyGenerator()
    ..init(
      ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
        random,
      ),
    );
  final pair = generator.generateKeyPair();
  final key = pair.privateKey;
  final signatureAlgorithm = _sequence([
    _der(0x06, [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 11]),
    _der(0x05, []),
  ]);
  final rsaAlgorithm = _sequence([
    _der(0x06, [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 1]),
    _der(0x05, []),
  ]);
  final name = _sequence([
    _der(
      0x31,
      _sequence([
        _der(0x06, [0x55, 0x04, 0x03]),
        _der(0x0c, utf8.encode('localhost')),
      ]),
    ),
  ]);
  final extensions = _sequence([
    _sequence([
      _der(0x06, [0x55, 0x1d, 0x13]),
      _der(0x01, [0xff]),
      _der(
        0x04,
        _sequence([
          _der(0x01, [0xff]),
        ]),
      ),
    ]),
    _sequence([
      _der(0x06, [0x55, 0x1d, 0x11]),
      _der(
        0x04,
        _sequence([
          _der(0x82, ascii.encode('localhost')),
          _der(0x87, [127, 0, 0, 1]),
        ]),
      ),
    ]),
  ]);
  final tbs = _sequence([
    _der(0xa0, _der(0x02, [2])),
    _der(0x02, [1]),
    signatureAlgorithm,
    name,
    _sequence([
      _der(0x17, ascii.encode('200101000000Z')),
      _der(0x17, ascii.encode('400101000000Z')),
    ]),
    name,
    _sequence([
      rsaAlgorithm,
      _der(0x03, [
        0,
        ..._sequence([_integer(key.modulus!), _integer(key.publicExponent!)]),
      ]),
    ]),
    _der(0xa3, extensions),
  ]);
  final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(key));
  final signature = signer.generateSignature(Uint8List.fromList(tbs));
  final certificate = _pem(
    'CERTIFICATE',
    _sequence([
      tbs,
      signatureAlgorithm,
      _der(0x03, [0, ...signature.bytes]),
    ]),
  );
  final privateKey = _pem(
    'RSA PRIVATE KEY',
    _sequence([
      _der(0x02, [0]),
      _integer(key.modulus!),
      _integer(key.publicExponent!),
      _integer(key.privateExponent!),
      _integer(key.p!),
      _integer(key.q!),
      _integer(key.privateExponent! % (key.p! - BigInt.one)),
      _integer(key.privateExponent! % (key.q! - BigInt.one)),
      _integer(key.q!.modInverse(key.p!)),
    ]),
  );
  final server = SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(certificate)
    ..usePrivateKeyBytes(privateKey);
  final client = SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificatesBytes(certificate);
  return (server, client);
}
