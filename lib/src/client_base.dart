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
typedef ProgressCallback = void Function(
    int count, int total, http.Response? response);

/// Callback to listen when upload finishes
typedef CompleteCallback = void Function(http.Response response);

/// Callback to listen when upload fails
typedef ErrorCallback = void Function(ProtocolException error);

/// This is a base client for the tus(https://tus.io) protocol.
abstract class TusBaseClient {
  /// The tus server URL
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

  int _fileSize = 0;
  String _fingerprint = '';
  String _uploadMetadata = '';
  Uri _uploadURI = Uri();
  int offset = 0;
  TusUploadState _state;
  Future? _uploadFuture;
  ProgressCallback? _onProgress;
  CompleteCallback? _onComplete;
  ErrorCallback? _onError;
  Function()? _onTimeout;
  String? _errorMessage;

  TusBaseClient({
    required this.url,
    int? chunkSize,
    this.tusVersion = Headers.defaultTusVersion,
    this.cache,
    Map<String, dynamic>? headers,
    this.metadata,
    Duration? timeout,
    http.Client? httpClient,
  })  : chunkSize = chunkSize ?? 256.KB,
        headers = headers?.parseToMapString ?? {},
        timeout = timeout ?? const Duration(seconds: 30),
        httpClient = httpClient ?? http.Client(),
        _state = TusUploadState.notStarted;

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

    _uploadURI = _parseToURI(locationURL);
    cache?.set(_fingerprint, _uploadURI.toString());
    _state = TusUploadState.created;
  }

  /// Check if it's possible to resume an already started upload
  Future<bool> canResume() async {
    if (!resumingEnabled) return false;

    _uploadURI = Uri.parse(await cache?.get(_fingerprint) ?? '');

    return _uploadURI.toString().isNotEmpty;
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
      if (!await canResume()) {
        await createUpload();
      }

      // Get offset from server
      offset = await _getOffset();

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

        int? serverOffset =
            _parseOffset(response.headers[Headers.uploadOffsetHeader]);
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
        cache?.remove(_fingerprint);
        _onComplete?.call(response!);
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

  /// Pause the current upload
  Future? pauseUpload() {
    return _uploadFuture?.timeout(
      Duration.zero,
      onTimeout: () {
        _state = TusUploadState.paused;
        return http.Response('', 200, reasonPhrase: 'Upload request paused');
      },
    );
  }

  /// Cancel the current upload
  Future? cancelUpload() {
    return _uploadFuture?.timeout(
      Duration.zero,
      onTimeout: () {
        _state = TusUploadState.cancelled;
        cache?.remove(_fingerprint);
        return http.Response('', 200, reasonPhrase: 'Upload request cancelled');
      },
    );
  }

  /// Override this method to customize creating file fingerprint
  String generateFingerprint() =>
      '$url${fileName != null ? '_$fileName' : ''}_$_fileSize'
          .replaceAll(RegExp(r'\W+'), '.');

  /// Override this to customize the header 'Upload-Metadata'
  String generateMetadata() {
    final meta = metadata ?? <String, dynamic>{};

    if (!meta.containsKey('filename') && fileName != null) {
      meta['filename'] = fileName!;
    }

    return meta.parseToMetadata;
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

    int? serverOffset =
        _parseOffset(response.headers[Headers.uploadOffsetHeader]);
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

  Uri _parseToURI(String locationURL) {
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
