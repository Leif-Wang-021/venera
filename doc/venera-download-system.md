# Venera 下载系统架构与移植指南

> 适用版本：`main`（2026-09-28，含 HarmonyOS / OHOS 专项适配）
> 目标读者：要把这套下载/图片管线移植到其他 Flutter 项目的人
> 主要代码：
> - `venera/lib/network/download.dart`（任务与管线，约 1348 行）
> - `venera/lib/network/images.dart`（图片获取层）
> - `venera/lib/network/app_dio.dart`（HTTP 客户端与拦截器）
> - `venera/lib/network/chapter_ready_gate.dart`（列表/下载两阶段交接门）
> - `venera/lib/network/fetch_concurrency_controller.dart`（图片列表自适应并发控制）
> - `venera/lib/network/file_downloader.dart`（归档分块下载）
> - `venera/lib/foundation/local.dart`（本地库与任务持久化）
> - `venera/lib/foundation/cache_manager.dart`（图片缓存）
> - `venera/lib/network/cache.dart`、`proxy.dart`、`cloudflare.dart`、`cookie_jar.dart`
> - `venera/lib/utils/io.dart`（平台文件选择器，含 OHOS）
> - `venera/ohos/entry/src/main/cpp/CMakeLists.txt`、`ohos/entry/src/main/ets/plugins/VeneraFilePickerPlugin.ets`

---

## 1. 总览：分层架构

```
┌──────────────────────────────────────────────────────────────┐
│ 表现层  pages/downloading_page.dart（速度聚合、暂停/取消/置顶） │
├──────────────────────────────────────────────────────────────┤
│ 任务层  DownloadTask                                        │
│   ├─ ImagesDownloadTask   ← 按章节下载图片（主流程）          │
│   └─ ArchiveDownloadTask  ← 整本归档下载 + 解压               │
│ 调度：LocalManager.downloadingTasks（队列，只有队首在跑）     │
├──────────────────────────────────────────────────────────────┤
│ 管线层  chapter_ready_gate.dart（两阶段并行交接）             │
│         fetch_concurrency_controller.dart（列表阶段自适应并发）│
│         _ImageDownloadWrapper（单图重试/退避/死链刷新）       │
├──────────────────────────────────────────────────────────────┤
│ 网络层  app_dio.dart（AppDio = rhttp 连接池 或 dart:io）      │
│         拦截器：Cookie → NetworkCache → Cloudflare → 日志     │
│         proxy.dart / DNS Overrides / TLS 选项                 │
├──────────────────────────────────────────────────────────────┤
│ 存储层  LocalManager（本地漫画目录、章节净化名、任务 JSON）    │
│         CacheManager（图片缓存 sqlite + 文件）                │
│         FileDownloader（归档多线程 Range 下载 + 断点续传）     │
└──────────────────────────────────────────────────────────────┘
```

数据来源是漫画源（JS 脚本）暴露的三个函数：

- `loadComicInfo(comicId)` → `ComicDetails`（标题、封面、章节表等）
- `loadComicPages(comicId, chapterId?)` → `List<String>` 图片 URL 列表
- `getImageLoadingConfig(imageKey, comicId, chapterId)` → 图片请求配置（headers、method、data、`onLoadFailed`、`onResponse`、`modifyImage` 等 JS 钩子）

移植到别的项目时，这三个函数就是你需要替换的“源适配器接口”。

---

## 2. 一次完整下载的生命周期（时序）

以多章节下载为例：

1. 用户在详情页点下载 → 创建 `ImagesDownloadTask(source, comicId, comic, chapters?)`
2. `LocalManager().addTask(task)`：加入 `downloadingTasks`，持久化，调用 `downloadingTasks.first.resume()`（队列语义：只有队首真正在跑）
3. `resume()`：
   - `comic == null` → 调 `loadComicInfo` 补齐
   - `path == null` → `LocalManager().findValidDirectory(...)` 并创建漫画根目录
   - `_cover == null` → `ImageDownloader.loadThumbnail` 下载封面并落盘为 `cover.<ext>`
   - `_images == null`：
     - 无章节漫画：直接 `loadComicPages(comicId, null)`，单章模式
     - 多章节：`_images = {}`，**同时启动** `_fetchImageList()` 与 `_runDownloadPipeline()`；某章列表一到就能开始下载该章
   - 断点恢复：`_images` 已存在 → `_gate.configure(keys, allReady: true)`，直接顺序下载
4. `_fetchImageList()`：用 `FetchConcurrencyController` 控制并发，每章完成后 `_gate.markReady(order)`
5. `_runDownloadPipeline()`：按规范顺序 `for order in 0..total-1`，`await _gate.waitReady(order)`，然后 `_downloadChapterImages(...)`
6. `_downloadChapterImages()`：逐章创建 `_ImageDownloadWrapper`，单图写盘、计数、限流持久化
7. 全部完成 → `_finishTask()`：写汇总日志、`LocalManager().completeTask(this)` 入库、队列下一任务 `resume()`

关键点：**列表抓取和图片下载是并行的**，但章节消费顺序仍严格规范；两阶段的并发各自有界，不会超订阅。

---

## 3. 任务模型与持久化

### 3.1 `DownloadTask` 抽象

`lib/network/download.dart`

```dart
abstract class DownloadTask with ChangeNotifier {
  double get progress;      // 0..1
  bool get isError;
  bool get isPaused;
  bool get isRunning;
  int get speed;            // bytes/s
  void cancel();
  void pause();
  void resume();
  String get title;
  String? get cover;
  String get message;
  String? path;             // 漫画根目录；null 表示尚未分配
  Map<String, dynamic> toJson();
  LocalComic toLocalComic();
  String get id;
  ComicType get comicType;
  static DownloadTask? fromJson(Map<String, dynamic> json);
}
```

