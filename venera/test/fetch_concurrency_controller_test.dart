import 'package:venera/network/fetch_concurrency_controller.dart';

/// Scenario tests for the fetch concurrency state machine, driven by a
/// virtual clock so cooldowns/stability windows are instant.
/// Run: dart run test/fetch_concurrency_controller_test.dart

late DateTime _now;
DateTime _clock() => _now;
void adv(int seconds) => _now = _now.add(Duration(seconds: seconds));

FetchConcurrencyController make(int initial, {int maxProbeFailures = 2}) {
  _now = DateTime(2026, 8, 24, 20, 0, 0);
  return FetchConcurrencyController(
    initialThreads: initial,
    clock: _clock,
    maxProbeFailures: maxProbeFailures,
  );
}

void feedFast(FetchConcurrencyController c, int n, {int latencyMs = 800}) {
  for (var i = 0; i < n; i++) {
    c.record(latencyMs: latencyMs, success: true, throttled: false);
  }
}

void expect(bool cond, String name) {
  if (!cond) throw StateError('FAIL: $name');
  print('PASS $name');
}

void main() {
  // --- T1: NORMAL does not +1 on single fast requests -----------------
  var c = make(5);
  adv(5);
  feedFast(c, 5);
  expect(
      c.state == FetchCcState.normal &&
          c.currentThreads == 5 &&
          c.safeThreads == 5,
      'T1a healthy-but-young stays 5/NORMAL');
  adv(31); // stable >30s now
  feedFast(c, 7); // window reaches 12 samples -> probe
  expect(c.state == FetchCcState.probing && c.currentThreads == 6,
      'T1b after stable window -> PROBING 6');

  // --- T2: throttle during probe -> 6->5 BACKOFF, safe stays 5 --------
  c.record(latencyMs: 40000, success: true, throttled: true);
  expect(
      c.state == FetchCcState.backoff &&
          c.currentThreads == 5 &&
          c.safeThreads == 5 &&
          c.failureCount == 1 &&
          !c.probeDisabled,
      'T2 probe throttle -> 6->5 BACKOFF safe=5 (fail 1/2)');

  // --- T3: healthy requests during cooldown do NOT raise --------------
  adv(10);
  feedFast(c, 15);
  expect(c.state == FetchCcState.backoff && c.currentThreads == 5,
      'T3 cooldown blocks increase despite healthy requests');

  // --- T4: first-cooldown expiry still retries via PROBING ------------
  adv(21); // past 30s cooldown
  c.record(latencyMs: 700, success: true, throttled: false);
  expect(c.state == FetchCcState.probing && c.currentThreads == 6,
      'T4 cooldown end -> PROBING retry 6');

  // --- T13: STALE throttled completion must not kill a fresh probe ----
  final epBefore = c.epoch;
  c.record(
      latencyMs: 40000,
      success: true,
      throttled: true,
      epochAtStart: epBefore - 1); // dispatched before this probe regime
  expect(
      c.state == FetchCcState.probing && c.currentThreads == 6,
      'T13 stale in-flight throttle ignored by fresh probe');
  // A genuinely current-regime throttle still fails it immediately:
  c.record(latencyMs: 40000, success: true, throttled: true);
  expect(
      c.state == FetchCcState.backoff &&
          c.currentThreads == 5 &&
          c.failureCount == 2 &&
          c.consecutiveProbeFailures == 2 &&
          c.probeDisabled,
      'T5 second failure -> BACKOFF 60s AND probing DISABLED');
  final cd2 = c.cooldownUntil.difference(_now).inSeconds;
  expect(cd2 >= 59 && cd2 <= 61, 'T5b cooldown doubled to ~60s (${cd2}s)');

  // --- T14: after cap reached, expiry SETTLES at safeThreads ----------
  adv(61);
  feedFast(c, 12); // triggers evaluation past cooldown
  expect(
      c.state == FetchCcState.normal &&
          c.currentThreads == 5 &&
          c.safeThreads == 5,
      'T14a settled at verified-safe 5, state NORMAL');
  adv(100); // long healthy period
  feedFast(c, 20);
  expect(
      c.state == FetchCcState.normal &&
          c.currentThreads == 5 &&
          c.safeThreads == 5,
      'T14b no more probing: stays parked at 5 (no oscillation)');
  // Even an explicit throttle while NORMAL only sheds one step, then recovers
  // to the SAME safe level — never re-escalates into the old loop:
  c.record(latencyMs: 40000, success: true, throttled: true);
  expect(c.state == FetchCcState.backoff && c.currentThreads == 4,
      'T14c real throttle in settled mode -> 5->4 BACKOFF');
  final cd3 = c.cooldownUntil.difference(_now).inSeconds;
  expect(cd3 >= 29 && cd3 <= 31,
      'T14c2 settled-regime throttle uses base 30s cooldown (${cd3}s)');
  adv(31);
  feedFast(c, 12);
  expect(c.state == FetchCcState.normal && c.currentThreads == 4,
      'T14d settled again at new safe=4');

  // --- T6: success path on a fresh controller; ceiling respected ------
  c = make(5);
  adv(31);
  feedFast(c, 12); // -> PROBING 6
  expect(c.state == FetchCcState.probing && c.currentThreads == 6,
      'T6a enter probe 6');
  adv(25); // >=20s probe window
  feedFast(c, 12);
  expect(
      c.state == FetchCcState.normal &&
          c.currentThreads == 6 &&
          c.safeThreads == 6 &&
          c.failureCount == 0 &&
          c.consecutiveProbeFailures == 0,
      'T6b probe OK -> NORMAL safe=6 counters reset');
  adv(40);
  feedFast(c, 15);
  expect(c.currentThreads == 6 && c.state == FetchCcState.normal,
      'T6c ceiling respected: never 7');

  // --- T7: sustained slow (>=2 x >8s) in NORMAL -> decrease+BACKOFF ----
  c = make(4);
  feedFast(c, 10); // young state: stability timer blocks any raise
  c.record(latencyMs: 9000, success: true, throttled: false);
  expect(c.state == FetchCcState.normal && c.currentThreads == 4,
      'T7a single slow request is tolerated');
  c.record(latencyMs: 9500, success: true, throttled: false);
  expect(c.state == FetchCcState.backoff && c.currentThreads == 3,
      'T7b second slow request -> 4->3 BACKOFF');

  // --- T8: simultaneous completions cause only ONE adjustment ----------
  c = make(5);
  c.record(latencyMs: 40000, success: true, throttled: true);
  c.record(latencyMs: 42000, success: true, throttled: true);
  c.record(latencyMs: 39000, success: true, throttled: true);
  expect(c.currentThreads == 4 && c.state == FetchCcState.backoff,
      'T8 three simultaneous throttles -> single -1');

  // --- T9: floor at 1, never 0; cooldown escalates and caps at 300s ----
  c = make(1, maxProbeFailures: 99);
  c.record(latencyMs: 40000, success: true, throttled: true);
  expect(c.currentThreads == 1 && c.failureCount == 1,
      'T9a floor keeps threads=1');
  final cds = <int>[];
  for (var f = 2; f <= 5; f++) {
    adv(c.cooldownUntil.difference(_now).inSeconds + 1);
    c.record(latencyMs: 700, success: true, throttled: false); // -> PROBING
    c.record(latencyMs: 40000, success: true, throttled: true); // fail again
    cds.add(c.cooldownUntil.difference(_now).inSeconds);
    expect(c.currentThreads == 1, 'T9b failure#$f still threads=1');
  }
  expect(cds[0] >= 59 && cds[0] <= 61, 'T9c escalation 60s');
  expect(cds[1] >= 119 && cds[1] <= 121, 'T9d escalation 120s');
  expect(cds[3] == 300, 'T9e escalation capped at 300s');

  // --- T10: mid-band hysteresis (2s..8s dead zone) adjusts nothing -----
  c = make(5);
  const midBand = [1500, 1800, 2300, 3100, 1900, 4200];
  for (final l in midBand) {
    c.record(latencyMs: l, success: true, throttled: false);
  }
  feedFast(c, 6);
  expect(c.state == FetchCcState.normal && c.currentThreads == 5,
      'T10 dead-zone latencies never adjust');

  // --- T11: full anti-oscillation lifecycle ----------------------------
  c = make(5);
  adv(31);
  feedFast(c, 12); // -> PROBING 6
  expect(c.currentThreads == 6, 'T11a enter probe 6');
  c.record(latencyMs: 40000, success: true, throttled: true); // fail #1
  adv(29); // just before cooldown ends
  feedFast(c, 20);
  expect(c.state == FetchCcState.backoff && c.currentThreads == 5,
      'T11b no raise before cooldown elapses');
  adv(2);
  c.record(latencyMs: 700, success: true, throttled: false); // -> PROBING 6
  c.record(latencyMs: 41000, success: true, throttled: true); // fail #2
  expect(c.currentThreads == 5 && c.failureCount == 2 && c.probeDisabled,
      'T11c retried once only, failed -> disable probing');
  adv(61);
  feedFast(c, 25);
  expect(
      c.state == FetchCcState.normal &&
          c.currentThreads == 5 &&
          c.safeThreads == 5,
      'T11d settled permanently at verified-safe 5');
  adv(120);
  feedFast(c, 30);
  expect(c.currentThreads == 5,
      'T11e even long-term health never re-escalates within this run');

  // --- T12: isCoolingDown gates NEW dispatches during cooldown ----------
  c = make(3);
  expect(c.isCoolingDown == false, 'T12a normal -> not cooling');
  adv(31);
  feedFast(c, 12); // -> PROBING 4
  expect(c.state == FetchCcState.probing && c.currentThreads == 4,
      'T12b probing 4');
  c.record(latencyMs: 40000, success: true, throttled: true); // fail #1
  expect(
      c.state == FetchCcState.backoff &&
          c.currentThreads == 3 &&
          c.isCoolingDown == true &&
          !c.probeDisabled,
      'T12c backoff cooling: caller must pause new requests (fail 1/2)');
  adv(15); // still inside 30s cooldown
  expect(c.isCoolingDown == true, 'T12d mid-cooldown still pausing');
  adv(16); // past cooldownUntil
  expect(c.isCoolingDown == false, 'T12e cooldown expired, dispatch may resume');
  c.record(latencyMs: 700, success: true, throttled: false);
  expect(c.state == FetchCcState.probing, 'T12f resumes via PROBING');

  print('ALL PASS');
}
