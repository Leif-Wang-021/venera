import 'dart:io';
import 'dart:isolate';

import 'package:zip_flutter/zip_flutter.dart';

Future<void> isolatesExtract(String zipFile, String extractTo, int isolates) {
  var zip = ZipFile.openRead(zipFile);
  try {
    var entries = zip.getAllEntries();
    var futures = <Future>[];
    var entriesPerIsolate = (entries.length / isolates).ceil();
    for (var i = 0; i < isolates; i++) {
      if (i * entriesPerIsolate >= entries.length) {
        break;
      }
      var tasks = entries.sublist(
        i * entriesPerIsolate,
        (i + 1) * entriesPerIsolate > entries.length
            ? entries.length
            : (i + 1) * entriesPerIsolate,
      );
      futures.add(
        extractEntries(zipFile, extractTo, tasks.map((e) => e.name).toList()),
      );
    }
    return Future.wait(futures);
  } finally {
    zip.close();
  }
}

Future<void> extractEntries(
    String zipFile, String extractTo, List<String> entries) {
  return Isolate.run(() {
    var zip = ZipFile.openRead(zipFile);
    try {
      for (var entryName in entries) {
        var resultFilePath = extractTo + Platform.pathSeparator + entryName;
        var entry = zip.getEntryByName(entryName);
        if (entry.isDir) {
          Directory(resultFilePath).createSync(recursive: true);
        } else {
          entry.writeToFile(resultFilePath);
        }
      }
    } finally {
      zip.close();
    }
  });
}

Future<void> compressFolderMultiThreaded(
    String folder, String zipFile, int threads) async {
  var names = <String>[];
  var fileNames = <String>[];
  var emptyDirs = <String>[];
  void walker(Directory dir) {
    for (var entity in dir.listSync()) {
      if (entity is File) {
        var filePathInZip = entity.path.replaceFirst(folder, "");
        if (filePathInZip.startsWith('/') || filePathInZip.startsWith('\\')) {
          filePathInZip = filePathInZip.substring(1);
        }
        names.add(filePathInZip);
        fileNames.add(entity.path);
      } else if (entity is Directory) {
        walker(entity);
        if (entity.listSync().isEmpty) {
          emptyDirs.add(entity.path.substring(folder.length + 1));
        }
      }
    }
  }

  walker(Directory(folder));
  var zip = ZipFile.open(zipFile);
  try {
    for (var dir in emptyDirs) {
      zip.addDirectory(dir);
    }
    var tasksPerThread = (names.length / threads).ceil();
    var futures = <Future>[];
    for (var i = 0; i < threads; i++) {
      if (i * tasksPerThread >= names.length) {
        break;
      }
      var start = i * tasksPerThread;
      var end = (i + 1) * tasksPerThread > names.length
          ? names.length
          : (i + 1) * tasksPerThread;
      futures.add(zip.addFilesAsync(
        names.sublist(start, end),
        fileNames.sublist(start, end),
      ));
    }
    await Future.wait(futures);
  } finally {
    zip.close();
  }
}