### 3.2 `ImagesDownloadTask` 关键状态

| 字段 | 含义 |
|---|---|
| `source` | `ComicSource` 适配器 |
| `comicId` / `comic` | 源漫画 id / 详情 |
| `chapters` | 选中的章节 id 列表；null = 全部章节 |
| `path` | 本地漫画根目录 |
| `_images` | `Map<章节id, List<图片URL>>` |
| `_downloadedCount` / `_totalCount` | 已下载 / 总图片数 |
| `_index` / `_chapter` | 当前图片下标 / 当前章节规范序 |
| `_gate` | `ChapterReadyGate` |
| `tasks` | `Map<int, _ImageDownloadWrapper>` 当前在途图片 |
| `_chapterRefresh` | 每章只刷新一次过期签名 URL |
| `_failedImages` / `_failedSamples` | 失败计数与样本 |
| `_deadLinkFailsInChapter` | 本章连续死链数（≥5 跳章） |

### 3.3 持久化格式

`LocalManager.saveCurrentDownloadingTasks()` 写入 `App.dataPath/downloading_tasks.json`：

```json
[
  {
    "type": "ImagesDownloadTask",
    "source": "sourceKey",
    "comicId": "123",
    "comic": { ...ComicDetails.toJson()... },
    "chapters": ["ch1", "ch2"],
    "path": "/.../local/漫画名",
    "cover": "file:///.../cover.jpg",
    "images": { "ch1": ["url1", "url2"] },
    "downloadedCount": 12,
    "totalCount": 100,
    "index": 3,
    "chapter": 0
  }
]
```

- 写盘节流：`_persistTaskProgress()` 每 5 张图或每 1 秒写一次，`pause()` 时强制写一次。
- `restoreDownloadingTasks()` 启动时读取；解析失败会删除坏文件并记日志。
- 已知边界：`DownloadTask.fromJson` 目前只分发 `ImagesDownloadTask`，`ArchiveDownloadTask` 有 `fromJson` 但不会被恢复。移植时若需要恢复归档任务，要补上这个 switch。

### 3.4 队列语义

- `LocalManager.downloadingTasks` 是列表，**只有 `first` 会被 `resume()`**。
- `completeTask()` 移除已完成任务，写入本地库，然后 `downloadingTasks.firstOrNull?.resume()`。
- `moveToFirst()` 用于“置顶”，会暂停旧队首、插入新队首、恢复新队首。
- `cancel()` 会从队列移除并删除本任务拥有的本地内容。

---

## 4. 两阶段并行：`ChapterReadyGate`

`lib/network/chapter_ready_gate.dart`（78 行，纯 Dart，零依赖，非常适合直接复制）

职责：列表抓取阶段与图片下载阶段之间的**有序交接门**。

```dart
class ChapterReadyGate {
  int get total;                 // 章节总数
  bool get getReady;             // 是否 allReady（恢复任务/单章）
  void configure(List<String> orderedChapters, {bool allReady = false});
  void markReady(int order);     // 第 order 章的列表已就绪
  Future<void> waitReady(int order);
  void releaseAll();             // 异常/暂停/取消时唤醒所有等待者
  String chapterAt(int order);
}
```

设计要点：

1. 下载侧严格按规范序（selected 顺序）等待，保证 `_chapter/_index` 持久化语义、单章日志与旧的串行实现一致。
2. `markReady` 先于 `waitReady` 也安全：就绪集合会记住，晚来的等待直接返回。
3. `releaseAll()` 在暂停、取消、错误、抓取阶段结束时调用，防止管线永久挂起。
4. 并发控制不变：
   - 列表阶段受 `imageListThreads` + `FetchConcurrencyController` 约束
   - 图片阶段受 `downloadThreads` 约束
   - 两阶段各自有界，不会叠加超订阅

移植时这个文件可以直接拿走，不需要任何改动。

---

## 5. 图片列表阶段：自适应并发控制器

`lib/network/fetch_concurrency_controller.dart`（486 行，纯 Dart，可单测）

Venera 的图片列表接口最容易触发源站限流（HTTP 210、连接重置、JS 内部 40s 惩罚等）。这个控制器不是简单的固定并发，而是状态机 + 观测 + 节奏器。

### 5.1 状态机

```
NORMAL ──健康稳定 30s──▶ PROBING(+1) ──探测成功──▶ NORMAL(safeThreads+1)
   ▲                          │
   │                          └─风控/持续慢──▶ BACKOFF
   └────────冷却到期──────── BACKOFF(30s→60s→…→300s)
```

主要参数（构造默认值）：

| 参数 | 默认 | 说明 |
|---|---|---|
| `minThreads` / `maxThreads` | 1 / 6 | 并发上下限 |
| `windowSize` | 20 | 观测窗口 |
| `minHealthySamples` | 10 | 健康窗口最小样本 |
| `healthyLatencyMs` | 2000 | 健康延迟上限 |
| `slowLatencyMs` | 8000 | 慢请求阈值 |
| `healthyRatio` | 0.9 | 健康样本占比 |
| `slowRequestThreshold` | 2 | 连续慢请求触发回退 |
| `stableDuration` | 30s | 稳定多久才尝试升并发 |
| `probeMinSamples` / `probeMinDuration` | 12 / 20s | 探测观察门槛 |
| `baseCooldown` / `maxCooldown` | 30s / 300s | 退避冷却 |
| `maxProbeFailures` | 1 | 探测失败几次后禁用探测（安家） |

### 5.2 观测信号

- `record(latencyMs, success, throttled, epochAtStart)`
- `throttled` 由调用方近似：**列表请求耗时 ≥ 15s** 视为明确限流（因为 JS 源脚本会吞掉 HTTP 210 并内部 sleep 40s，Dart 侧拿不到状态码）。
- `epochAtStart`：请求发起时的控制器 epoch。旧 regime 的迟到结果不会误判新状态（避免“旧请求的 40s sleep 把新探测打死”）。

