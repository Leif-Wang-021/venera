import 'dart:async';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/chapter_ready_gate.dart';
import 'package:venera/network/fetch_concurrency_controller.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'app_dio.dart';
import 'file_downloader.dart';

abstract class DownloadTask with ChangeNotifier {
  /// 0-1
  double get progress;

  bool get isError;

  bool get isPaused;

  /// Whether the task is actively running (resume() started, not yet
  /// finished, errored or paused).
  bool get isRunning;

  /// bytes per second
  int get speed;

  void cancel();

  void pause();

  void resume();

  String get title;

  String? get cover;

  String get message;

  /// root path for the comic. If null, the task is not scheduled.
  String? path;

  /// convert current state to json, which can be used to restore the task
  Map<String, dynamic> toJson();

  LocalComic toLocalComic();

  String get id;

  ComicType get comicType;

  static DownloadTask? fromJson(Map<String, dynamic> json) {
    switch (json["type"]) {
      case "ImagesDownloadTask":
        return ImagesDownloadTask.fromJson(json);
      default:
        return null;
    }
  }

  @override
  bool operator ==(Object other) {
    return other is DownloadTask &&
        other.id == id &&
        other.comicType == comicType;
  }

  @override
  int get hashCode => Object.hash(id, comicType);
}

class ImagesDownloadTask extends DownloadTask with _TransferSpeedMixin {
  final ComicSource source;

  final String comicId;

  /// comic details. If null, the comic details will be fetched from the source.
  ComicDetails? comic;

  /// chapters to download. If null, all chapters will be downloaded.
  final List<String>? chapters;

  @override
  String get id => comicId;

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  String? comicTitle;

  ImagesDownloadTask({
    required this.source,
    required this.comicId,
    this.comic,
    this.chapters,
    this.comicTitle,
  });

  @override
  void cancel() {
    _isRunning = false;
    // Interrupt every in-flight image download right away.
    for (var t in tasks.values) {
      t.cancel();
    }
    // Release a pipeline that may be parked waiting for the next chapter.
    _gate.releaseAll();
    LocalManager().removeTask(this);
    // Fire-and-forget: UI callers expect cancel() to return immediately;
    // deletion runs right away but tolerates transient file locks.
    _deleteLocalFolderAfterCancel();
  }

