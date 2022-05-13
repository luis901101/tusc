//ignore_for_file: non_constant_identifier_names
extension IntExtension on int {
  /// Number in bytes
  int get B => this;

  /// Number in Kilo Bytes
  int get KB => B * 1024;

  /// Number in Mega Bytes
  int get MB => KB * 1024;

  /// Number in Giga Bytes
  int get GB => MB * 1024;

  //No need to create others
}
