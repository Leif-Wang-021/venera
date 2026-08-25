// Synchronizes the app version from the SINGLE source of truth
// (pubspec.yaml -> version) to every derived location:
//   1. lib/foundation/app_version.dart  (Dart constant used by App.version)
//   2. windows/build_sourcekey.iss      (#define MyAppVersion)
//
// Usage: dart run tool/sync_version.dart
// Drift is additionally caught by test/version_consistency_test.dart.
import 'dart:io';

void main() {
  var pubspec = File('pubspec.yaml').readAsStringSync();
  var match = RegExp(r'^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)', multiLine: true)
      .firstMatch(pubspec);
  if (match == null) {
    stderr.writeln('ERROR: version not found in pubspec.yaml');
    exit(1);
  }
  var semver = '${match.group(1)}.${match.group(2)}.${match.group(3)}';
  var build = match.group(4)!;

  // 1. Dart constant
  File('lib/foundation/app_version.dart').writeAsStringSync('''
// GENERATED FILE — do not edit manually.
// Source of truth: pubspec.yaml -> version
// Regenerate with: dart run tool/sync_version.dart
// Guarded by test/version_consistency_test.dart so any drift fails CI/tests.
const String kAppVersion = '$semver';
const String kAppBuildNumber = '$build';
''');

  // 2. Inno Setup define
  var iss = File('windows/build_sourcekey.iss');
  if (iss.existsSync()) {
    var text = iss.readAsStringSync();
    var updated = text.replaceFirst(
      RegExp(r'#define MyAppVersion "[^"]*"'),
      '#define MyAppVersion "$semver"',
    );
    if (updated != text) {
      iss.writeAsStringSync(updated);
      print('updated windows/build_sourcekey.iss -> $semver');
    }
  }

  print('app_version.dart -> $semver+$build');
}