### 5.3 自适应并发（NORMAL / PROBING / BACKOFF）

- NORMAL：持续慢 → BACKOFF；达到 `maxThreads` 或 `probeDisabled` → 保持；健康窗口满足且稳定 → PROBING（`currentThreads+1`）。
- PROBING：达到 `probeMinSamples` + `probeMinDuration` 且探测窗口健康 → 锁定 `safeThreads = currentThreads`，回 NORMAL；否则继续观察；风控/持续慢直接失败并进入 BACKOFF（`consecutiveProbeFailures`，达到上限就 `probeDisabled = true`，避免反复试探继续挨罚）。
- BACKOFF：冷却到期后：
  - `probeDisabled` → 回到 `safeThreads` 安家，重置 `failureCount`，清窗。
  - 否则 → 再次 PROBING（尝试更高并发）。
- NORMAL 态遇到风控会分流：
  - 恢复后**已有健康成功** → 判定为长惩罚窗的周期性配额事件，只 `pause-only` 冷却，不裁撤 worker、不下调 safe。
  - 恢复后**零健康** → 当前级别确实过热，才 `-1` 并夹紧 `safeThreads`。

### 5.4 发起节奏器（BURST / CRUISE）

这是为了解决“7 章快跑 → 48s 冻结”的锯齿问题：与其盲目冷却，不如把请求发起间隔贴合源站的回充速率，让流连续。

- `_wMs`：目标发起间隔总等待（0 = 全速）。
- `bookStartSlot()`：返回调用方应等待的毫秒数；保证“下次发起 ≥ 上次实际发起 + `_wMs`”。调用方在**不占并发许可**的情况下等待，避免阻塞其他 worker。
- `noteStart()`：记录实际发起时刻，维护相邻发起间隔 EMA（`_mObsEma`，200ms~60s 才采样）。
- 健康成功会衰减 `_wMs`：
  - healthy 分类：每 3 个健康成功 `w *= 0.55`
  - non-healthy：每 6 个健康成功 `w *= 0.8`，但惩罚预算 `punBudget = clamp(40000/pest, 1, 3)` 用完后冻结探索
  - `w < 40ms` 直接归零
- 风控时：
  - 首次：按观测发起间隔 M 种子（non-healthy 取 `clamp(M+500, 1500, 7000)`；healthy 取 600ms）
  - 后续：`w += 900ms`，封顶 8000ms
  - `pest = 风控请求耗时 - 健康耗时EMA`，用于 `healthy/non-healthy` 分类
- `isCoolingDown`：BACKOFF 冷却期内不派发任何新请求（继续发只会烧掉配额）。

### 5.5 在 `_fetchImageList()` 中的接线

```dart
final cc = FetchConcurrencyController(
  initialThreads: _imageListConcurrency,   // 来自 settings['imageListThreads']，clamp 1..8
  onEvent: (m) => Log.info("Download", "[fetch-cc] $m"),
);

Future<void> worker() async {
  while (_isRunning && !_isError) {
    // 1) 取规范序章节
    final slotMs = cc.bookStartSlot();     // 2) 预订发起时间槽
    // 等待 slotMs...
    while (_isRunning && !_isError &&
        (active >= cc.allowedConcurrent || cc.isCoolingDown)) {
      await Future.delayed(const Duration(milliseconds: 50));   // 3) 等许可
    }
    active++;
    cc.noteStart();
    final sw = Stopwatch()..start();
    final epoch = cc.epoch;
    final res = await _runWithRetry(() => source.loadComicPages!(comicId, chapter));
    cc.record(
      latencyMs: sw.elapsedMilliseconds,
      success: !res.error,
      throttled: sw.elapsedMilliseconds >= 15000,
      epochAtStart: epoch,
    );
    // 成功：_images[i] = res.data; _totalCount += ...; cpCount++;
    //       _gate.markReady(order);
    active--;
  }
}

await Future.wait(List.generate(6, (_) => worker()));  // 6 个 worker 竞争许可
_gate.releaseAll();
```

注意：这里启动 6 个 worker 只是“最多 6 个协程”，真正的网络并发由 `cc.allowedConcurrent` 控制。

---

## 6. 图片下载阶段

### 6.1 调度 `_scheduleTasks()`

- 从 `_gate.chapterAt(_chapter)` 拿当前章节键（**不能依赖 map 插入序**，并行下插入序 = 完成序）。
- 同章节目录只创建/检查一次（`saveTo`）。
- 从 `_index` 开始遍历图片，最多同时 `_maxConcurrentTasks = settings['downloadThreads']` 个在途。
- 每张图创建一个 `_ImageDownloadWrapper(task, chapter, url, saveTo, index)`，完成后再调 `_scheduleTasks()` 补位。

### 6.2 单图包装器 `_ImageDownloadWrapper`

核心逻辑：

1. `ImageDownloader.loadComicImageUnwrapped(image, sourceKey, comicId, chapter, writeCache: false)` 流式拉取。
2. 收到 `imageBytes` 时：
   - `detectFileType` 判断扩展名
   - `saveTo/<index><ext>` 写盘（下载任务**不写图片缓存**，只写本地漫画目录）
   - `isComplete = true`，唤醒所有 `wait()` 的 completer
