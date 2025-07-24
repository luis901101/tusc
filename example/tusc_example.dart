import 'dart:io';

import 'package:tusc/tusc.dart';
import 'package:cross_file/cross_file.dart' show XFile;
import 'package:http/http.dart' as http;

void main() async {
  /// File to be uploaded
  final file = XFile('/path/to/some/video.mp4');
  final uploadURL = 'https://master.tus.io/files';

  /// Create a client
  final tusClient = TusClient(
    url: uploadURL,

    /// Required
    file: file,

    /// Required
    chunkSize: 5.MB,

    /// Optional, defaults to 256 KB
    tusVersion: Headers.defaultTusVersion,

    /// Optional, defaults to 1.0.0. Change this only if your tus server uses different version
    cache: TusPersistentCache('/some/path'),

    /// Optional, defaults to null. See also [TusMemoryCache]
    headers: <String, dynamic>{
      /// Optional, defaults to null. Use it when you need to pass extra headers in request like for authentication
      HttpHeaders.authorizationHeader:
          'Bearer d843udhq3fkjasdnflkjasdf.hedomiqxh3rx3r23r.8f392zqh3irgqig',
    },
    metadata: <String, dynamic>{
      /// Optional, defaults to null. Use it when you need to pass extra data like file name or any other specific business data
      'name': 'my-video',
    },
    timeout: Duration(seconds: 10),

    /// Optional, defaults to 30 seconds
    httpClient: http.Client(),

    /// Optional, defaults to http.Client(), use it when you need more control over http requests
  );

  /// Starts the upload
  tusClient.startUpload(
    /// count: the amount of data already uploaded
    /// total: the amount of data to be uploaded
    /// response: the http response of the last chunkSize uploaded
    onProgress: (count, total, progress) {
      print('Progress: $count of $total | ${(count / total * 100).toInt()}%');
    },

    /// response: the http response of the last chunkSize uploaded
    onComplete: (response) {
      print('Upload Completed');
      print(tusClient.uploadUrl.toString());
    },
    onTimeout: () {
      print('Upload timed out');
    },
    onError: (e) {
      print('Error message: ${e.message}');
      print('Response status code: ${e.response.statusCode}');
      print('Response status reasonPhrase: ${e.response.reasonPhrase}');
      print('Response body: ${e.response.body}');
      print('Response headers: ${e.response.headers}');
    },
  );

  await Future.delayed(const Duration(seconds: 6), () async {
    await tusClient.pauseUpload();
    print(tusClient.state);

    /// Pauses the upload progress
  });

  await Future.delayed(const Duration(seconds: 6), () async {
    await tusClient.cancelUpload();
    print(tusClient.state);

    /// Cancels the upload progress
  });

  await Future.delayed(const Duration(seconds: 8), () async {
    tusClient.resumeUpload();
    print(tusClient.state);

    /// Resumes the upload progress where it left of, and notify to the same callbacks used in the startUpload(...)
  });
}