  /// Deletes everything THIS task owns locally, immediately after a
  /// cancellation. A task that was never registered in the local library
  /// owns the whole folder; a task running on top of an existing local
  /// entry only owns the chapter directories it was (re-)downloading.
  /// Retries a few times because freshly-written files may still be held
  /// open by antivirus/indexer handles for a moment on Windows.
  Future<void> _deleteLocalFolderAfterCancel() async {
    var p = path;
    if (p == null || p.isEmpty) {
      return;
    }
    var local = LocalManager().find(id, comicType);
    List<String> targets;
    if (local == null) {
      targets = [p];
    } else {
      // Only the chapters this task was (re-)downloading; other chapters
      // of the same comic that already exist locally must survive.
      targets = (chapters ?? const [])
          .map((c) => FilePath.join(
              p, LocalManager.getChapterDirectoryName(c)))
          .toList();
      if (targets.isEmpty) {
        Log.info("Download",
            "Cancelled; nothing owned by this task to delete under $p");
        return;
      }
    }
    for (var t in targets) {
      var dir = Directory(t);
      if (!dir.existsSync()) {
        continue;
      }
      Object? lastError;
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          await dir.delete(recursive: true);
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          // Brief yield: let in-flight writers release their handles.
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }
      if (lastError != null) {
        Log.error("Download",
            "Failed to delete directory '$t' after 3 attempts: $lastError");
        // User-visible hint on top of the log record.
        _message = "Cancelled (folder cleanup failed)";
        notifyListeners();
      } else {
        Log.info("Download", "Cancelled; deleted $t");
      }
    }
  }

  @override
  String? get cover => _cover ?? comic?.cover;

  @override
  String get message => _message;

  @override
  void pause() {
    if (isPaused) {
      return;
    }
    _isRunning = false;
    _message = "Paused";
    _currentSpeed = 0;
    var shouldMove = <int>[];
    for (var entry in tasks.entries) {
      if (!entry.value.isComplete) {
        entry.value.cancel();
        shouldMove.add(entry.key);
      }
    }
    for (var i in shouldMove) {
      tasks.remove(i);
    }
    // Release a pipeline that may be parked waiting for the next chapter.
    _gate.releaseAll();
    stopRecorder();
    LocalManager().saveCurrentDownloadingTasks();
    notifyListeners();
  }

  @override
  double get progress => _totalCount == 0 ? 0 : _downloadedCount / _totalCount;

  bool _isRunning = false;

  bool _isError = false;

  String _message = "Fetching comic info...";

  String? _cover;

  /// All images to download, key is chapter name
  Map<String, List<String>>? _images;

  /// Downloaded image count
  int _downloadedCount = 0;

  /// Total image count
  int _totalCount = 0;

  /// Current downloading image index
  int _index = 0;

  /// Current downloading chapter, index of [_images]
  int _chapter = 0;

  /// Chapters whose persisted image list is being/has been re-fetched due
  /// to expired time-limited signed URLs (404/410 on resume). One shot per
  /// chapter per task instance to avoid refresh loops.
  final Map<String, Future<bool>> _chapterRefresh = {};

  /// Images that exhausted all retries during the current run.
  int _failedImages = 0;

  final List<String> _failedSamples = [];

  /// Consecutive dead-link failures within the current chapter. When this
  /// reaches [_deadLinkChapterSkipThreshold], the remaining images of the
  /// chapter are cancelled and the task moves on.
  int _deadLinkFailsInChapter = 0;

  static const int _deadLinkChapterSkipThreshold = 5;

  /// Tick counter for periodic [Log] telemetry of the speed pipeline.
  int _speedLogTicks = 0;

  int _saveCountSinceLastPersist = 0;

  DateTime _lastPersistTime = DateTime.now();

  var tasks = <int, _ImageDownloadWrapper>{};

  // --- List-fetch ↔ download pipeline -----------------------------------
  // Chapters become downloadable the moment their image list is ready
  // instead of after every list in the task has been fetched. See
  // [ChapterReadyGate] for the ordering & termination-safety contract.
  final ChapterReadyGate _gate = ChapterReadyGate();

  int get _maxConcurrentTasks =>
      (appdata.settings["downloadThreads"] as num).toInt();

  int get _imageListConcurrency {
    final v = appdata.settings["imageListThreads"];
    if (v is num) {
      return v.toInt().clamp(1, 8).toInt();
    }
    return 3;
  }

  /// Returns the current URL for [index] in [chapter], or null when the
  /// (possibly refreshed) list no longer contains that index.
  String? imageFor(String chapter, int index) {
    var list = _images![chapter];
    if (list == null || index < 0 || index >= list.length) {
      return null;
    }
    return list[index];
  }

  /// Re-fetches the image list for [chapter] once. Returns true when a new,
  /// different list was obtained. Needed because many sources hand out
  /// time-limited signed image URLs; restoring a task from disk days later
  /// makes every stored URL 404, and blind retries can never fix that.
  Future<bool> refreshChapterImages(String chapter) {
    return _chapterRefresh.putIfAbsent(chapter, () async {
      try {
        if (!_isRunning || comic == null) {
          return false;
        }
        _message = "Refreshing image list...";
        notifyListeners();
        var res = await _runWithRetry(() async {
          var r = await source.loadComicPages!(
              comicId, chapter.isEmpty ? null : chapter);
          if (r.error) {
            throw r.errorMessage!;
          }
          return r.data;
        });
        if (!_isRunning || res.error || res.data.isEmpty) {
          return false;
        }
        var old = _images![chapter];
        if (old != null &&
            old.length == res.data.length &&
            _urlListEquals(old, res.data)) {
          Log.info("Download",
              "Refreshed stale image list for chapter '$chapter' "
              "but URLs are unchanged (${res.data.length} images)");
          return false;
        }
        _images![chapter] = res.data;
        await LocalManager().saveCurrentDownloadingTasks();
        Log.info("Download",
            "Refreshed stale image list for chapter '$chapter' (${res.data.length} images)");
        return true;
      } catch (e) {
        Log.error("Download", "Failed to refresh image list: $e");
        return false;
      }
    });
  }

  /// Whether [a] and [b] contain the exact same URLs in the same order.
  static bool _urlListEquals(List<String> a, List<String> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  /// Called by an image wrapper after all its retries are exhausted, so a
  /// single dead image no longer aborts the whole task.
  void onImageGaveUp(String chapter, int index, String url) {
    _failedImages++;
    if (_failedSamples.length < 20) {
      _failedSamples.add(url);
    }
  }

  Future<void> _persistTaskProgress({bool force = false}) async {
    _saveCountSinceLastPersist++;
    final now = DateTime.now();
    if (force ||
        _saveCountSinceLastPersist >= 5 ||
        now.difference(_lastPersistTime) >= const Duration(seconds: 1)) {
      _lastPersistTime = now;
      _saveCountSinceLastPersist = 0;
      await LocalManager().saveCurrentDownloadingTasks();
    }
  }

  void _scheduleTasks() {
    // Under the pipelined fetch+download flow the map's insertion order is
    // completion order, so chapter identity MUST come from the canonical
    // ordered list rather than from map positions.
    var chapterKey = _gate.chapterAt(_chapter);
    var images = _images![chapterKey]!;
    var downloading = 0;
    Directory? saveTo;
    if (comic!.chapters != null) {
      saveTo = Directory(FilePath.join(
        path!,
        LocalManager.getChapterDirectoryName(chapterKey),
      ));
      if (!saveTo.existsSync()) {
        saveTo.createSync(recursive: true);
      }
    }
    for (var i = _index; i < images.length; i++) {
      if (downloading >= _maxConcurrentTasks) {
        return;
      }
      if (tasks[i] != null) {
        if (!tasks[i]!.isComplete) {
          downloading++;
        }
        if (tasks[i]!.error == null) {
          continue;
        }
      }
      var task = _ImageDownloadWrapper(
        this,
        chapterKey,
        images[i],
        saveTo ?? Directory(path!),
        i,
      );
      tasks[i] = task;
      task.wait().then((task) {
        if (task.isComplete) {
          _scheduleTasks();
        }
      });
      downloading++;
    }
  }

  Future<void> _fetchImageList() async {
    final allChapters = comic!.chapters!.allChapters.keys.toList();
    final selected = chapters == null
        ? allChapters
        : allChapters.where(chapters!.contains).toList();
    // Canonical order for the download pipeline (see ChapterReadyGate).
    _gate.configure(selected);
    final totalCpCount = selected.length;
    var cpCount = 0;
    var nextIndex = 0;

    // Adaptive concurrency for the image-list phase only, driven by a
    // NORMAL/PROBING/BACKOFF state machine (see
    // fetch_concurrency_controller.dart). Starts at the user's
    // imageListThreads setting and converges on the largest verified-safe
    // concurrency instead of oscillating +/-1 per request.
    final cc = FetchConcurrencyController(
      initialThreads: _imageListConcurrency,
      onEvent: (m) => Log.info("Download", "[fetch-cc] $m"),
    );
    var active = 0;

    Future<void> worker() async {
      while (_isRunning && !_isError) {
        if (nextIndex >= selected.length) {
          return;
        }
        final order = nextIndex++; // canonical position of this chapter
        final i = selected[order];

        if (_images![i] != null) {
          _totalCount += _images![i]!.length;
          cpCount++;
          _message = "Fetching image list ($cpCount/$totalCpCount)...";
          notifyListeners();
          // Already-fetched lists are downloadable immediately.
          _gate.markReady(order);
          continue;
        }

        // Start-rate governor: book this dispatch's slot BEFORE taking a
        // permit so the learned spacing never blocks other workers, and the
        // latency stopwatch below stays free of pacing time. With gap=0
        // (healthy sources / pre-contact) this is a no-op.
        final slotMs = cc.bookStartSlot();
        if (slotMs > 0) {
          final due = DateTime.now().add(Duration(milliseconds: slotMs));
          while (_isRunning &&
              !_isError &&
              DateTime.now().isBefore(due)) {
            await Future.delayed(const Duration(milliseconds: 50));
          }
          if (!_isRunning || _isError) {
            return;
          }
        }

        // Wait for an available permit before hitting the source. While the
        // controller is in BACKOFF cooldown we dispatch NOTHING new: firing
        // more requests at lower concurrency still burns the exhausted
        // quota and chains 40s JS-side penalties (log-evidenced stalls).
        while (_isRunning &&
            !_isError &&
            (active >= cc.allowedConcurrent || cc.isCoolingDown)) {
          await Future.delayed(const Duration(milliseconds: 50));
        }
        if (!_isRunning || _isError) {
          return;
        }
        active++;
        cc.noteStart(); // actual dispatch instant: feeds the burst-M estimate
        final stopwatch = Stopwatch()..start();
        final dispatchEpoch =
            cc.epoch; // freshness tag for this request's verdict
        try {
          _message = "Fetching image list ($cpCount/$totalCpCount)...";
          notifyListeners();
          final res = await _runWithRetry(() async {
            final r = await source.loadComicPages!(comicId, i);
            if (r.error) {
              throw r.errorMessage!;
            }
            return r.data;
          });
          // Record BEFORE any early return so every attempt feeds the
          // controller. Source scripts swallow HTTP 210 and turn it into
          // very long internal waits (e.g. hot_manga/copy_manga sleep 40s),
          // so a >=15s list request is treated as an explicit rate-limit
          // hit. Plain errors are NOT throttles (they have their own retry
          // path) and must not trigger BACKOFF.
          final latencyMs = stopwatch.elapsedMilliseconds;
          cc.record(
            latencyMs: latencyMs,
            success: !res.error,
            throttled: latencyMs >= 15000,
            epochAtStart: dispatchEpoch,
          );
          if (!_isRunning || _isError) {
            return;
          }
          if (res.error) {
            Log.error("Download", res.errorMessage!);
            _setError("Error: ${res.errorMessage}");
            return;
          }
          _images![i] = res.data;
          _totalCount += _images![i]!.length;
          cpCount++;
          _message = "Fetching image list ($cpCount/$totalCpCount)...";
          notifyListeners();
          // Hand the fresh chapter to the download pipeline right away —
          // this is what makes list-fetching and downloading parallel.
          _gate.markReady(order);
        } finally {
          active--;
        }
      }
    }

    await Future.wait(List.generate(6, (_) => worker()));
    // Whatever the outcome, no pipeline waiter may stay parked forever.
    _gate.releaseAll();
  }

  @override
  void resume() async {
    if (_isRunning) return;
    _isError = false;
    _message = "Resuming...";
    _isRunning = true;
    notifyListeners();
    runRecorder();

    if (comic == null) {
      _message = "Fetching comic info...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        var r = await source.loadComicInfo!(comicId);
        if (r.error) {
          throw r.errorMessage!;
        } else {
          return r.data;
        }
      });
      if (!_isRunning) {
        return;
      }
      if (res.error) {
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        comic = res.data;
      }
    }

    if (path == null) {
      try {
        var dir = await LocalManager().findValidDirectory(
          comicId,
          comicType,
          comic!.title,
        );
        if (!(await dir.exists())) {
          await dir.create();
        }
        path = dir.path;
      } catch (e, s) {
        Log.error("Download", e.toString(), s);
        _setError("Error: $e");
        return;
      }
    }

    await LocalManager().saveCurrentDownloadingTasks();

    if (_cover == null) {
      _message = "Downloading cover...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        Uint8List? data;
        await for (var progress
            in ImageDownloader.loadThumbnail(comic!.cover, source.key)) {
          if (progress.imageBytes != null) {
            data = progress.imageBytes;
          }
        }
        if (data == null) {
          throw "Failed to download cover";
        }
        var fileType = detectFileType(data);
        var file = File(FilePath.join(path!, "cover${fileType.ext}"));
        file.writeAsBytesSync(data);
        return "file://${file.path}";
      });
      if (res.error) {
        Log.error("Download", res.errorMessage!);
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        _cover = res.data;
        notifyListeners();
      }
      await LocalManager().saveCurrentDownloadingTasks();
    }

    if (_images == null) {
      if (comic!.chapters == null) {
        _message = "Fetching image list...";
        notifyListeners();
        var res = await _runWithRetry(() async {
          var r = await source.loadComicPages!(comicId, null);
          if (r.error) {
            throw r.errorMessage!;
          } else {
            return r.data;
          }
        });
        if (!_isRunning) {
          return;
        }
        if (res.error) {
          Log.error("Download", res.errorMessage!);
          _setError("Error: ${res.errorMessage}");
          return;
        } else {
          _images = {'': res.data};
          _totalCount = _images!['']!.length;
          _gate.configure(_images!.keys.toList(), allReady: true);
        }
      } else {
        _images = {};
        _totalCount = 0;
        // PARALLEL PHASES: list fetching starts NOW and keeps running while
        // the pipeline below downloads every chapter as soon as its list
        // arrives. Ordering/persistence semantics are unchanged (see
        // ChapterReadyGate); concurrency stays bounded by the existing
        // imageListThreads / downloadThreads pools respectively.
        _message = "Fetching image list...";
        notifyListeners();
        final fetching = _fetchImageList();
        await _runDownloadPipeline();
        await fetching; // reap the fetch phase (it exits via task flags)
        if (!_isRunning || _isError) {
          return;
        }
        return; // pipeline already ran the finish/summary path
      }
      _message = "$_downloadedCount/$_totalCount";
      notifyListeners();
      await LocalManager().saveCurrentDownloadingTasks();
    } else {
      // Restored from disk: all lists already exist.
      _gate.configure(_images!.keys.toList(), allReady: true);
    }

    await _runDownloadPipeline();
  }

  /// Downloads chapters one at a time in canonical order, starting each as
  /// soon as its image list is ready. Concurrency control is unchanged:
  /// image-level parallelism is capped by [downloadThreads] inside
  /// [_scheduleTasks], and the list phase by imageListThreads + the
  /// FetchConcurrencyController, so the two phases cannot oversubscribe
  /// beyond the user's configured limits.
  Future<void> _runDownloadPipeline() async {
    final overallStart = DateTime.now();
    final startDownloadedCount = _downloadedCount;
    for (var order = 0; order < _gate.total; order++) {
      if (!_isRunning || _isError || isPaused) {
        return;
      }
      await _gate.waitReady(order);
      if (!_isRunning || _isError || isPaused) {
        return;
      }
      var ok = await _downloadChapterImages(_gate.chapterAt(order), order);
      if (!ok) {
        return;
      }
    }
    _finishTask(overallStart, startDownloadedCount);
  }

  /// Downloads one chapter's images. Returns false when the task must stop
  /// (paused, cancelled or errored); true when the chapter is finished or
  /// legitimately skipped.
  Future<bool> _downloadChapterImages(String chapterKey, int order) async {
    _chapter = order;
    _index = 0;
    var images = _images![chapterKey]!;
    var chapterStart = DateTime.now();
    var chapterStartCount = _downloadedCount;
    _deadLinkFailsInChapter = 0;
    tasks.clear();
    while (_index < images.length) {
      _scheduleTasks();
      var task = tasks[_index]!;
      await task.wait();
      if (isPaused) {
        return false;
      }
      if (task.error != null) {
        // A single dead image must not kill the whole task: record it,
        // leave its file slot empty and continue with the rest.
        Log.error(
          "Download",
          "Image failed after all retries: ${images[_index]} "
              "(${task.error})",
        );
        if (task.deadLink) {
          _deadLinkFailsInChapter++;
          // A chapter whose beginning is almost entirely dead links is
          // very likely a stale/missing chapter (e.g. signed URLs that
          // expired and cannot be re-signed by the source). Skip the rest
          // instead of grinding through every remaining image for hours.
          if (_deadLinkFailsInChapter >= _deadLinkChapterSkipThreshold) {
            var remaining = images.length - _index - 1;
            for (var i = _index + 1; i < images.length; i++) {
              _failedImages++;
              if (_failedSamples.length < 20) {
                _failedSamples.add(images[i]);
              }
            }
            for (var t in tasks.values) {
              t.cancel();
            }
            Log.error(
              "Download",
              "Chapter '$chapterKey' skipped: "
                  "$_deadLinkFailsInChapter consecutive dead images "
                  "($remaining remaining)",
            );
            _index = images.length;
            break;
          }
        } else {
          _deadLinkFailsInChapter = 0;
        }
      }
      _index++;
      _downloadedCount++;
      _message = "$_downloadedCount/$_totalCount";
      await _persistTaskProgress();
    }
    var chapterSeconds =
        DateTime.now().difference(chapterStart).inMilliseconds / 1000;
    var chapterImages = _downloadedCount - chapterStartCount;
    if (chapterImages > 0 && chapterSeconds > 0) {
      Log.info(
        "Download",
        "Chapter '$chapterKey' finished: "
            "$chapterImages images in ${chapterSeconds.toStringAsFixed(1)}s "
            "(${(chapterImages / chapterSeconds).toStringAsFixed(2)} img/s, "
            "threads=$_maxConcurrentTasks)",
      );
    }
    return true;
  }

  /// Shared tail for a fully-completed pipeline: summary telemetry, task
  /// completion bookkeeping and recorder shutdown.
  void _finishTask(DateTime overallStart, int startDownloadedCount) {
    var totalSeconds =
        DateTime.now().difference(overallStart).inMilliseconds / 1000;
    var totalImages = _downloadedCount - startDownloadedCount;
    if (totalImages > 0 && totalSeconds > 0) {
      Log.info(
        "Download",
        "Task finished: $totalImages images in ${totalSeconds.toStringAsFixed(1)}s "
            "(${(totalImages / totalSeconds).toStringAsFixed(2)} img/s avg)",
      );
    }
    if (_failedImages > 0) {
      Log.error(
        "Download",
        "Task finished with $_failedImages failed images; first failed: "
            "${_failedSamples.take(3).join(', ')}",
      );
      _message = "$_downloadedCount/$_totalCount ($_failedImages failed)";
    }
    LocalManager().completeTask(this);
    stopRecorder();
  }

  @override
  void onNextSecond(Timer t) {
    notifyListeners();
    super.onNextSecond(t);
    _speedLogTicks++;
    if (_speedLogTicks % 5 == 0) {
      var active =
          tasks.values.where((t) => !t.isComplete && t.error == null).length;
      Log.info(
        "Download",
        "[speed] current=$_currentSpeed B/s pending=$_bytesSinceLastSecond B "
            "activeWorkers=$active",
      );
    }
  }

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    // Release a pipeline that may be parked waiting for the next chapter.
    _gate.releaseAll();
    notifyListeners();
    stopRecorder();
  }

  @override
  int get speed => currentSpeed;

  @override
  String get title => comic?.title ?? comicTitle ?? "Loading...";

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ImagesDownloadTask",
      "source": source.key,
      "comicId": comicId,
      "comic": comic?.toJson(),
      "chapters": chapters,
      "path": path,
      "cover": _cover,
      "images": _images,
      "downloadedCount": _downloadedCount,
      "totalCount": _totalCount,
      "index": _index,
      "chapter": _chapter,
    };
  }

  static ImagesDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ImagesDownloadTask") {
      return null;
    }

    Map<String, List<String>>? images;
    if (json["images"] != null) {
      images = {};
      for (var entry in json["images"].entries) {
        images[entry.key] = List<String>.from(entry.value);
      }
    }

    return ImagesDownloadTask(
      source: ComicSource.find(json["source"])!,
      comicId: json["comicId"],
      comic:
          json["comic"] == null ? null : ComicDetails.fromJson(json["comic"]),
      chapters: ListOrNull.from(json["chapters"]),
    )
      ..path = json["path"]
      .._cover = json["cover"]
      .._images = images
      .._downloadedCount = json["downloadedCount"]
      .._totalCount = json["totalCount"]
      .._index = json["index"]
      .._chapter = json["chapter"];
  }

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  bool get isRunning => _isRunning;

  /// Last error message; null unless [isError].
  String? get error => isError ? _message : null;

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic!.id,
      title: title,
      subtitle: comic!.subTitle ?? '',
      tags: comic!.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: comic!.chapters,
      cover: File(_cover!.split("file://").last).name,
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: chapters ?? comic?.chapters?.ids.toList() ?? [],
      createdAt: DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is ImagesDownloadTask) {
      return other.comicId == comicId && other.source.key == source.key;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(comicId, source.key);
}