3. 异常处理：
   - 404/410（死链）：`deadLink = true` → `task.refreshChapterImages(chapter)` 重新拉列表：
     - 若拿到不同的新 URL → 立刻用新 URL 重试（不走退避）
     - 若列表没变 → 判定永久死链，快速失败（不浪费退避链）
   - 其它异常：`retry = 4`，指数退避 + 抖动：
     - `800 * 2^attempts`，乘 `0.85~1.15` 抖动，封顶 8s
     - 依次约 0.8s → 1.6s → 3.2s → 6.4s
   - 重试耗尽：`error = ...`，`task.onImageGaveUp(...)`，唤醒 completer
4. `_TransferSpeedMixin`：`onData(增量字节)` 累计，1 秒 Timer 刷新 `currentSpeed`。

### 6.3 单图失败隔离与死章跳过

`_downloadChapterImages()` 中：

- 单图失败不会杀掉整个任务：记日志、留空位、继续下一张。
- 若本章连续死链数 ≥ `_deadLinkChapterSkipThreshold`（5）：
  - 把剩余图片全部计入失败
  - 取消本章所有在途 wrapper
  - 直接跳到下一章，避免“过期签名 URL 的整章空转几小时”。
- 非死链错误会重置连续计数。

### 6.4 过期签名 URL 刷新

很多源站给的是限时签名 URL，断点恢复几天后全部 404。`refreshChapterImages(chapter)`：

- `_chapterRefresh.putIfAbsent` 保证每章每个任务实例只刷新一次，防止刷新循环。
- 重新 `loadComicPages`，若 URL 列表逐项相同 → 返回 false；不同 → 替换 `_images[chapter]` 并持久化，返回 true。
- 刷新失败只记日志，不抛异常。

---

## 7. 网络层：`AppDio`

`lib/network/app_dio.dart`

### 7.1 客户端选择

```dart
class AppDio with DioMixin {
  AppDio([BaseOptions? options]) {
    this.options = options ?? BaseOptions();
    if (App.isOhos) {
      // OHOS：rhttp 的 Rust 引擎尚未构建，回退 dart:io
      httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
        var client = HttpClient();
        client.badCertificateCallback = (cert, host, port) {
          try {
            return appdata.settings['ignoreBadCertificate'] == true || App.isOhos;
          } catch (e) {
            return App.isOhos;
          }
        };
        return client;
      });
    } else {
      httpClientAdapter = RHttpAdapter();   // Rust 客户端连接池
    }
    if (App.isInitialized) {
      interceptors..add(CookieManagerSql(SingleInstanceCookieJar.instance!))
                  ..add(NetworkCacheManager())
                  ..add(CloudflareInterceptor())
                  ..add(MyLogInterceptor());
    }
  }
}
```

### 7.2 `RHttpAdapter` 连接池（桌面/Android）

这是把下载速度从“每请求一次完整 DNS+TCP+TLS 握手”提升到复用连接的关键改动。

- 池键：`proxy|verifyCertificates|sni|dnsOverrides`，最多 6 个客户端 LRU。
- `ClientSettings`：
  - `proxySettings`（无代理 / 指定代理）
  - `redirectSettings: limited(5)`
  - `timeoutSettings: connect 15s, keepAlive 60s, keepAlivePing 30s`
  - `throwOnStatusCode: false`
  - `dnsSettings: static(overrides)`
  - `tlsSettings: sni / verifyCertificates`
- 请求：`client.request(expectBody: stream)` → `HttpStreamResponse` → 转成 Dio `ResponseBody`。
- 创建失败会从池中移除，允许下次重试。

### 7.3 拦截器链

| 拦截器 | 作用 |
|---|---|
| `CookieManagerSql(SingleInstanceCookieJar)` | sqlite 持久化 Cookie，Cloudflare / 登录态共用 |
| `NetworkCacheManager` | 只缓存 GET、状态码 200、大小 <1MB；**210 绝不入缓存**（否则会被 JS 重试瞬间反复命中，变成 40s sleep 链） |
| `CloudflareInterceptor` | 检测 `cf-mitigated: challenge`，抛 `CloudflareException`；配合 `passCloudflare()` 用 WebView 取 `cf_clearance` |
| `MyLogInterceptor` | 默认只记 URL/状态码；`logNetworkVerbose` 打开才记完整 headers/body（全量日志本身会影响性能） |

`NetworkCacheManager` 的 TTL 规则：5 秒内直接命中；2 小时内用 HEAD 校验；`cache-time: long` 可 6 小时；服务端返回 210 时继续用缓存（不放大限流）。

### 7.4 代理与 DNS

- `proxy.dart`：`getProxy()` 1 秒缓存；设置支持 `direct` / `system` / 手动 `user:pass@host:port`；非 Linux 平台通过 MethodChannel 询问系统代理。
- `enableDnsOverrides` + `dnsOverrides`：把指定域名静态解析到指定 IP，走 rhttp `DnsSettings.static`。
- TLS：`ignoreBadCertificate`、`sni` 设置。

`AppDio.request()` 还支持 `prevent-parallel: true` 头：同一路径请求串行化。

---

## 8. 图片获取层：`ImageDownloader`

`lib/network/images.dart`

三个入口：

| 方法 | 用途 | 特点 |
|---|---|---|
| `loadThumbnail(url, sourceKey, [cid])` | 封面/缩略图 | 先查 CacheManager，成功后写缓存；支持 `cover.*` 二次解析 |
| `loadComicImage(imageKey, sourceKey, cid, eid)` | 阅读器加载 | 用 `_loadingImages` 去重，同一图片多监听者共享一个流 |
| `loadComicImageUnwrapped(..., {writeCache = true})` | 下载管线专用 | 不去重，直连；下载时传 `writeCache: false`，避免同一张图写两份盘 |

`_loadComicImage()` 的请求配置来自 `source.getImageLoadingConfig(imageKey, cid, eid)`，支持：

