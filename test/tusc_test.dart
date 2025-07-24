import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:http/http.dart';
import 'package:tusc/tusc.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

///
/// Make sure to set these environment variables before running tests.
///
/// export UPLOAD_URL=https://master.tus.io/files
/// export IMAGE_FILE=/Users/user/Desktop/image-test.jpg
/// export VIDEO_FILE=/Users/user/Desktop/video-test.mp4
///

String headersPrettyPrint(Map<String, String> headers) =>
    headers.entries.map((e) => '${e.key}: ${e.value}').join('\n');

void main() {
  final String uploadURL =
      Platform.environment['UPLOAD_URL'] ?? 'https://master.tus.io/files';
  final imageFile = File(Platform.environment['IMAGE_FILE'] ?? ''),
      videoFile = File(Platform.environment['VIDEO_FILE'] ?? '');

  test('Fingerprint max length test', () async {
    // This path has more than 400 chars
    final reallyLongFilePath =
        'this/is/a/really/long/file/path/that/should/be/hashed/to/a/fingerprint/that/is/longer/than/256/and/should/not/be/truncated/to/128/characters/so/that/we/can/test/the/fingerprint/generation/and/make/sure/it/works/as/expected/and/does/not/cause/any/issues/with/the/tus/client/implementation/and/should/be/able/to/be/uploaded/without/any/problems/or/errors/and/should/not/cause/any/performance/impact/on/the/upload/process/or/the/client/performance/in/general';
    final tusClient = TusClient(
      url: uploadURL,
      file: XFile(reallyLongFilePath),
      chunkSize: 5.KB,
      cache: TusPersistentCache(''),
    );
    final fingerprint = tusClient.generateFingerprint();
    await tusClient.cache?.set(fingerprint, uploadURL);
    final getValue = await tusClient.cache?.get(fingerprint);
    expect(uploadURL, getValue);
  }, timeout: Timeout(Duration(seconds: 10)));

  group('Tus Client tests', () {
    test('Image upload using Tus Client with tus protocol', () async {
      if (uploadURL.isEmpty) fail('No uploadURL to upload to');
      if (!imageFile.existsSync()) fail('No image file available to upload');
      final tusClient = TusClient(
        url: uploadURL,
        file: XFile(imageFile.path),
        chunkSize: 5.KB,
        cache: TusMemoryCache(),
      );
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
    }, timeout: Timeout(Duration(minutes: 1)));

    test('Video upload using Tus Client using tus protocol', () async {
      if (uploadURL.isEmpty) fail('No uploadURL to upload to');
      if (!videoFile.existsSync()) fail('No video file available to upload');
      final tusClient = TusClient(
        url: uploadURL,
        file: XFile(videoFile.path),
        chunkSize: 256.KB,
        cache: TusPersistentCache(''),
      );
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
    }, timeout: Timeout(Duration(minutes: 10)));
  });

  group('Tus Stream Client tests', () {
    test('Image upload using Tus Stream Client with tus protocol', () async {
      if (uploadURL.isEmpty) fail('No uploadURL to upload to');
      if (!imageFile.existsSync()) fail('No image file available to upload');
      final tusClient = TusStreamClient(
        url: uploadURL,
        fileStreamGenerator: () => imageFile.openRead(),
        fileSize: imageFile.lengthSync(),
        fileName: p.basename(imageFile.path),
        chunkSize: 5.KB,
        cache: TusMemoryCache(),
      );
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
    }, timeout: Timeout(Duration(hours: 1)));

    test('Video upload using Tus Stream Client with tus protocol', () async {
      if (uploadURL.isEmpty) fail('No uploadURL to upload to');
      if (!videoFile.existsSync()) fail('No video file available to upload');
      final tusClient = TusStreamClient(
        url: uploadURL,
        fileStreamGenerator: () => videoFile.openRead(),
        fileSize: videoFile.lengthSync(),
        fileName: p.basename(videoFile.path),
        chunkSize: 256.KB,
        cache: TusPersistentCache(''),
      );
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
    }, timeout: Timeout(Duration(minutes: 10)));
  });
}