Future<Res<T>> _runWithRetry<T>(Future<T> Function() task,
    {int retry = 3}) async {
  for (var i = 0; i < retry; i++) {
    try {
      return Res(await task());
    } catch (e) {
      if (i == retry - 1) {
        return Res.error(e.toString());
      }
      await Future.delayed(Duration(seconds: i + 1));
    }
  }
  throw UnimplementedError();
}

class _ImageDownloadWrapper {
  final ImagesDownloadTask task;

  final String chapter;

  final int index;

  String image;

  final Directory saveTo;

  _ImageDownloadWrapper(
    this.task,
    this.chapter,
    this.image,
    this.saveTo,
    this.index,
  ) {
    start();
  }

  bool isComplete = false;

  String? error;

  /// Whether the terminal failure was caused by a dead link (HTTP 404/410).
  bool deadLink = false;

  bool isCancelled = false;

  void cancel() {
    isCancelled = true;
  }

  var completers = <Completer<_ImageDownloadWrapper>>[];

  var retry = 4;

  /// Chunks received for the current attempt (io telemetry).
  int _chunks = 0;

  /// Number of retries already used for the current image.
  int _attempts = 0;

  /// Exponential backoff with jitter before a retry. Transient server
  /// errors (e.g. Cloudflare 520/521/530, 429) need time to recover;
  /// retrying immediately hammers the origin and wastes all attempts
  /// within milliseconds. Delays: ~0.8s, 1.6s, 3.2s, 6.4s (cap 8s).
  Future<void> _backoffBeforeRetry() async {
    var ms = min(800 * (1 << _attempts.clamp(0, 4)), 8000);
    ms = (ms * (0.85 + Random().nextDouble() * 0.3)).round();
    var waited = 0;
    while (waited < ms && !isCancelled) {
      await Future.delayed(const Duration(milliseconds: 100));
      waited += 100;
    }
  }

