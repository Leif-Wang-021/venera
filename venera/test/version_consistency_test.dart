import 'dart:io';

import 'package:venera/foundation/app_version.dart';

/// Drift guard: every version display in the app derives from pubspec.yaml.
/// If this test fails, someone edited a derived file by hand — run
/// `dart run tool/sync_version.dart` instead.

void expect(bool cond, String name) {
  if (!cond) throw StateError('FAIL: $name');
  print('PASS $name');
}

void main() {
  var repoRoot = Directory.current.path;
  // Test runs from venera/ workspace root; pubspec lives here too.
  var pubspec = File('$repoRoot/pubspec.yaml').readAsStringSync();
  var m = RegExp(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)', multiLine: true)
      .firstMatch(pubspec);
  expect(m != null, 'V1 pubspec has version field');
  var semver = m!.group(1)!;
  var build = m.group(2)!;

  expect(kAppVersion == semver,
      'V2 generated Dart constant matches pubspec ($semver)');
  expect(kAppBuildNumber == build, 'V3 build number matches');

  var iss = File('$repoRoot/windows/build_sourcekey.iss');
  if (iss.existsSync()) {
    var issText = iss.readAsStringSync();
    expect(issText.contains('#define MyAppVersion "$semver"'),
        'V4 Inno Setup define matches pubspec');
  }

  // No stale hardcoded versions left in Dart sources.
  var libDir = Directory('$repoRoot/lib');
  var offenders = <String>[];
  for (var e in libDir.listSync(recursive: true)) {
    if (e is File && e.path.endsWith('.dart')) {
      var text = e.readAsStringSync();
      if (text.contains('"1.6.3"') || text.contains("'1.6.3'")) {
        offenders.add(e.path);
      }
    }
  }
  expect(offenders.isEmpty, 'V5 no hardcoded old version strings under lib/');
}
