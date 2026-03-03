import 'dart:async';
import 'dart:math' show min;
import 'dart:typed_data' show Uint8List, BytesBuilder;

import 'package:cross_file/cross_file.dart' show XFile;
import 'package:tusc/src/client_base.dart';

/// A tus resumable upload client that reads data from an [XFile].
///
/// Use this client when your upload source is a file on the device.
///
/// Provide [url] to create a new upload on the server, or [uploadUrl] to
/// resume an existing one without creating a new upload:
///
/// ```dart
/// // New upload
/// final client = TusClient(
///   url: 'https://example.com/files',
///   file: XFile('/path/to/file'),
/// );
///
/// // Resume existing upload
/// final client = TusClient(
///   uploadUrl: 'https://example.com/files/my-upload-id',
///   file: XFile('/path/to/file'),
/// );
/// ```
class TusClient extends TusBaseClient {
  /// The file to upload
  final XFile file;

  int _fileSize = 0;

  TusClient({
    required this.file,
    super.url,
    super.uploadUrl,
    super.chunkSize,
    super.tusVersion,
    super.cache,
    super.headers,
    super.metadata,
    super.timeout,
    super.httpClient,
  });

  @override
  Future<int> get fileSize async =>
      _fileSize > 0 ? _fileSize : _fileSize = await file.length();

  @override
  String? get fileName => file.name;

  /// Get data from file to upload
  @override
  Future<Uint8List> getData() async {
    int start = offset;
    int end = min(offset + chunkSize, _fileSize);

    final result = BytesBuilder();
    await for (final chunk in file.openRead(start, end)) {
      result.add(chunk);
    }

    final bytesRead = min(chunkSize, result.length);
    offset += bytesRead;

    return result.takeBytes();
  }
}