  void start() async {
    int lastBytes = 0;
    try {
      await for (var p in ImageDownloader.loadComicImageUnwrapped(
          image, task.source.key, task.comicId, chapter,
          writeCache: false)) {
        if (isCancelled) {
          return;
        }
        _chunks++;
        task.onData(p.currentBytes - lastBytes);
        lastBytes = p.currentBytes;
        if (p.imageBytes != null) {
          if (isCancelled) {
            return;
          }
          Log.info("Download",
              "[io] img#$index chunks=$_chunks bytes=${p.currentBytes}");
          var fileType = detectFileType(p.imageBytes!);
          var file = saveTo.joinFile("$index${fileType.ext}");
          await file.writeAsBytes(p.imageBytes!);
          isComplete = true;
          for (var c in completers) {
            c.complete(this);
          }
          completers.clear();
        }
      }
    } catch (e, s) {
      if (isCancelled) {
        return;
      }
      Log.error("Download", e.toString(), s);
      retry--;
      var statusCode = e is DioException ? e.response?.statusCode : null;
      var deadLink = statusCode == 404 || statusCode == 410;
      if (deadLink) {
        this.deadLink = true;
        var refreshed = await task.refreshChapterImages(chapter);
        var fresh = refreshed ? task.imageFor(chapter, index) : null;
        if (refreshed && fresh != null && fresh != image) {
          // Fresh signed URL available: retry immediately, no backoff.
          image = fresh;
          _attempts++;
          if (isCancelled) {
            return;
          }
          start();
          return;
        }
        // A refresh that produced no new URL is a permanently dead link:
        // fail fast instead of burning the retry/backoff chain.
        error = e.toString();
        task.onImageGaveUp(chapter, index, image);
        for (var c in completers) {
          if (!c.isCompleted) {
            c.complete(this);
          }
        }
        return;
      }
      if (retry > 0) {
        await _backoffBeforeRetry();
        _attempts++;
        if (isCancelled) {
          return;
        }
        start();
        return;
      }
      error = e.toString();
      task.onImageGaveUp(chapter, index, image);
      for (var c in completers) {
        if (!c.isCompleted) {
          c.complete(this);
        }
      }
    }
  }

