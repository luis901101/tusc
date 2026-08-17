import 'dart:async';
import 'dart:math' show min;
import 'dart:typed_data' show Uint8List;

import 'package:http/http.dart' as http;
import 'package:tusc/src/cache.dart';
import 'package:tusc/src/exceptions.dart';
import 'package:tusc/src/tus_upload_state.dart';
import 'package:tusc/src/utils/header_utils.dart';
import 'package:tusc/src/utils/http_status.dart';
import 'package:tusc/src/utils/map_utils.dart';
import 'package:tusc/src/utils/num_utils.dart';

/// Callback to listen the progress for sending data.
/// [count] the length of the bytes that have been sent.
/// [total] the content length.
///
/// This is called while a chunk is still being sent, every
/// [TusBaseClient.progressSliceSize] bytes, and again with the [response] of
/// the request once the server has confirmed the chunk.
///
/// [count] is therefore bytes *sent*, not bytes the server has acknowledged.
/// A chunk that fails on the way is reported as sent and then, once the offset
/// has been read back from the server, reported again at its confirmed value,
/// so [count] can go backwards after a failure. [response] is `null` for the
/// reports made while a chunk is in flight.
typedef ProgressCallback =
    void Function(int count, int total, http.Response? response);

/// Callback to listen when upload finishes
typedef CompleteCallback = void Function(http.Response response);

/// Callback to listen when upload fails
typedef ErrorCallback = void Function(ProtocolException error);

/// A base client for the [tus](https://tus.io) resumable upload protocol.
///
/// Provides core functionality for uploading files in chunks, supporting
/// pause, resume, and cancellation of uploads.
///
/// ## Setup
///
/// To create a new upload, provide the [url] of the tus server. The client
/// will send a `POST` request to this URL to create the upload and obtain
/// an upload URL from the server:
///
/// ```dart
/// final client = MyTusClient(
///   url: 'https://example.com/files',
/// );
/// ```
///
/// To resume an existing upload without creating a new one on the server,
/// provide the [uploadUrl] obtained from a previous session. In this case,
/// [url] is not required:
///
/// ```dart
/// final client = MyTusClient(
///   uploadUrl: 'https://example.com/files/my-upload-id',
/// );
/// ```
///
/// ## Resuming uploads
///
/// To enable pause/resume support across sessions, provide a [TusCache]
/// implementation. The client will store and retrieve upload URLs using
/// the file fingerprint as the key:
///
/// ```dart
/// final client = MyTusClient(
///   url: 'https://example.com/files',
///   cache: TusPersistentCache(),
/// );
/// ```
///
/// The cache is keyed by [generateFingerprint], so resuming across sessions
/// only works if the next client instance produces the very same fingerprint
/// for the same file. Read [generateFingerprint] before relying on this,
/// especially if [url] is a one-time or pre-signed creation URL.
abstract class TusBaseClient {
  /// The base URL of the tus server where uploads will be created.
  /// This is used to send POST requests to create new uploads.
  ///
  /// If you already have an upload URL from a previous session, pass it via
  /// [uploadUrl] in the constructor to skip the upload creation step and resume
  /// directly from where it left off. This is particularly useful for resuming
  /// interrupted uploads without needing to create a new upload on the server.
  final String url;

  /// The tus protocol version you want to use
  /// Default value: 1.0.0
  final String tusVersion;

  /// Storage used to save and retrieve upload URLs by its fingerprint.
  /// This is required if you need to pause/resume uploads.
  final TusCache? cache;

  /// Metadata for specific upload server
  final Map<String, dynamic>? metadata;

  /// Any additional headers
  final Map<String, String> headers;

  /// The size in bytes when uploading the file in chunks
  /// Default value: 256 KB
  final int chunkSize;

  /// How much of a chunk is handed to the network at a time, and with it how
  /// often [ProgressCallback] is called while that chunk is in flight.
  /// Default value: 64 KB
  ///
  /// A chunk is sent as a stream of slices this size, so a 50 MB [chunkSize]
  /// reports progress roughly 800 times on the way instead of once at the end.
  /// Set it to [chunkSize] or more to go back to a single report per chunk.
  ///
  /// Note this counts bytes handed to the platform's http client, which is as
  /// close to the wire as dart gets. On web the whole body is buffered before
  /// the request is issued, so the reports all arrive up front rather than
  /// spread over the transfer.
  final int progressSliceSize;