- `headers`（默认补 `user-agent: webUA`）
- `method` / `data`
- `onLoadFailed`（JS 钩子，最多重试 5 次，用于换域名/换 UA/刷新签名）
- `onResponse`（JS 钩子，对响应字节做处理，必须返回 `List<int>`）
- `modifyImage`（JS 图片处理，走 `modifyImageWithScript`）

`ImageDownloadProgress`：

```dart
class ImageDownloadProgress {
  final int currentBytes;
  final int? totalBytes;
  final Uint8List? imageBytes;   // 仅最后一帧非 null
}
```

图片缓存 `CacheManager`：

- sqlite `cache.db`（key/dir/name/expires/type）+ 文件 `App.cachePath/cache/<0..99>/<md5>`
- 默认 7 天过期；`cacheSize`（MB）控制上限，超限按 expires 清理
- `_scanDir` 在 Isolate 中执行；OHOS 下需要 `ensureSqliteLoadedInIsolate()` 重新注册原生库

---

## 9. 本地存储：`LocalManager`

`lib/foundation/local.dart`

### 9.1 目录布局

```
<App.dataPath>/local_path                 # 用户自定义存储路径
<App.dataPath>/local.db                   # 本地漫画 sqlite
<App.dataPath>/downloading_tasks.json     # 下载任务持久化
<storage path>/<漫画名>/                   # 漫画根目录
    cover.jpg
    <章节净化名>/0.jpg, 1.jpg, ...
```

- `findDefaultPath()`：Android 用 `getExternalStorageDirectories()/local`；iOS 用 Documents/local；OHOS/桌面用 `App.dataPath/local`。
- `_checkPathValidation()`：写测试文件失败就回退默认路径。
- `setNewPath(newPath)`：新建目录、校验可写、`copyDirectoryIsolate` 迁移旧内容、写 `local_path`、清空旧目录。
- `getChapterDirectoryName(name)`：把 `/ \ : * ? " < > |` 替换为 `_`，防止章节名破坏路径。
- `findValidDirectory(id, type, name)`：已有漫画返回其目录；否则截断到 80 字符并生成唯一目录名后创建。

### 9.2 任务队列 API

| 方法 | 说明 |
|---|---|
| `addTask(task)` | 入队、持久化、恢复队首 |
| `completeTask(task)` | `add(task.toLocalComic())` 入库、出队、持久化、恢复下一个 |
| `removeTask(task)` | 出队、持久化 |
| `moveToFirst(task)` | 置顶 |
| `saveCurrentDownloadingTasks()` | 写 JSON |
| `restoreDownloadingTasks()` | 启动恢复；坏文件删除 |

### 9.3 取消时删除本地内容

`ImagesDownloadTask.cancel()` 会：

1. `_isRunning = false`，取消所有在途 wrapper；
2. `_gate.releaseAll()` 唤醒管线；
3. `LocalManager().removeTask(this)`；
4. 异步 `_deleteLocalFolderAfterCancel()`：
   - 任务未入库（`LocalManager().find` 为 null）→ 删除整个任务目录；
   - 已入库 → 只删除本任务所选章节的净化名目录，不影响同漫画其它章节；
   - 3 次重试 × 300ms，兼容 Windows 上杀软/索引器短暂占用文件句柄；
   - 失败记 `Log.error` 并把 message 设为 `Cancelled (folder cleanup failed)`。

### 9.4 删除章节

`deleteComicChapters()` 更新数据库中的 `downloadedChapters`，把对应章节目录丢到独立 Isolate 里删除（避免阻塞 UI），并处理“删空后整本删除”。

---

## 10. 归档下载：`ArchiveDownloadTask` + `FileDownloader`

适用于源提供整本 zip/cbz 的场景。

### 10.1 `ArchiveDownloadTask`

1. `resume()`：分配目录 → `FileDownloader(archiveUrl, App.dataPath/archive_downloading.zip)` → 流式进度（bytes/s、总大小）→ 完成后解压。
2. `_extractArchive()`：
   - 普通目录：`Isolate.run(() => ZipFile.openAndExtract(archive, outDir))`
   - Android `AndroidDirectory`（SAF 无法被原生代码访问）：先解压到 cache，再 `copyDirectoryIsolate` 到目标目录，最后删 cache。
3. 删临时 zip，`completeTask`。
4. `cancel()`：停止 downloader、删除目标目录、`removeTask`。

### 10.2 `FileDownloader`

多线程 Range 分块 + 断点续传：

- HEAD 拿 `content-length`；块大小：默认 16MB，>512MB 用 32MB，>1GB 用 64MB。
- 状态文件 `<savePath>.download`，每行 `start-end-downloadedBytes`。
- `_scheduleDownload()` 最多 `maxConcurrent`（默认 4）个块并发，`Range: bytes=<start+downloaded>-<end-1>`。
- 每收满 16KB 写一次文件并更新状态文件（`_writeStatus`）。
- `stop()` 取消并关文件，下次继续。
- 注意：`FileDownloader` 内部用的是裸 `Dio()` + `IOHttpClientAdapter`（只处理代理），**不走 AppDio 的 Cookie/Cloudflare 拦截器**；需要鉴权的归档链接要自行改造。

---

## 11. UI 与遥测

### 11.1 下载页

`lib/pages/downloading_page.dart`：

- 顶部速度是**所有活跃任务聚合**（`sum(task.speed)`），不是只取第一个。
- 队首任务决定 Pause / Start 按钮。
- 每项显示标题、message、进度条；菜单提供 Cancel / Move To First。

### 11.2 日志与遥测

`ImagesDownloadTask` 会写这些日志（默认进 `logs.txt`）：

- `[io] img#<index> chunks=<n> bytes=<n>`：单图流式读取
- `[speed] current=<B/s> pending=<B> activeWorkers=<n>`：每 5 秒
- `Chapter '<x>' finished: <n> images in <s>s (<img/s>, threads=<n>)`
- `Task finished: <n> images in <s>s (<img/s> avg)`
- `Task finished with <n> failed images; first failed: ...`
- `[fetch-cc] ...`：并发控制器状态迁移 / BACKOFF / gap

