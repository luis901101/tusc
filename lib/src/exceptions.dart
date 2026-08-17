import 'package:http/http.dart';

/// This exception is thrown when an upload cannot go on.
///
/// Most of the time this is a protocol failure: the server sent a response with
/// an unexpected status code or missing/invalid headers, and [response] holds
/// that response.
///
/// [response] is `null` when the failure did not come from a server response at
/// all, for instance when the data source runs out of bytes before the declared
/// file size has been uploaded.
class ProtocolException implements Exception {
  final String message;
  final Response? response;

  ProtocolException(this.message, [this.response]);

  /// The status code the server responded with, or `null` when the failure did
  /// not come from a server response.
  int? get statusCode => response?.statusCode;

  @override
  String toString() => 'ProtocolException: $message';
}
