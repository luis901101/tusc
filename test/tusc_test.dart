import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:http/http.dart';
import 'package:tusc/tusc.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import 'test_utils.dart';

///
/// Make sure to set these environment variables before running tests.
///
/// export TUS_SERVER_URL=https://master.tus.io/files
/// export IMAGE_FILE=/Users/user/Desktop/image-test.jpg
/// export VIDEO_FILE=/Users/user/Desktop/video-test.mp4
///

String headersPrettyPrint(Map<String, String> headers) =>
    headers.entries.map((e) => '${e.key}: ${e.value}').join('\n');

void main() {
  final String tusServerURL =
      Platform.environment['TUS_SERVER_URL'] ?? 'https://master.tus.io/files';
  final imageFile = File(Platform.environment['IMAGE_FILE'] ?? ''),
      videoFile = File(Platform.environment['VIDEO_FILE'] ?? '');

  final imageChunkSize = 5.KB;
  final videoChunkSize = 1.MB;

  group('Assertion tests', () {
    test('Null url and uploadUrl test', () {
      expect(
        () => TusClient(file: XFile('')),
        throwsA(isA<AssertionError>()),
      );
    });
    test('Empty url and uploadUrl test', () {
      expect(
        () => TusClient(url: '', uploadUrl: '', file: XFile('')),
        throwsA(isA<AssertionError>()),
      );
    });
    test('Null url and empty uploadUrl test', () {
      expect(
        () => TusClient(uploadUrl: '', file: XFile('')),
        throwsA(isA<AssertionError>()),
      );
    });
    test('Empty url and null uploadUrl test', () {
      expect(
        () => TusClient(url: '', file: XFile('')),
        throwsA(isA<AssertionError>()),
      );
    });
    test('Null url and non null nor empty uploadUrl test', () {
      expect(
        () => TusClient(uploadUrl: 'some-url', file: XFile('')),
        returnsNormally,
      );
    });
    test('No null nor empty url and null uploadUrl test', () {
      expect(
        () => TusClient(url: 'some-url', file: XFile('')),
        returnsNormally,
      );
    });
  });

  test('Fingerprint max length test', () async {
    // This path has more than 400 chars
    final reallyLongFilePath =
        'this/is/a/really/long/file/path/that/should/be/hashed/to/a/fingerprint/that/is/longer/than/256/and/should/not/be/truncated/to/128/characters/so/that/we/can/test/the/fingerprint/generation/and/make/sure/it/works/as/expected/and/does/not/cause/any/issues/with/the/tus/client/implementation/and/should/be/able/to/be/uploaded/without/any/problems/or/errors/and/should/not/cause/any/performance/impact/on/the/upload/process/or/the/client/performance/in/general';
    final tusClient = TusClient(
      url: tusServerURL,
      file: XFile(reallyLongFilePath),
      chunkSize: imageChunkSize,
      cache: TusPersistentCache(''),
    );
    final fingerprint = tusClient.generateFingerprint();
    await tusClient.cache?.set(fingerprint, tusServerURL);
    final getValue = await tusClient.cache?.get(fingerprint);
    expect(tusServerURL, getValue);
  }, timeout: Timeout(Duration(seconds: 10)));

  group('Tus Client tests', () {
    test(
        'Image upload to tusServerURL using Tus Client with tus protocol',
        () async => await genericImageUploadTest(
            imageFile: imageFile,
            tusClient: TusClient(
              url: tusServerURL,
              file: XFile(imageFile.path),
              chunkSize: imageChunkSize,
              cache: TusMemoryCache(),
            )),
        timeout: Timeout(Duration(minutes: 1)));
    test(
        'Image upload to uploadUrl using Tus Client with tus protocol',
        () async => await genericImageUploadTest(
              imageFile: imageFile,
              tusClient: TusClient(
                uploadUrl: await generateUploadUrlForTest(
                  url: tusServerURL,
                  file: imageFile,
                ),
                file: XFile(imageFile.path),
                chunkSize: imageChunkSize,
                cache: TusMemoryCache(),
              ),
            ),
        timeout: Timeout(Duration(minutes: 1)));

    test(
        'Video upload to tusServerURL using Tus Client using tus protocol',
        () async => await genericVideoUploadTest(
              videoFile: videoFile,
              tusClient: TusClient(
                url: tusServerURL,
                file: XFile(videoFile.path),
                chunkSize: videoChunkSize,
                cache: TusPersistentCache(''),
              ),
            ),
        timeout: Timeout(Duration(minutes: 10)));
    test(
        'Video upload to uploadUrl using Tus Client using tus protocol',
        () async => await genericVideoUploadTest(
              videoFile: videoFile,
              tusClient: TusClient(
                uploadUrl: await generateUploadUrlForTest(
                  url: tusServerURL,
                  file: videoFile,
                ),
                file: XFile(videoFile.path),
                chunkSize: videoChunkSize,
                cache: TusPersistentCache(''),
              ),
            ),
        timeout: Timeout(Duration(minutes: 10)));
  });

  group('Tus Stream Client tests', () {
    test(
        'Image upload to tusServerURL using Tus Stream Client with tus protocol',
        () async => await genericImageUploadTest(
              imageFile: imageFile,
              tusClient: TusStreamClient(
                url: tusServerURL,
                fileStreamGenerator: () => imageFile.openRead(),
                fileSize: imageFile.lengthSync(),
                fileName: p.basename(imageFile.path),
                chunkSize: imageChunkSize,
                cache: TusMemoryCache(),
              ),
            ),
        timeout: Timeout(Duration(hours: 1)));
    test(
        'Image upload to uploadUrl using Tus Stream Client with tus protocol',
        () async => await genericImageUploadTest(
              imageFile: imageFile,
              tusClient: TusStreamClient(
                uploadUrl: await generateUploadUrlForTest(
                  url: tusServerURL,
                  file: imageFile,
                ),
                fileStreamGenerator: () => imageFile.openRead(),
                fileSize: imageFile.lengthSync(),
                fileName: p.basename(imageFile.path),
                chunkSize: imageChunkSize,
                cache: TusMemoryCache(),
              ),
            ),
        timeout: Timeout(Duration(minutes: 1)));

    test(
        'Video upload to tusServerURL using Tus Stream Client with tus protocol',
        () async => await genericVideoUploadTest(
              videoFile: videoFile,
              tusClient: TusStreamClient(
                url: tusServerURL,
                fileStreamGenerator: () => videoFile.openRead(),
                fileSize: videoFile.lengthSync(),
                fileName: p.basename(videoFile.path),
                chunkSize: videoChunkSize,
                cache: TusPersistentCache(''),
              ),
            ),
        timeout: Timeout(Duration(minutes: 10)));
    test(
        'Video upload to uploadUrl using Tus Stream Client using tus protocol',
        () async => await genericVideoUploadTest(
              videoFile: videoFile,
              tusClient: TusStreamClient(
                uploadUrl: await generateUploadUrlForTest(
                  url: tusServerURL,
                  file: videoFile,
                ),
                fileStreamGenerator: () => videoFile.openRead(),
                fileSize: videoFile.lengthSync(),
                fileName: p.basename(videoFile.path),
                chunkSize: videoChunkSize,
                cache: TusPersistentCache(''),
              ),
            ),
        timeout: Timeout(Duration(minutes: 10)));
  });
}

