import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:exvpn_domain/exvpn_domain.dart';
import 'package:flutter/material.dart';

/// Icons are requested only when a lazy row is built. Native reads are bounded
/// independently of scrolling, and disposing a sheet releases its timers/queue.
class ApplicationIconCache {
  ApplicationIconCache(this.bridge);
  final VpnBridge bridge;
  final _cache = <String, Future<Uint8List?>>{};
  final _queue = Queue<({String id, Completer<Uint8List?> result})>();
  final _active = <Completer<Uint8List?>, Timer>{};
  bool _disposed = false;

  Future<Uint8List?> load(String id) {
    if (_disposed || bridge is! ApplicationIconBridge) return Future.value();
    final cached = _cache.remove(id);
    if (cached != null) {
      _cache[id] = cached;
      return cached;
    }
    while (_cache.length >= 128) {
      _cache.remove(_cache.keys.first);
    }
    if (_queue.length >= 96) {
      final old = _queue.removeFirst();
      if (!old.result.isCompleted) old.result.complete();
      _cache.remove(old.id);
    }
    final result = Completer<Uint8List?>();
    _cache[id] = result.future;
    _queue.add((id: id, result: result));
    _drain();
    return result.future;
  }

  void _drain() {
    while (!_disposed && _active.length < 3 && _queue.isNotEmpty) {
      final request = _queue.removeFirst();
      final result = request.result;
      final timer = Timer(const Duration(seconds: 3), () {
        if (!result.isCompleted) result.complete();
      });
      _active[result] = timer;
      unawaited(
        Future<Uint8List?>.sync(
              () => (bridge as ApplicationIconBridge).getApplicationIcon(
                request.id,
              ),
            )
            .then(
              (bytes) {
                if (!result.isCompleted) result.complete(_validIcon(bytes));
              },
              onError: (Object _) {
                if (!result.isCompleted) result.complete();
              },
            )
            .whenComplete(() {
              // A UI timeout is not cancellation of native work. Keep its slot
              // until the real call completes, so slow native reads cannot overlap.
              _active.remove(result)?.cancel();
              while (_cache.length > 128) {
                _cache.remove(_cache.keys.first);
              }
              _drain();
            }),
      );
    }
  }

  Uint8List? _validIcon(Uint8List? bytes) {
    if (bytes == null || bytes.length < 24 || bytes.length > 64 * 1024) {
      return null;
    }
    const png = [137, 80, 78, 71, 13, 10, 26, 10];
    for (var i = 0; i < png.length; i++) {
      if (bytes[i] != png[i]) return null;
    }
    final header = ByteData.sublistView(bytes);
    return header.getUint32(16) == 64 && header.getUint32(20) == 64
        ? bytes
        : null;
  }

  void dispose() {
    _disposed = true;
    for (final request in _queue) {
      if (!request.result.isCompleted) request.result.complete();
    }
    _queue.clear();
    for (final entry in _active.entries.toList()) {
      entry.value.cancel();
      if (!entry.key.isCompleted) entry.key.complete();
    }
    _active.clear();
    _cache.clear();
  }
}

class ApplicationIcon extends StatelessWidget {
  const ApplicationIcon({super.key, required this.icon});
  final Future<Uint8List?> icon;

  @override
  Widget build(BuildContext context) {
    Widget fallback() => Icon(
      Icons.apps_rounded,
      size: 24,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return SizedBox.square(
      dimension: 28,
      child: FutureBuilder<Uint8List?>(
        future: icon,
        builder: (context, snapshot) => snapshot.data == null
            ? fallback()
            : ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(
                  snapshot.data!,
                  width: 28,
                  height: 28,
                  cacheWidth: 64,
                  cacheHeight: 64,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => fallback(),
                ),
              ),
      ),
    );
  }
}
