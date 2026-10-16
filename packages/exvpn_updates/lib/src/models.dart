// SPDX-License-Identifier: Apache-2.0
part of '../exvpn_updates.dart';

enum UpdateError {
  invalidPolicy,
  invalidEnvelope,
  invalidSignature,
  untrustedKey,
  invalidManifest,
  incompatible,
  staleRevision,
  pathDenied,
  tooLarge,
  hashMismatch,
  downloadFailed,
  timeout,
  storageFailure,
  corruptState,
  busy,
  stageUnavailable,
  activationDeferred,
}

final class UpdateException implements Exception {
  const UpdateException(this.code);
  final UpdateError code;
  @override
  String toString() => 'UpdateException(${code.name})';
}

Never _fail(UpdateError code) => throw UpdateException(code);

/// SemVer precedence; build metadata never changes compatibility ordering.
final class AppVersion implements Comparable<AppVersion> {
  AppVersion._(this.major, this.minor, this.patch, this.prerelease, this.text);
  factory AppVersion.parse(String text) {
    final match = RegExp(
      r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
    ).firstMatch(text);
    if (match == null || text.length > 128) _fail(UpdateError.invalidManifest);
    final numbers = [
      for (var i = 1; i <= 3; i++) int.tryParse(match.group(i)!),
    ];
    if (numbers.any((n) => n == null || n > 2147483647)) {
      _fail(UpdateError.invalidManifest);
    }
    final pre = match.group(4)?.split('.') ?? <String>[];
    for (final item in pre) {
      if (RegExp(r'^[0-9]+$').hasMatch(item) &&
          item.length > 1 &&
          item.startsWith('0')) {
        _fail(UpdateError.invalidManifest);
      }
    }
    return AppVersion._(
      numbers[0]!,
      numbers[1]!,
      numbers[2]!,
      List.unmodifiable(pre),
      text,
    );
  }
  final int major, minor, patch;
  final List<String> prerelease;
  final String text;
  @override
  int compareTo(AppVersion other) {
    for (final pair in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      final c = pair.$1.compareTo(pair.$2);
      if (c != 0) return c;
    }
    if (prerelease.isEmpty || other.prerelease.isEmpty) {
      return prerelease.isEmpty ? (other.prerelease.isEmpty ? 0 : 1) : -1;
    }
    for (var i = 0; i < min(prerelease.length, other.prerelease.length); i++) {
      final a = prerelease[i], b = other.prerelease[i];
      final numericA = RegExp(r'^[0-9]+$').hasMatch(a),
          numericB = RegExp(r'^[0-9]+$').hasMatch(b);
      final comparison = numericA && numericB
          ? (a.length != b.length
                ? a.length.compareTo(b.length)
                : a.compareTo(b))
          : numericA != numericB
          ? (numericA ? -1 : 1)
          : a.compareTo(b);
      if (comparison != 0) return comparison;
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }
}

enum UpdateChannel { beta, stable }

final class UpdateContext {
  UpdateContext({
    required String appVersion,
    required this.build,
    required this.channel,
  }) : appVersion = AppVersion.parse(appVersion) {
    if (build < 1 || build > _maxInteger) _fail(UpdateError.invalidPolicy);
  }
  final AppVersion appVersion;
  final int build;
  final UpdateChannel channel;
}

const _maxInteger = 9007199254740991;

final class UpdateLimits {
  const UpdateLimits({
    this.manifestBytes = 128 * 1024,
    this.envelopeBytes = 192 * 1024,
    this.maxFiles = 64,
    this.fileBytes = 4 * 1024 * 1024,
    this.bundleBytes = 32 * 1024 * 1024,
    this.requestTimeout = const Duration(seconds: 20),
    this.downloadBudget = const Duration(minutes: 2),
  });
  final int manifestBytes, envelopeBytes, maxFiles, fileBytes, bundleBytes;
  final Duration requestTimeout, downloadBudget;
}

/// Constructed by the application, never from a subscription or manifest.
/// File URLs are content-addressed beneath filesBaseUri: `<sha256>`.
final class TrustedUpdatePolicy {
  TrustedUpdatePolicy({
    required this.manifestUri,
    required this.filesBaseUri,
    required Map<String, List<int>> publicKeys,
    required Map<String, int> resourceLimits,
    Set<String> requiredPaths = const {},
    this.limits = const UpdateLimits(),
  }) : publicKeys = Map.unmodifiable({
         for (final e in publicKeys.entries)
           e.key: List<int>.unmodifiable(e.value),
       }),
       resourceLimits = Map.unmodifiable(resourceLimits),
       requiredPaths = Set.unmodifiable(requiredPaths) {
    if (!_secureUri(manifestUri) ||
        !_secureUri(filesBaseUri) ||
        !filesBaseUri.path.endsWith('/') ||
        publicKeys.isEmpty ||
        publicKeys.length > 8 ||
        resourceLimits.isEmpty ||
        resourceLimits.length > 64 ||
        limits.manifestBytes < 1 ||
        limits.manifestBytes > 128 * 1024 ||
        limits.envelopeBytes < 1 ||
        limits.envelopeBytes > 192 * 1024 ||
        limits.maxFiles < 1 ||
        limits.maxFiles > 64 ||
        limits.fileBytes < 1 ||
        limits.fileBytes > 16 * 1024 * 1024 ||
        limits.bundleBytes < 1 ||
        limits.bundleBytes > 128 * 1024 * 1024 ||
        limits.requestTimeout <= Duration.zero ||
        limits.requestTimeout > const Duration(minutes: 1) ||
        limits.downloadBudget <= Duration.zero ||
        limits.downloadBudget > const Duration(minutes: 5)) {
      _fail(UpdateError.invalidPolicy);
    }
    for (final e in this.publicKeys.entries) {
      if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(e.key) ||
          e.value.length != 32 ||
          e.value.any((b) => b < 0 || b > 255)) {
        _fail(UpdateError.invalidPolicy);
      }
    }
    for (final e in this.resourceLimits.entries) {
      if (!_safeResourcePath(e.key) ||
          e.value < 0 ||
          e.value > limits.fileBytes) {
        _fail(UpdateError.invalidPolicy);
      }
    }
    if (!this.resourceLimits.keys.toSet().containsAll(requiredPaths)) {
      _fail(UpdateError.invalidPolicy);
    }
  }
  final Uri manifestUri, filesBaseUri;
  final Map<String, List<int>> publicKeys;
  final Map<String, int> resourceLimits;
  final Set<String> requiredPaths;
  final UpdateLimits limits;
}

