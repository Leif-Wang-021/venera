import 'dart:async';
import 'dart:isolate';

import 'package:venera/utils/io.dart';
import 'package:zip_flutter/zip_flutter.dart';

/// Progress snapshot of a running compression task.
///
/// The primary metric is BYTES ([bytesDone]/[bytesTotal]) — a pure file
/// counter would be misleading when a few large images dominate the archive
/// (e.g. 62 large files ≫ 2000 small ones).
class ZipProgress {
  ZipProgress({
    required this.filesDone,
    required this.filesTotal,
    required this.bytesDone,
    required this.bytesTotal,
  });

  final int filesDone;
  final int filesTotal;
  final int bytesDone;
  final int bytesTotal;

  double get ratio => bytesTotal <= 0 ? 1 : bytesDone / bytesTotal;
}

typedef ZipProgressListener = void Function(ZipProgress progress);

/// Raised by [ZipCompression.run] when [ZipHandle.cancel] was requested.
class ZipCancelledException implements Exception {
  const ZipCancelledException();
  @override
  String toString() => 'Zip compression cancelled';
}

/// Handle used to request cancellation of a running compression.
///
/// Semantics: "cancel after the current file finishes" — a synchronous FFI
/// call cannot be interrupted mid-flight, and force-killing native threads
/// is exactly what made the old multithreaded compressor unstable.
class ZipHandle {
  ZipHandle._();

  SendPort? _controlPort;
  final List<String> _pending = [];
  final Completer<void> _done = Completer<void>();

  /// Resolves when the task finished, failed or was cancelled.
  /// Throws on failure and [ZipCancelledException] on cancellation.
  Future<void> get done => _done.future;

  /// Ask the worker to stop after its current file.
  void cancel() {
    var port = _controlPort;
    if (port != null) {
      port.send('cancel');
    } else {
      // Worker not started yet — buffer, delivered on attach.
      _pending.add('cancel');
    }
  }

  void _attach(SendPort port) {
    _controlPort = port;
    for (var m in _pending) {
      port.send(m);
    }
    _pending.clear();
  }
}

/// Compresses a folder into a ZIP archive using a dedicated worker isolate.
///
/// Why this shape (2026-08-25 export rework):
/// - zip_flutter's built-in `compressFolderAsync` drives a NATIVE thread
///   pool that proved unstable on some Android devices ("Failed to write
///   content" / "Failed to open file", swallowed error codes).
/// - A plain sequential loop calls synchronous blocking FFI per file; on
///   the UI isolate that froze the interface for tens of seconds and kept
///   one core pinned (user-visible jank + heat).
/// - So: ONE worker isolate, ONE sequential FFI compression stream — the
///   stability of single-threaded writing with the responsiveness of the
///   old threaded version.
///
/// Safety properties:
/// - Writes to `<dst>.tmp`, verifies readability, then renames — a killed
///   app / failed run never leaves a half-written archive that looks valid.
/// - Progress messages are throttled (time + percent delta) so the UI is
///   not flooded with thousands of updates for large trees.
/// - All state exchanged with the worker is sendable (strings/ints/ports);
///   no FFI pointers ever cross isolate boundaries — the worker creates and
///   owns its own native zip object.
class ZipCompression {
  /// One-shot helper: compress and complete when done.
  /// See [start] for semantics.
  static Future<void> run({
    required String src,
    required String dst,
    ZipProgressListener? onProgress,
  }) {
    return start(src: src, dst: dst, onProgress: onProgress).done;
  }

