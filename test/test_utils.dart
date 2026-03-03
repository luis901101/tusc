import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:tusc/src/client.dart';
import 'package:tusc/src/utils/header_utils.dart';
import 'package:http/http.dart' as http;

Future<String?> generateUploadUrlForTest({
  required String url,
  required File file,
  String? fileName,
}) async {
  final tusClient = TusClient(
    url: url,
    file: XFile(file.path, name: fileName),
  );
  int fileSize = await tusClient.fileSize;
  String uploadMetadata = tusClient.generateMetadata();

  final createHeaders = {
    Headers.tusResumableHeader: tusClient.tusVersion,
    Headers.uploadMetadataHeader: uploadMetadata,
    Headers.uploadLengthHeader: '$fileSize',
  };

  http.Client httpClient = http.Client();

  final response = await httpClient.post(
    Uri.parse(url),
    headers: createHeaders,
  );

  if (!(response.statusCode >= 200 && response.statusCode < 300)) {
    return null;
  }

  String locationURL = response.headers[Headers.location]?.toString() ?? '';
  if (locationURL.isEmpty) {
    return null;
  }

  final uploadUrl = tusClient.parseToURI(locationURL).toString();
  return uploadUrl;
}
