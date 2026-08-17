import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tusc/src/utils/http_status.dart';
import 'package:tusc/tusc.dart';

/// Hermetic tests for resuming uploads. No tus server and no fixture files are
/// needed, everything runs against [_FakeTusServer] over a [MockClient].
void main() {
  const createEndpoint = 'https://tus.example.com/files';
  const fileSize = 10240;
  const chunkSize = 1024;

  late Directory tempDir;
  late File file;
  late Uint8List fileBytes;
  late _FakeTusServer server;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('tusc_resume_test');
    fileBytes = Uint8List.fromList(
      List.generate(fileSize, (index) => index % 251),
    );
    file = File('${tempDir.path}/video-test.mp4')..writeAsBytesSync(fileBytes);
    server = _FakeTusServer(createEndpoint: createEndpoint);
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort cleanup, an open Hive box can keep files locked.
    }
  });

  /// Retries are off unless a test asks for them, so the tests that fail on
  /// purpose fail straight away instead of waiting out the default delays.
  TusClient buildClient({
    TusCache? cache,
    String? url,
    String? uploadUrl,
    List<Duration> retryDelays = const [],
  }) => TusClient(
    url: url,
    uploadUrl: uploadUrl,
    file: XFile(file.path),
    chunkSize: chunkSize,
    cache: cache,
    retryDelays: retryDelays,
    httpClient: server.client,
  );

  /// Runs an upload that dies after [failAfterBytes] bytes have landed on the
  /// server, standing in for a crashed or killed process, and returns the
  /// upload URL that was left behind half uploaded.
  Future<String> uploadUntilItDies(
    TusBaseClient client, {
    required int failAfterBytes,
  }) async {
    server.failAfterBytes = failAfterBytes;
    await expectLater(client.startUpload(), throwsA(isA<ProtocolException>()));
    server.failAfterBytes = null;
    expect(server.offsetOf(client.uploadUrl), failAfterBytes);
    return client.uploadUrl;
  }

  group('Resuming from cache with a new client instance', () {
    test('TusClient resumes an upload cached by a previous instance', () async {
      final cache = TusMemoryCache();

      // First instance, dies with 3 KB already on the server.
      final firstClient = buildClient(cache: cache, url: createEndpoint);
      final uploadUrl = await uploadUntilItDies(
        firstClient,
        failAfterBytes: 3 * chunkSize,
      );

      // Second instance. It knows nothing but the file, the endpoint and the
      // cache, exactly like a fresh process would.
      final secondClient = buildClient(cache: cache, url: createEndpoint);
      expect(secondClient.uploadUrl, isEmpty);

      final progress = <int>[];
      await secondClient.startUpload(
        onProgress: (count, total, response) => progress.add(count),
      );

      expect(
        server.createCount,
        1,
        reason:
            'the second instance must reuse the cached upload, not '
            'create a new one on the server',
      );
      expect(secondClient.uploadUrl, uploadUrl);
      expect(secondClient.fingerprint, firstClient.fingerprint);
      expect(
        progress.first,
        3 * chunkSize,
        reason: 'the upload must pick up where the previous instance left off',
      );
      expect(secondClient.state, TusUploadState.completed);
      expect(server.bytesOf(uploadUrl), fileBytes);
      expect(
        await cache.get(secondClient.fingerprint),
        isNull,
        reason: 'a completed upload must not stay in the cache',
      );
    });

    test(
      'TusStreamClient resumes an upload cached by a previous instance',
      () async {
        final cache = TusMemoryCache();

        TusStreamClient buildStreamClient() => TusStreamClient(
          url: createEndpoint,
          fileStreamGenerator: () => file.openRead(),
          fileSize: fileSize,
          fileName: 'video-test.mp4',
          chunkSize: chunkSize,
          cache: cache,
          retryDelays: const [],
          httpClient: server.client,
        );

        final uploadUrl = await uploadUntilItDies(
          buildStreamClient(),
          failAfterBytes: 3 * chunkSize,
        );

        final secondClient = buildStreamClient();
        await secondClient.startUpload();

        expect(server.createCount, 1);
        expect(secondClient.uploadUrl, uploadUrl);
        expect(secondClient.state, TusUploadState.completed);
        expect(
          server.bytesOf(uploadUrl),
          fileBytes,
          reason:
              'the resumed stream must seek to the server offset and send '
              'the bytes that actually follow it',
        );
      },
    );

    test(
      'TusPersistentCache survives across independent cache instances',
      () async {
        final firstClient = buildClient(
          cache: TusPersistentCache(tempDir.path),
          url: createEndpoint,
        );
        final uploadUrl = await uploadUntilItDies(
          firstClient,
          failAfterBytes: 4 * chunkSize,
        );

        // A brand new cache object over the same storage, which is what a
        // restarted process gets.
        final secondCache = TusPersistentCache(tempDir.path);
        final secondClient = buildClient(
          cache: secondCache,
          url: createEndpoint,
        );
        await secondClient.startUpload();

        expect(server.createCount, 1);
        expect(secondClient.uploadUrl, uploadUrl);
        expect(server.bytesOf(uploadUrl), fileBytes);
        await secondCache.clear();
      },
    );

    test('without a cache every instance starts a new upload', () async {
      final firstClient = buildClient(url: createEndpoint);
      await uploadUntilItDies(firstClient, failAfterBytes: 3 * chunkSize);

      final secondClient = buildClient(url: createEndpoint);
      await secondClient.startUpload();

      expect(server.createCount, 2);
      expect(secondClient.uploadUrl, isNot(firstClient.uploadUrl));
    });
  });

  group('Stale upload URL', () {
    for (final statusCode in [
      HttpStatus.forbidden,
      HttpStatus.notFound,
      HttpStatus.gone,
    ]) {
      test(
        'a cached URL answering $statusCode is evicted and recreated',
        () async {
          final cache = TusMemoryCache();

          final firstClient = buildClient(cache: cache, url: createEndpoint);
          final staleUploadUrl = await uploadUntilItDies(
            firstClient,
            failAfterBytes: 3 * chunkSize,
          );
          final fingerprint = firstClient.fingerprint;
          expect(await cache.get(fingerprint), staleUploadUrl);

          // The server sweeps the half finished upload.
          server.sweep(staleUploadUrl, statusCode: statusCode);

          final requestsBeforeResume = server.requestLog.length;
          final secondClient = buildClient(cache: cache, url: createEndpoint);
          final progress = <int>[];
          await secondClient.startUpload(
            onProgress: (count, total, response) => progress.add(count),
          );

          expect(
            server.requestLog.skip(requestsBeforeResume),
            contains('HEAD $staleUploadUrl'),
            reason:
                'the cached upload URL must be picked up and probed before '
                'it can be found stale',
          );
          expect(
            secondClient.state,
            TusUploadState.completed,
            reason:
                'a swept upload URL must fall back to creating a new '
                'upload instead of failing the whole upload',
          );
          expect(server.createCount, 2);
          expect(secondClient.uploadUrl, isNot(staleUploadUrl));
          expect(progress.first, 0);
          expect(server.bytesOf(secondClient.uploadUrl), fileBytes);
          expect(await cache.get(fingerprint), isNull);
        },
      );
    }

    test('a caller supplied uploadUrl is never silently swapped', () async {
      final firstClient = buildClient(url: createEndpoint);
      final staleUploadUrl = await uploadUntilItDies(
        firstClient,
        failAfterBytes: 3 * chunkSize,
      );
      server.sweep(staleUploadUrl);

      // Built from the upload URL alone, so there is no endpoint to POST to
      // and no upload other than the requested one may be used.
      final secondClient = buildClient(
        cache: TusMemoryCache(),
        uploadUrl: staleUploadUrl,
      );
      await expectLater(
        secondClient.startUpload(),
        throwsA(isA<ProtocolException>()),
      );

      expect(server.createCount, 1);
    });

    test(
      'a dead mapping is evicted even when it cannot be recreated',
      () async {
        final cache = TusMemoryCache();

        _StableFingerprintClient buildStableClient({
          String? url,
          String? uploadUrl,
        }) => _StableFingerprintClient(
          url: url,
          uploadUrl: uploadUrl,
          file: XFile(file.path),
          chunkSize: chunkSize,
          cache: cache,
          retryDelays: const [],
          httpClient: server.client,
        );

        final firstClient = buildStableClient(url: createEndpoint);
        final staleUploadUrl = await uploadUntilItDies(
          firstClient,
          failAfterBytes: 3 * chunkSize,
        );
        final fingerprint = firstClient.fingerprint;
        expect(await cache.get(fingerprint), staleUploadUrl);
        server.sweep(staleUploadUrl);

        // Same fingerprint, but no endpoint to create a replacement upload at.
        final secondClient = buildStableClient(uploadUrl: staleUploadUrl);
        await expectLater(
          secondClient.startUpload(),
          throwsA(isA<ProtocolException>()),
        );

        expect(server.createCount, 1);
        expect(
          await cache.get(fingerprint),
          isNull,
          reason:
              'a mapping the server has proven dead must not survive, even '
              'when this client cannot create a replacement upload',
        );
      },
    );

    test('a non stale error is not swallowed', () async {
      final cache = TusMemoryCache();

      final firstClient = buildClient(cache: cache, url: createEndpoint);
      final uploadUrl = await uploadUntilItDies(
        firstClient,
        failAfterBytes: 3 * chunkSize,
      );
      server.sweep(uploadUrl, statusCode: HttpStatus.locked);

      final secondClient = buildClient(cache: cache, url: createEndpoint);
      await expectLater(
        secondClient.startUpload(),
        throwsA(isA<ProtocolException>()),
      );

      expect(server.createCount, 1);
      expect(
        await cache.get(secondClient.fingerprint),
        uploadUrl,
        reason: 'a locked upload is still there, so its mapping must be kept',
      );
    });
  });

  group('Resuming with an explicit uploadUrl', () {
    test('resumes without creating a new upload', () async {
      final firstClient = buildClient(url: createEndpoint);
      final uploadUrl = await uploadUntilItDies(
        firstClient,
        failAfterBytes: 6 * chunkSize,
      );

      final requestsBeforeResume = server.requestLog.length;
      final secondClient = buildClient(uploadUrl: uploadUrl);
      final progress = <int>[];
      await secondClient.startUpload(
        onProgress: (count, total, response) => progress.add(count),
      );

      expect(server.createCount, 1);
      expect(progress.first, 6 * chunkSize);
      expect(secondClient.state, TusUploadState.completed);
      expect(server.bytesOf(uploadUrl), fileBytes);
      expect(
        server.requestLog
            .skip(requestsBeforeResume)
            .where((entry) => entry.startsWith('POST')),
        isEmpty,
        reason: 'the upload creation step must be skipped entirely',
      );
    });

    test('resumes without creating a new upload when a cache is set', () async {
      final firstClient = buildClient(url: createEndpoint);
      final uploadUrl = await uploadUntilItDies(
        firstClient,
        failAfterBytes: 6 * chunkSize,
      );

      final secondClient = buildClient(
        cache: TusMemoryCache(),
        uploadUrl: uploadUrl,
      );
      await secondClient.startUpload();

      expect(server.createCount, 1);
      expect(secondClient.uploadUrl, uploadUrl);
      expect(server.bytesOf(uploadUrl), fileBytes);
    });
  });

  group('Cancelling', () {
    /// Cancels from the progress callback, once [atOffset] bytes are reported.
    /// At that point no request is in flight, which is the case the
    /// Duration.zero timeout never covered.
    Future<void> uploadUntilCancelled(
      TusBaseClient client, {
      required int atOffset,
    }) async {
      Future? cancelled;
      await client.startUpload(
        onProgress: (count, total, response) {
          if (count == atOffset) cancelled ??= client.cancelUpload();
        },
      );
      await cancelled;
    }

    test('cancel takes effect with no request in flight', () async {
      final client = buildClient(cache: TusMemoryCache(), url: createEndpoint);

      await uploadUntilCancelled(client, atOffset: 2 * chunkSize);

      expect(
        client.state,
        TusUploadState.cancelled,
        reason: 'cancelling must not depend on catching a request in flight',
      );
      expect(
        server.offsetOf(client.uploadUrl),
        lessThan(fileSize),
        reason: 'the upload must stop instead of running to completion',
      );
    });

    test('pause takes effect with no request in flight', () async {
      final client = buildClient(cache: TusMemoryCache(), url: createEndpoint);

      await client.startUpload(
        onProgress: (count, total, response) {
          if (count == 2 * chunkSize) client.pauseUpload();
        },
      );

      expect(client.state, TusUploadState.paused);
      expect(server.offsetOf(client.uploadUrl), lessThan(fileSize));
    });

    test('cancel takes effect when the request beats the timer', () async {
      // No artificial latency at all, so an in flight request always resolves
      // before a Duration.zero timer could fire.
      final client = buildClient(cache: TusMemoryCache(), url: createEndpoint);
      Future? cancelled;
      server.beforeRespond = (method, uploadUrl) async {
        if (method == 'PATCH' && server.offsetOf(uploadUrl) == 2 * chunkSize) {
          cancelled ??= client.cancelUpload();
        }
      };

      await client.startUpload();
      await cancelled;

      expect(client.state, TusUploadState.cancelled);
      expect(server.offsetOf(client.uploadUrl), lessThan(fileSize));
    });

    test('a cancelled upload is abandoned, not resumed', () async {
      final cache = TusMemoryCache();
      final client = buildClient(cache: cache, url: createEndpoint);

      await uploadUntilCancelled(client, atOffset: 2 * chunkSize);
      final cancelledUploadUrl = client.uploadUrl;
      final bytesUploaded = server.offsetOf(cancelledUploadUrl);

      expect(
        await cache.get(client.fingerprint),
        isNull,
        reason: 'cancelling must drop the cache entry and not re add it',
      );

      await client.resumeUpload();

      expect(
        server.createCount,
        2,
        reason: 'resuming a cancelled upload must create a new upload',
      );
      expect(client.uploadUrl, isNot(cancelledUploadUrl));
      expect(
        server.offsetOf(cancelledUploadUrl),
        bytesUploaded,
        reason: 'the abandoned upload must be left untouched on the server',
      );
      expect(server.bytesOf(client.uploadUrl), fileBytes);
      expect(client.state, TusUploadState.completed);
    });

    test('a cancelled upload restarts from offset 0', () async {
      final cache = TusMemoryCache();
      final client = buildClient(cache: cache, url: createEndpoint);
      await uploadUntilCancelled(client, atOffset: 2 * chunkSize);

      final progress = <int>[];
      await client.startUpload(
        onProgress: (count, total, response) => progress.add(count),
      );

      expect(progress.first, 0);
      expect(server.bytesOf(client.uploadUrl), fileBytes);
    });

    test(
      'TusStreamClient restarts a cancelled upload from the beginning',
      () async {
        final cache = TusMemoryCache();
        final client = TusStreamClient(
          url: createEndpoint,
          fileStreamGenerator: () => file.openRead(),
          fileSize: fileSize,
          fileName: 'video-test.mp4',
          chunkSize: chunkSize,
          cache: cache,
          retryDelays: const [],
          httpClient: server.client,
        );

        await uploadUntilCancelled(client, atOffset: 2 * chunkSize);
        final cancelledUploadUrl = client.uploadUrl;

        await client.resumeUpload();

        expect(server.createCount, 2);
        expect(client.uploadUrl, isNot(cancelledUploadUrl));
        expect(
          server.bytesOf(client.uploadUrl),
          fileBytes,
          reason: 'the restarted stream must be read from the beginning again',
        );
      },
    );

    test('a new instance does not resume a cancelled upload either', () async {
      final cache = TusMemoryCache();
      final firstClient = buildClient(cache: cache, url: createEndpoint);
      await uploadUntilCancelled(firstClient, atOffset: 2 * chunkSize);

      final secondClient = buildClient(cache: cache, url: createEndpoint);
      await secondClient.startUpload();

      expect(server.createCount, 2);
      expect(secondClient.uploadUrl, isNot(firstClient.uploadUrl));
      expect(server.bytesOf(secondClient.uploadUrl), fileBytes);
    });

    test('a client with no creation url keeps its upload on cancel', () async {
      final firstClient = buildClient(url: createEndpoint);
      final uploadUrl = await uploadUntilItDies(
        firstClient,
        failAfterBytes: 3 * chunkSize,
      );

      final secondClient = buildClient(
        cache: TusMemoryCache(),
        uploadUrl: uploadUrl,
      );
      await uploadUntilCancelled(secondClient, atOffset: 5 * chunkSize);
      expect(secondClient.state, TusUploadState.cancelled);

      await secondClient.resumeUpload();

      expect(
        server.createCount,
        1,
        reason:
            'there is no creation url, so there is no new upload to '
            'fall back on and the cancelled one has to be kept',
      );
      expect(secondClient.uploadUrl, uploadUrl);
      expect(server.bytesOf(uploadUrl), fileBytes);
    });

    test('cancelling a completed upload leaves it alone', () async {
      final client = buildClient(cache: TusMemoryCache(), url: createEndpoint);
      await client.startUpload();
      expect(client.state, TusUploadState.completed);

      expect(client.cancelUpload(), isNull);
      expect(client.pauseUpload(), isNull);
      expect(client.state, TusUploadState.completed);
    });
  });

  group('Retrying', () {
    const fastRetries = [Duration.zero, Duration.zero, Duration.zero];

    test(
      'a transient server error is retried and the upload finishes',
      () async {
        final client = buildClient(
          cache: TusMemoryCache(),
          url: createEndpoint,
          retryDelays: fastRetries,
        );
        server
          ..failNextPatches = 2
          ..patchFailure = HttpStatus.serviceUnavailable;

        await client.startUpload();

        expect(client.state, TusUploadState.completed);
        expect(server.bytesOf(client.uploadUrl), fileBytes);
      },
    );

    test('a transport failure is retried', () async {
      final client = buildClient(
        cache: TusMemoryCache(),
        url: createEndpoint,
        retryDelays: fastRetries,
      );
      // A null failure throws a ClientException, which is how package:http
      // reports a dropped connection.
      server
        ..failNextPatches = 1
        ..patchFailure = null;

      await client.startUpload();

      expect(client.state, TusUploadState.completed);
      expect(server.bytesOf(client.uploadUrl), fileBytes);
    });

    test('retrying re-reads the offset instead of resending a chunk', () async {
      final client = buildClient(
        cache: TusMemoryCache(),
        url: createEndpoint,
        retryDelays: fastRetries,
      );
      server
        ..failNextPatches = 1
        ..patchFailure = HttpStatus.badGateway;

      await client.startUpload();

      expect(
        server.bytesOf(client.uploadUrl),
        fileBytes,
        reason: 'a retry must not duplicate or skip any bytes',
      );
      expect(
        server.requestLog.where((entry) => entry.startsWith('HEAD')).length,
        2,
        reason: 'the offset has to be re-read from the server before retrying',
      );
    });

    test('a stream source is rewound before a retry', () async {
      final client = TusStreamClient(
        url: createEndpoint,
        fileStreamGenerator: () => file.openRead(),
        fileSize: fileSize,
        fileName: 'video-test.mp4',
        chunkSize: chunkSize,
        retryDelays: fastRetries,
        httpClient: server.client,
      );
      server
        ..failNextPatches = 1
        ..patchFailure = HttpStatus.serviceUnavailable;

      await client.startUpload();

      expect(
        server.bytesOf(client.uploadUrl),
        fileBytes,
        reason:
            'a stream that already handed out a chunk that never landed '
            'has to start over rather than carry on from where it was',
      );
    });

    test('retries run out and the error is reported', () async {
      final client = buildClient(
        cache: TusMemoryCache(),
        url: createEndpoint,
        retryDelays: const [Duration.zero],
      );
      server
        ..failNextPatches = 5
        ..patchFailure = HttpStatus.serviceUnavailable;

      await expectLater(
        client.startUpload(),
        throwsA(isA<ProtocolException>()),
      );
      expect(client.state, TusUploadState.error);
    });

    test('a client error is not retried', () async {
      final client = buildClient(
        cache: TusMemoryCache(),
        url: createEndpoint,
        retryDelays: fastRetries,
      );
      server
        ..failNextPatches = 1
        ..patchFailure = HttpStatus.badRequest;

      await expectLater(
        client.startUpload(),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        server.requestLog.where((entry) => entry.startsWith('HEAD')).length,
        1,
        reason: 'a 400 will not go away by asking again',
      );
    });

    test('a pause racing a retryable failure is honoured', () async {
      final client = buildClient(
        cache: TusMemoryCache(),
        url: createEndpoint,
        retryDelays: fastRetries,
      );
      // The pause lands while the chunk that is about to fail is in flight.
      var paused = false;
      server.beforeRespond = (method, uploadUrl) async {
        if (method == 'PATCH' &&
            server.offsetOf(uploadUrl) == 2 * chunkSize &&
            !paused) {
          paused = true;
          client.pauseUpload();
          server
            ..failNextPatches = 1
            ..patchFailure = HttpStatus.serviceUnavailable;
        }
      };

      // The failure of the request that was in flight is not worth reporting:
      // the caller had already asked to stop.
      await expectLater(client.startUpload(), completes);

      expect(
        client.state,
        TusUploadState.paused,
        reason: 'a retry must not carry a paused upload on regardless',
      );
      expect(client.offset, 2 * chunkSize);
      expect(server.offsetOf(client.uploadUrl), lessThan(fileSize));

      // And the pause is a pause, not a dead end.
      await client.resumeUpload();
      expect(client.state, TusUploadState.completed);
      expect(server.bytesOf(client.uploadUrl), fileBytes);
    });

    test('a cancel racing a retryable failure is honoured', () async {
      final client = buildClient(
        cache: TusMemoryCache(),
        url: createEndpoint,
        retryDelays: fastRetries,
      );
      var cancelled = false;
      server.beforeRespond = (method, uploadUrl) async {
        if (method == 'PATCH' &&
            server.offsetOf(uploadUrl) == 2 * chunkSize &&
            !cancelled) {
          cancelled = true;
          client.cancelUpload();
          server
            ..failNextPatches = 1
            ..patchFailure = HttpStatus.serviceUnavailable;
        }
      };

      await expectLater(client.startUpload(), completes);

      expect(client.state, TusUploadState.cancelled);
      expect(server.offsetOf(client.uploadUrl), lessThan(fileSize));
    });
  });

  group('Upload length verification', () {
    test(
      'an upload created for a different file is not resumed into',
      () async {
        final cache = TusMemoryCache();
        final firstClient = buildClient(cache: cache, url: createEndpoint);
        final otherFileUploadUrl = await uploadUntilItDies(
          firstClient,
          failAfterBytes: 3 * chunkSize,
        );

        // Same fingerprint, but the server says that upload is for a file of a
        // different size, so it cannot be the one this client is uploading.
        server.reportLength(otherFileUploadUrl, fileSize * 2);

        final secondClient = buildClient(cache: cache, url: createEndpoint);
        await secondClient.startUpload();

        expect(
          server.createCount,
          2,
          reason:
              'resuming into an upload of a different length would corrupt '
              'it, so a new upload has to be created instead',
        );
        expect(secondClient.uploadUrl, isNot(otherFileUploadUrl));
        expect(server.bytesOf(secondClient.uploadUrl), fileBytes);
        expect(
          server.bytesOf(otherFileUploadUrl),
          hasLength(3 * chunkSize),
          reason: 'the other upload must be left untouched',
        );
      },
    );

    test('a mismatch with no creation url is reported', () async {
      final firstClient = buildClient(url: createEndpoint);
      final uploadUrl = await uploadUntilItDies(
        firstClient,
        failAfterBytes: 3 * chunkSize,
      );
      server.reportLength(uploadUrl, fileSize * 2);

      final secondClient = buildClient(uploadUrl: uploadUrl);
      await expectLater(
        secondClient.startUpload(),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.response,
            'response',
            isNull,
          ),
        ),
      );
      expect(server.createCount, 1);
    });

    test('a server that omits Upload-Length is still resumed from', () async {
      final cache = TusMemoryCache();
      final firstClient = buildClient(cache: cache, url: createEndpoint);
      final uploadUrl = await uploadUntilItDies(
        firstClient,
        failAfterBytes: 3 * chunkSize,
      );
      server.reportLength(uploadUrl, null);

      final secondClient = buildClient(cache: cache, url: createEndpoint);
      await secondClient.startUpload();

      expect(server.createCount, 1);
      expect(secondClient.uploadUrl, uploadUrl);
    });
  });

  group('Failure handling', () {
    test('a source shorter than the declared size fails loudly', () async {
      final client = TusStreamClient(
        url: createEndpoint,
        // Declares 10240 bytes but only ever yields 4096.
        fileStreamGenerator: () => Stream.value(fileBytes.sublist(0, 4096)),
        fileSize: fileSize,
        fileName: 'truncated.bin',
        chunkSize: chunkSize,
        retryDelays: const [],
        httpClient: server.client,
      );

      await expectLater(
        client.startUpload(),
        throwsA(
          isA<ProtocolException>()
              .having((e) => e.response, 'response', isNull)
              .having((e) => e.message, 'message', contains('ran out of data')),
        ),
      );
      expect(client.state, TusUploadState.error);
      expect(client.errorMessage, contains('ran out of data'));
    });

    test('cancelling after a transport failure does not rethrow it', () async {
      final client = buildClient(cache: TusMemoryCache(), url: createEndpoint);
      server
        ..failNextPatches = 1
        ..patchFailure = null;

      await expectLater(
        client.startUpload(),
        throwsA(isA<http.ClientException>()),
      );

      // Must not surface the long dead request's error.
      await expectLater(client.cancelUpload(), completes);
      await expectLater(client.pauseUpload() ?? Future.value(), completes);
    });

    test('resumeUpload keeps delivering errors to onError', () async {
      final client = buildClient(cache: TusMemoryCache(), url: createEndpoint);

      final errors = <ProtocolException>[];
      server
        ..failNextPatches = 1
        ..patchFailure = HttpStatus.badRequest;
      await client.startUpload(onError: errors.add);
      expect(errors, hasLength(1));

      server
        ..failNextPatches = 1
        ..patchFailure = HttpStatus.badRequest;
      await client.resumeUpload();

      expect(
        errors,
        hasLength(2),
        reason: 'resumeUpload must forward onError like every other callback',
      );
    });

    test('a second concurrent upload is rejected', () async {
      final client = buildClient(cache: TusMemoryCache(), url: createEndpoint);

      final first = client.startUpload();
      await expectLater(client.startUpload(), throwsA(isA<StateError>()));
      await first;

      expect(client.state, TusUploadState.completed);
      expect(server.bytesOf(client.uploadUrl), fileBytes);
      expect(
        server.requestLog.where((entry) => entry.startsWith('PATCH')).length,
        fileSize ~/ chunkSize,
        reason: 'exactly one loop must have run',
      );
    });

    test('a new upload can start once the previous one is done', () async {
      final client = buildClient(url: createEndpoint);
      await client.startUpload();
      await expectLater(client.startUpload(), completes);
    });
  });

  group('Client hygiene', () {
    test('metadata given by the caller is left alone', () {
      final callerMetadata = <String, dynamic>{'name': 'my-video'};
      final client = buildClient(url: createEndpoint);
      final withMetadata = TusClient(
        url: createEndpoint,
        file: XFile(file.path, name: 'video-test.mp4'),
        metadata: callerMetadata,
        httpClient: server.client,
      );

      withMetadata.generateMetadata();

      expect(callerMetadata, {
        'name': 'my-video',
      }, reason: 'the map belongs to the caller');
      expect(client.generateMetadata(), isNotEmpty);
    });

    test('a const metadata map is accepted', () {
      final client = TusClient(
        url: createEndpoint,
        file: XFile(file.path, name: 'video-test.mp4'),
        metadata: const <String, dynamic>{'name': 'my-video'},
        httpClient: server.client,
      );

      expect(client.generateMetadata, returnsNormally);
      expect(client.generateMetadata(), contains('filename'));
    });

    test('close disposes only a client it created', () {
      final callerClient = _ClosableClient(server.client);
      final withCallerClient = TusClient(
        url: createEndpoint,
        file: XFile(file.path),
        httpClient: callerClient,
      );

      withCallerClient.close();

      expect(
        callerClient.closed,
        isFalse,
        reason: 'a caller supplied http client may still be in use elsewhere',
      );
      // A client that made its own has nothing observable to assert on beyond
      // not throwing.
      expect(
        TusClient(url: createEndpoint, file: XFile(file.path)).close,
        returnsNormally,
      );
    });

    test('chunkSize must be positive', () {
      expect(
        () => TusClient(
          url: createEndpoint,
          file: XFile(file.path),
          chunkSize: 0,
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('offset only counts bytes the server confirmed', () async {
      final client = buildClient(url: createEndpoint);
      server
        ..failNextPatches = 1
        ..patchFailure = HttpStatus.badRequest;

      await expectLater(
        client.startUpload(),
        throwsA(isA<ProtocolException>()),
      );

      expect(
        client.offset,
        0,
        reason: 'the chunk was read but never landed, so it does not count',
      );
    });

    test('a relative Location is resolved against the creation url', () {
      final client = TusClient(
        url: 'https://tus.example.com/files/',
        file: XFile(file.path),
        httpClient: server.client,
      );

      expect(
        client.parseToURI('abc123').toString(),
        'https://tus.example.com/files/abc123',
      );
      expect(
        client.parseToURI('/other/abc123').toString(),
        'https://tus.example.com/other/abc123',
      );
      expect(
        client.parseToURI('https://cdn.example.com/abc123').toString(),
        'https://cdn.example.com/abc123',
      );
    });
  });

  group('TusPersistentCache', () {
    test('concurrent access opens the storage once', () async {
      final cache = TusPersistentCache(tempDir.path);

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
      expect(await cache.get('b'), 'url-b');
      await cache.clear();
    });

    test('a write is readable through another instance right away', () async {
      final writer = TusPersistentCache(tempDir.path);
      await writer.set('fingerprint', 'https://tus.example.com/files/abc');

      final reader = TusPersistentCache(tempDir.path);
      expect(
        await reader.get('fingerprint'),
        'https://tus.example.com/files/abc',
      );
      await reader.clear();
    });
  });

  group('Fingerprint', () {
    test('is computed before the cache is looked up', () async {
      final cache = _RecordingCache();
      final client = buildClient(cache: cache, url: createEndpoint);

      await client.startUpload();

      expect(cache.getKeys, isNotEmpty);
      expect(
        cache.getKeys.first,
        isNotEmpty,
        reason:
            'looking the upload up under an empty fingerprint can never '
            'hit an entry written under the real one',
      );
      expect(cache.getKeys.first, client.fingerprint);
      expect(cache.setKeys, everyElement(client.fingerprint));
    });

    test('is stable across instances for the same file and endpoint', () async {
      final firstClient = buildClient(url: createEndpoint);
      final secondClient = buildClient(url: createEndpoint);
      await firstClient.startUpload();
      await secondClient.startUpload();

      expect(firstClient.fingerprint, secondClient.fingerprint);
      expect(firstClient.fingerprint, isNotEmpty);
    });

    test('changes when the creation url changes, so an override is needed for '
        'one time creation urls', () async {
      final firstClient = buildClient(url: '$createEndpoint?token=first');
      final secondClient = buildClient(url: '$createEndpoint?token=second');
      await firstClient.startUpload();
      await secondClient.startUpload();

      expect(firstClient.fingerprint, isNot(secondClient.fingerprint));
    });

    test(
      'an override makes the fingerprint stable across one time urls',
      () async {
        final cache = TusMemoryCache();

        _StableFingerprintClient buildStableClient(String token) =>
            _StableFingerprintClient(
              url: '$createEndpoint?token=$token',
              file: XFile(file.path),
              chunkSize: chunkSize,
              cache: cache,
              retryDelays: const [],
              httpClient: server.client,
            );

        final firstClient = buildStableClient('first');
        final uploadUrl = await uploadUntilItDies(
          firstClient,
          failAfterBytes: 3 * chunkSize,
        );

        final secondClient = buildStableClient('second');
        await secondClient.startUpload();

        expect(server.createCount, 1);
        expect(secondClient.uploadUrl, uploadUrl);
        expect(server.bytesOf(uploadUrl), fileBytes);
      },
    );
  });
}

/// Records whether it was closed, to check [TusBaseClient.close] ownership.
class _ClosableClient extends http.BaseClient {
  bool closed = false;
  final http.Client _inner;

  _ClosableClient(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() {
    closed = true;
    _inner.close();
  }
}

/// A [TusClient] whose fingerprint does not depend on the creation url, which
/// is what a one time or pre signed creation url requires.
class _StableFingerprintClient extends TusClient {
  _StableFingerprintClient({
    required super.file,
    super.url,
    super.uploadUrl,
    super.chunkSize,
    super.cache,
    super.retryDelays,
    super.httpClient,
  });

  @override
  String generateFingerprint() => 'stable-fingerprint-${file.name}';
}

/// A [TusMemoryCache] that records the keys it is asked about.
class _RecordingCache extends TusMemoryCache {
  final List<String> getKeys = [];
  final List<String> setKeys = [];

  @override
  Future<String?> get(String fingerprint) {
    getKeys.add(fingerprint);
    return super.get(fingerprint);
  }

  @override
  Future<void> set(String fingerprint, String url) {
    setKeys.add(fingerprint);
    return super.set(fingerprint, url);
  }
}

/// An in memory tus server, good enough to exercise create, offset lookup and
/// chunked upload, and to assert on what actually landed on it.
class _FakeTusServer {
  _FakeTusServer({required this.createEndpoint});

  final String createEndpoint;

  /// Upload URL to the bytes stored for it.
  final Map<String, BytesBuilder> _uploads = {};

  /// Upload URL to the total length declared when it was created, which is what
  /// a HEAD reports back as `Upload-Length`.
  final Map<String, int> _lengths = {};

  /// Upload URLs the server no longer serves, to the status code it answers
  /// with, simulating an expired or swept upload.
  final Map<String, int> _swept = {};

  /// Fails the next [failNextPatches] PATCH requests with [patchFailure], to
  /// exercise retrying. A `null` failure drops the connection instead.
  int failNextPatches = 0;
  int? patchFailure;

  /// When set, an upload stops accepting chunks once this many bytes have
  /// landed, simulating a dropped connection or a killed process.
  int? failAfterBytes;

  /// Called before every response is produced, so a test can hold a request in
  /// flight or act while the client is waiting on the network.
  Future<void> Function(String method, String uploadUrl)? beforeRespond;

  int createCount = 0;
  int _nextId = 0;
  final List<String> requestLog = [];

  http.Client get client => MockClient(_handle);

  /// The bytes stored for [uploadUrl], or `null` if it is unknown.
  Uint8List? bytesOf(String uploadUrl) => _uploads[uploadUrl]?.toBytes();

  int offsetOf(String uploadUrl) => _uploads[uploadUrl]?.length ?? -1;

  void sweep(String uploadUrl, {int statusCode = HttpStatus.gone}) {
    _uploads.remove(uploadUrl);
    _swept[uploadUrl] = statusCode;
  }

  /// Makes [uploadUrl] report a different total length, as if it had been
  /// created for another file. A `null` length stops it reporting the header at
  /// all, which the protocol allows.
  void reportLength(String uploadUrl, int? length) {
    if (length == null) {
      _lengths.remove(uploadUrl);
    } else {
      _lengths[uploadUrl] = length;
    }
  }

  Future<http.Response> _handle(http.Request request) async {
    final method = request.method;
    final uploadUrl = request.url.toString();
    requestLog.add('$method $uploadUrl');
    await beforeRespond?.call(method, uploadUrl);

    if (method == 'POST') {
      createCount++;
      final createdUploadUrl = '$createEndpoint/upload-${_nextId++}';
      _uploads[createdUploadUrl] = BytesBuilder();
      _lengths[createdUploadUrl] = int.parse(
        request.headers[Headers.uploadLengthHeader]!,
      );
      return http.Response(
        '',
        HttpStatus.created,
        headers: {Headers.location: createdUploadUrl},
      );
    }

    final sweptStatusCode = _swept[uploadUrl];
    if (sweptStatusCode != null) return http.Response('', sweptStatusCode);

    final upload = _uploads[uploadUrl];
    if (upload == null) return http.Response('', HttpStatus.notFound);

    switch (method) {
      case 'HEAD':
        return http.Response(
          '',
          HttpStatus.ok,
          headers: {
            Headers.uploadOffsetHeader: '${upload.length}',
            if (_lengths[uploadUrl] != null)
              Headers.uploadLengthHeader: '${_lengths[uploadUrl]}',
          },
        );
      case 'PATCH':
        if (failNextPatches > 0) {
          failNextPatches--;
          final failure = patchFailure;
          if (failure == null) {
            throw http.ClientException('connection reset', request.url);
          }
          return http.Response('', failure);
        }
        final failAfter = failAfterBytes;
        if (failAfter != null && upload.length >= failAfter) {
          return http.Response('', HttpStatus.internalServerError);
        }
        final expectedOffset = int.parse(
          request.headers[Headers.uploadOffsetHeader]!,
        );
        if (expectedOffset != upload.length) {
          return http.Response('', HttpStatus.conflict);
        }
        upload.add(request.bodyBytes);
        return http.Response(
          '',
          HttpStatus.noContent,
          headers: {Headers.uploadOffsetHeader: '${upload.length}'},
        );
      default:
        return http.Response('', HttpStatus.methodNotAllowed);
    }
  }
}
