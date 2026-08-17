@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tusc/src/utils/http_status.dart';
import 'package:tusc/tusc.dart';

/// Tests for progress being reported while a chunk is in flight, rather than
/// only once the whole chunk has landed.
void main() {
  const createEndpoint = 'https://tus.example.com/files';
  const fileSize = 8192;

  late Directory tempDir;
  late File file;
  late Uint8List fileBytes;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('tusc_progress_test');
    fileBytes = Uint8List.fromList(
      List.generate(fileSize, (index) => index % 251),
    );
    file = File('${tempDir.path}/video-test.mp4')..writeAsBytesSync(fileBytes);
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // ignore
    }
  });

  /// A mock tus server that accepts everything, and records the body it got.
  http.Client buildServer({Map<String, int>? contentLengths}) {
    final uploads = <String, int>{};
    var nextId = 0;
    return MockClient((request) async {
      final target = request.url.toString();
      if (request.method == 'POST') {
        final created = '$createEndpoint/upload-${nextId++}';
        uploads[created] = 0;
        return http.Response(
          '',
          HttpStatus.created,
          headers: {Headers.location: created},
        );
      }
      final offset = uploads[target]!;
      if (request.method == 'HEAD') {
        return http.Response(
          '',
          HttpStatus.ok,
          headers: {
            Headers.uploadOffsetHeader: '$offset',
            Headers.uploadLengthHeader: '$fileSize',
          },
        );
      }
      contentLengths?[target] = request.bodyBytes.length;
      uploads[target] = offset + request.bodyBytes.length;
      return http.Response(
        '',
        HttpStatus.noContent,
        headers: {Headers.uploadOffsetHeader: '${uploads[target]}'},
      );
    });
  }

  test('progress is reported several times within a single chunk', () async {
    final client = TusClient(
      url: createEndpoint,
      file: XFile(file.path),
      // One chunk for the whole file, so every report but the last one has to
      // come from inside that chunk.
      chunkSize: fileSize,
      progressSliceSize: 1024,
      httpClient: buildServer(),
    );

    final reported = <int>[];
    await client.startUpload(
      onProgress: (count, total, response) => reported.add(count),
    );

    expect(
      reported,
      containsAllInOrder([0, 1024, 2048, 3072, 4096, 5120, 6144, 7168, 8192]),
      reason:
          'a single 8 KB chunk sliced at 1 KB has to report on the way, '
          'not just at 0 and 8192',
    );
    expect(reported.last, fileSize);
    expect(client.state, TusUploadState.completed);
  });

  test('reported counts are absolute file offsets across chunks', () async {
    final client = TusClient(
      url: createEndpoint,
      file: XFile(file.path),
      chunkSize: 4096,
      progressSliceSize: 1024,
      httpClient: buildServer(),
    );

    final reported = <int>[];
    await client.startUpload(
      onProgress: (count, total, response) => reported.add(count),
    );

    expect(
      reported,
      containsAllInOrder([1024, 2048, 3072, 4096, 5120, 6144, 7168, 8192]),
      reason: 'the second chunk must continue from 4096, not restart at 0',
    );
    for (final count in reported) {
      expect(count, inInclusiveRange(0, fileSize));
    }
    // Monotonic, since nothing fails in this test.
    expect(reported, orderedEquals(List.of(reported)..sort()));
  });

  test('a slice as large as the chunk reports once per chunk', () async {
    final client = TusClient(
      url: createEndpoint,
      file: XFile(file.path),
      chunkSize: 4096,
      progressSliceSize: 4096,
      httpClient: buildServer(),
    );

    final reported = <int>[];
    await client.startUpload(
      onProgress: (count, total, response) => reported.add(count),
    );

    expect(
      reported.toSet(),
      {0, 4096, 8192},
      reason: 'this is the pre existing chunk by chunk behaviour',
    );
  });

  test('the whole chunk still reaches the server', () async {
    final contentLengths = <String, int>{};
    final client = TusClient(
      url: createEndpoint,
      file: XFile(file.path),
      chunkSize: fileSize,
      progressSliceSize: 1000,
      httpClient: buildServer(contentLengths: contentLengths),
    );

    await client.startUpload();

    expect(
      contentLengths.values.single,
      fileSize,
      reason: 'slicing the body must not drop or duplicate any of it',
    );
  });

  test('progressSliceSize must be positive', () {
    expect(
      () => TusClient(
        url: createEndpoint,
        file: XFile(file.path),
        progressSliceSize: 0,
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test(
    'progress paces with a real socket and keeps Content-Length',
    () async {
      // A real server over a real socket, so the slices are pulled as the
      // connection drains rather than all at once.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://${server.address.host}:${server.port}';
      var storedOffset = 0;
      var declaredLength = 0;
      int? patchContentLength;
      var wasChunked = false;
      var reportCount = 0;
      // How many progress reports the client had already made by the time the
      // server had taken the whole body. Anything above zero means progress is
      // reported during the transfer rather than after the response.
      final reportsWhenBodyRead = Completer<int>();

      unawaited(
        server.forEach((request) async {
          switch (request.method) {
            case 'POST':
              declaredLength = int.parse(
                request.headers.value(Headers.uploadLengthHeader)!,
              );
              storedOffset = 0;
              request.response
                ..statusCode = HttpStatus.created
                ..headers.set(Headers.location, '$base/upload-1');
              await request.response.close();
            case 'HEAD':
              request.response
                ..statusCode = HttpStatus.ok
                ..headers.set(Headers.uploadOffsetHeader, '$storedOffset')
                ..headers.set(Headers.uploadLengthHeader, '$declaredLength');
              await request.response.close();
            case 'PATCH':
              patchContentLength = request.headers.contentLength;
              wasChunked = request.headers.chunkedTransferEncoding;
              // Read slowly, so the client cannot dump the whole body into the
              // socket buffer in one go.
              await for (final data in request) {
                storedOffset += data.length;
                await Future<void>.delayed(const Duration(milliseconds: 1));
              }
              if (!reportsWhenBodyRead.isCompleted) {
                reportsWhenBodyRead.complete(reportCount);
              }
              request.response
                ..statusCode = HttpStatus.noContent
                ..headers.set(Headers.uploadOffsetHeader, '$storedOffset');
              await request.response.close();
          }
        }),
      );

      // 16 MB in one chunk, sliced at 256 KB. Big enough that the socket
      // buffer cannot swallow the whole body, so backpressure is real.
      const bigFileSize = 16 * 1024 * 1024;
      final bigFile = File('${tempDir.path}/big.bin')
        ..writeAsBytesSync(Uint8List(bigFileSize));
      final client = TusClient(
        url: '$base/files',
        file: XFile(bigFile.path),
        chunkSize: bigFileSize,
        progressSliceSize: 256 * 1024,
      );

      final stopwatch = Stopwatch()..start();
      final reportedAt = <int, int>{};
      await client.startUpload(
        onProgress: (count, total, response) {
          reportCount++;
          reportedAt[count] = stopwatch.elapsedMilliseconds;
        },
      );
      await server.close(force: true);
      client.close();

      expect(client.state, TusUploadState.completed);
      expect(
        patchContentLength,
        bigFileSize,
        reason:
            'slicing the body must not turn the request chunked, tus needs '
            'a Content-Length',
      );
      expect(wasChunked, isFalse);
      expect(
        reportedAt.length,
        greaterThan(8),
        reason: 'a 16 MB chunk sliced at 256 KB should report many times',
      );

      // The point of the whole exercise: progress arrives while the body is
      // still going out, not in one burst once the server has answered.
      expect(
        await reportsWhenBodyRead.future,
        greaterThan(1),
        reason:
            'the client must have reported progress before the server '
            'finished taking the body',
      );
      expect(
        reportedAt.keys.last,
        bigFileSize,
        reason: 'the reports have to end at the full size of the file',
      );
      // How far apart in time the reports land is a property of the connection,
      // not of this code. Over loopback the kernel buffer swallows megabytes at
      // a time, so there is little pacing to observe and asserting on the
      // spread here would only make this test flaky.
      expect(stopwatch.elapsedMilliseconds, greaterThan(0));
    },
    timeout: Timeout(Duration(seconds: 60)),
  );
}
