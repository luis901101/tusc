import 'package:tusc/tusc.dart';
import 'package:cross_file/cross_file.dart' show XFile;
import 'package:http/http.dart' as http;

void main() async {
  /// File to be uploaded
  final file = XFile('/path/to/some/video.mp4');
  final uploadURL = 'https://master.tus.io/files';

  /// Initialize a TusClient instance from a XFile
  /// This is the most common way to use the TusClient
  final tusClient = initTusClient(file, uploadURL);
  handleClient(tusClient);

  /// Initialize a TusStreamClient instance from a Stream generator function
  /// This is useful when you want to upload a file from a stream.
  /// The only difference is that this client doesn't rely on a file but rather
  /// on a stream of bytes. It's intended for cases where the file is excessively
  /// large.
  final tusStreamClient = await initTusStreamClient(file, uploadURL);
  handleClient(tusStreamClient);
}

TusBaseClient initTusClient(XFile file, String uploadURL) => TusClient(
      /// Required
      url: uploadURL,

      /// Required
      file: file,

      /// Optional, defaults to 256 KB
      chunkSize: 5.MB,

      /// Optional, defaults to 1.0.0. Change this only if your tus server uses different version
      tusVersion: Headers.defaultTusVersion,

      /// Optional, defaults to null. See also [TusMemoryCache]
      cache: TusPersistentCache('/some/path'),

      /// Optional, defaults to null. Use it when you need to pass extra headers in request like for authentication
      headers: <String, dynamic>{
        'Authorization':
            'Bearer d843udhq3fkjasdnflkjasdf.hedomiqxh3rx3r23r.8f392zqh3irgqig',
      },

      /// Optional, defaults to null. Use it when you need to pass extra data like file name or any other specific business data
      metadata: <String, dynamic>{
        'name': 'my-video',
      },

      /// Optional, defaults to 30 seconds
      timeout: Duration(seconds: 10),

      /// Optional, defaults to http.Client(), use it when you need more control over http requests
      httpClient: http.Client(),
    );

Future<TusBaseClient> initTusStreamClient(XFile file, String uploadURL) async =>
    TusStreamClient(
      /// Required
      url: uploadURL,

      /// Required
      fileStreamGenerator: () => file.openRead(),

      /// Required
      fileSize: await file.length(),

      /// Required
      fileName: file.name,

      /// Optional, defaults to 256 KB
      chunkSize: 5.MB,

      /// Optional, defaults to 1.0.0. Change this only if your tus server uses different version
      tusVersion: Headers.defaultTusVersion,

      /// Optional, defaults to null. See also [TusMemoryCache]
      cache: TusPersistentCache('/some/path'),

      /// Optional, defaults to null. Use it when you need to pass extra headers in request like for authentication
      headers: <String, dynamic>{
        'Authorization':
            'Bearer d843udhq3fkjasdnflkjasdf.hedomiqxh3rx3r23r.8f392zqh3irgqig',
      },

      /// Optional, defaults to null. Use it when you need to pass extra data like file name or any other specific business data
      metadata: <String, dynamic>{
        'name': 'my-video',
      },

      /// Optional, defaults to 30 seconds
      timeout: Duration(seconds: 10),

      /// Optional, defaults to http.Client(), use it when you need more control over http requests
      httpClient: http.Client(),
    );

void handleClient(TusBaseClient tusClient) {
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

  Future.delayed(const Duration(seconds: 6), () async {
    /// Pauses the upload progress
    await tusClient.pauseUpload();
    print(tusClient.state);
  });

  Future.delayed(const Duration(seconds: 6), () async {
    /// Cancels the upload progress
    await tusClient.cancelUpload();
    print(tusClient.state);
  });

  Future.delayed(const Duration(seconds: 8), () async {
    /// Resumes the upload progress where it left of, and notify to the same callbacks used in the startUpload(...)
    tusClient.resumeUpload();
    print(tusClient.state);
  });
}