  /// Timeout duration for tus server requests
  /// Default value: 30 seconds
  final Duration timeout;

  /// How long to wait before each retry of a failed request.
  ///
  /// A request that fails because of a transport error, such as a connection
  /// reset, or because the server responded 408, 429 or a 5xx, is tried again
  /// after the next delay in this list. Every retry re-reads the offset from
  /// the server first, so a chunk that landed just before the failure is not
  /// sent twice.
  ///
  /// The length of the list is the number of retries. The default retries three
  /// times, after 1, 3 and 5 seconds. Pass an empty list to fail on the first
  /// error instead.
  ///
  /// [pauseUpload] and [cancelUpload] stop retrying: the caller asked the
  /// upload to stop, so the failure of the request that was in flight is not
  /// retried and not reported either.
  final List<Duration> retryDelays;

  /// Set this if you need to use a custom http client.
  ///
  /// A client passed in here belongs to the caller, so [close] leaves it alone.
  /// When none is given one is created internally and [close] disposes of it.
  final http.Client httpClient;

  /// Whether [httpClient] was created here rather than supplied by the caller,
  /// and is therefore this client's to close.
  final bool _ownsHttpClient;

  /// The size of the file being uploaded, as reported by [fileSize].
  ///
  /// Note subclasses declare their own private `_fileSize` field, which is a
  /// genuinely different field since dart privacy is per library, not per
  /// class. This one is the one [generateFingerprint] reads, and it is
  /// populated by awaiting [fileSize].
  int _fileSize = 0;
  String _fingerprint = '';
  String _uploadMetadata = '';
  Uri _uploadURI = Uri();
  int _offset = 0;

  /// Set by [cancelUpload] and consumed by the next [_upload]. A cancelled
  /// upload is abandoned, so the attempt that follows must not resume it.
  bool _uploadCancelled = false;

  /// The state the caller asked this upload to stop in, set by [pauseUpload]
  /// and [cancelUpload] and cleared by [startUpload].
  ///
  /// Kept apart from [_state] because a failing request overwrites the state
  /// with [TusUploadState.error], which would otherwise hide the fact that a
  /// stop was asked for and let a retry carry the upload on regardless.
  TusUploadState? _requestedStop;

  /// The upload currently running, used to reject a second concurrent one.
  Future<void>? _activeUpload;
  TusUploadState _state;
  Future? _uploadFuture;
  ProgressCallback? _onProgress;
  CompleteCallback? _onComplete;
  ErrorCallback? _onError;
  Function()? _onTimeout;
  String? _errorMessage;

  TusBaseClient({
    String? url,
    String? uploadUrl,
    int? chunkSize,
    int? progressSliceSize,
    this.tusVersion = Headers.defaultTusVersion,
    this.cache,
    Map<String, dynamic>? headers,
    this.metadata,
    Duration? timeout,
    List<Duration>? retryDelays,
    http.Client? httpClient,
  }) : url = url ?? '',
       _uploadURI = uploadUrl != null
           ? Uri.tryParse(uploadUrl) ?? Uri()
           : Uri(),
       chunkSize = chunkSize ?? 256.KB,
       progressSliceSize = progressSliceSize ?? 64.KB,
       headers = headers?.parseToMapString ?? {},
       timeout = timeout ?? const Duration(seconds: 30),
       retryDelays = retryDelays ?? defaultRetryDelays,
       httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null,
       _state = TusUploadState.notStarted,
       assert(
         (url != null && url.isNotEmpty) ||
             (uploadUrl != null && uploadUrl.isNotEmpty),
         'Either url or uploadUrl must be provided',
       ),
       assert(
         chunkSize == null || chunkSize > 0,
         'chunkSize must be greater than 0',
       ),
       assert(
         progressSliceSize == null || progressSliceSize > 0,
         'progressSliceSize must be greater than 0',
       );

