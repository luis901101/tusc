import 'dart:convert';

extension MapExtension<K, V> on Map<K, V> {
  Map<K2, V2> mapWhere<K2, V2>(
    MapEntry<K2, V2> Function(K key, V value) convert,
    bool Function(K key, V value) test,
  ) {
    Map<K2, V2> result = {};
    for (final entry in entries) {
      if (test(entry.key, entry.value)) {
        final convertedEntry = convert(entry.key, entry.value);
        result[convertedEntry.key] = convertedEntry.value;
      }
    }
    return result;
  }

  Map<String, String> get parseToMapString => mapWhere(
        (key, value) => MapEntry<String, String>(
          key is String ? key : jsonEncode(key),
          value is String ? value : jsonEncode(value),
        ),
        (key, value) => key != null && value != null,
      );

  String get parseToMetadata => parseToMapString.entries
      .map(
        (entry) => '${entry.key} ${base64.encode(utf8.encode(entry.value))}',
      )
      .join(',');
}
