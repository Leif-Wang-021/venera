import 'dart:async';

/// Ordered hand-off gate between the image-LIST fetching phase and the
/// image-DOWNLOAD phase of [ImagesDownloadTask].
///
/// The download side consumes chapters strictly in canonical (selected)
/// order so progress bookkeeping (`_chapter`/`_index` persistence,
/// per-chapter logs) behaves exactly like the previous serial
/// implementation; the only behavioural change is that a chapter becomes
/// downloadable the moment its list is ready instead of after the whole
/// task's lists have been fetched.
///
/// Termination safety: [releaseAll] wakes every parked waiter so a paused /
/// cancelled / errored task can never leave the pipeline hanging on a
/// completer future.
class ChapterReadyGate {
  ChapterReadyGate();

  List<String> _chapters = const [];
  bool _allReady = false;
  bool _released = false;
  final Set<int> _readyOrders = {};
  final Map<int, Completer<void>> _waiters = {};

  /// Number of chapters the pipeline will deliver.
  int get total => _chapters.length;

  /// Whether every chapter is already deliverable without waiting
  /// (restored task / single-chapter comic).
  bool get getReady => _allReady;

  /// Registers the canonical chapter order.
  ///
  /// [allReady] marks every chapter instantly ready — used when all lists
  /// already exist (restored task, single-chapter comics).
  void configure(List<String> orderedChapters, {bool allReady = false}) {
    _chapters = List.unmodifiable(orderedChapters);
    _allReady = allReady;
  }

  /// Signals that the chapter at canonical position [order] has its image
  /// list ready for downloading. Safe to call before anyone waits: the
  /// signal is remembered, so a late [waitReady] returns immediately.
  void markReady(int order) {
    _readyOrders.add(order);
    _waiters.remove(order)?.complete();
  }

  /// Resolves once [order]'s list is ready (or the gate was released).
  Future<void> waitReady(int order) async {
    if (_allReady || _released || _readyOrders.contains(order)) {
      return;
    }
    final c = _waiters.putIfAbsent(order, Completer<void>.new);
    // Double-check after registration: markReady may have run between the
    // fast-path check above and putIfAbsent.
    if (_readyOrders.contains(order)) {
      _waiters.remove(order);
      return;
    }
    await c.future;
  }

  /// Wakes every parked waiter. Called when the task terminates abnormally
  /// (error / pause / cancel) or when the fetch phase ends, so no caller
  /// can hang forever.
  void releaseAll() {
    _released = true;
    for (var c in _waiters.values) {
      if (!c.isCompleted) {
        c.complete();
      }
    }
    _waiters.clear();
  }

  String chapterAt(int order) => _chapters[order];
}