bool _secureUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty &&
    !uri.hasFragment &&
    !uri.hasQuery;

bool _safeResourcePath(String path) {
  if (path.length > 160 ||
      !RegExp(
        r'^[a-z0-9_-]+(?:/[a-z0-9_-]+)*\.(json|txt|png|webp|dat)$',
      ).hasMatch(path)) {
    return false;
  }
  final segments = path.split('/');
  if (segments.length > 8) return false;
  return !segments.any(
    (s) => RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)').hasMatch(s),
  );
}

final class ResourceFile {
  ResourceFile._(this.path, this.size, this.sha256);
  final String path, sha256;
  final int size;
}

final class VerifiedManifest {
  VerifiedManifest._({
    required this.revision,
    required this.channel,
    required this.minVersion,
    required this.maxVersionExclusive,
    required this.minBuild,
    required this.maxBuild,
    required this.files,
    required this.envelope,
    required this.sha256,
    this.rollbackOf,
  });
  final int revision, minBuild, maxBuild;
  final int? rollbackOf;
  final UpdateChannel channel;
  final AppVersion minVersion, maxVersionExclusive;
  final List<ResourceFile> files;
  final List<int> envelope;
  final String sha256;
  bool supports(UpdateContext context) =>
      channel == context.channel &&
      context.appVersion.compareTo(minVersion) >= 0 &&
      context.appVersion.compareTo(maxVersionExclusive) < 0 &&
      context.build >= minBuild &&
      context.build <= maxBuild;
}
