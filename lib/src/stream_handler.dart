import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

class StreamHandler {
  /// Will have a portion of the stream read into it, the portion will be always
  /// from [_streamOffset] to [_streamOffset + _buffer.length]
  final BytesBuilder _buffer = BytesBuilder();

  /// The stream from which bytes are read.
  final Stream<List<int>> Function() streamGenerator;

  /// The stream iterator used to read from the stream in chunks.
  late StreamIterator<List<int>> _streamIterator;

  /// The current offset in the stream, used to track how many bytes have been read.
  int _streamOffset = 0;
  StreamHandler(this.streamGenerator)
      : _streamIterator = StreamIterator<List<int>>(streamGenerator());

  /// Returns a chunk of bytes from the stream.
  ///
  /// [start] defaults to 0.
  /// [end] must be greater than [start] and defaults 64 KB (65536).
  /// [chunkSize] must be greater than 0 and defaults to [end] - [start].
  Future<Uint8List> read({int start = 0, int? end, int? chunkSize}) async {
    if (chunkSize != null) {
      end = start + chunkSize;
    } else if (end != null) {
      chunkSize = end - start;
    }
    end ??= 65536; // 64 KB default
    chunkSize ??= end - start;

    await _moveToOffset(start);

    // Move stream iterator offset and add more bytes to the buffer
    // if chunkSize is larger than the buffer length
    while (_buffer.length < chunkSize && await _streamIterator.moveNext()) {
      _streamOffset += _streamIterator.current.length;
      _buffer.add(_streamIterator.current);
    }

    chunkSize = min(chunkSize, _buffer.length);
    if (chunkSize == 0) return Uint8List(0);

    // Take all the bytes from the buffer and check if chunk should be split
    Uint8List bufferBytes = _buffer.takeBytes();
    Uint8List chunk;
    if (bufferBytes.length > chunkSize) {
      // If the bytes taken from the buffer are larger than the requested chunk size, then split it
      chunk = Uint8List.sublistView(bufferBytes, 0, chunkSize);
      // Add the remaining bytes back to the buffer
      _buffer.add(bufferBytes.sublist(chunkSize));
    } else {
      // If the bytes taken from the buffer are smaller or equal to the requested chunk size, then use them as is
      // Keep the buffer empty, so it gets filled with the next stream chunk
      chunk = bufferBytes;
    }

    return chunk;
  }

  Future<void> _moveToOffset(int offset) async {
    if (offset == _streamOffset) return;

    // Advance the stream to the correct offset
    while (offset > _streamOffset && await _streamIterator.moveNext()) {
      final chunk = _streamIterator.current;
      _streamOffset += chunk.length;
      // If the current offset is greater than the requested offset,
      // then we need to fill the buffer starting at the difference offset,
      // to ensure the buffer contains the correct bytes.
      if (_streamOffset > offset) {
        _buffer.add(chunk.sublist(_streamOffset - offset));
      }
    }
  }

  void reset() {
    _streamIterator.cancel();
    _streamIterator = StreamIterator<List<int>>(streamGenerator());
    _streamOffset = 0;
    _buffer.clear();
  }
}