Future<void> genericImageUploadTest(
    {required File imageFile, required TusBaseClient tusClient}) async {
  if (!imageFile.existsSync()) fail('No image file available to upload');

  bool isComplete = false;
  void onProgress(int count, int total, Response? response) {
    if (isComplete) return;
    print(
      'tus image upload from file: ${p.basename(imageFile.path)} progress: $count/$total ${(count / total * 100).toInt()}%',
    );
    if (response != null) {
      print('----------------------');
      print('Response headers: ${headersPrettyPrint(response.headers)}');
      print('----------------------');
    }
  }

  final testProgressCallback = expectAsyncUntil3(
    onProgress,
    () => isComplete,
  );
  try {
    await tusClient.startUpload(
      onProgress: testProgressCallback,
      onComplete: (response) {
        expect(tusClient.state, TusUploadState.completed);
        print('Response headers: ${headersPrettyPrint(response.headers)}');
        print(
          '--------------------------------------------------------------',
        );
        print(
          '--------------------------------------------------------------',
        );
        print(
          '--------------------------------------------------------------',
        );
        print(
          '------------------------Upload completed----------------------',
        );
        print(tusClient.uploadUrl);
        print(
          '--------------------------------------------------------------',
        );
        print(
          '--------------------------------------------------------------',
        );
        print(
          '--------------------------------------------------------------',
        );
        isComplete = true;
        testProgressCallback(0, 0, null);
      },
    );
  } on ProtocolException catch (e) {
    print('Response status code: ${e.response.statusCode}');
    print('Response status reasonPhrase: ${e.response.reasonPhrase}');
    print('Response body: ${e.response.body}');
    print('Response headers: ${headersPrettyPrint(e.response.headers)}');
    rethrow;
  } catch (e) {
    print(e);
    rethrow;
  }
}