  Future<_ImageDownloadWrapper> wait() {
    if (isComplete) {
      return Future.value(this);
    }
    var c = Completer<_ImageDownloadWrapper>();
    completers.add(c);
    return c.future;
  }
}

abstract mixin class _TransferSpeedMixin {
  int _bytesSinceLastSecond = 0;

  int _currentSpeed = 0;

  int get currentSpeed => _currentSpeed;

  Timer? timer;

  void onData(int length) {
    if (timer == null) return;
    if (length < 0) {
      return;
    }
    _bytesSinceLastSecond += length;
  }

  void onNextSecond(Timer t) {
    _currentSpeed = _bytesSinceLastSecond;
    _bytesSinceLastSecond = 0;
  }

  void runRecorder() {
    if (timer != null) {
      timer!.cancel();
    }
    _bytesSinceLastSecond = 0;
    timer = Timer.periodic(const Duration(seconds: 1), onNextSecond);
  }

  void stopRecorder() {
    timer?.cancel();
    timer = null;
    _currentSpeed = 0;
    _bytesSinceLastSecond = 0;
  }
}

class ArchiveDownloadTask extends DownloadTask {
  final String archiveUrl;

  final ComicDetails comic;

  late ComicSource source;

  /// Download comic by archive url
  ///
  /// Currently only support zip file and comics without chapters
  ArchiveDownloadTask(this.archiveUrl, this.comic) {
    source = ComicSource.find(comic.sourceKey)!;
  }