### 11.3 Headless 基准工具

`lib/headless.dart` 提供：

- `dlbench`：真实图片管线基准（AppDio 池 + 拦截器 + ImageDownloader 流式）
- `dltask`：跑真实 `ImagesDownloadTask`（不入库）并每秒采样 `task.speed`
- `fetchbench`：只跑图片列表抓取基准

移植后建议保留类似的自测入口，下载优化没有基准就会变成玄学。

---

## 12. HarmonyOS / OHOS 专项适配（重点）

### 12.1 平台判定

`lib/foundation/app.dart`：

```dart
bool get isOhos => Platform.operatingSystem == 'ohos';
bool get isMobile => Platform.isAndroid || Platform.isIOS;   // 注意：OHOS 不算 mobile
```

移植时不要把 OHOS 当成 Android/iOS 的 `isMobile`，很多分支会漏。

### 12.2 HTTP 层：rhttp → dart:io

`AppDio` 在 OHOS 分支使用 `IOHttpClientAdapter`（见 7.1），原因：

- rhttp 的 Rust 引擎未为 OHOS 构建；
- `badCertificateCallback` 在 OHOS 上**直接放行坏证书**（`... || App.isOhos`），对齐原版 Rust 栈对国内漫画 CDN 过期证书的处理；
- 用 try/catch 兜底，确保设置尚未加载时也不会拒握手。

`utils/data_sync.dart` 同样在 OHOS 下传 `adapter: null`，不走 `RHttpAdapter`。

`file_downloader.dart` 本来就用 `IOHttpClientAdapter`，OHOS 可直接用。

### 12.3 sqlite 原生库

`lib/init.dart`：

```dart
if (App.isOhos) {
  // libvenerasqlite3.so 由 ohos entry 模块打包
  sqlite3_open.open.overrideForAll(
      () => ffi.DynamicLibrary.open('libvenerasqlite3.so'));
}
```

`lib/foundation/sqlite_isolate_init.dart`：

```dart
void ensureSqliteLoadedInIsolate() {
  if (Platform.operatingSystem == 'ohos') {
    sqlite3_open.open.overrideForAll(
        () => ffi.DynamicLibrary.open('libvenerasqlite3.so'));
  }
}
```

为什么需要第二份：Dart Isolate 有独立的顶层静态变量，主 Isolate 的 `overrideForAll` 不会带进子 Isolate。`CacheManager._scanDir`、导出/删除等 Isolate 任务必须在入口调用 `ensureSqliteLoadedInIsolate()`，否则报 `Unsupported operation: Unsupported platform: ohos`。

### 12.4 存储路径与沙箱

- `LocalManager.setNewPath()` 在 OHOS 下**跳过“目录必须为空”校验**：系统 Picker 返回的目录由应用自己新建、绝对可控，而且 `Directory.list()` 在沙箱文件系统上可能给出意外条目。
- OHOS 默认存储路径就是应用沙箱内的 `App.dataPath/local`（`findDefaultPath` 走 else 分支）。
- 目录迁移仍走 `copyDirectoryIsolate` + 可写性探针 `.venera_writable`。
- 应用设置里的“Set New Storage Path”在 OHOS 不再调用 `DirectoryPicker`，而是弹出应用内可写目录选择对话框（`settings/app.dart` 的 `_OhosStorageDirDialog`），因为 HarmonyOS 没有公开的“选择任意目录”API。

### 12.5 系统文件管理器接入

`lib/utils/io.dart` 通过 MethodChannel `venera/ohos_file` 接入：

| 方法 | 作用 |
|---|---|
| `openDocument(exts)` | DocumentViewPicker 文件模式（按后缀过滤）→ 复制到应用缓存 → 返回沙箱路径 |
| `pickDirectory()` | DocumentSelectOptions `selectMode=FOLDER` 拉起文件夹选择器 |
| `saveDocument(filename, dataBase64)` | DocumentSaveOptions 保存（小文件） |
| `saveFileFromPath(filename, srcPath)` | DocumentSaveOptions 保存，但**直接传源文件路径**给 ArkTS 拷贝 |

关键优化：导出 CBZ / 备份这类大文件**不再走 base64 大通道**，而是 `saveFileFromPath` 让 ArkTS 直接按路径复制。之前 base64 大 blob 会 OOM 崩溃。

ArkTS 侧实现：`ohos/entry/src/main/ets/plugins/VeneraFilePickerPlugin.ets`

- `openDocument`：选中文件后复制到应用缓存，返回 `{ path }`；
- `pickDirectory`：选中可写目录直接使用；不可写则回退应用公共 Download 目录 `/storage/Users/currentUser/Download/<bundle>/local_comics`（系统文件管理器可见、可写）；
- `saveDocument` / `saveFileFromPath`：写入用户选定的 URI。
- 踩坑记录：`AbilityPluginBinding.getActivity` 要改成 `getAbility().context`；`fs.fstatSync` 不存在；`openSync` 返回 `File`，写操作需要 `.fd`。

### 12.6 原生库打包（`ohos/entry/src/main/cpp/CMakeLists.txt`）

OHOS 没有现成的社区插件预编译库，所以把以下 Dart FFI 原生件在 entry 模块直接编译：

