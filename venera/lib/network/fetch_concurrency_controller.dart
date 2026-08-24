import 'dart:collection';

/// Adaptive concurrency controller for the image-list fetching phase.
///
/// State machine: NORMAL -> PROBING -> (ok? NORMAL : BACKOFF) -> PROBING...
///
/// Design goals (see product_log 2026-08-24 section 六):
/// - find the largest *verified-safe* concurrency (safeThreads) instead of
///   oscillating +/-1 on every single request;
/// - hysteresis: 2s..8s is a dead zone, single outliers never adjust;
/// - explicit rate-limit (or >=2 sustained slow requests) drops concurrency
///   by exactly 1 and enters BACKOFF with exponential cooldown
///   30s -> 60s -> ... -> 300s;
/// - cooldown expiry re-enters PROBING (never directly increases);
/// - all evaluations are synchronous (Dart single isolate) so adjustments
///   are atomic; a minimum adjust interval plus window-clearing on
///   transitions prevents multi-step cascades when many requests finish
///   simultaneously.
///
/// Pure Dart on purpose: unit-testable without Flutter bindings.

enum FetchCcState { normal, probing, backoff }

class FetchRequestResult {
  FetchRequestResult({
    required this.at,
    required this.latencyMs,
    required this.success,
    required this.throttled,
    required this.concurrencyAtStart,
  });

  final DateTime at;
  final int latencyMs;
  final bool success;

  /// Explicit rate-control signal. The source scripts swallow HTTP 210 and
  /// translate it into very long internal waits, so the caller approximates
  /// "definitely throttled" with a latency floor (see integration site).
  final bool throttled;

  /// Concurrency at the moment this request STARTED (required to attribute
  /// slow requests to the right thread count).
  final int concurrencyAtStart;
}

class FetchConcurrencyController {
  FetchConcurrencyController({
    required int initialThreads,
    this.minThreads = 1,
    this.maxThreads = 6,
    this.windowSize = 20,
    this.minHealthySamples = 10,
    this.healthyLatencyMs = 2000,
    this.slowLatencyMs = 8000,
    this.healthyRatio = 0.9,
    this.slowRequestThreshold = 2,
    this.stableDuration = const Duration(seconds: 30),
    this.probeMinSamples = 12,
    this.probeMinDuration = const Duration(seconds: 20),
    this.baseCooldown = const Duration(seconds: 30),
    this.maxCooldown = const Duration(seconds: 300),
    DateTime Function()? clock,
    void Function(String message)? onEvent,
  })  : _clock = clock ?? DateTime.now,
        _onEvent = onEvent {
    currentThreads = initialThreads.clamp(minThreads, maxThreads).toInt();
    safeThreads = currentThreads;
    state = FetchCcState.normal;
    final now = _clock();
    _stateSince = now;
    _lastAdjustAt = now;
    cooldownUntil = now;
    probeStartedAt = now;
  }

  final int minThreads;
  final int maxThreads;
  final int windowSize;
  final int minHealthySamples;
  final int healthyLatencyMs;
  final int slowLatencyMs;
  final double healthyRatio;
  final int slowRequestThreshold;
  final Duration stableDuration;
  final int probeMinSamples;
  final Duration probeMinDuration;
  final Duration baseCooldown;
  final Duration maxCooldown;
  final DateTime Function() _clock;
  final void Function(String message)? _onEvent;

  final ListQueue<FetchRequestResult> _window = ListQueue<FetchRequestResult>();

  /// Currently applied concurrency (what workers wait on).
  int currentThreads = 3;

  /// Latest verified-safe concurrency.
  int safeThreads = 3;

  FetchCcState state = FetchCcState.normal;

  int failureCount = 0;

  DateTime _stateSince = DateTime.now();
  DateTime _lastAdjustAt = DateTime.now();
  DateTime cooldownUntil = DateTime.now();
  DateTime probeStartedAt = DateTime.now();

  int get allowedConcurrent => currentThreads;

  void record({
    required int latencyMs,
    required bool success,
    required bool throttled,
  }) {
    final now = _clock();
    _window.addLast(FetchRequestResult(
      at: now,
      latencyMs: latencyMs,
      success: success,
      throttled: throttled,
      concurrencyAtStart: currentThreads,
    ));
    while (_window.length > windowSize) {
      _window.removeFirst();
    }
    _evaluate(now);
  }

  // ------------------------------------------------------------------ //