  FileDownloader? _downloader;

  String _message = "Fetching comic info...";

  bool _isRunning = false;

  bool _isError = false;

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    Log.error("Download", message);
  }

  @override
  void cancel() async {
    _isRunning = false;
    await _downloader?.stop();
    if (path != null) {
      Directory(path!).deleteIgnoreError(recursive: true);
    }
    path = null;
    LocalManager().removeTask(this);
  }

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  @override
  bool get isError => _isError;

  @override
  bool get isRunning => _isRunning;

  /// Last error message; null unless [isError].
  String? get error => isError ? _message : null;

  @override
  String? get cover => comic.cover;

  @override
  String get id => comic.id;

  @override
  bool get isPaused => !_isRunning;

  @override
  String get message => _message;

  int _currentBytes = 0;

  int _expectedBytes = 0;

  int _speed = 0;

  @override
  void pause() {
    _isRunning = false;
    _message = "Paused";
    _downloader?.stop();
    notifyListeners();
  }

  @override
  double get progress =>
      _expectedBytes == 0 ? 0 : _currentBytes / _expectedBytes;

  @override
  void resume() async {
    if (_isRunning) {
      return;
    }
    _isError = false;
    _isRunning = true;
    notifyListeners();
    _message = "Downloading...";

    if (path == null) {
      var dir = await LocalManager().findValidDirectory(
        comic.id,
        comicType,
        comic.title,
      );
      if (!(await dir.exists())) {
        try {
          await dir.create();
        } catch (e) {
          _setError("Error: $e");
          return;
        }
      }
      path = dir.path;
    }

    var archiveFile =
        File(FilePath.join(App.dataPath, "archive_downloading.zip"));

    Log.info("Download", "Downloading $archiveUrl");

    _downloader = FileDownloader(archiveUrl, archiveFile.path);

    bool isDownloaded = false;

    try {
      await for (var status in _downloader!.start()) {
        _currentBytes = status.downloadedBytes;
        _expectedBytes = status.totalBytes;
        _message =
            "${bytesToReadableString(_currentBytes)}/${bytesToReadableString(_expectedBytes)}";
        _speed = status.bytesPerSecond;
        isDownloaded = status.isFinished;
        notifyListeners();
      }
    } catch (e) {
      _setError("Error: $e");
      return;
    }

    if (!_isRunning) {
      return;
    }

    if (!isDownloaded) {
      _setError("Error: Download failed");
      return;
    }

    try {
      await _extractArchive(archiveFile.path, path!);
    } catch (e) {
      _setError("Failed to extract archive: $e");
      return;
    }

    await archiveFile.deleteIgnoreError();

    LocalManager().completeTask(this);
  }

  static Future<void> _extractArchive(String archive, String outDir) async {
    var out = Directory(outDir);
    if (out is AndroidDirectory) {
      // Saf directory can't be accessed by native code.
      var cacheDir = FilePath.join(App.cachePath, "archive_downloading");
      Directory(cacheDir).forceCreateSync();
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, cacheDir);
      });
      await copyDirectoryIsolate(Directory(cacheDir), Directory(outDir));
      await Directory(cacheDir).deleteIgnoreError(recursive: true);
    } else {
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, outDir);
      });
    }
  }

  @override
  int get speed => _speed;

  @override
  String get title => comic.title;

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ArchiveDownloadTask",
      "archiveUrl": archiveUrl,
      "comic": comic.toJson(),
      "path": path,
    };
  }

  static ArchiveDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ArchiveDownloadTask") {
      return null;
    }
    return ArchiveDownloadTask(
      json["archiveUrl"],
      ComicDetails.fromJson(json["comic"]),
    )..path = json["path"];
  }

  String _findCover() {
    var files = Directory(path!).listSync();
    for (var f in files) {
      if (f.name.startsWith('cover')) {
        return f.name;
      }
    }
    files.sort((a, b) {
      return a.name.compareTo(b.name);
    });
    return files.first.name;
  }

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic.id,
      title: title,
      subtitle: comic.subTitle ?? '',
      tags: comic.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: null,
      cover: _findCover(),
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: [],
      createdAt: DateTime.now(),
    );
  }
}
