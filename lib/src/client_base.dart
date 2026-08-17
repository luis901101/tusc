import 'dart:async';
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

  /// Timeout duration for tus server requests
  /// Default value: 30 seconds
  final Duration timeout;

  /// Set this if you need to use a custom http client
  final http.Client httpClient;

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
  int offset = 0;

  /// Set by [cancelUpload] and consumed by the next [_upload]. A cancelled
  /// upload is abandoned, so the attempt that follows must not resume it.
  bool _uploadCancelled = false;
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
    this.tusVersion = Headers.defaultTusVersion,
    this.cache,
    Map<String, dynamic>? headers,
    this.metadata,
    Duration? timeout,
    http.Client? httpClient,
  }) : url = url ?? '',
       _uploadURI = uploadUrl != null
           ? Uri.tryParse(uploadUrl) ?? Uri()
           : Uri(),
       chunkSize = chunkSize ?? 256.KB,
       headers = headers?.parseToMapString ?? {},
       timeout = timeout ?? const Duration(seconds: 30),
       httpClient = httpClient ?? http.Client(),
       _state = TusUploadState.notStarted,
       assert(
         (url != null && url.isNotEmpty) ||
             (uploadUrl != null && uploadUrl.isNotEmpty),
         'Either url or uploadUrl must be provided',
       );

  /// Get the upload state
  TusUploadState get state => _state;

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
          offset = 0;
        }
      }

      if (!await canResume()) {
        await createUpload();
      }

      // Get offset from server
      offset = await _resolveOffset();

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
        Headers.uploadOffsetHeader: '$offset',
        Headers.contentType: Headers.contentTypeOffsetOctetStream,
      };

      // Start upload
      _state = TusUploadState.uploading;
      while ((_state != TusUploadState.paused &&
              _state != TusUploadState.completed &&
              _state != TusUploadState.cancelled) &&
          offset < _fileSize) {
        _state = TusUploadState.uploading;
        // Update upload progress
        _onProgress?.call(offset, _fileSize, response);

        uploadHeaders[Headers.uploadOffsetHeader] = '$offset';

        final chunk = await getData();
        if (chunk.isEmpty) break;

        _uploadFuture = httpClient.patch(
          _uploadURI,
          headers: uploadHeaders,
          body: chunk,
        );
        response = await _uploadFuture?.timeout(
          timeout,
          onTimeout: () {
            _onTimeout?.call();
            _state = TusUploadState.error;
            return http.Response(
              '',
              HttpStatus.requestTimeout,
              reasonPhrase: _errorMessage = 'Request timeout',
            );
          },
        );
        _uploadFuture = null;

        // Check if correctly uploaded
        if (!(response!.statusCode >= 200 && response.statusCode < 300)) {
          _state = TusUploadState.error;
          throw ProtocolException(
            _errorMessage =
                'Unexpected status code (${response.statusCode}) while uploading chunk',
            response,
          );
        }

        int? serverOffset = _parseOffset(
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
        if (offset != serverOffset) {
          _state = TusUploadState.error;
          throw ProtocolException(
            _errorMessage =
                'Response contains different Upload-Offset value ($serverOffset) than expected ($offset)',
            response,
          );
        }
      }

      // Update upload progress
      _onProgress?.call(offset, _fileSize, response);

      if (offset == _fileSize) {
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
    _onProgress = onProgress;
    _onComplete = onComplete;
    _onError = onError;
    _onTimeout = onTimeout;
    _state = TusUploadState.uploading;
    return _upload();
  }

  /// Resumes an upload where it left of. This function calls [upload()]
  /// using the same callbacks used last time [upload()] was called.
  /// Throws [ProtocolException] on server error
  Future<void> resumeUpload() => startUpload(
    onProgress: _onProgress,
    onComplete: _onComplete,
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
    _state = TusUploadState.paused;
    return _uploadFuture?.timeout(
      Duration.zero,
      onTimeout: () => http.Response(
        '',
        HttpStatus.ok,
        reasonPhrase: 'Upload request paused',
      ),
    );
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
    final inFlightResponse = await _uploadFuture?.timeout(
      Duration.zero,
      onTimeout: () => cancelledResponse,
    );
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
    final meta = metadata ?? <String, dynamic>{};

    if (!meta.containsKey('filename') && fileName != null) {
      meta['filename'] = fileName!;
    }

    return meta.parseToMetadata;
  }

  /// Status codes that mean the upload URL is no longer usable: the server
  /// either never knew it, has already swept it, or no longer grants access to
  /// it. In every case there is nothing left to resume from.
  static const _staleUploadUrlStatusCodes = <int>{
    HttpStatus.forbidden,
    HttpStatus.notFound,
    HttpStatus.gone,
  };

  /// Gets the current offset from the server, recovering from an upload URL the
  /// server no longer knows about.
  ///
  /// A cached upload URL, or one created in a previous session, can expire or
  /// be swept server side. The HEAD request in [_getOffset] then fails with one
  /// of [_staleUploadUrlStatusCodes]. Rather than failing the whole upload, the
  /// dead URL is dropped from [cache] and a brand new upload is created, so the
  /// upload restarts instead of hard failing.
  ///
  /// The recovery needs a creation [url] to POST to. Without one, which is the
  /// case for a client built from an explicit `uploadUrl`, the
  /// [ProtocolException] is rethrown, since the caller asked for that specific
  /// upload and silently uploading somewhere else is not what they requested.
  Future<int> _resolveOffset() async {
    try {
      return await _getOffset();
    } on ProtocolException catch (e) {
      if (!_staleUploadUrlStatusCodes.contains(e.response.statusCode)) rethrow;

      // Only evict the entry that actually points at the dead URL, so a cached
      // mapping to some other upload is left untouched.
      if (await cache?.get(_fingerprint) == uploadUrl) {
        await cache?.remove(_fingerprint);
      }

      if (url.isEmpty) rethrow;

      _uploadURI = Uri();
      _errorMessage = null;
      await createUpload();
      return await _getOffset();
    }
  }

  /// Get offset from server throwing [ProtocolException] on error
  Future<int> _getOffset() async {
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

    int? serverOffset = _parseOffset(
      response.headers[Headers.uploadOffsetHeader],
    );
    if (serverOffset == null) {
      _state = TusUploadState.error;
      throw ProtocolException(
        _errorMessage = 'Missing upload offset in response for resuming upload',
        response,
      );
    }
    return serverOffset;
  }

  /// Get data from file to upload
  Future<Uint8List> getData();

  int? _parseOffset(String? offset) {
    if (offset == null || offset.isEmpty) return null;
    if (offset.contains(',')) {
      offset = offset.substring(0, offset.indexOf(','));
    }
    return int.tryParse(offset);
  }

  Uri parseToURI(String locationURL) {
    if (locationURL.contains(',')) {
      locationURL = locationURL.substring(0, locationURL.indexOf(','));
    }
    Uri uploadURI = Uri.parse(locationURL);
    Uri baseURI = Uri.parse(url);
    if (uploadURI.host.isEmpty) {
      uploadURI = uploadURI.replace(host: baseURI.host, port: baseURI.port);
    }
    if (uploadURI.scheme.isEmpty) {
      uploadURI = uploadURI.replace(scheme: baseURI.scheme);
    }
    return uploadURI;
  }
}
