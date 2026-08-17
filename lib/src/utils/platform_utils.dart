// This is a conditional export that picks the web implementation when the
// program is being compiled for a browser, and the native one otherwise.
//
// The check is `dart.library.js_interop` rather than `dart.library.html`,
// because `dart:html` only exists when compiling with dart2js. A Flutter web
// app built to WebAssembly has no `dart:html`, so keying on it would quietly
// hand a browser the native implementation. `dart:js_interop` exists on both
// web compilers and on neither native one.
export 'platform_utils_io.dart'
    if (dart.library.js_interop) 'platform_utils_web.dart';
