class Headers {
  /// Version of the tus protocol used by the client. The remote server needs to
  /// support this version, too.
  static const defaultTusVersion = '1.0.0';
  static const contentTypeOffsetOctetStream = 'application/offset+octet-stream';

  static const tusResumableHeader = 'tus-resumable';
  static const uploadMetadataHeader = 'upload-metadata';
  static const uploadOffsetHeader = 'upload-offset';
  static const uploadLengthHeader = 'upload-length';
  static const location = 'location';
  static const contentType = 'content-type';
}
