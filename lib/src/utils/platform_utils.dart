// This is a conditional export.
// It tries to load the '_html.dart' version if the dart.library.html constant is true (i.e., we're on the web).
// Otherwise, it falls back to the '_io.dart' version.
export 'platform_utils_io.dart'
    if (dart.library.html) 'platform_utils_html.dart';
