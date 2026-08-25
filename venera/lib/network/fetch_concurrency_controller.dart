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
    this.maxProbeFailures = 1,
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
  /// this fetch run and settle at [safeThreads]. Default 1: for a source
  /// whose penalty window lasts minutes, EVERY probe attempt costs a full
  /// round of JS-side 210 sleeps (~20-60s drain, log section 九) — retrying
  /// probes only adds stalls without any realistic chance of the limit
  /// lifting mid-task. Healthy sources succeed their first probe and are
  /// unaffected.
  int consecutiveProbeFailures = 0;
  bool probeDisabled = false;

  /// Healthy successes since the last state transition. A throttle landing
  /// while this is still 0 means the current level is genuinely too hot
  /// (shed a worker); a throttle after many successes is the periodic burst
  /// quota of a long penalty window (pause only, keep workers).
  int _healthySinceResume = 0;

  // --- Start-rate governor: BURST / CRUISE ------------------------------
  // Generic online rate control (no source identity involved). Observable
  // signals only: "was this request punished" and "how expensive was the
  // penalty". w = target TOTAL spacing between request STARTS, enforced as
  // an absolute floor on the last ACTUAL dispatch instant, so any pacing
  // the source script does itself counts toward w instead of stacking.
  //
  //   BURST : w=0 full speed; observe M = inter-start spacing (EMA).
  //   CRUISE: seeded from M on first pressure event, then
  //           punished      -> w += 900 (cap 8000)
  //           healthy class -> every 3 ok: w *= 0.55 (fast way back to 0)
  //           non-healthy   -> every 6 ok: w *= 0.8, BUT exploration
  //                            freezes once the punishment budget
  //                            punBudget = clamp(40000/pest,1,3) is spent
  //                            (repeated expensive drains buy nothing).
  int _wMs = 0;
  int _okStreak = 0;
  DateTime _nextStartAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastStartAt;
  double _mObsEma = 0; // observed inter-start spacing (burst_M proxy)
  bool _mObsValid = false;
  double _emaHealthyMs = 1200; // typical unpunished completion latency
  int _pestMs = 0;
  bool? _healthyCls; // null until first pressure classification
  int punCount = 0;
  int punBudget = 0; // 0 = not set (healthy class ignores it anyway)

  int get startGapMs => _wMs;

  /// Last estimated penalty cost (ms above typical healthy latency).
  int get pestEstimateMs => _pestMs;

  /// Worker reports an actual dispatch instant (called right before the
  /// network call). Feeds the burst-spacing estimate used to seed w.
  void noteStart() {
    final now = _clock();
    if (_lastStartAt != null) {
      final d = now.difference(_lastStartAt!).inMilliseconds;
      if (d >= 200 && d <= 60000) {
        _mObsEma = _mObsValid ? (_mObsEma * 0.7 + d * 0.3) : d.toDouble();
        _mObsValid = true;
      }
    }
    _lastStartAt = now;
  }

  /// Book the next dispatch instant. Returns milliseconds the caller should
  /// wait before sending. Always 0 while no pacing is in force.
  int bookStartSlot() {
    final now = _clock();
    var base = now.isAfter(_nextStartAt) ? now : _nextStartAt;
    if (_wMs > 0 && _lastStartAt != null) {
      final floor = _lastStartAt!.add(Duration(milliseconds: _wMs));
      if (floor.isAfter(base)) base = floor;
    }
    _nextStartAt = base.add(Duration(milliseconds: _wMs));
    return base.difference(now).inMilliseconds;
  }

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
    if (success && !throttled) {
      _healthySinceResume++;
      _emaHealthyMs = _emaHealthyMs * 0.7 + latencyMs * 0.3;
      _okStreak++;
      // Cruise decay toward 0. Exploration (decaying w) freezes once the
      // punishment budget of a non-healthy source is spent.
      final budgetSpent =
          _healthyCls == false && punBudget > 0 && punCount > punBudget;
      if (!budgetSpent && _wMs > 0) {
        final need = _healthyCls == false ? 6 : 3;
        if (_okStreak >= need) {
          _wMs = _healthyCls == false ? (_wMs * 8 ~/ 10) : (_wMs * 55 ~/ 100);
          if (_wMs < 40) _wMs = 0; // negligible: snap back to full speed
          _okStreak = 0;
        }
      }
    }
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
          _toBackoff(now, 'rate limited during probe',
              fromProbe: true, latencyMs: last.latencyMs);
          return;
        case FetchCcState.normal:
          // Under a long server penalty window, throttles recur
          // periodically regardless of concurrency (log 2026-08-25:
          // identical ~10-request burst cycles at threads=1 AND threads=2).
          // Shedding workers for such transients is pure loss — pause
          // dispatch only. Shed one worker solely when the throttle lands
          // right after a resume with zero healthy successes in between,
          // which DOES indicate the level is genuinely too hot.
          _toBackoff(now, 'rate limited',
              shedWorker: _healthySinceResume == 0,
              latencyMs: last.latencyMs);
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
            _healthySinceResume = 0;
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
            _healthySinceResume = 0;
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
    _healthySinceResume = 0;
    _window.clear(); // baseline the probe observation window
    _log('PROBING threads=$currentThreads (safe=$safeThreads)');
  }

  void _toBackoff(DateTime now, String reason,
      {bool fromProbe = false, bool shedWorker = true, int? latencyMs}) {
    if (shedWorker && currentThreads > minThreads) {
      currentThreads--;
      if (safeThreads > currentThreads) {
        safeThreads = currentThreads;
      }
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
    // Once probing is disabled, escalation loses its purpose: the doubled
    // cooldown existed to space out PROBE retries. Resume at the settled
    // level after the plain base pause instead (log section 九).
    var effectiveCooldown = probeDisabled
        ? (cooldownSec > baseCooldown.inSeconds
            ? baseCooldown.inSeconds
            : cooldownSec)
        : cooldownSec;
    // With the start-rate governor ALREADY engaged, spacing is handled
    // continuously; long blind pauses are redundant. Keep only a short
    // transition breather (the throttled request already drained its
    // penalty inside the source script).
    if (probeDisabled && _wMs > 0 && effectiveCooldown > 10) {
      effectiveCooldown = 10;
    }
    cooldownUntil = now.add(Duration(seconds: effectiveCooldown));
    state = FetchCcState.backoff;
    _stateSince = now;
    _lastAdjustAt = now;
    _epoch++; // in-flight stragglers from the old regime become stale
    _healthySinceResume = 0;
    _nextStartAt = now; // re-anchor the slot pointer to this transition
    // Pressure adaptation AFTER the cooldown decision above, so the very
    // first contact keeps the full base pause and only later events enjoy
    // the governor's short breather.
    punCount++;
    if (latencyMs != null) {
      _pestMs = latencyMs - _emaHealthyMs.toInt();
      if (_pestMs < 500) _pestMs = 500;
      _healthyCls = _pestMs < 8000;
      if (_healthyCls == false && punBudget == 0) {
        punBudget = (40000 / _pestMs).floor().clamp(1, 3);
      }
    }
    if (_wMs == 0) {
      // Seed: non-healthy sources start near their observed sustainable
      // edge (burst spacing + bias); healthy ones barely back off.
      _wMs = _healthyCls == false
          ? (((_mObsValid ? _mObsEma : 3000) + 500).round().clamp(1500, 7000))
          : 600;
    } else {
      _wMs += 900; // additive climb per further pressure event
      if (_wMs > 8000) _wMs = 8000;
    }
    _okStreak = 0;
    _window.clear(); // one adjustment per control cycle; drop stale evidence
    _log(
        'BACKOFF ($reason${shedWorker ? "" : ", pause-only"}) '
        'threads=$currentThreads safe=$safeThreads '
        'cooldown=${effectiveCooldown}s'
        '${_wMs > 0 ? " w=${_wMs}ms" : ""}'
        '${_healthyCls != null ? (_healthyCls! ? " class=healthy" : " class=non-healthy pest=${_pestMs}ms") : ""} '
        '(failure#$failureCount'
        '${probeDisabled ? ", probing disabled" : ""})');
  }

  void _log(String message) {
    _onEvent?.call(message);
  }
}
