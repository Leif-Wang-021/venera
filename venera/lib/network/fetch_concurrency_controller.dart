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
    this.epochAtStart,
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

  /// Controller epoch captured when the request was dispatched. Requests
  /// that started before the latest state transition are STALE: their
  /// latency/throttle verdict belongs to a regime that is already gone and
  /// must not fail a freshly started probe or re-trigger backoff.
  /// null (= unknown / always fresh) is treated as current.
  final int? epochAtStart;
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
    this.maxProbeFailures = 2,
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
  final int maxProbeFailures;
  final DateTime Function() _clock;
  final void Function(String message)? _onEvent;

  final ListQueue<FetchRequestResult> _window = ListQueue<FetchRequestResult>();

  /// Currently applied concurrency (what workers wait on).
  int currentThreads = 3;

  /// Latest verified-safe concurrency.
  int safeThreads = 3;

  FetchCcState state = FetchCcState.normal;

  int failureCount = 0;

  /// Consecutive PROBE failures (reset on probe success). Once it reaches
  /// [maxProbeFailures] we stop trying to raise concurrency for the rest of
  /// this fetch run and settle at [safeThreads]: with a source whose penalty
  /// window lasts minutes, endless probe cycles only re-trigger the limit
  /// and stretch stalls exponentially (log 2026-08-24 section 八).
  int consecutiveProbeFailures = 0;
  bool probeDisabled = false;

  /// Bumped on every state transition. Requests dispatched under an older
  /// epoch are stale and excluded from all control decisions.
  int _epoch = 0;
  int get epoch => _epoch;

  DateTime _stateSince = DateTime.now();
  DateTime _lastAdjustAt = DateTime.now();
  DateTime cooldownUntil = DateTime.now();
  DateTime probeStartedAt = DateTime.now();

  int get allowedConcurrent => currentThreads;

  /// True while in BACKOFF and the cooldown has not expired yet. Callers
  /// should pause dispatching NEW requests during this window so the source
  /// quota recovers, instead of burning it at a lower concurrency.
  bool get isCoolingDown =>
      state == FetchCcState.backoff && _clock().isBefore(cooldownUntil);

  void record({
    required int latencyMs,
    required bool success,
    required bool throttled,
    int? epochAtStart,
  }) {
    final now = _clock();
    _window.addLast(FetchRequestResult(
      at: now,
      latencyMs: latencyMs,
      success: success,
      throttled: throttled,
      concurrencyAtStart: currentThreads,
      epochAtStart: epochAtStart,
    ));
    while (_window.length > windowSize) {
      _window.removeFirst();
    }
    _evaluate(now);
  }

  // ------------------------------------------------------------------ //

  void _evaluate(DateTime now) {
    final last = _window.isNotEmpty ? _window.last : null;

    // Priority 1: explicit rate limiting — but only from requests dispatched
    // under the CURRENT regime. A throttled completion from a request that
    // started before the latest transition (e.g. a JS-side 40s sleep still
    // draining when a probe begins) must not instantly kill the new state.
    if (last != null &&
        last.throttled &&
        !_isStale(last)) {
      switch (state) {
        case FetchCcState.probing:
          _toBackoff(now, 'rate limited during probe', fromProbe: true);
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
        if (currentThreads >= maxThreads || probeDisabled) {
          break; // ceiling reached or probing retired: stay NORMAL
        }
        if (_healthyWindow() &&
            now.difference(_stateSince) >= stableDuration &&
            now.difference(_lastAdjustAt) >= stableDuration) {
          _enterProbing(now);
        }
        break;

      case FetchCcState.probing:
        if (_sustainedSlow()) {
          _toBackoff(now, 'sustained slow during probe', fromProbe: true);
          break;
        }
        final probeRecords = _window
            .where((r) =>
                !_isStale(r) && r.concurrencyAtStart == currentThreads)
            .toList(growable: false);
        final elapsed = now.difference(probeStartedAt);
        if (probeRecords.length >= probeMinSamples &&
            elapsed >= probeMinDuration) {
          if (_healthyWindowFor(probeRecords)) {
            // Probe succeeded: lock in the higher concurrency.
            safeThreads = currentThreads;
            failureCount = 0;
            consecutiveProbeFailures = 0;
            state = FetchCcState.normal;
            _stateSince = now;
            _lastAdjustAt = now;
            _epoch++; // fresh regime at the higher level
            _window.clear();
            _log('probe OK -> threads=$currentThreads (safe)');
          }
          // Otherwise keep observing; only throttle/sustained-slow fails a
          // probe early (hysteresis: mid-band latency never adjusts).
        }
        break;

      case FetchCcState.backoff:
        if (!now.isBefore(cooldownUntil)) {
          if (probeDisabled) {
            currentThreads = safeThreads;
            state = FetchCcState.normal;
            _stateSince = now;
            _epoch++;
            // Fresh regime: later real throttles start from base cooldown
            // again instead of inheriting the probe-loop escalation.
            failureCount = 0;
            _window.clear();
            _log('cooldown ended -> SETTLED at safe=$safeThreads '
                '(probing disabled after $consecutiveProbeFailures failures)');
          } else {
            _log('cooldown ended -> PROBING (try ${currentThreads + 1})');
            _enterProbing(now);
          }
        }
        break;
    }
  }

  bool _isStale(FetchRequestResult r) =>
      r.epochAtStart != null && r.epochAtStart != _epoch;

  List<FetchRequestResult> get _fresh =>
      _window.where((r) => !_isStale(r)).toList(growable: false);

  // ------------------------------------------------------------------ //

  bool _healthyWindow() => _healthyWindowFor(_fresh);

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
    for (final r in _fresh) {
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
    _epoch++; // requests dispatched from now on belong to the probe regime
    _window.clear(); // baseline the probe observation window
    _log('PROBING threads=$currentThreads (safe=$safeThreads)');
  }

  void _toBackoff(DateTime now, String reason, {bool fromProbe = false}) {
    if (currentThreads > minThreads) {
      currentThreads--;
    }
    if (safeThreads > currentThreads) {
      safeThreads = currentThreads;
    }
    failureCount++;
    if (fromProbe) {
      consecutiveProbeFailures++;
      if (consecutiveProbeFailures >= maxProbeFailures) {
        probeDisabled = true;
      }
    }
    final cooldownSec =
        (baseCooldown.inSeconds * (1 << (failureCount - 1))).clamp(
            baseCooldown.inSeconds, maxCooldown.inSeconds).toInt();
    cooldownUntil = now.add(Duration(seconds: cooldownSec));
    state = FetchCcState.backoff;
    _stateSince = now;
    _lastAdjustAt = now;
    _epoch++; // in-flight stragglers from the old regime become stale
    _window.clear(); // one adjustment per control cycle; drop stale evidence
    _log(
        'BACKOFF ($reason) threads=$currentThreads safe=$safeThreads '
        'cooldown=${cooldownSec}s (failure#$failureCount'
        '${probeDisabled ? ", probing disabled" : ""})');
  }

  void _log(String message) {
    _onEvent?.call(message);
  }
}
