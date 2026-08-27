import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:sqlite3/open.dart' as sqlite3_open;

/// Registers the bundled sqlite3 native library again inside a spawned
/// isolate. Dart isolates own independent copies of top-level statics, so the
/// main isolate's `open.overrideForAll` (set up in `init.dart` for OHOS) does
/// NOT carry over — without this, the first `sqlite3` access in an isolate
/// throws `Unsupported operation: Unsupported platform: ohos`.
///
/// No-op on all other platforms.
void ensureSqliteLoadedInIsolate() {
  if (Platform.operatingSystem == 'ohos') {
    sqlite3_open.open.overrideForAll(
      () => ffi.DynamicLibrary.open('libvenerasqlite3.so'),
    );
  }
}