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
///
/// Its storage is its own: opening it neither disturbs, nor is disturbed by,
/// whatever else the host application keeps in the same storage engine, and two
/// instances over different [path]s stay separate.
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

  /// The directory this cache's storage lives in, a `tus` subdirectory of
  /// [path] so nothing of the host application's shares it.
  String get _storagePath => p.normalize(p.join(path, 'tus'));

  /// The name the storage is opened under.
  ///
  /// Derived from the path, because storage is opened by name process wide: two
  /// caches over different paths asking for the same name are both handed
  /// whichever was opened first, regardless of the path the second one asked
  /// for. On web there are no paths to tell apart, so the plain name is used.
  String get _boxName => isWeb
      ? 'tus-persistent-cache'
      : 'tus-persistent-cache-${_hashKeyWithSha1(_storagePath)}';

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

  Future<Box<String>> _open() => Hive.openBox<String>(
    _boxName,
    // Given per box, and deliberately not through `Hive.init`, which sets the
    // storage directory for the *whole process*. An application using this
    // package keeps its own data in that storage too, and it opens it when it
    // needs it rather than all at once — so pointing the process at this cache's
    // directory sends everything opened from the first upload onwards to the
    // wrong place, where the data written before it is nowhere to be found.
    path: isWeb ? null : _storagePath,
  );

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
