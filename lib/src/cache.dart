import 'dart:convert' show utf8;

import 'package:tusc/src/utils/platform_utils.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';

/// Implementations of this interface are used to lookup a
/// [fingerprint] with the corresponding [url].
///
/// This functionality is used to allow resuming uploads.
///
/// See [TusMemoryCache] or [TusPersistentCache]
abstract class TusCache {
  /// Cache a new [fingerprint] and its upload [url].
  Future<void> set(String fingerprint, String url);

  /// Retrieves an upload URL for a [fingerprint].
  /// If no matching entry is found this method will return `null`.
  Future<String?> get(String fingerprint);

  /// Remove an entry from the cache using an upload's [fingerprint].
  Future<void> remove(String fingerprint);

  /// Clears the cache
  Future<void> clear();
}

/// This class is used to cache upload url in memory and to resume upload later.
///
/// This cache **will not** keep the values after your application crashes or
/// restarts.
class TusMemoryCache implements TusCache {
  final _cache = <String, String>{};

  @override
  Future<void> set(String fingerprint, String url) async {
    final hashedFingerprint = _hashKeyWithSha1(fingerprint);
    _cache[hashedFingerprint] = url;
  }

  @override
  Future<String?> get(String fingerprint) async {
    final hashedFingerprint = _hashKeyWithSha1(fingerprint);
    return _cache[hashedFingerprint];
  }

  @override
  Future<void> remove(String fingerprint) async {
    final hashedFingerprint = _hashKeyWithSha1(fingerprint);
    _cache.remove(hashedFingerprint);
  }

  @override
  Future<void> clear() {
    _cache.clear();
    return Future.value();
  }
}

/// This class is used to cache upload url in a persistent way to resume upload
/// later.
///
/// This cache **will** keep the values after your application crashes or
/// restarts.
/// Note the underlying storage is initialized globally, so several instances
/// pointing at different [path]s in the same process end up sharing the storage
/// of whichever one was opened first.
class TusPersistentCache implements TusCache {
  /// Where the cache storage is kept. Ignored on web, where the platform
  /// handles storage itself.
  final String path;

  /// The pending or finished box opening.
  ///
  /// Memoized so concurrent callers share a single open. Opening it per call
  /// instead lets two callers both find the box closed and open it twice.
  Future<Box<String>>? _boxFuture;

  TusPersistentCache(this.path);

  Future<Box<String>> _openBox() async {
    final pendingBox = _boxFuture ??= _open();
    try {
      return await pendingBox;
    } catch (_) {
      // A failed open is not remembered, so a later call gets to try again.
      if (identical(_boxFuture, pendingBox)) _boxFuture = null;
      rethrow;
    }
  }

  Future<Box<String>> _open() async {
    if (!isWeb) Hive.init(p.join(path, 'tus'));
    return Hive.openBox<String>('tus-persistent-cache');
  }

  /// Cache a new [fingerprint] and its upload [url].
  @override
  Future<void> set(String fingerprint, String url) async {
    final box = await _openBox();
    // Awaited so the entry is on disk when this completes. Without it a crash
    // right after an upload starts can lose the very mapping that would have
    // let the upload be resumed.
    await box.put(_hashKeyWithSha1(fingerprint), url);
  }

  /// Retrieve an upload URL for a [fingerprint].
  /// If no matching entry is found this method will return `null`.
  @override
  Future<String?> get(String fingerprint) async {
    final box = await _openBox();
    return box.get(_hashKeyWithSha1(fingerprint));
  }

  /// Remove an entry from the cache using an upload [fingerprint].
  @override
  Future<void> remove(String fingerprint) async {
    final box = await _openBox();
    await box.delete(_hashKeyWithSha1(fingerprint));
  }

  @override
  Future<void> clear() async {
    final box = await _openBox();
    await box.clear();
  }
}

// 40 chars output
String _hashKeyWithSha1(String fingerprint) =>
    sha1.convert(utf8.encode(fingerprint)).toString();
