# A tus client 

[![Pub Version](https://img.shields.io/pub/v/tusc)](https://pub.dev/packages/tusc)

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
import 'package:tusc/tusc.dart';
import 'package:cross_file/cross_file.dart' show XFile;
import 'package:http/http.dart' as http;

void main() async {
  /// File to be uploaded
  final file = XFile('/path/to/some/video.mp4');
  final tusServerURL = 'https://master.tus.io/files';

  /// Initialize a TusClient instance from a XFile
  final tusClient = initTusClient(file, tusServerURL);
  handleClient(tusClient);

  /// Initialize a TusStreamClient instance from a Stream generator function
  /// This is useful when you want to upload a file from a stream.
  /// The only difference is that this client doesn't rely on a file but rather
  /// on a stream of bytes. It's intended for cases where the file is excessively
  /// large.
  final tusStreamClient = await initTusStreamClient(file, tusServerURL);
  handleClient(tusStreamClient);
}

TusBaseClient initTusClient(XFile file, String tusServerURL) => TusClient(
  /// Required if [uploadUrl] is not provided.
  /// The base URL of the tus server. A POST request will be sent here to create a new upload.
  url: tusServerURL,
  /// Required if [url] is not provided.
  /// Use this to skip the upload creation step and resume directly from a known upload URL
  /// (e.g. obtained from a previous session or stored externally). No cache needed.
  uploadUrl: 'https://master.tus.io/files/my-upload-id',
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

Future<TusBaseClient> initTusStreamClient(XFile file, String tusServerURL) async => TusStreamClient(
  /// Required if [uploadUrl] is not provided.
  /// The base URL of the tus server. A POST request will be sent here to create a new upload.
  url: tusServerURL,
  /// Required if [url] is not provided.
  /// Use this to skip the upload creation step and resume directly from a known upload URL
  /// (e.g. obtained from a previous session or stored externally). No cache needed.
  uploadUrl: 'https://master.tus.io/files/my-upload-id',
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
```

### Chunk size
The file is uploaded in chunks. Default size is 256KB. This should be set considering **speed of upload** and **device memory constraints**.
For specifying the `chunkSize` you can easily set it like `512.KB` or `10.MB` and this will use an int extension under the hook to calculate the amount in bytes.  

```dart
final tusClient = TusClient(
    tusServerURL,
    file,
    chunkSize: 10.MB,
);
```

### Upload callbacks
When you call `tusClient.startUpload(...)` you optionally can set some callbacks:
- `onProgress: (count, total, progress)`: This callback notifies about the upload progress. It provides `count` which is the amount of data already uploaded, `total` the amount of data to be uploaded and `response` which is the http response of the last `chunkSize` uploaded. With this response you can check for headers or body in case your tus server returns some info there.
- `onComplete: (response)`: This callback notifies the upload has completed. It provides a `response` which is the http response of the last `chunkSize` uploaded. With this response you can check for headers or body in case your tus server returns some info there.
- `onTimeout: ()`: This callback notifies the upload timed out according to the `timeout` property specified in the `TusClient` constructor which by default is 30 seconds.
- `onError: (error)`: This callback notifies the upload has failed. It provides an `error` which is a `ProtocolException` with a `message` description and the http `response` from the failed request. If this callback is omitted then the `startUpload` will throw `ProtocolException` on failure.   
  
### Cache
For `TusClient` to manage `pause/resume` uploads you can set a `cache` by using:
- `TusMemoryCache`: with this cache you can `pause/resume` uploads while your app is running. If your app crashes or simply closes you will not be able to resume a pending upload.
- `TusPersistentCache`: with this cache you can `pause/resume` uploads any time, no matter if your app crashes, closes or even your device restarts.

> **Note:** If you already know the upload URL from a previous session (e.g. you stored it yourself), you can pass it via `uploadUrl` in the constructor and skip the cache entirely. See [Resuming with uploadUrl](#resuming-with-uploadurl).

```dart
final tusClient = TusClient(
    tusServerURL,
    file,
    cache: TusMemoryCache(),
);
```
or
```dart
final tusClient = TusClient(
    tusServerURL,
    file,
    cache: TusPersistentCache('/some/path'),
);
```
Note that `TusPersistentCache` requires a path, this path will be where the cache storage will take place. This persistent cache implementation works in pure dart so, no matter if you want to use it in a `flutter` project or a `dart` project, it simply works.

### Fingerprints

The cache stores upload URLs keyed by a **fingerprint**, produced by `generateFingerprint()`. Resuming works only if the client that resumes produces the *same* fingerprint as the client that started the upload, so the fingerprint must be:

- **Stable** for the same file and destination across attempts, app restarts and crashes. A fingerprint that changes between attempts never hits the cache, so every attempt creates a new upload on the server and restarts from `0`.
- **Unique** per file and destination. Two different files sharing a fingerprint make the second one resume into the first one's upload, corrupting it.

The default is built from the creation `url`, the file name and the file size:

```dart
'$url${fileName != null ? '_$fileName' : ''}_$fileSize'
```

> ⚠️ **One-time or pre-signed creation URLs break the default.** If your `url` embeds a per-request token — a [Cloudflare Stream direct upload URL](https://developers.cloudflare.com/stream/uploading-videos/direct-creator-uploads/) is the typical case — you request a new one on every attempt, so the fingerprint changes with it and the cache can never hit. Override `generateFingerprint()` with something derived from the file plus whatever identifies the destination in your own domain:

```dart
class MyTusClient extends TusClient {
  MyTusClient({
    required this.videoId,
    required super.file,
    super.url,
    super.cache,
  });

  final String videoId;

  @override
  String generateFingerprint() => 'video_${videoId}_${file.path}';
}
```

Also note the default says nothing about the file *contents*: a file edited in place that keeps its name and size keeps its fingerprint too. Include a content hash or a last modified timestamp if that can happen in your app.

As a backstop, the client compares the server's `Upload-Length` against the size of the file being uploaded when it resumes. If they differ, the cached upload belongs to a different file, so it is dropped and a new upload is created rather than corrupting the other one.

If the server no longer knows the cached upload URL — it expired or was swept — the client drops the stale entry and creates a new upload instead of failing, as long as it was given a creation `url` to do so.

### How to set persistent cache in flutter
You can use [path_provider](https://pub.dev/packages/path_provider) plugin to be able to get the path to a directory where your app has permissions to write.
[path_provider](https://pub.dev/packages/path_provider) works on most platforms except on web, but this is not a problem, the `TusPersistentCache` takes care of it, you just need to set a `path` and if app is running on web `TusPersistentCache` ignores that `path` and handles the persistent cache under the hook. 

The following sample code works on any platform.
```dart
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

Future<void> sample() async {
  Directory dir = kIsWeb ? Directory.systemTemp : await getApplicationDocumentsDirectory();

  final tusClient = TusClient(
    tusServerURL,
    file,
    cache: TusPersistentCache(dir.path),
  );
}

```

### Progress reporting

`onProgress` is called while a chunk is being sent, not only once it lands. A chunk goes out as a stream of slices of `progressSliceSize` bytes — 64 KB by default — and each slice handed to the network produces a report. With a 50 MB `chunkSize` that is roughly 800 reports spread across the transfer instead of one at the end, so a progress bar actually moves.

```dart
final tusClient = TusClient(
  url: tusServerURL,
  file: file,
  chunkSize: 50.MB,
  /// Optional, defaults to 64 KB. Set it to chunkSize or more for one report per chunk.
  progressSliceSize: 256.KB,
);
```

Two things follow from this:

- `count` is bytes **sent**, not bytes the server has acknowledged. If a chunk fails on the way it is reported as sent, and then reported again at its real value once the offset has been read back from the server — so `count` can go backwards after a failure. That is the honest picture of a retry.
- `response` is `null` for the reports made while a chunk is in flight. It is non-null only on the report that follows the server confirming the chunk.

On web the whole request body is buffered before it is issued, so the reports all arrive up front rather than spread over the transfer. Native platforms stream the body, which is where this pays off.

### Retrying

A request that fails on a transport error — a dropped connection, DNS, TLS — or because the server responded `408`, `429` or a `5xx`, is retried according to `retryDelays`. The default is three retries, after 1, 3 and 5 seconds:

```dart
final tusClient = TusClient(
  url: tusServerURL,
  file: file,
  /// Optional. Defaults to [1s, 3s, 5s]. Pass an empty list to fail on the first error.
  retryDelays: const [Duration(seconds: 2), Duration(seconds: 10)],
);
```

Each retry re-reads the offset from the server before sending anything, so a chunk that landed just before the failure is never sent twice. A `4xx` other than those above is not retried — asking again will not change the answer.

`pauseUpload()` and `cancelUpload()` stop retrying. If the request in flight fails right as you stop the upload, that failure is neither retried nor reported: you already asked it to stop.

`TusStreamClient` cannot read its stream backwards, so a retry calls `fileStreamGenerator` again and reads forward to the server's offset. A stream that cannot be recreated therefore cannot be retried; see [`fileStreamGenerator`](#tus-stream-client) for the options there.

### Releasing the client

`close()` disposes of the `http.Client` the client created for itself. One passed in through `httpClient` belongs to you and is left open.

```dart
tusClient.close();
```

It does not stop a running upload — pause or cancel first, and await the future of the running `startUpload(...)`.

### Pausing upload
Pausing upload can be done after current uploading chunk is completed.
Just by calling: `tusClient.pauseUpload()`

The upload is flagged as paused right away, so it stops even if no request happens to be in flight at that moment. The chunk already in flight is not aborted, it still lands on the server, and the returned future — `null` when nothing is in flight — completes as soon as that request is given up on, without waiting for it.

### Cancelling upload
Cancelling upload can be done after current uploading chunk is completed.
Just by calling: `tusClient.cancelUpload()`

Cancelling **abandons** the upload rather than just stopping it: its cache entry is dropped and so is its upload URL, so a later `startUpload(...)` or `resumeUpload()` creates a new upload on the server and starts over from the beginning. Await the returned future if you need the cache entry to be gone before you move on.

A client built from an explicit `uploadUrl` has no creation `url` to POST to, so it has no new upload to fall back on. Cancelling such a client only stops it, and a later resume continues the same upload.

### Resuming upload
For resuming a previously paused upload to take place you should have set a `cache` to the `TusClient` constructor you used when started upload.
Resuming an upload can be made in two ways:
- By calling `tusClient.startUpload(...)` again. Take into account by calling `startUpload(...)` again you will lose the reference to the previous callbacks you set in the first call to `startUpload(...)` before the pause. Here you should set the callbacks again as well.
- By calling `tusClient.resumeUpload()`. With this function `resumeUpload()` the upload is resumed and the callbacks you set in the first call to `startUpload(...)` before pause are used to notify. Note that if you resume an upload previously cancelled, the upload will start from the beginning, since cancelling abandons the upload — unless the client has no creation `url`, as described in [Cancelling upload](#cancelling-upload).

Both `startUpload(...)` and `resumeUpload()` return a future that completes when the upload itself finishes — that is, when it completes, is paused, or is cancelled. Awaiting one of them therefore waits for the whole upload, not just for it to get going.

### Resuming with `uploadUrl`
If you stored the upload URL externally (e.g. in a database or shared preferences) you can pass it directly via `uploadUrl` when constructing the client. This lets the client skip the upload creation step and resume from exactly where the previous session left off — no `cache` required.

```dart
// Save the upload URL after starting an upload
final savedUploadUrl = tusClient.uploadUrl;

// Later — in a new session — resume by passing uploadUrl directly
final tusClient = TusClient(
  uploadUrl: savedUploadUrl,   // resumes from the known URL; no POST is sent to the server
  file: XFile('/path/to/some/video.mp4'),
);
tusClient.startUpload(...);
```

The same applies to `TusStreamClient`:

```dart
final tusStreamClient = TusStreamClient(
  uploadUrl: savedUploadUrl,
  fileStreamGenerator: () => file.openRead(),
  fileSize: await file.length(),
  fileName: file.name,
);
tusStreamClient.startUpload(...);
```

> **Note:** `url` and `uploadUrl` are mutually exclusive — you must provide exactly one of them.