  /// Spawns the worker and returns immediately with a [ZipHandle].
  ///
  /// [onProgress] is invoked on the CALLING isolate, throttled to at most
  /// one call per ~150 ms plus a final 100% sample.
  static ZipHandle start({
    required String src,
    required String dst,
    ZipProgressListener? onProgress,
  }) {
    // Metadata walk on the calling isolate: cheap (names+sizes only).
    var files = <String>[];
    var sizes = <int>[];
    var emptyDirs = <String>[];
    var totalBytes = 0;
    void walk(String dir) {
      for (var entity in Directory(dir).listSync()) {
        if (entity is File) {
          files.add(entity.path);
          var len = entity.lengthSync();
          sizes.add(len);
          totalBytes += len;
        } else if (entity is Directory) {
          walk(entity.path);
          if (entity.listSync().isEmpty) {
            emptyDirs.add(entity.path);
          }
        }
      }
    }

    walk(src);
    if (files.isEmpty && emptyDirs.isEmpty) {
      throw ArgumentError('Nothing to compress in $src');
    }

    var results = ReceivePort();
    var handle = ZipHandle._();
    var tmp = '$dst.tmp';
    var lastSentMs = 0;
    var lastRatio = -1.0;

    results.listen((message) {
      // Fatal worker errors arrive via onError as [error, stackTrace].
      if (message is List) {
        if (!handle._done.isCompleted) {
          handle._done.completeError(StateError(message.first.toString()));
        }
        results.close();
        return;
      }
      var msg = message as Map;
      switch (msg['type'] as String) {
        case 'progress':
          if (onProgress == null) break;
          var p = ZipProgress(
            filesDone: msg['filesDone'] as int,
            filesTotal: msg['filesTotal'] as int,
            bytesDone: msg['bytesDone'] as int,
            bytesTotal: msg['bytesTotal'] as int,
          );
          var now = DateTime.now().millisecondsSinceEpoch;
          // Throttle: >=150ms between updates, always send completion.
          var finished = p.filesDone >= p.filesTotal;
          if (finished ||
              now - lastSentMs >= 150 &&
                  (p.ratio - lastRatio).abs() >= 0.01) {
            lastSentMs = now;
            lastRatio = p.ratio;
            onProgress(p);
          }
        case 'done':
          handle._done.complete();
          results.close();
        case 'cancelled':
          handle._done.completeError(const ZipCancelledException());
          results.close();
        case 'error':
          handle._done.completeError(StateError(msg['message'] as String));
          results.close();
      }
    });

    var handshake = ReceivePort();
    handshake.listen((p) {
      handle._attach(p as SendPort);
      handshake.close();
    });

    Isolate.spawn(
      _workerEntry,
      {
        'src': src,
        'tmp': tmp,
        'dst': dst,
        'files': files,
        'sizes': sizes,
        'emptyDirs': emptyDirs,
        'totalBytes': totalBytes,
        'handshake': handshake.sendPort,
        'results': results.sendPort,
      },
      errorsAreFatal: true,
      onError: results.sendPort,
    );

    return handle;
  }

  @pragma('vm:entry-point')
  static Future<void> _workerEntry(Map params) async {
    var results = params['results'] as SendPort;
    var handshake = params['handshake'] as SendPort;
    var control = ReceivePort();
    handshake.send(control.sendPort);

    var cancelled = false;
    control.listen((m) {
      if (m == 'cancel') cancelled = true;
    });

    var src = params['src'] as String;
    var tmp = params['tmp'] as String;
    var dst = params['dst'] as String;
    var files = (params['files'] as List).cast<String>();
    var sizes = (params['sizes'] as List).cast<int>();
    var emptyDirs = (params['emptyDirs'] as List).cast<String>();
    var totalBytes = params['totalBytes'] as int;
    var filesTotal = files.length;

    void sendProgress(int done, int bytes) {
      results.send({
        'type': 'progress',
        'filesDone': done,
        'filesTotal': filesTotal,
        'bytesDone': bytes,
        'bytesTotal': totalBytes,
      });
    }

    void cleanupTmp() {
      try {
        var f = File(tmp);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }

    ZipFile? zip;
    try {
      // Never leave a stale half-written archive behind.
      var oldTmp = File(tmp);
      if (oldTmp.existsSync()) oldTmp.deleteSync();
      var oldDst = File(dst);
      if (oldDst.existsSync()) oldDst.deleteSync();

      zip = ZipFile.open(tmp, level: 4);
      String rel(String p) => p.replaceFirst(src, '').replaceAll('\\', '/');

      for (var dir in emptyDirs) {
        zip.addDirectory(rel(dir));
      }

      var bytesDone = 0;
      for (var i = 0; i < files.length; i++) {
        if (cancelled) break;
        // Synchronous blocking FFI: full read + deflate + write. This is
        // exactly why this code must NOT run on the UI isolate.
        zip.addFile(rel(files[i]), files[i]);
        bytesDone += sizes[i];
        sendProgress(i + 1, bytesDone);
        // Yield to the worker's own event loop so queued control messages
        // ('cancel') can actually be dispatched — a pure synchronous loop
        // would starve its listener and ignore cancellation forever.
        await Future<void>.delayed(Duration.zero);
      }

      zip.close();
      zip = null;

      if (cancelled) {
        cleanupTmp();
        results.send({'type': 'cancelled'});
        return;
      }

      // Verify the archive is readable before it can masquerade as valid.
      ZipFile.openRead(tmp).close();
      File(tmp).renameSync(dst);
      results.send({'type': 'done'});
    } catch (e) {
      zip?.close();
      cleanupTmp();
      results.send({'type': 'error', 'message': e.toString()});
    } finally {
      control.close();
    }
  }
}
