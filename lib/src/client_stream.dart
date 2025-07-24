import 'dart:async';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:tusc/src/client_base.dart';
import 'package:tusc/src/stream_handler.dart';

/// This is a client for the tus(https://tus.io) protocol.
class TusStreamClient extends TusBaseClient {
  /// The stream handler that will read the stream in chunks
  final StreamHandler _streamHandler;

  /// A function that returns a new stream instance each time it is called.
  /// This stream will be used to read the bytes to be uploaded.
  ///
  /// This needs to be a function (not a stream) so that uploads can be [cancelled]
  /// and [resumed] without creating a new [TusStreamClient] instance.
  ///
  /// When an upload is [cancelled], the current stream is [closed].
  /// To [resume] the upload, a new stream instance is required—hence the need
  /// for a function that can generate it on demand.
  ///
  /// This is an example of how to create a Tus client instance to upload from
  /// a file:
  ///
  /// ```dart
  /// import 'dart:io';
  /// import 'package:tusc/tusc.dart';
  ///
  /// Future<void> initTus() async {
  ///   File file = File('');
  ///   final tus = TusClient(
  ///     url: 'https://example.com/tus',
  ///     fileStreamGenerator: () => file.openRead(),
  ///     fileSize: await file.length(),
  ///     fileName: file.path,
  ///   );
  /// }
  /// ```
  ///
  /// If re-creating the stream is not possible or very expensive
  /// (e.g., it's from a one-time network request), your options are:
  ///
  /// 1. Don't cancel the upload, just pause/resume it. This will be your only
  /// option, if the stream is from a file excessively large to fit in memory.
  /// 2.If the stream is not from a file excessively large to fit in memory,
  /// then you could read the entire stream into memory once and then create
  /// new streams from that buffered data, for example:
  /// ```dart
  /// import 'dart:typed_data';
  /// import 'package:tusc/tusc.dart';
  ///
  /// Future<Uint8List> bufferStream(Stream<List<int>> stream) async {
  ///   final builder = BytesBuilder();
  ///   await for (final chunk in stream) {
  ///     builder.add(chunk);
  ///   }
  ///   return builder.toBytes();
  /// }
  ///
  /// Future<void> initTus(Stream<List<int>> stream) async {
  ///   final bufferedData = await bufferStream(stream);
  ///   final tus = TusClient(
  ///     url: 'https://example.com/tus',
  ///     fileStreamGenerator: () => Stream.fromIterable([bufferedData]),
  ///     fileSize: bufferedData.length,
  ///     fileName: 'example.txt',
  ///   );
  /// }
  /// ```
  final Stream<List<int>> Function() fileStreamGenerator;

  /// The total size of the file to upload
  final int _fileSize;

  /// A [fileName] will be used as identifier of the file being uploaded,
  /// this will be used for cache when resuming uploads. If not provided, a
  /// fingerprint will be generated based on the url to upload and the file size,
  /// but it is recommended to specify some unique file name.
  final String? _fileName;

  TusStreamClient({
    required this.fileStreamGenerator,
    required int fileSize,
    String? fileName,
    required super.url,
    super.chunkSize,
    super.tusVersion,
    super.cache,
    super.headers,
    super.metadata,
    super.timeout,
    super.httpClient,
  })  : _streamHandler = StreamHandler(fileStreamGenerator),
        _fileSize = fileSize,
        _fileName = fileName;

  @override
  Future<int> get fileSize async => _fileSize;

  @override
  String? get fileName => _fileName;

  @override
  Future<void> createUpload() async {
    _streamHandler.reset();
    return super.createUpload();
  }

  /// Get data from stream to upload
  @override
  Future<Uint8List> getData() async {
    final Uint8List chunk =
        await _streamHandler.read(start: offset, chunkSize: chunkSize);

    final bytesRead = min(chunkSize, chunk.length);
    offset += bytesRead;

    return chunk;
  }
}