  void _evaluate(DateTime now) {
    final last = _window.isNotEmpty ? _window.last : null;

    // Priority 1: explicit rate limiting.
    // NOTE: no rate gate here on purpose — the very first explicit throttle
    // MUST react immediately. Cascade protection comes from the BACKOFF
    // state itself: entering it clears the window and further throttle
    // reports land in the backoff branch and are ignored.
    if (last != null && last.throttled) {
      switch (state) {
        case FetchCcState.probing:
          _toBackoff(now, 'rate limited during probe');
          return;
        case FetchCcState.normal:
          _toBackoff(now, 'rate limited');
          return;
        case FetchCcState.backoff:
          // Cooldown already governs recovery; do not refresh it per request.
          break;
      }
    }

    switch (state) {
      case FetchCcState.normal:
        if (_sustainedSlow()) {
          _toBackoff(now, 'sustained slow requests');
          break;
        }
        if (currentThreads >= maxThreads) {
          break; // stay at ceiling, remain NORMAL
        }
        if (_healthyWindow() &&
            now.difference(_stateSince) >= stableDuration &&
            now.difference(_lastAdjustAt) >= stableDuration) {
          _enterProbing(now);
        }
        break;

      case FetchCcState.probing:
        if (_sustainedSlow()) {
          _toBackoff(now, 'sustained slow during probe');
          break;
        }
        final probeRecords = _window
            .where((r) => r.concurrencyAtStart == currentThreads)
            .toList(growable: false);
        final elapsed = now.difference(probeStartedAt);
        if (probeRecords.length >= probeMinSamples &&
            elapsed >= probeMinDuration) {
          if (_healthyWindowFor(probeRecords)) {
            // Probe succeeded: lock in the higher concurrency.
            safeThreads = currentThreads;
            failureCount = 0;
            state = FetchCcState.normal;
            _stateSince = now;
            _lastAdjustAt = now;
            _window.clear();
            _log('probe OK -> threads=$currentThreads (safe)');
          }
          // Otherwise keep observing; only throttle/sustained-slow fails a
          // probe early (hysteresis: mid-band latency never adjusts).
        }
        break;

      case FetchCcState.backoff:
        if (!now.isBefore(cooldownUntil)) {
          _log('cooldown ended -> PROBING (try ${currentThreads + 1})');
          _enterProbing(now);
        }
        break;
    }
  }

  // ------------------------------------------------------------------ //

  bool _healthyWindow() => _healthyWindowFor(_window.toList(growable: false));

  bool _healthyWindowFor(List<FetchRequestResult> rs) {
    if (rs.length < minHealthySamples) return false;
    var fast = 0;
    var slow = 0;
    var bad = 0;
    for (final r in rs) {
      if (!r.success || r.throttled) {
        bad++;
      } else if (r.latencyMs > slowLatencyMs) {
        slow++;
      } else if (r.latencyMs < healthyLatencyMs) {
        fast++;
      }
      // healthyLatency..slowLatency is the hysteresis dead zone.
    }
    if (bad > 0) return false;
    if (slow >= slowRequestThreshold) return false;
    return fast / rs.length >= healthyRatio;
  }

  bool _sustainedSlow() {
    var slow = 0;
    for (final r in _window) {
      if (!r.success || r.throttled || r.latencyMs > slowLatencyMs) {
        slow++;
      }
    }
    return slow >= slowRequestThreshold;
  }

  void _enterProbing(DateTime now) {
    if (currentThreads >= maxThreads) {
      // Already at ceiling: nothing to probe, remain/stay NORMAL.
      state = FetchCcState.normal;
      _stateSince = now;
      return;
    }
    currentThreads++;
    state = FetchCcState.probing;
    probeStartedAt = now;
    _stateSince = now;
    _lastAdjustAt = now;
    _window.clear(); // baseline the probe observation window
    _log('PROBING threads=$currentThreads (safe=$safeThreads)');
  }

  void _toBackoff(DateTime now, String reason) {
    if (currentThreads > minThreads) {
      currentThreads--;
    }
    if (safeThreads > currentThreads) {
      safeThreads = currentThreads;
    }
    failureCount++;
    final cooldownSec =
        (baseCooldown.inSeconds * (1 << (failureCount - 1))).clamp(
            baseCooldown.inSeconds, maxCooldown.inSeconds).toInt();
    cooldownUntil = now.add(Duration(seconds: cooldownSec));
    state = FetchCcState.backoff;
    _stateSince = now;
    _lastAdjustAt = now;
    _window.clear(); // one adjustment per control cycle; drop stale evidence
    _log(
        'BACKOFF ($reason) threads=$currentThreads safe=$safeThreads '
        'cooldown=${cooldownSec}s (failure#$failureCount)');
  }

  void _log(String message) {
    _onEvent?.call(message);
  }
}
