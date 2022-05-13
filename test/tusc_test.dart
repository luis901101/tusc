import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:http/http.dart';
import 'package:tusc/tusc.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

///
/// Make sure to set these environment variables before running tests.
///
/// export UPLOAD_URL=https://master.tus.io/files/
/// export IMAGE_FILE=/Users/user/Desktop/image-test.jpg
/// export VIDEO_FILE=/Users/user/Desktop/video-test.mp4
///

String headersPrettyPrint(Map<String, String> headers) =>
  headers.entries.map((e) => '${e.key}: ${e.value}').join('\n');

void main() {
  final String uploadURL = Platform.environment['UPLOAD_URL'] ?? 'https://master.tus.io/files/';
  final imageFile = File(Platform.environment['IMAGE_FILE'] ?? ''),
      videoFile = File(Platform.environment['VIDEO_FILE'] ?? '');

  group('tus client tests', () {
    test('Image upload using tus protocol', () async {
      if (uploadURL.isEmpty) fail('No uploadURL to upload to');
      if (!imageFile.existsSync()) fail('No image file available to upload');
      final tusClient = TusClient(
        url: uploadURL,
        chunkSize: 5 * 1024, //5 KB
        file: XFile(imageFile.path),
        store: TusMemoryStore(),
      );
      bool isComplete = false;
      onProgress(int count, int total, Response? response) {
        if(isComplete) return;
        print('tus image upload from file: ${p.basename(imageFile.path)} progress: $count/$total ${(count/total * 100).toInt()}%');
        if(response != null) {
          print('----------------------');
          print('Response headers: ${headersPrettyPrint(response.headers)}');
          print('----------------------');
        }
      }
      final testProgressCallback = expectAsyncUntil3(onProgress, () => isComplete);
      try {
        await tusClient.startUpload(
          onProgress: testProgressCallback,
          onComplete: (response) {
            print('Response headers: ${headersPrettyPrint(response.headers)}');
            print('--------------------------------------------------------------');
            print('--------------------------------------------------------------');
            print('--------------------------------------------------------------');
            print('------------------------Upload completed----------------------');
            print('--------------------------------------------------------------');
            print('--------------------------------------------------------------');
            print('--------------------------------------------------------------');
            isComplete = true;
            testProgressCallback(0, 0, null);
          }
        );
      } on ProtocolException catch(e){
        print('Response status code: ${e.response.statusCode}');
        print('Response status reasonPhrase: ${e.response.reasonPhrase}');
        print('Response body: ${e.response.body}');
        print('Response headers: ${headersPrettyPrint(e.response.headers)}');
        rethrow;
      } catch(e) {
        print(e);
        rethrow;
      }
    }, timeout: Timeout(Duration(minutes: 1)));

    test('Video upload using tus protocol', () async {
      if (uploadURL.isEmpty) fail('No uploadURL to upload to');
      if (!videoFile.existsSync()) fail('No video file available to upload');
      final tusClient = TusClient(
        url: uploadURL,
        chunkSize: 20 * 1024, //20 KB
        file: XFile(videoFile.path),
        store: TusPersistentStore(''),
      );
      bool isComplete = false;
      onProgress(int count, int total, Response? response) {
        if(isComplete) return;
        print('tus video upload from file: ${p.basename(videoFile.path)} progress: $count/$total ${(count/total * 100).toInt()}%');
        if(response != null) {
          print('----------------------');
          print('Response headers: ${headersPrettyPrint(response.headers)}');
          print('----------------------');
        }
      }
      final testProgressCallback = expectAsyncUntil3(onProgress, () => isComplete);
      tusClient.startUpload(
        onProgress: testProgressCallback,
        onComplete: (response) {
          print('Response headers: ${headersPrettyPrint(response.headers)}');
          print('--------------------------------------------------------------');
          print('--------------------------------------------------------------');
          print('--------------------------------------------------------------');
          print('------------------------Upload completed----------------------');
          print('--------------------------------------------------------------');
          print('--------------------------------------------------------------');
          print('--------------------------------------------------------------');
          isComplete = true;
          testProgressCallback(0, 0, null);
        },
        onTimeoutCallback: () {
          print('Request timeout');
        }
      );

      await Future.delayed(const Duration(seconds: 6), () async {
        await tusClient.pauseUpload();
        print('--------------------------------------------------------------');
        print('--------------------------------------------------------------');
        print('--------------------------------------------------------------');
        print('------------------------Upload paused------------------------');
        print('--------------------------------------------------------------');
        print('--------------------------------------------------------------');
        print('--------------------------------------------------------------');
      });

      await Future.delayed(const Duration(seconds: 8), () async {
        tusClient.resumeUpload();
        print('--------------------------------------------------------------');
        print('--------------------------------------------------------------');
        print('--------------------------------------------------------------');
        print('------------------------Upload resumed------------------------');
        print('--------------------------------------------------------------');
        print('--------------------------------------------------------------');
        print('--------------------------------------------------------------');
      });

    }, timeout: Timeout(Duration(minutes: 1)));
  });
}
