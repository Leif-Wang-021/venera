import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:venera/foundation/app.dart';
import 'package:venera/utils/zip_worker.dart';
import 'package:venera/utils/io.dart';
import 'package:flutter/widgets.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/images.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/init.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';

void cliPrint(Map<String, dynamic> data) {
  hPrint('[CLI PRINT] ${jsonEncode(data)}');
}

/// Output sink for headless runs. GUI-subsystem executables on Windows do
/// not attach to the parent console, so every headless output line is
/// mirrored into this file when `--out=<path>` is provided.
File? _headlessOut;

void hPrint(String line) {
  // ignore: avoid_print
  print(line);
  _headlessOut?.writeAsStringSync('$line\n', mode: FileMode.append);
}

Future<void> runHeadlessMode(List<String> args) async {
  for (var a in args) {
    if (a.startsWith('--out=')) {
      try {
        _headlessOut = File(a.substring('--out='.length));
        _headlessOut!.writeAsStringSync('', mode: FileMode.write);
      } catch (_) {}
    }
  }
  hPrint('[headless] started args=$args');
  WidgetsFlutterBinding.ensureInitialized();
  hPrint('[headless] binding ok');
  if (args.contains('--ignore-disheadless-log')) {
    Log.isMuted = true;
  }
  if(Platform.isLinux || Platform.isMacOS){
    Directory.current = Platform.environment['HOME']!;
  }
  // The first arg is '--headless', so we look at the next ones.
  var commandIndex = args.indexOf('--headless') + 1;
  if (commandIndex >= args.length) {
    cliPrint({'status': 'error', 'message': 'No command provided for headless mode.'});
    exit(1);
  }

  // Need to initialize the app for some features to work
  hPrint('[headless] init begin');
  await init();
  hPrint('[headless] init done');

  var command = args[commandIndex];
  var subCommand = (commandIndex + 1 < args.length) ? args[commandIndex + 1] : null;

  // Hard watchdog: a hung command must never leave an orphaned process
  // (single-instance guard would block all later launches).
  var watchdog = Timer(const Duration(minutes: 10), () {
    cliPrint({'status': 'error', 'message': 'Headless command timed out.'});
    exit(3);
  });

  try {
    switch (command) {
    case 'webdav':
      if (subCommand == 'up') {
        cliPrint({'status': 'running', 'message': 'Uploading WebDAV data...'});
        await DataSync().uploadData();
        cliPrint({'status': 'success', 'message': 'Upload complete.'});
      } else if (subCommand == 'down') {
        cliPrint({'status': 'running', 'message': 'Downloading WebDAV data...'});
        await DataSync().downloadData();
        cliPrint({'status': 'success', 'message': 'Download complete.'});
      } else {
        cliPrint({'status': 'error', 'message': 'Invalid webdav command. Use "up" or "down".'});
        exit(1);
      }
      break;
    case 'updatescript':
      if (subCommand == 'all') {
        cliPrint({'status': 'running', 'message': 'Checking for comic source script updates...'});
        await ComicSourcePage.checkComicSourceUpdate();
        var updates = ComicSourceManager().availableUpdates;
        if (updates.isEmpty) {
          cliPrint({'status': 'success', 'message': 'No updates found.'});
        } else {
          var total = updates.length;
          var current = 0;
          var errors = 0;
          var updated = 0;
          cliPrint({
            'status': 'running',
            'message': 'Updating all comic source scripts...',
            'data': {
              'total': total,
              'current': 0,
              'updated': 0,
              'errors': 0,
            }
          });
          for (var key in updates.keys) {
            var source = ComicSource.find(key);
            if (source != null) {
              current++;
              var data = {
                'current': current,
                'total': total,
                'source': {
                  'key': source.key,
                  'name': source.name,
                  'version': source.version,
                  'url': source.url,
                }
              };
              try {
                await ComicSourcePage.update(source, false);
                updated++;
                cliPrint({
                  'status': 'running',
                  'message': 'Progress',
                  'data': data,
                });
              } catch (e) {
                errors++;
                cliPrint({
                  'status': 'running',
                  'message': 'ProgressError',
                  'data': {
                    ...data,
                    'error': e.toString(),
                  },
                });
              }
            }
          }
          cliPrint({
            'status': 'success',
            'message': 'All scripts updated.',
            'data': {
              'total': total,
              'updated': updated,
              'errors': errors,
            }
          });
        }
      } else {
        cliPrint({'status': 'error', 'message': 'Invalid updatescript command. Use "all".'});
        exit(1);
      }
      break;
    case 'updatesubscribe':
      cliPrint({'status': 'running', 'message': 'Updating subscribed comics...'});
      var folder = appdata.settings["followUpdatesFolder"];
      if (folder == null) {
        cliPrint({'status': 'error', 'message': 'Follow updates folder is not configured.'});
        exit(1);
      }

      var updateIndex = args.indexOf('--update-comic-by-id-type');
      if (updateIndex != -1) {
        var id = args[updateIndex + 1];
        var type = args[updateIndex + 2];
        var comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
        var comic = comics.firstWhere((c) => c.id == id && c.type.sourceKey == type);
        
        var result = await updateComic(comic, folder);
        
        Map<String, dynamic> data = {
          'current': 1,
          'total': 1,
          'comic': {
            'id': comic.id,
            'name': comic.name,
            'coverUrl': comic.coverPath,
            'author': comic.author,
            'type': comic.type.sourceKey,
            'updateTime': comic.updateTime,
            'tags': comic.tags,
          }
        };

        var message = 'Progress';
        if (result.errorMessage != null) {
          message = 'ProgressError';
          data['error'] = result.errorMessage;
        }

        cliPrint({
          'status': 'running',
          'message': message,
          'data': data,
        });

        cliPrint({
          'status': 'running',
          'message': 'Update check complete.',
          'data': {
            'total': 1,
            'updated': result.updated ? 1 : 0,
            'errors': result.errorMessage != null ? 1 : 0,
          }
        });

        await Future.delayed(const Duration(milliseconds: 500));
        var json = await getUpdatedComicsAsJson(folder);
        cliPrint({
          'status': result.errorMessage != null ? 'error' : 'success',
          'message': 'Updated comics list.',
          'data': jsonDecode(json),
        });
      } else {
        int total = 0;
        int updated = 0;
        int errors = 0;
        await for (var progress in updateFolder(folder, true)) {
          total = progress.total;
          updated = progress.updated;
          errors = progress.errors;
          Map<String, dynamic> data = {
            'current': progress.current,
            'total': progress.total,
          };
          if (progress.comic != null) {
            data['comic'] = {
              'id': progress.comic!.id,
              'name': progress.comic!.name,
              'coverUrl': progress.comic!.coverPath,
              'author': progress.comic!.author,
              'type': progress.comic!.type.sourceKey,
              'updateTime': progress.comic!.updateTime,
              'tags': progress.comic!.tags,
            };
          }
          var message = 'Progress';
          if (progress.errorMessage != null) {
            message = 'ProgressError';
            data['error'] = progress.errorMessage;
          }
          cliPrint({
            'status': 'running',
            'message': message,
            'data': data,
          });
        }
        cliPrint({
          'status': 'running',
          'message': 'Update check complete.',
          'data': {
            'total': total,
            'updated': updated,
            'errors': errors,
          }
        });
        await Future.delayed(const Duration(milliseconds: 500));
        var json = await getUpdatedComicsAsJson(folder);
        cliPrint({
          'status': errors > 0 ? 'error' : 'success',
          'message': 'Updated comics list.',
          'data': jsonDecode(json),
        });
      }
      break;
    case 'zipbench': {
      // Compression-worker benchmark / feasibility probe:
      // zipbench [files=300] [sizeKB=256] [cancelAfterMs=0]
      // Generates a synthetic tree under <cache>/zipbench_src (mixed
      // compressible + random content), runs the ZipCompression worker
      // isolate, prints throttled progress samples and a JSON summary.
      // cancelAfterMs>0 additionally exercises mid-flight cancellation:
      // expects a cancelled outcome, no .tmp residue and no output file.
      var rest = args.sublist(commandIndex + 1);
      var files = rest.isNotEmpty ? int.tryParse(rest[0]) ?? 300 : 300;
      var sizeKb = rest.length > 1 ? int.tryParse(rest[1]) ?? 256 : 256;
      var cancelAfterMs =
          rest.length > 2 ? int.tryParse(rest[2]) ?? 0 : 0;

      var cache = App.cachePath;
      var src = FilePath.join(cache, 'zipbench_src');
      var dst = FilePath.join(cache, 'zipbench_out.zip');
      var srcDir = Directory(src);
      if (srcDir.existsSync()) srcDir.deleteSync(recursive: true);
      srcDir.createSync(recursive: true);
      var outFile = File(dst);
      if (outFile.existsSync()) outFile.deleteSync();

      var rnd = Random(42);
      var chunk = List<int>.generate(64 * 1024, (i) => i & 0xFF); // compressible
      for (var i = 0; i < files; i++) {
        var sub = Directory(
            FilePath.join(src, 'ch${(i % 20).toString().padLeft(2, '0')}'));
        if (!sub.existsSync()) sub.createSync();
        var f = File(FilePath.join(
            sub.path, 'img_${i.toString().padLeft(5, '0')}.bin'));
        var sink = f.openWrite();
        for (var b = 0; b < sizeKb * 1024; b += chunk.length) {
          if (i % 3 == 0 && b % (128 * 1024) == 0) {
            sink.add(List<int>.generate(chunk.length, (_) => rnd.nextInt(256)));
          } else {
            sink.add(chunk);
          }
        }
        await sink.close();
      }
      var totalBytes = files * sizeKb * 1024;
      hPrint('[zipbench] generated $files files '
          '(${(totalBytes / 1048576).toStringAsFixed(1)} MB) at $src');

      var sw = Stopwatch()..start();
      var progressSamples = 0;
      var lastReported = -1.0;
      final handle = ZipCompression.start(
        src: src,
        dst: dst,
        onProgress: (p) {
          progressSamples++;
          lastReported = p.ratio;
          if (progressSamples <= 8 || progressSamples % 5 == 0) {
            hPrint('[zipbench] progress ${(p.ratio * 100).toStringAsFixed(1)}% '
                'files=${p.filesDone}/${p.filesTotal} '
                '(${(p.bytesDone / 1048576).toStringAsFixed(1)}MB)');
          }
        },
      );
      Timer? cancelTimer;
      var cancelSentAt = 0;
      if (cancelAfterMs > 0) {
        cancelTimer = Timer(Duration(milliseconds: cancelAfterMs), () {
          cancelSentAt = sw.elapsedMilliseconds;
          handle.cancel();
          hPrint('[zipbench] cancel requested at ${cancelSentAt}ms');
        });
      }

      var status = '';
      String? errorText;
      try {
        await handle.done;
        status = cancelAfterMs > 0 ? 'UNEXPECTED_SUCCESS' : 'success';
      } on ZipCancelledException {
        status = 'cancelled';
      } catch (e) {
        status = 'error';
        errorText = e.toString();
      }
      cancelTimer?.cancel();
      sw.stop();

      var outExists = outFile.existsSync();
      var tmpResidue = File('$dst.tmp').existsSync();
      cliPrint({
        'status': (status == 'error' ||
                status == 'UNEXPECTED_SUCCESS' ||
                tmpResidue)
            ? 'error'
            : 'success',
        'message': 'zipbench complete.',
        'data': {
          'mode': cancelAfterMs > 0 ? 'cancel' : 'full',
          'outcome': status,
          'error': errorText,
          'durationMs': sw.elapsedMilliseconds,
          'files': files,
          'sizeKB': sizeKb,
          'progressSamples': progressSamples,
          'lastRatio': lastReported,
          'outputExists': outExists,
          'tmpResidue': tmpResidue,
          'cancelSentAtMs': cancelSentAt,
        },
      });
      exit((status == 'error' || status == 'UNEXPECTED_SUCCESS' || tmpResidue ||
              (cancelAfterMs > 0 && status != 'cancelled'))
          ? 1
          : 0);
    }
    case 'dlbench': {
      // Real-pipeline download benchmark:
      // dlbench <sourceKey> <comicId> <chapterId> [maxImages=30] [threads=8]
      //         [bandwidthBytesPerSec]
      // Exercises the exact production primitives: AppDio pooled adapter,
      // interceptors and the ImageDownloader streaming path, with a 1-second
      // sampler that mirrors ImagesDownloadTask's speed accounting.
      var rest = args.sublist(commandIndex + 1);
      if (rest.length < 3) {
        cliPrint({'status': 'error',
          'message': 'usage: dlbench <sourceKey> <comicId> <chapterId> '
              '[maxImages] [threads] [bandwidthBps]'});
        exit(1);
      }
      var sourceKey = rest[0];
      var comicId = rest[1];
      var chapterId = rest[2];
      var maxImages = rest.length > 3 ? int.tryParse(rest[3]) ?? 30 : 30;
      var threads = rest.length > 4 ? int.tryParse(rest[4]) ?? 8 : 8;
      var bandwidth = rest.length > 5
          ? int.tryParse(rest[5]) ?? 7821200
          : 7821200; // measured via curl, see product_log_2026-8-24

      var source = ComicSource.find(sourceKey);
      if (source == null || source.loadComicPages == null) {
        cliPrint({'status': 'error', 'message': 'Source not found or has no '
            'loadComicPages: $sourceKey'});
        exit(1);
      }
      var pages = await source.loadComicPages!(comicId, chapterId);
      if (pages.error || pages.data.isEmpty) {
        cliPrint({'status': 'error',
          'message': 'loadComicPages failed: ${pages.errorMessage}'});
        exit(1);
      }
      hPrint('[headless] loadComicPages returned '
          'error=${pages.error} n=${pages.data.length}');
      var urls = pages.data.take(maxImages).toList();
      hPrint('[bench] source=$sourceKey comic=$comicId '
          'chapter=$chapterId images=${urls.length} threads=$threads');
      for (var u in urls) {
        hPrint('[bench] url: $u');
      }

      var next = 0;
      var totalBytes = 0;
      var zeroDeltaEvents = 0;
      var chunkCounts = <int>[];
      var peakOneSecond = 0;
      var pending = 0;

      final timer = Timer.periodic(const Duration(seconds: 1), (t) {
        hPrint('[bench][t=${t.tick}s] sampled=$pending B/s');
        if (pending > peakOneSecond) peakOneSecond = pending;
        pending = 0;
      });

      Future<void> worker() async {
        while (true) {
          var i = next++;
          if (i >= urls.length) return;
          int lastBytes = 0;
          int chunks = 0;
          await for (var p in ImageDownloader.loadComicImageUnwrapped(
              urls[i], sourceKey, comicId, chapterId,
              writeCache: false)) {
            chunks++;
            var delta = p.currentBytes - lastBytes;
            lastBytes = p.currentBytes;
            pending += delta;
            totalBytes += delta;
            if (delta <= 0 && chunks > 1) zeroDeltaEvents++;
          }
          chunkCounts.add(chunks);
          hPrint('[bench] img#$i done chunks=$chunks bytes=$lastBytes');
        }
      }

      final sw = Stopwatch()..start();
      await Future.wait(List.generate(threads, (_) => worker()));
      sw.stop();
      timer.cancel();

      chunkCounts.sort();
      var secs = sw.elapsedMilliseconds / 1000;
      var avg = totalBytes / 1048576 / secs;
      var pct = (totalBytes / secs / bandwidth * 100);
      var summary = {
        'images': urls.length,
        'totalMB': double.parse((totalBytes / 1048576).toStringAsFixed(2)),
        'elapsedS': double.parse(secs.toStringAsFixed(2)),
        'avgMBSec': double.parse(avg.toStringAsFixed(2)),
        'peakSampledBSec': peakOneSecond,
        'bandwidthBps': bandwidth,
        'pctOfBandwidth': double.parse(pct.toStringAsFixed(1)),
        'chunksMin': chunkCounts.first,
        'chunksMax': chunkCounts.last,
        'zeroDeltaEvents': zeroDeltaEvents,
      };
      cliPrint({'status': 'success', 'message': 'dlbench complete.',
          'data': summary});
      break;
    }
    case 'dltask': {
      // Runs a REAL ImagesDownloadTask (unregistered, so nothing is written
      // to the user's library) and samples its public speed getter every
      // second — the end-to-end verification of the speed pipeline:
      // wrapper.onData -> _TransferSpeedMixin -> task.speed.
      // dltask <sourceKey> <comicId> <chapterId[,chapterId...]> [seconds=25]
      var rest2 = args.sublist(commandIndex + 1);
      if (rest2.length < 3) {
        cliPrint({'status': 'error',
          'message': 'usage: dltask <sourceKey> <comicId> <chapterId[,chapter]> '
              '[seconds]'});
        exit(1);
      }
      var sourceKey = rest2[0];
      var comicId = rest2[1];
      var chapterIds = rest2[2].split(',');
      var seconds = rest2.length > 3 ? int.tryParse(rest2[3]) ?? 25 : 25;
      var source = ComicSource.find(sourceKey);
      if (source == null) {
        cliPrint({'status': 'error', 'message': 'Source not found: $sourceKey'});
        exit(1);
      }
      hPrint('[dltask] creating real ImagesDownloadTask '
          'comic=$comicId chapters=${chapterIds.length} first=${chapterIds.first}');
      var task = ImagesDownloadTask(
        source: source,
        comicId: comicId,
        comicTitle: 'headless-bench',
        chapters: chapterIds,
      );
      task.resume();
      final sw2 = Stopwatch()..start();
      var maxSpeed = 0;
      var done = Completer<void>();
      Timer.periodic(const Duration(seconds: 1), (t) {
        var s = task.speed;
        if (s > maxSpeed) maxSpeed = s;
        hPrint('[dltask][t=${t.tick}s] speed=$s B/s '
            'state=${task.isRunning ? "running" : (task.isError ? "error" : "done")}'
            '${task.isError ? " msg=${task.error}" : ""}');
        if ((!task.isRunning && t.tick > 1) || t.tick >= seconds + 5) {
          done.complete();
        }
      });
      // Keep sampling until the task settles or the cap is reached.
      while (!done.isCompleted) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
      cliPrint({'status': task.isError ? 'error' : 'success',
        'message': 'dltask finished in ${sw2.elapsedMilliseconds}ms',
        'data': {'peakSpeedBSec': maxSpeed,
            'error': task.isError ? task.error : null}});
      if (task.isError) {
        exit(1);
      }
      break;
    }
    case 'fetchbench': {
      // Image-list fetch benchmark (does NOT download images):
      // fetchbench <sourceKey> <comicId> <count> <threads>
      var rest2 = args.sublist(commandIndex + 1);
      if (rest2.length < 3) {
        cliPrint({'status': 'error',
          'message': 'usage: fetchbench <sourceKey> <comicId> <count> [threads]'});
        exit(1);
      }
      var sourceKey = rest2[0];
      var comicId = rest2[1];
      var count = int.tryParse(rest2[2]) ?? 6;
      var threads = rest2.length > 3 ? int.tryParse(rest2[3]) ?? 3 : 3;
      var source = ComicSource.find(sourceKey);
      if (source == null || source.loadComicPages == null) {
        cliPrint({'status': 'error', 'message': 'Source not found or no '
            'loadComicPages: $sourceKey'});
        exit(1);
      }
      hPrint('[fetchbench] loading comic info $comicId');
      var info = await source.loadComicInfo!(comicId);
      if (info.error || info.data.chapters == null) {
        cliPrint({'status': 'error', 'message': 'loadComicInfo failed'});
        exit(1);
      }
      var chs = info.data.chapters!.allChapters.keys
          .take(count.clamp(1, 100)).toList();
      hPrint('[fetchbench] chapters=$chs');
      var next = 0;
      var ok = 0;
      var err = 0;
      final sw = Stopwatch()..start();
      Future<void> worker() async {
        while (true) {
          var i = next++;
          if (i >= chs.length) return;
          try {
            var r = await source.loadComicPages!(comicId, chs[i]);
            if (r.error) {
              err++;
              hPrint('[fetchbench] ch$i error ${r.errorMessage}');
            } else {
              ok++;
              hPrint('[fetchbench] ch$i images=${r.data.length}');
            }
          } catch (e) {
            err++;
            hPrint('[fetchbench] ch$i exception $e');
          }
        }
      }
      await Future.wait(List.generate(threads, (_) => worker()));
      sw.stop();
      cliPrint({'status': 'success',
        'message': 'fetchbench complete',
        'data': {'chapters': chs.length, 'ok': ok, 'err': err, 'threads': threads,
          'elapsedS': double.parse((sw.elapsedMilliseconds / 1000).toStringAsFixed(1))}});
      break;
    }
    default:
      cliPrint({'status': 'error', 'message': 'Unknown command: $command'});
      exit(1);
    }
  } catch (e, st) {
    cliPrint({'status': 'error', 'message': 'Command failed: $e',
        'data': {'stack': '$st'}});
    exit(1);
  }
  watchdog.cancel();

  // Exit after command execution
  exit(0);
}