  /// The [retryDelays] used when none are given: three retries, after 1, 3 and
  /// 5 seconds.
  static const defaultRetryDelays = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 3),
    Duration(seconds: 5),
  ];

  /// Get the upload state
  TusUploadState get state => _state;

  /// The number of bytes the server has confirmed for this upload.
  ///
  /// Maintained from what the server reports, so a chunk that never landed does
  /// not count towards it. [getData] reads it to know where to read from, and
  /// must not change it.
  int get offset => _offset;

  /// Get the error message in case of any error
  String? get errorMessage => _errorMessage;

  /// Whether the client supports resuming
  bool get resumingEnabled => cache != null;

  /// The URI on the server for the file
  String get uploadUrl => _uploadURI.toString();

  /// The fingerprint of the file being uploaded
  String get fingerprint => _fingerprint;

  /// The uploadMetadataHeaderKey header sent to server
  String get uploadMetadata => _uploadMetadata;

  Future<int> get fileSize;
  String? get fileName;

  /// Create a new [startUpload] throwing [ProtocolException] on server error
  Future<void> createUpload() async {
    _fileSize = await fileSize;
    _fingerprint = generateFingerprint();
    _uploadMetadata = generateMetadata();

    if (uploadUrl.isEmpty) {
      final createHeaders = {
        ...headers,
        Headers.tusResumableHeader: tusVersion,
        Headers.uploadMetadataHeader: _uploadMetadata,
        Headers.uploadLengthHeader: '$_fileSize',
      };

      final response = await httpClient.post(
        Uri.parse(url),
        headers: createHeaders,
      );

      if (!(response.statusCode >= 200 && response.statusCode < 300)) {
        _state = TusUploadState.error;
        throw ProtocolException(
          _errorMessage =
              'Unexpected status code (${response.statusCode}) while creating upload',
          response,
        );
      }

      String locationURL = response.headers[Headers.location]?.toString() ?? '';
      if (locationURL.isEmpty) {
        _state = TusUploadState.error;
        throw ProtocolException(
          _errorMessage = 'Missing upload URL in response for creating upload',
          response,
        );
      }

      _uploadURI = parseToURI(locationURL);
    }
    // Awaited on purpose. The mapping has to be durable before the first chunk
    // is sent, otherwise a crash right after that chunk lands on the server
    // leaves an upload that can never be resumed, which is precisely the
    // scenario this cache exists for.
    await cache?.set(_fingerprint, _uploadURI.toString());
    _state = TusUploadState.created;
  }

  /// Check if it's possible to resume an already started upload.
  ///
  /// Returns `true` when an upload URL is already known, either because it was
  /// supplied through the `uploadUrl` constructor parameter or because [cache]
  /// holds one for the current [fingerprint].
  ///
  /// Resuming requires a [cache], so this returns `false` when none was
  /// provided, even if an upload URL is already known.
  ///
  /// Note this is not a pure predicate. When no upload URL is known yet, the
  /// one cached for the current [fingerprint], if any, is adopted as this
  /// client's [uploadUrl]. That side effect is what makes the following
  /// [startUpload] resume instead of creating a new upload on the server.
  ///
  /// The lookup key is [fingerprint], so this is only meaningful once
  /// [generateFingerprint] has run against the current file size.
  /// [startUpload] takes care of that before calling this.
  Future<bool> canResume() async {
    if (!resumingEnabled) return false;

    if (uploadUrl.isEmpty) await _restoreUploadUrlFromCache();

    return uploadUrl.isNotEmpty;
  }

  /// Adopts the upload URL [cache] holds for the current [fingerprint], if any.
  Future<void> _restoreUploadUrlFromCache() async {
    _uploadURI = Uri.parse(await cache?.get(_fingerprint) ?? '');
  }

  void _notifyError(ProtocolException error) {
    if (_onError != null) {
      _onError!(error);
    } else {
      throw error;
    }
  }

  Future<void> _upload() async {
    try {
      _errorMessage = null;
      _fileSize = await fileSize;

      // The fingerprint is the key this upload is stored under in [cache], so
      // it has to be computed before [canResume] does the lookup. Otherwise a
      // freshly built client would look the upload up under the fingerprint of
      // an empty file, always miss, and start over from offset 0.
      // [generateFingerprint] needs the file size, which is resolved above.
      _fingerprint = generateFingerprint();

      // A cancelled upload is abandoned, so this attempt has to start a new one
      // instead of resuming it. The upload URL is dropped here and not in
      // [cancelUpload] because the chunk loop may still be running when the
      // cancellation arrives, and pulling the URL from under it would send the
      // chunk in flight nowhere.
      if (_uploadCancelled) {
        _uploadCancelled = false;
        // With no creation url there is no new upload to fall back on, so the
        // cancelled one is kept and cancelling only stops it.
        if (url.isNotEmpty) {
          _uploadURI = Uri();
          _offset = 0;
        }
      }

      if (!await canResume()) {
        await createUpload();
      }

      http.Response? response;
      for (var attempt = 0; ; attempt++) {
        try {
          response = await _uploadChunks();
          break;
        } on Exception catch (e) {
          // A pause or cancel was asked for, so this attempt is over either
          // way and what the last request did is no longer worth reporting.
          final requestedStop = _requestedStop;
          if (requestedStop != null) {
            _state = requestedStop;
            _errorMessage = null;
            break;
          }
          if (!_shouldRetry(e, attempt)) rethrow;
          _errorMessage = null;
          await Future.delayed(retryDelays[attempt]);
          // The failed attempt may have read bytes that never reached the
          // server, and the next one restarts from the offset the server
          // confirms, so the source has to be able to go back there.
          await resetSource();
        }
      }

      // Update upload progress
      _onProgress?.call(_offset, _fileSize, response);

      if (_offset == _fileSize) {
        // Upload completed
        _state = TusUploadState.completed;
        // Awaited so the entry is really gone before the caller is notified and
        // before this future completes, otherwise a process that exits right
        // after completion can leave a mapping to an already finished upload.
        await cache?.remove(_fingerprint);
        _onComplete?.call(response ?? http.Response('', HttpStatus.ok));
      }
    } on ProtocolException catch (e) {
      _notifyError(e);
    } catch (e) {
      rethrow;
    }
  }

  /// Re-reads the offset from the server and sends chunks from there until the
  /// file is done, or until the upload is paused or cancelled. Returns the last
  /// response received, or `null` when no chunk had to be sent.
  ///
  /// Every retry runs this again from the top, so the offset is always taken
  /// from the server rather than assumed from the failed attempt.
  Future<http.Response?> _uploadChunks() async {
    _offset = await _resolveOffset();

    // Cache the mapping on every path that gets this far, not just on newly
    // created uploads. A client built from an explicit `uploadUrl` never
    // reaches [createUpload]'s creation branch, yet its upload URL is just as
    // worth resuming from in a later session. Skipped when the upload was
    // cancelled while the offset was being resolved, so the entry
    // [cancelUpload] just removed does not come straight back.
    if (_state != TusUploadState.cancelled) {
      await cache?.set(_fingerprint, uploadUrl);
    }

    http.Response? response;

    final uploadHeaders = {
      ...headers,
      Headers.tusResumableHeader: tusVersion,
      Headers.uploadOffsetHeader: '$_offset',
      Headers.contentType: Headers.contentTypeOffsetOctetStream,
    };

    // Start upload
    _state = TusUploadState.uploading;
    while (_state != TusUploadState.paused &&
        _state != TusUploadState.cancelled &&
        _offset < _fileSize) {
      _state = TusUploadState.uploading;
      // Update upload progress
      _onProgress?.call(_offset, _fileSize, response);

      uploadHeaders[Headers.uploadOffsetHeader] = '$_offset';

      final chunk = await getData();
      if (chunk.isEmpty) {
        // The source is shorter than the file size it reported. Stopping here
        // silently would leave a half uploaded file and report success.
        _state = TusUploadState.error;
        throw ProtocolException(
          _errorMessage =
              'The upload source ran out of data at offset $_offset, but '
              '$_fileSize bytes were expected',
        );
      }

      // Captured before the request goes out, so the reports made on the way
      // are absolute file offsets rather than offsets within the chunk.
      final chunkStart = _offset;
      final request = _ChunkUploadRequest(
        _uploadURI,
        body: chunk,
        sliceSize: progressSliceSize,
        onBytesSent: (bytesSent) =>
            _onProgress?.call(chunkStart + bytesSent, _fileSize, null),
      )..headers.addAll(uploadHeaders);

      try {
        _uploadFuture = httpClient.send(request).then(http.Response.fromStream);
        response = await _uploadFuture?.timeout(
          timeout,
          onTimeout: () {
            _onTimeout?.call();
            return http.Response(
              '',
              HttpStatus.requestTimeout,
              reasonPhrase: 'Request timeout',
            );
          },
        );
      } finally {
        // Cleared even when the request fails, so that [pauseUpload] and
        // [cancelUpload] never wait on, and rethrow the error of, a request
        // that is long gone.
        _uploadFuture = null;
      }

      // Check if correctly uploaded
      if (!(response!.statusCode >= 200 && response.statusCode < 300)) {
        _state = TusUploadState.error;
        throw ProtocolException(
          _errorMessage =
              'Unexpected status code (${response.statusCode}) while uploading chunk',
          response,
        );
      }

      int? serverOffset = _parseHeaderInt(
        response.headers[Headers.uploadOffsetHeader],
      );
      if (serverOffset == null) {
        _state = TusUploadState.error;
        throw ProtocolException(
          _errorMessage =
              'Response to PATCH request contains no or invalid Upload-Offset header',
          response,
        );
      }
      final expectedOffset = _offset + chunk.length;
      if (expectedOffset != serverOffset) {
        _state = TusUploadState.error;
        throw ProtocolException(
          _errorMessage =
              'Response contains different Upload-Offset value ($serverOffset) than expected ($expectedOffset)',
          response,
        );
      }
      _offset = serverOffset;
    }
    return response;
  }

  /// Status codes worth trying again: the server could not take the chunk right
  /// now, rather than refusing it outright.
  static const _retryableStatusCodes = <int>{
    HttpStatus.requestTimeout,
    HttpStatus.tooManyRequests,
    HttpStatus.internalServerError,
    HttpStatus.badGateway,
    HttpStatus.serviceUnavailable,
    HttpStatus.gatewayTimeout,
  };

  /// Whether [error], hit on the given zero based [attempt], is worth retrying.
  bool _shouldRetry(Exception error, int attempt) {
    if (attempt >= retryDelays.length) return false;
    // Transport failures: connection reset, DNS, TLS and the like. package:http
    // funnels all of them through ClientException, which keeps this working on
    // web too, where dart:io types do not exist.
    if (error is http.ClientException) return true;
    if (error is ProtocolException) {
      return _retryableStatusCodes.contains(error.statusCode);
    }
    return false;
  }

  /// Called before a failed attempt is retried, so a source that cannot be read
  /// backwards can start over.
  ///
  /// A chunk handed out by [getData] may never have reached the server, and the
  /// retry picks up from the offset the server confirms, which can be behind
  /// what the source has already read. A random access source such as a file
  /// needs nothing here, which is why this does nothing by default.
  Future<void> resetSource() async {}

  /// Starts or resumes an upload in chunks of [chunkSize].
  /// If [onError] is specified all errors will be notified through the callback
  /// otherwise it will throw a [ProtocolException] on server error.
  Future<void> startUpload({
    /// Callback to notify about the upload progress. It provides [count] which
    /// is the amount of data already uploaded, [total] the amount of data to be
    /// uploaded and [response] which is the http response of the last
    /// [chunkSize] uploaded.
    ProgressCallback? onProgress,

    /// Callback to notify the upload has completed. It provides a [response]
    /// which is the http response of the last [chunkSize] uploaded.
    CompleteCallback? onComplete,

    /// Callback to notify the upload has failed. It provides an [error]
    /// which is a [ProtocolException] with a [message] description and the
    /// http [response] from the failed request.
    ErrorCallback? onError,

    /// Callback to notify the upload timed out according to the [timeout]
    /// property specified in the [TusBaseClient] constructor which by default is
    /// 30 seconds
    Function()? onTimeout,
  }) async {
    // Two upload loops on one client share the same offset and the same in
    // flight request, which desynchronizes both from the server.
    if (_activeUpload != null) {
      throw StateError(
        'An upload is already running on this client. Await the future of the '
        'previous startUpload() or resumeUpload(), or pause or cancel it, '
        'before starting another one.',
      );
    }
    _onProgress = onProgress;
    _onComplete = onComplete;
    _onError = onError;
    _onTimeout = onTimeout;
    _requestedStop = null;
    _state = TusUploadState.uploading;

    // Assigned before the first suspension, so a second call made right after
    // this one returns already sees an upload in progress.
    final upload = _upload();
    _activeUpload = upload;
    try {
      await upload;
    } finally {
      _activeUpload = null;
    }
  }

  /// Resumes an upload where it left of. This function calls [upload()]
  /// using the same callbacks used last time [upload()] was called.
  /// Throws [ProtocolException] on server error
  Future<void> resumeUpload() => startUpload(
    onProgress: _onProgress,
    onComplete: _onComplete,
    onError: _onError,
    onTimeout: _onTimeout,
  );

  /// Pause the current upload.
  ///
  /// The upload is flagged as paused straight away, so the chunk loop stops
  /// even when no request happens to be in flight at that moment. A following
  /// [resumeUpload] picks up from the offset the server reports.
  ///
  /// The returned future, when a request is in flight, completes as soon as
  /// that request is given up on, without waiting for its chunk to land. It is
  /// `null` when nothing is in flight, and when the upload has already
  /// completed, in which case there is nothing to pause and the upload is left
  /// alone.
  Future? pauseUpload() {
    if (_state == TusUploadState.completed) return null;
    // Set here rather than from the timeout callback below: that callback only
    // runs if the timer wins the race against the request in flight, and does
    // not run at all when there is no request to time out.
    _requestedStop = TusUploadState.paused;
    _state = TusUploadState.paused;
    final pausedResponse = http.Response(
      '',
      HttpStatus.ok,
      reasonPhrase: 'Upload request paused',
    );
    // A failure of the request in flight is the running upload's to report, not
    // this one's, so it is not allowed to escape through here.
    return _uploadFuture
        ?.timeout(Duration.zero, onTimeout: () => pausedResponse)
        .catchError((_) => pausedResponse);
  }

  /// Cancel the current upload.
  ///
  /// Cancelling abandons the upload rather than just stopping it: its [cache]
  /// entry is dropped and so is its upload URL, so a following [startUpload] or
  /// [resumeUpload] creates a new upload on the server and starts over from the
  /// beginning.
  ///
  /// A client built from an explicit `uploadUrl`, with no creation [url] to
  /// POST to, has no new upload to fall back on. Cancelling such a client only
  /// stops it, and a later resume continues the same upload.
  ///
  /// The upload is flagged as cancelled straight away, so the chunk loop stops
  /// even when no request happens to be in flight at that moment. Note the
  /// chunk already in flight is not aborted, it still lands on the server.
  ///
  /// The returned future completes once the cancellation has been recorded,
  /// [cache] removal included, so awaiting it is what guarantees the entry is
  /// really gone. It is `null` when the upload has already completed, in which
  /// case there is nothing to cancel and the upload is left alone.
  Future? cancelUpload() {
    if (_state == TusUploadState.completed) return null;
    _requestedStop = TusUploadState.cancelled;
    _state = TusUploadState.cancelled;
    _uploadCancelled = true;
    return _recordCancellation();
  }

  Future<http.Response> _recordCancellation() async {
    final cancelledResponse = http.Response(
      '',
      HttpStatus.ok,
      reasonPhrase: 'Upload request cancelled',
    );
    // Awaited so that awaiting the returned future guarantees the entry is
    // gone, instead of racing a process exit against the cache write.
    await cache?.remove(_fingerprint);
    // A failure of the request in flight is the running upload's to report, not
    // this one's, so it is not allowed to escape through here.
    final inFlightResponse = await _uploadFuture
        ?.timeout(Duration.zero, onTimeout: () => cancelledResponse)
        .catchError((_) => cancelledResponse);
    return inFlightResponse is http.Response
        ? inFlightResponse
        : cancelledResponse;
  }

  /// Builds the key this upload is stored under in [cache].
  /// Override this method to customize creating the file fingerprint.
  ///
  /// The fingerprint is what makes resuming possible, so it must be:
  ///
  /// - **Stable** for the same file and the same destination across attempts,
  ///   app restarts and process crashes. A fingerprint that changes between
  ///   attempts can never hit the cache, so every attempt creates a brand new
  ///   upload on the server and restarts from offset 0.
  /// - **Unique** per file and destination. Two different files sharing a
  ///   fingerprint make the second one resume into the first one's upload,
  ///   which produces a corrupt file on the server.
  ///
  /// The default is built from [url], [fileName] and the file size, which is
  /// stable only as long as the creation [url] itself is stable.
  ///
  /// ⚠️ It is **not** stable for one-time or pre-signed creation URLs, such as
  /// a Cloudflare Stream direct upload URL, which embeds a per-request token.
  /// A new creation URL is requested on every attempt, so the default
  /// fingerprint changes with it and the cache can never hit. Overriding this
  /// method is the escape hatch. Derive the fingerprint from the file itself
  /// plus whatever identifies the destination in your own domain:
  ///
  /// ```dart
  /// class MyTusClient extends TusClient {
  ///   MyTusClient({
  ///     required this.videoId,
  ///     required super.file,
  ///     super.url,
  ///     super.cache,
  ///   });
  ///
  ///   final String videoId;
  ///
  ///   @override
  ///   String generateFingerprint() => 'video_${videoId}_${file.path}';
  /// }
  /// ```
  ///
  /// Note the default says nothing about the file contents, so a file edited in
  /// place that keeps its name and size keeps its fingerprint too. Include a
  /// content hash or a last modified timestamp if that is a possibility in your
  /// app.
  ///
  /// Called by [startUpload] and [createUpload] once the file size is known.
  String generateFingerprint() =>
      '$url${fileName != null ? '_$fileName' : ''}_$_fileSize'.replaceAll(
        RegExp(r'\W+'),
        '.',
      );

  /// Override this to customize the header 'Upload-Metadata'
  String generateMetadata() {
    // A copy, so that the caller's [metadata] is neither modified behind their
    // back nor required to be modifiable in the first place.
    final meta = <String, dynamic>{...?metadata};

    if (!meta.containsKey('filename') && fileName != null) {
      meta['filename'] = fileName!;
    }

    return meta.parseToMetadata;
  }

  /// Releases the resources held by this client.
  ///
  /// Closes [httpClient] when it was created by this client. One passed in
  /// through the constructor belongs to the caller and is left open, since it
  /// may still be in use elsewhere.
  ///
  /// This does not stop a running upload. Call [pauseUpload] or [cancelUpload],
  /// and await the future of the running [startUpload], before closing.
  void close() {
    if (_ownsHttpClient) httpClient.close();
  }

  /// Status codes that mean the upload URL is no longer usable: the server
  /// either never knew it, has already swept it, or no longer grants access to
  /// it. In every case there is nothing left to resume from.
  static const _staleUploadUrlStatusCodes = <int>{
    HttpStatus.forbidden,
    HttpStatus.notFound,
    HttpStatus.gone,
  };

  /// Gets the current offset from the server, recovering from an upload URL
  /// that cannot be used for this file.
  ///
  /// A cached upload URL, or one created in a previous session, can expire or
  /// be swept server side, in which case the HEAD request in [_getUploadState]
  /// fails with one of [_staleUploadUrlStatusCodes]. It can also still exist
  /// but belong to a different file, which the server's `Upload-Length` gives
  /// away: resuming into it would corrupt that upload. Both cases drop the URL
  /// from [cache] and create a brand new upload, so the upload starts over
  /// instead of hard failing or corrupting someone else's file.
  ///
  /// The recovery needs a creation [url] to POST to. Without one, which is the
  /// case for a client built from an explicit `uploadUrl`, the
  /// [ProtocolException] is thrown, since the caller asked for that specific
  /// upload and silently uploading somewhere else is not what they requested.
  Future<int> _resolveOffset() async {
    ProtocolException failure;
    try {
      final serverState = await _getUploadState();
      // A server that does not report the length, which the protocol allows for
      // a deferred length upload, leaves nothing to cross check.
      if (serverState.length == null || serverState.length == _fileSize) {
        return serverState.offset;
      }
      _state = TusUploadState.error;
      failure = ProtocolException(
        _errorMessage =
            'The upload at $uploadUrl is ${serverState.length} bytes long but '
            '$_fileSize bytes were expected, so it belongs to a different file',
      );
    } on ProtocolException catch (e) {
      if (!_staleUploadUrlStatusCodes.contains(e.statusCode)) rethrow;
      failure = e;
    }

    // Only evict the entry that actually points at the unusable URL, so a
    // cached mapping to some other upload is left untouched.
    if (await cache?.get(_fingerprint) == uploadUrl) {
      await cache?.remove(_fingerprint);
    }

    if (url.isEmpty) throw failure;

    _uploadURI = Uri();
    _errorMessage = null;
    await createUpload();
    return (await _getUploadState()).offset;
  }

  /// Reads how far the server got with this upload, and how long it expects the
  /// file to be. Throws [ProtocolException] on error.
  ///
  /// `length` is `null` when the server does not report `Upload-Length`.
  Future<({int offset, int? length})> _getUploadState() async {
    final offsetHeaders = {...headers, Headers.tusResumableHeader: tusVersion};
    final response = await httpClient.head(_uploadURI, headers: offsetHeaders);

    if (!(response.statusCode >= 200 && response.statusCode < 300)) {
      _state = TusUploadState.error;
      throw ProtocolException(
        _errorMessage =
            'Unexpected status code (${response.statusCode}) while resuming upload',
        response,
      );
    }

    int? serverOffset = _parseHeaderInt(
      response.headers[Headers.uploadOffsetHeader],
    );
    if (serverOffset == null) {
      _state = TusUploadState.error;
      throw ProtocolException(
        _errorMessage = 'Missing upload offset in response for resuming upload',
        response,
      );
    }
    return (
      offset: serverOffset,
      length: _parseHeaderInt(response.headers[Headers.uploadLengthHeader]),
    );
  }

  /// Get data from file to upload.
  ///
  /// Must return the bytes starting at [offset], at most [chunkSize] of them,
  /// and must not change [offset] itself. The client advances [offset] from
  /// what the server confirms once the chunk has landed.
  Future<Uint8List> getData();

  int? _parseHeaderInt(String? value) {
    if (value == null || value.isEmpty) return null;
    if (value.contains(',')) {
      value = value.substring(0, value.indexOf(','));
    }
    return int.tryParse(value.trim());
  }

  /// Resolves the `Location` of a created upload against the creation [url].
  Uri parseToURI(String locationURL) {
    if (locationURL.contains(',')) {
      locationURL = locationURL.substring(0, locationURL.indexOf(','));
    }
    final location = Uri.parse(locationURL.trim());
    if (url.isEmpty) return location;
    // RFC 3986 resolution, so an absolute, a root relative and a path relative
    // Location all end up where the server meant them to, instead of a path
    // relative one silently losing the base path.
    return Uri.parse(url).resolveUri(location);
  }
}

/// A tus `PATCH` whose body is handed over in slices rather than in one go, so
/// that progress can be reported while the chunk is still being sent instead of
/// only once the server has taken all of it.
///
/// The slices are pulled by the http client as it writes to the socket, so
/// [onBytesSent] follows the pace of the transfer rather than a timer.
class _ChunkUploadRequest extends http.BaseRequest {
  _ChunkUploadRequest(
    Uri url, {
    required this.body,
    required this.sliceSize,
    required this.onBytesSent,
  }) : super('PATCH', url) {
    // Set before finalizing, so the request still carries a Content-Length and
    // is not sent chunked.
    contentLength = body.length;
  }

  final Uint8List body;
  final int sliceSize;

  /// Called with the number of bytes of [body] handed over so far, after each
  /// slice has been taken.
  final void Function(int bytesSent) onBytesSent;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_slices());
  }

  Stream<List<int>> _slices() async* {
    var sent = 0;
    while (sent < body.length) {
      final end = min(sent + sliceSize, body.length);
      // Views, so slicing a chunk costs nothing beyond the bookkeeping.
      yield Uint8List.sublistView(body, sent, end);
      sent = end;
      onBytesSent(sent);
    }
  }
}
