# A tus client 

[![Pub Version](https://img.shields.io/pub/v/tus_client)](https://pub.dev/packages/tusc)

A tus client written in pure dart for [resumable uploads using tus protocol](https://tus.io/)

> **tus** is a protocol based on HTTP for *resumable file uploads*. Resumable
> means that an upload can be interrupted at any moment and can be resumed without
> re-uploading the previous data again. An interruption may happen willingly, if
> the user wants to pause, or by accident in case of a network issue or server
> outage.

## This package is based on [tus_client](https://pub.dev/packages/tus_client) but with some improvements.

## Installation
The first thing is to add **tusc** as a dependency of your project, 
for this you can use the command:

**For purely Dart projects**
```shell
dart pub add tusc
```
**For Flutter projects**
```shell
flutter pub add tusc
```
This command will add **tusc** to the **pubspec.yaml** of your project.
Finally you just have to run:

`dart pub get` **or** `flutter pub get` depending on the project type and this will download the dependency to your pub-cache

## Usage

```dart
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
    url: uploadURL, /// Required
    file: file, /// Required
    chunkSize: 5.MB, /// Optional, defaults to 256 KB
    tusVersion: TusClient.defaultTusVersion, /// Optional, defaults to 1.0.0. Change this only if your tus server uses different version
    cache: TusPersistentCache('/some/path'), /// Optional, defaults to null. See also [TusMemoryCache]
    headers: <String, dynamic>{ /// Optional, defaults to null. Use it when you need to pass extra headers in request like for authentication
      HttpHeaders.authorizationHeader: 'Bearer d843udhq3fkjasdnflkjasdf.hedomiqxh3rx3r23r.8f392zqh3irgqig'
    },
    metadata: <String, dynamic>{ /// Optional, defaults to null. Use it when you need to pass extra data like file name or any other specific business data
      'name': 'my-video'
    },
    timeout: Duration(seconds: 10), /// Optional, defaults to 30 seconds
    httpClient: http.Client(), /// Optional, defaults to http.Client(), use it when you need more control over http requests
  );

  /// Starts the upload
  tusClient.startUpload(
    /// count: the amount of data already uploaded
    /// total: the amount of data to be uploaded
    /// response: the http response of the last chunkSize uploaded
      onProgress: (count, total, progress) {
        print('Progress: $count of $total | ${(count/total * 100).toInt()}%');
      },

      /// response: the http response of the last chunkSize uploaded
      onComplete: (response) {
        print('Upload Completed');
        print(tusClient.uploadUrl.toString());
      },

      onTimeout: () {
        print('Upload timed out');
      }
  );

  await Future.delayed(const Duration(seconds: 6), () async {
    await tusClient.pauseUpload(); /// Pauses the upload progress
  });

  await Future.delayed(const Duration(seconds: 8), () async {
    tusClient.resumeUpload(); /// Resumes the upload progress where it left of, and notify to the same callbacks used in the startUpload(...)
  });
}
```

### Chunk size
The file is uploaded in chunks. Default size is 256KB. This should be set considering **speed of upload** and **device memory constraints**.
For specifying the `chunkSize` you can easily set it like `512.KB` or `10.MB` and this will use an int extension under the hook to calculate the amount in bytes.  

```dart
final tusClient = TusClient(
    uploadURL,
    file,
    chunkSize: 10.MB,
);
```

### Upload callbacks
When you call `tusClient.startUpload(...)` you optionally can set some callbacks:
- `onProgress: (count, total, progress)`: This callback notifies about the upload progress. It provides `count` which is the amount of data already uploaded, `total` the amount of data to be uploaded and `response` which is the http response of the last `chunkSize` uploaded. With this response you can check for headers or body in case your tus server returns some info there.
- `onComplete: (response)`: This callback notifies the upload has completed. It provides a `response` which is the http response of the last `chunkSize` uploaded. With this response you can check for headers or body in case your tus server returns some info there.
- `onTimeout: ()`: This callback notifies the upload timed out according to the `timeout` property specified in the `TusClient` constructor which by default is 30 seconds.
  
### Cache
For `TusClient` to manage `pause/resume` uploads you can set a `cache` by using:
- `TusMemoryCache`: with this cache you can `pause/resume` uploads while your app is running. If your app crashes or simply closes you will not be able to resume a pending upload.
- `TusPersistentCache`: with this cache you can `pause/resume` uploads any time, no matter if your app crashes, closes or even your device restarts.

```dart
final tusClient = TusClient(
    uploadURL,
    file,
    cache: TusMemoryCache(),
);
```
or
```dart
final tusClient = TusClient(
    uploadURL,
    file,
    cache: TusPersistentCache('/some/path'),
);
```
Note that `TusPersistentCache` requires a path, this path will be where the cache storage will take place. This persistent cache implementation works in pure dart so, no matter if you want to use it in a `flutter` project or a `dart` project, it simply works.

### How to set persistent cache in flutter
You can use [path_provider](https://pub.dev/packages/path_provider) plugin to be able to get the path to a directory where your app has permissions to write.
[path_provider](https://pub.dev/packages/path_provider) works on most platforms except on web, but this is not a problem, the `TusPersistentCache` takes care of it, you just need to set a `path` and if app is running on web `TusPersistentCache` ignores that `path` and handles the persistent cache under the hook. 

The following sample code works on any platform.
```dart
import 'dart:io';
import 'package:path_provider/path_provider.dart';

Future<void> sample() async {
  Directory dir = Directory.systemTemp;
  try {
    /// Here the try/catch is to handle [MissingPlatformDirectoryException] throws from path_provider in case of app running on unsupported platform, like web.
    /// You can handle this differently, for instance asking to kIsWeb, but this is just a sample
    dir = await getApplicationDocumentsDirectory();
  } catch (e) {
    print(e);
  }

  final tusClient = TusClient(
    uploadURL,
    file,
    cache: TusPersistentCache(dir.path),
  );
}

```

### Pausing upload
Pausing upload can be done after current uploading chunk is completed.
Just by calling: `tusClient.pauseUpload()`

### Resuming upload
For resuming a previously paused upload to take place you should have set a `cache` to the `TusClient` constructor you used when started upload.
Resuming an upload can be made in two ways:
- By calling `tusClient.startUpload(...)` again. Take into account by calling `startUpload(...)` again you will lose the reference to the previous callbacks you set in the first call to `startUpload(...)` before the pause. Here you should set the callbacks again as well.
- By calling `tusClient.resumeUpload()`. With this function `resumeUpload()` the the upload is resumed and the callbacks you set in the first call to `startUpload(...)` before pause are used to notify.