| 库 | 来源 | 用途 |
|---|---|---|
| `libvenerasqlite3.so` | vendored `sqlite/sqlite3.c` | 本地库/缓存数据库 |
| `libqjs.so` | `ohos_plugins/flutter_qjs` + quickjs-ng | 漫画源 JS 运行时 |
| `libzip_flutter.so` | `ohos_plugins/zip_flutter` | CBZ/zip 导入导出 |
| `liblodepng_flutter.so` | `ohos_plugins/lodepng_flutter` | PNG 编解码 |
| `libflutter_7zip.so` | `ohos_plugins/flutter_7zip` + LZMA SDK | 7z 归档 |

`pubspec.yaml` 里对 `flutter_qjs`、`lodepng_flutter`、`flutter_7zip`、`zip_flutter`、`flutter_saf`、`path_provider`、`file_selector` 使用 `dependency_overrides` 指向 `ohos_plugins/` 下的 vendor 实现。

构建环境（OHOS 专线）：

- `flutter_ohos` = `F:\flutter_ohos`（Flutter 3.35.8-ohos-1.0.3-beta，Dart 3.9.2）
- `JAVA_HOME` 指向 DevEco 的 jbr
- PATH 含 `flutter_ohos/bin` 与 DevEco 的 `ohpm/hvigor/node`
- 构建：`flutter build hap --debug` / `--release`
- 部署：`hdc install` / `bm install`

### 12.7 其它 OHOS 优化 / 已知边界

- 120Hz：`EntryAbility.ets` 用 `displaySync` 申请 `expected120/min90/max120`。
- 日志：hilog 与 Dart 日志混排，排查看设置→关于→导出 `logs.txt`；hilog ring buffer 容易轮转。
- 已知边界：
  - 沙箱目录在系统文件管理器中不可见（公共 Download 目录需要 URI 大改造）。
  - `copy_manga` 的 1 小时风控是源站特性，不是移植缺陷。
  - 部分海外源站 CDN 握手被重置（`Connection terminated during handshake`），与网络环境相关。
  - `ohos_surface_vulkan_impeller SetPresentInfo failed` 是渲染层告警，可忽略（不致命）。
  - `url_launcher_ohos` 打开某些 https 链接可能 `ACTIVITY_NOT_FOUND`。

---

## 13. 移植到其他 Flutter 项目的清单

### 13.1 建议直接复制的“核心资产”

按依赖从少到多：

1. **纯 Dart，无依赖（直接拿）**
   - `lib/network/chapter_ready_gate.dart`
   - `lib/network/fetch_concurrency_controller.dart`
2. **网络与图片层（改 import）**
   - `lib/network/app_dio.dart`
   - `lib/network/images.dart`
   - `lib/network/cache.dart`
   - `lib/network/proxy.dart`
   - `lib/network/cloudflare.dart`
   - `lib/network/cookie_jar.dart`
3. **下载任务层（需要源适配器/存储适配器）**
   - `lib/network/download.dart`
   - `lib/network/file_downloader.dart`
4. **存储与缓存**
   - `lib/foundation/local.dart`（可裁剪，只保留下载相关部分）
   - `lib/foundation/cache_manager.dart`
   - `lib/foundation/sqlite_isolate_init.dart`
5. **UI**
   - `lib/pages/downloading_page.dart`
6. **可选**
   - `lib/headless.dart` 的 `dlbench/dltask/fetchbench` 部分

### 13.2 需要抽象/替换的符号

| Venera 符号 | 移植时要替换成 |
|---|---|
| `ComicSource` / `ComicDetails` / `ComicChapters` | 你自己的源适配器：`loadComicInfo` / `loadComicPages` / `getImageLoadingConfig` |
| `App.dataPath` / `App.cachePath` | `path_provider` 的 ApplicationSupport / ApplicationCache |
| `appdata.settings[...]` | 你自己的设置读取（`downloadThreads`、`imageListThreads` 等） |
| `Log` | 你自己的 logger |
| `LocalManager` / `LocalComic` | 你自己的本地库（若不需要本地漫画库，可只保留目录与任务持久化） |
| `CacheManager` | 可替换为 `cached_network_image` 或你自己的缓存 |
| `FilePath` / `Res` / `detectFileType` | 通用工具，直接抄 |
| `ComicType` | 漫画源身份标识（可用 `sourceKey.hashCode`） |

### 13.3 依赖参考（pubspec）

核心：`dio`、`path_provider`、`sqlite3`（可选）、`crypto`（缓存 md5）

可选：
- `rhttp`：桌面/Android 连接池；不想引入可全平台用 `IOHttpClientAdapter`（会损失连接复用性能）
- `flutter_qjs`：只有需要执行漫画源 JS 时才需要
- `zip_flutter`、`flutter_7zip`、`lodepng_flutter`：只有需要 CBZ/7z 导入导出时才需要
- `flutter_saf`：Android SAF 目录访问才需要

### 13.4 平台适配矩阵

| 能力 | Android | Windows/macOS/Linux | OHOS |
|---|---|---|---|
| HTTP | rhttp（或 IO） | rhttp | **必须 dart:io（IOHttpClientAdapter）** |
| 坏证书放行 | 按设置 | 按设置 | **默认放行** |
| sqlite 原生库 | sqlite3_flutter_libs | sqlite3_flutter_libs | **libvenerasqlite3.so + isolate 重新注册** |
| 存储路径 | 外部存储/SAF | 用户目录 | **应用沙箱 + 无“任意目录”API** |
| 保存大文件 | flutter_file_dialog | 原生/系统对话框 | **DocumentSaveOptions + saveFileFromPath（免 base64）** |
| WebView | inappwebview | inappwebview/DesktopWebview | inappwebview ohos vendor |

### 13.5 推荐移植顺序

