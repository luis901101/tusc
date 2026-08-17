@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tusc/src/utils/http_status.dart';
import 'package:tusc/src/utils/platform_utils.dart';
import 'package:tusc/tusc.dart';

/// Runs in a real browser, with `dart test --platform chrome`.
///
/// Nothing here may touch `dart:io`, which is the point: it is the guard that
/// the package still works when compiled for the web.
void main() {
  const createEndpoint = 'https://tus.example.com/files';
  const fileSize = 8192;
  const chunkSize = 1024;

  final fileBytes = Uint8List.fromList(
    List.generate(fileSize, (index) => index % 251),
  );

  http.Client buildServer() {
    final uploads = <String, BytesBuilder>{};
    final lengths = <String, int>{};
    var nextId = 0;
    return MockClient((request) async {
      final target = request.url.toString();
      if (request.method == 'POST') {
        final created = '$createEndpoint/upload-${nextId++}';
        uploads[created] = BytesBuilder();
        lengths[created] = int.parse(
          request.headers[Headers.uploadLengthHeader]!,
        );
        return http.Response(
          '',
          HttpStatus.created,
          headers: {Headers.location: created},
        );
      }
      final upload = uploads[target];
      if (upload == null) return http.Response('', HttpStatus.notFound);
      if (request.method == 'HEAD') {
        return http.Response(
          '',
          HttpStatus.ok,
          headers: {
            Headers.uploadOffsetHeader: '${upload.length}',
            Headers.uploadLengthHeader: '${lengths[target]}',
          },
        );
      }
      upload.add(request.bodyBytes);
      return http.Response(
        '',
        HttpStatus.noContent,
        headers: {Headers.uploadOffsetHeader: '${upload.length}'},
      );
    });
  }

  test('the web implementation of the platform check is the one selected', () {
    expect(
      isWeb,
      isTrue,
      reason:
          'a browser must not end up on the native code path, whichever '
          'web compiler was used',
    );
  });

  test('an upload from an in memory file runs to completion', () async {
    final client = TusStreamClient(
      url: createEndpoint,
      fileStreamGenerator: () => Stream.value(fileBytes),
      fileSize: fileSize,
      fileName: 'video-test.mp4',
      chunkSize: chunkSize,
      progressSliceSize: 256,
      cache: TusMemoryCache(),
      retryDelays: const [],
      httpClient: buildServer(),
    );

    final progress = <int>[];
    await client.startUpload(
      onProgress: (count, total, response) => progress.add(count),
    );

    expect(client.state, TusUploadState.completed);
    expect(progress.last, fileSize);
    expect(
      progress.length,
      greaterThan(fileSize ~/ chunkSize),
      reason:
          'the sliced body has to report more often than once per chunk, '
          'even where the body is buffered before it is sent',
    );
  });

  test('XFile backed uploads work in the browser', () async {
    final client = TusClient(
      url: createEndpoint,
      file: XFile.fromData(fileBytes, name: 'video-test.mp4'),
      chunkSize: chunkSize,
      cache: TusMemoryCache(),
      retryDelays: const [],
      httpClient: buildServer(),
    );

    await client.startUpload();

    expect(client.state, TusUploadState.completed);
    expect(client.offset, fileSize);
  });

  test('resuming from cache works with a fresh client', () async {
    final cache = TusMemoryCache();
    final server = buildServer();

    TusStreamClient build() => TusStreamClient(
      url: createEndpoint,
      fileStreamGenerator: () => Stream.value(fileBytes),
      fileSize: fileSize,
      fileName: 'video-test.mp4',
      chunkSize: chunkSize,
      cache: cache,
      retryDelays: const [],
      httpClient: server,
    );

    final first = build();
    await first.startUpload();
    expect(first.state, TusUploadState.completed);

    // Completing clears the entry, so a second run starts a new upload and
    // must still finish cleanly.
    final second = build();
    await second.startUpload();
    expect(second.state, TusUploadState.completed);
    expect(second.uploadUrl, isNot(first.uploadUrl));
  });

  group('TusPersistentCache', () {
    // The path is meaningless in a browser, where storage is handled by the
    // platform, so it is only there to satisfy the constructor.
    tearDown(() => TusPersistentCache('').clear());

    test('works over the browser storage', () async {
      final cache = TusPersistentCache('');

      await cache.set('fingerprint', 'https://example.com/files/abc');
      expect(await cache.get('fingerprint'), 'https://example.com/files/abc');

      await cache.remove('fingerprint');
      expect(await cache.get('fingerprint'), isNull);
    });

    test('a write is readable through another instance', () async {
      await TusPersistentCache('').set('fingerprint', 'https://example.com/x');

      expect(
        await TusPersistentCache('').get('fingerprint'),
        'https://example.com/x',
        reason:
            'a browser has no paths to tell caches apart, so they all '
            'share the one storage',
      );
    });

    test('concurrent access opens the storage once', () async {
      final cache = TusPersistentCache('');

      await expectLater(
        Future.wait([
          cache.set('a', 'url-a'),
          cache.get('a'),
          cache.set('b', 'url-b'),
          cache.get('b'),
        ]),
        completes,
      );
      expect(await cache.get('a'), 'url-a');
    });

    test('resuming an upload across client instances works', () async {
      final cache = TusPersistentCache('');
      final server = buildServer();
      var created = 0;

      TusStreamClient build() => TusStreamClient(
        url: createEndpoint,
        fileStreamGenerator: () => Stream.value(fileBytes),
        fileSize: fileSize,
        fileName: 'video-test.mp4',
        chunkSize: chunkSize,
        cache: cache,
        retryDelays: const [],
        httpClient: server,
      );

      final first = build();
      await first.startUpload();
      created++;

      final second = build();
      await second.startUpload();
      created++;

      expect(created, 2);
      expect(second.state, TusUploadState.completed);
    });
  });

  test('close does not throw on the browser client', () {
    final client = TusClient(
      url: createEndpoint,
      file: XFile.fromData(fileBytes, name: 'x'),
    );
    expect(client.close, returnsNormally);
  });
}