Future<void> genericVideoUploadTest(
    {required File videoFile, required TusBaseClient tusClient}) async {
  if (!videoFile.existsSync()) fail('No video file available to upload');

  bool isComplete = false;
  void onProgress(int count, int total, Response? response) {
    if (isComplete) return;
    print(
      'tus video upload from file: ${p.basename(videoFile.path)} progress: $count/$total ${(count / total * 100).toInt()}%',
    );
    if (response != null) {
      print('----------------------');
      print('Response headers: ${headersPrettyPrint(response.headers)}');
      print('----------------------');
    }
  }

  final testProgressCallback = expectAsyncUntil3(
    onProgress,
    () => isComplete,
  );
  tusClient.startUpload(
    onProgress: testProgressCallback,
    onComplete: (response) {
      print('Response headers: ${headersPrettyPrint(response.headers)}');
      print(
        '--------------------------------------------------------------',
      );
      print(
        '--------------------------------------------------------------',
      );
      print(
        '--------------------------------------------------------------',
      );
      print(
        '------------------------Upload completed----------------------',
      );
      print(tusClient.uploadUrl);
      print(
        '--------------------------------------------------------------',
      );
      print(
        '--------------------------------------------------------------',
      );
      print(
        '--------------------------------------------------------------',
      );
      isComplete = true;
      testProgressCallback(0, 0, null);
    },
    onTimeout: () {
      print(
        '--------------------------------------------------------------',
      );
      print(
        '--------------------------------------------------------------',
      );
      print(
        '--------------------------------------------------------------',
      );
      print(
        '------------------------Upload request timeout----------------',
      );
      print(
        '--------------------------------------------------------------',
      );
      print(
        '--------------------------------------------------------------',
      );
      print(
        '--------------------------------------------------------------',
      );
    },
  );

  await Future.delayed(const Duration(seconds: 3), () async {
    await tusClient.pauseUpload();
    expect(tusClient.state, TusUploadState.paused);
    print('--------------------------------------------------------------');
    print('--------------------------------------------------------------');
    print('--------------------------------------------------------------');
    print('------------------------Upload paused------------------------');
    print('--------------------------------------------------------------');
    print('--------------------------------------------------------------');
    print('--------------------------------------------------------------');
  });

  await Future.delayed(const Duration(seconds: 6), () async {
    tusClient.resumeUpload();
    expect(tusClient.state, TusUploadState.uploading);
    print('--------------------------------------------------------------');
    print('--------------------------------------------------------------');
    print('--------------------------------------------------------------');
    print('------------------------Upload resumed------------------------');
    print('--------------------------------------------------------------');
    print('--------------------------------------------------------------');
    print('--------------------------------------------------------------');
  });

  await Future.delayed(const Duration(seconds: 10), () async {
    tusClient.cancelUpload();
    expect(tusClient.state, TusUploadState.uploading);
    print('--------------------------------------------------------------');
    print('--------------------------------------------------------------');
    print('--------------------------------------------------------------');
    print('------------------------Upload cancelled----------------------');
    print('--------------------------------------------------------------');
    print('--------------------------------------------------------------');
    print('--------------------------------------------------------------');
  });

  await Future.delayed(const Duration(seconds: 14), () async {
    tusClient.resumeUpload();
    expect(tusClient.state, TusUploadState.uploading);
    print('--------------------------------------------------------------');
    print('--------------------------------------------------------------');
    print('--------------------------------------------------------------');
    print('------------------------Upload restarted----------------------');
    print('--------------------------------------------------------------');
    print('--------------------------------------------------------------');
    print('--------------------------------------------------------------');
  });
}