1. 先拿 `chapter_ready_gate` + `fetch_concurrency_controller`，写单测跑通。
2. 接 `AppDio` + 单图退避/重试 + `ImageDownloader`，用 1 个章节验证“列表抓取 → 图片落盘”。
3. 接 `LocalManager` 的目录/任务持久化，验证暂停恢复、取消删目录。
4. 接 `ImagesDownloadTask` 完整管线（两阶段并行 + 死链跳章 + 过期 URL 刷新）。
5. 加 UI 与速度聚合日志。
6. 需要整本归档再加 `ArchiveDownloadTask` + `FileDownloader`。
7. 最后做平台分支（Android SAF / OHOS dart:io + sqlite + Picker）。

### 13.6 验证方法

- 单测：
  - `test/fetch_concurrency_controller_test.dart`（58 断言）
  - `test/chapter_ready_gate_test.dart`（8 断言）
- Headless：
  - `dltask <source> <comic> <chapter> [seconds]`
  - `fetchbench <source> <comic> <count> [threads]`
  - `dlbench ...`
- 日志关键字：
  - `[fetch-cc]`：并发控制器状态
  - `[io] img#`：单图读取
  - `[speed]`：每秒速度
  - `Chapter ... finished` / `Task finished`：章节/任务吞吐

---

## 14. 调优参数速查

| 参数 | 位置 | 默认 | 建议 |
|---|---|---|---|
| `downloadThreads` | `appdata.settings` | 5 | 1~16；源站风控强时先降 |
| `imageListThreads` | `appdata.settings` | 3 | 1~8；控制器上限 6 |
| 单图重试次数 | `_ImageDownloadWrapper.retry` | 4 | 风控源可再加 |
| 单图退避 | `_backoffBeforeRetry` | 800ms→8s，±15% 抖动 | 不要改成 0 |
| 死链跳章阈值 | `_deadLinkChapterSkipThreshold` | 5 | 按源站稳定性调 |
| 列表重试 | `_runWithRetry` | 3 次，1s/2s | 可加抖动 |
| 列表“限流”判定 | `_fetchImageList` | 耗时 ≥15s | 适配你源脚本的 sleep 时长 |
| 任务写盘节流 | `_persistTaskProgress` | 每 5 张 / 1s | 磁盘慢可再放宽 |
| 缓存大小 | `cacheSize` | MB | 按设备 |
| 归档并发 | `FileDownloader.maxConcurrent` | 4 | 服务器支持 Range 时有效 |

---

## 15. 已知坑与注意事项

1. **不要用 map 插入序当章节序**：并行下 `_images` 的插入序 = 完成序，必须用 `_gate.chapterAt(order)`。
2. **暂停/取消必须 `_gate.releaseAll()`**，否则等待列表的管线会永久挂起。
3. **旧 epoch 的请求结果不能参与新状态决策**：JS 侧 40s sleep 会让“旧请求”在状态切换后才返回。
4. **210 不能进网络缓存**：会把一次限流放大成 JS 重试风暴。
5. **下载时用 `writeCache: false`**：否则同一张图写两份盘，吞吐被磁盘拖死。
6. **过期签名 URL 必须走 `refreshChapterImages`**，否则断点恢复后整章 404 空转。
7. **`DownloadTask.fromJson` 目前不恢复归档任务**：需要就补 switch。
8. **`FileDownloader` 不走 AppDio 拦截器**：Cookie/Cloudflare 不生效。
9. **OHOS 的 Isolate 必须重新注册 sqlite**：`ensureSqliteLoadedInIsolate()`。
10. **OHOS 大文件保存不要走 base64**：用 `saveFileFromPath`。
11. **`App.isMobile` 不包含 OHOS**：新增分支要显式判断 `App.isOhos`。
12. **rhttp 在 OHOS 不可用**：必须保留 `IOHttpClientAdapter` 回退分支。

---

## 16. 快速索引（文件 → 职责）

| 文件 | 职责 |
|---|---|
| `lib/network/download.dart` | `DownloadTask` / `ImagesDownloadTask` / `_ImageDownloadWrapper` / `ArchiveDownloadTask` / 两阶段管线 |
| `lib/network/chapter_ready_gate.dart` | 列表↔下载有序交接门（纯 Dart） |
| `lib/network/fetch_concurrency_controller.dart` | 列表阶段自适应并发 + 发起节奏器（纯 Dart） |
| `lib/network/images.dart` | `ImageDownloader`、图片配置/JS 钩子、缓存读写 |
| `lib/network/app_dio.dart` | `AppDio`、`RHttpAdapter`（连接池）、日志拦截器 |
| `lib/network/cache.dart` | `NetworkCacheManager`（HTTP 响应缓存） |
| `lib/network/proxy.dart` | 系统/手动代理解析与缓存 |
| `lib/network/cloudflare.dart` | CF 挑战检测与 WebView 过盾 |
| `lib/network/cookie_jar.dart` | sqlite CookieJar + 拦截器 |
| `lib/network/file_downloader.dart` | 多线程 Range 分块 + 断点续传 |
| `lib/foundation/local.dart` | 本地漫画库、目录、任务队列持久化、取消删目录 |
| `lib/foundation/cache_manager.dart` | 图片缓存（sqlite + 文件） |
| `lib/foundation/sqlite_isolate_init.dart` | OHOS Isolate sqlite 重新注册 |
| `lib/utils/io.dart` | 文件/目录选择器（含 OHOS MethodChannel） |
| `lib/pages/downloading_page.dart` | 下载页 UI 与速度聚合 |
| `lib/headless.dart` | `dlbench` / `dltask` / `fetchbench` 基准入口 |
| `ohos/entry/src/main/cpp/CMakeLists.txt` | OHOS 原生库（sqlite/qjs/zip/lodepng/7zip） |
| `ohos/entry/src/main/ets/plugins/VeneraFilePickerPlugin.ets` | OHOS 系统文件选择器桥接 |

---

_文档版本：2026-09-28。移植时请以当时 `main` 分支代码为准；日志见 `log/` 目录。_
