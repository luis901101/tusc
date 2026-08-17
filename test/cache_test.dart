@TestOn('vm')
library;

import 'dart:io';

import 'package:hive_ce/hive.dart';
import 'package:test/test.dart';
import 'package:tusc/tusc.dart';

/// Tests for [TusPersistentCache] keeping to its own storage, and not standing
/// on the toes of the application that hosts it.
void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('tusc_cache_test'));

  tearDown(() async {
    await Hive.close();
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort, an open box can keep files locked.
    }
  });

  test('two caches over different paths stay separate', () async {
    final first = TusPersistentCache('${tempDir.path}/one');
    final second = TusPersistentCache('${tempDir.path}/two');

    await first.set('fingerprint', 'https://example.com/first');
    await second.set('fingerprint', 'https://example.com/second');

    expect(
      await first.get('fingerprint'),
      'https://example.com/first',
      reason:
          'storage is opened by name process wide, so two caches asking '
          'for the same name would both be handed whichever opened first',
    );
    expect(await second.get('fingerprint'), 'https://example.com/second');
  });

  test('each cache writes under its own path', () async {
    final cache = TusPersistentCache('${tempDir.path}/one');
    await cache.set('fingerprint', 'https://example.com/x');

    final storageDir = Directory('${tempDir.path}/one/tus');
    expect(storageDir.existsSync(), isTrue);
    expect(
      storageDir.listSync().whereType<File>().map(
        (file) => file.path.endsWith('.hive'),
      ),
      contains(isTrue),
      reason: 'the cache has to keep its storage under the path it was given',
    );
  });

  test('the host application keeps its own storage directory', () async {
    // An application that uses this package has its own Hive data, and opens
    // it when it needs it rather than all at once.
    final hostPath = '${tempDir.path}/host';
    Directory(hostPath).createSync(recursive: true);
    Hive.init(hostPath);

    final beforeUpload = await Hive.openBox<String>('host-data');
    await beforeUpload.put('key', 'value');

    // An upload happens, which opens the tus cache.
    final cache = TusPersistentCache('${tempDir.path}/uploads');
    await cache.set('fingerprint', 'https://example.com/x');

    // The application carries on and opens another box, without a path of its
    // own, exactly as it did before the upload.
    final afterUpload = await Hive.openBox<String>('host-later');
    await afterUpload.put('key', 'value');

    expect(
      File('$hostPath/host-later.hive').existsSync(),
      isTrue,
      reason:
          'opening the tus cache must not move where the application that '
          'hosts it keeps its data',
    );
    expect(
      Directory('${tempDir.path}/uploads/tus')
          .listSync()
          .whereType<File>()
          .map((file) => file.uri.pathSegments.last)
          .where((name) => name.startsWith('host-')),
      isEmpty,
      reason: "the application's boxes must not end up in the cache directory",
    );
    expect(beforeUpload.get('key'), 'value');
  });

  test('a value survives a fresh cache instance over the same path', () async {
    final writer = TusPersistentCache(tempDir.path);
    await writer.set('fingerprint', 'https://example.com/x');

    final reader = TusPersistentCache(tempDir.path);
    expect(await reader.get('fingerprint'), 'https://example.com/x');

    await reader.remove('fingerprint');
    expect(await TusPersistentCache(tempDir.path).get('fingerprint'), isNull);
  });

  test('concurrent access opens the storage once', () async {
    final cache = TusPersistentCache(tempDir.path);

    await expectLater(
      Future.wait([
        cache.set('a', 'url-a'),
        cache.get('a'),
        cache.set('b', 'url-b'),
        cache.get('b'),
        cache.clear(),
      ]),
      completes,
    );
  });

  test('clear empties only this cache', () async {
    final first = TusPersistentCache('${tempDir.path}/one');
    final second = TusPersistentCache('${tempDir.path}/two');
    await first.set('fingerprint', 'https://example.com/first');
    await second.set('fingerprint', 'https://example.com/second');

    await first.clear();

    expect(await first.get('fingerprint'), isNull);
    expect(await second.get('fingerprint'), 'https://example.com/second');
  });
}
