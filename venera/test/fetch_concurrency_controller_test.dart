import 'package:venera/network/fetch_concurrency_controller.dart';

/// Scenario tests for the fetch concurrency state machine, driven by a
/// virtual clock so cooldowns/stability windows are instant.
/// Run: dart run test/fetch_concurrency_controller_test.dart

late DateTime _now;
DateTime _clock() => _now;
void adv(int seconds) => _now = _now.add(Duration(seconds: seconds));

FetchConcurrencyController make(int initial, {int maxProbeFailures = 1}) {
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

  // --- T2: throttle during FIRST probe -> immediate settle path --------
  c.record(latencyMs: 40000, success: true, throttled: true);
  expect(
      c.state == FetchCcState.backoff &&
          c.currentThreads == 5 &&
          c.safeThreads == 5 &&
          c.failureCount == 1 &&
          c.consecutiveProbeFailures == 1 &&
          c.probeDisabled,
      'T2 first probe throttle -> BACKOFF safe=5 AND probing DISABLED');

  // --- T3: healthy requests during cooldown do NOT raise --------------
  adv(10);
  feedFast(c, 15);
  expect(c.state == FetchCcState.backoff && c.currentThreads == 5,
      'T3 cooldown blocks increase despite healthy requests');

  // --- T13: STALE throttled completion must not kill a fresh state ----
  // (re-armed here on a fresh controller before its first probe)
  c = make(5);
  adv(31);
  feedFast(c, 12); // -> PROBING 6
  expect(c.state == FetchCcState.probing && c.currentThreads == 6,
      'T13a enter probe 6');
  final epBefore = c.epoch;
  c.record(
      latencyMs: 40000,
      success: true,
      throttled: true,
      epochAtStart: epBefore - 1); // dispatched before this probe regime
  expect(
      c.state == FetchCcState.probing && c.currentThreads == 6,
      'T13b stale in-flight throttle ignored by fresh probe');
  // A genuinely current-regime throttle still fails it immediately:
  c.record(latencyMs: 40000, success: true, throttled: true);
  expect(
      c.state == FetchCcState.backoff &&
          c.currentThreads == 5 &&
          c.probeDisabled,
      'T13c genuine probe throttle -> BACKOFF + disabled');
  final cdSettle = c.cooldownUntil.difference(_now).inSeconds;
  expect(cdSettle >= 29 && cdSettle <= 31,
      'T13d disabled-probe cooldown capped at base 30s (${cdSettle}s)');

  // --- T14: settled mode — periodic throttles PAUSE but never shed -----
  adv(31); // base 30s cooldown (capped, not doubled)
  feedFast(c, 12); // triggers evaluation past cooldown -> SETTLED at 5
  expect(
      c.state == FetchCcState.normal &&
          c.currentThreads == 5 &&
          c.safeThreads == 5,
      'T14a settled at verified-safe 5, state NORMAL');
  adv(100); // long healthy stretch
  feedFast(c, 20);
  // Periodic server-side throttle after plenty of healthy successes:
  c.record(latencyMs: 40000, success: true, throttled: true);
  expect(
      c.state == FetchCcState.backoff &&
          c.currentThreads == 5 &&
          c.safeThreads == 5,
      'T14b periodic throttle is pause-only: threads kept at 5');
  final cdS = c.cooldownUntil.difference(_now).inSeconds;
  expect(cdS >= 29 && cdS <= 31,
      'T14c settled-regime throttle uses base 30s cooldown (${cdS}s)');
  adv(31);
  feedFast(c, 12);
  expect(c.state == FetchCcState.normal && c.currentThreads == 5,
      'T14d resumed at the SAME level (no oscillation, no loss)');

  // --- T15: immediate re-throttle right after resume DOES shed ---------
  c = make(5);
  adv(31);
  feedFast(c, 12); // -> PROBING 6
  c.record(latencyMs: 40000, success: true, throttled: true); // fail #1
  adv(31);
  c.record(latencyMs: 700, success: true, throttled: false); // -> SETTLED 5
  expect(c.state == FetchCcState.normal && c.currentThreads == 5,
      'T15a settled at 5');
  c.record(latencyMs: 40000, success: true, throttled: true);
  expect(
      c.state == FetchCcState.backoff &&
          c.currentThreads == 4 &&
          c.safeThreads == 4,
      'T15b zero-healthy re-throttle sheds one worker (level too hot)');
  final cdHot = c.cooldownUntil.difference(_now).inSeconds;
  expect(cdHot >= 29 && cdHot <= 31, 'T15c shed path uses base cooldown');

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
  c.record(latencyMs: 40000, success: true, throttled: true); // fail -> disable
  adv(29); // just before cooldown ends
  feedFast(c, 20);
  expect(c.state == FetchCcState.backoff && c.currentThreads == 5,
      'T11b no raise before cooldown elapses');
  adv(2);
  feedFast(c, 25); // past cooldown: settles instead of probing again
  expect(
      c.state == FetchCcState.normal &&
          c.currentThreads == 5 &&
          c.safeThreads == 5,
      'T11c settled permanently at verified-safe 5');
  adv(120);
  feedFast(c, 30);
  expect(c.currentThreads == 5,
      'T11d even long-term health never re-escalates within this run');

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
          c.probeDisabled,
      'T12c backoff cooling: caller must pause new requests (disabled)');
  adv(15); // still inside 30s cooldown
  expect(c.isCoolingDown == true, 'T12d mid-cooldown still pausing');
  adv(16); // past cooldownUntil
  expect(c.isCoolingDown == false, 'T12e cooldown expired, dispatch may resume');
  c.record(latencyMs: 700, success: true, throttled: false);
  expect(
      c.state == FetchCcState.normal && c.currentThreads == 3,
      'T12f resumes SETTLED at safe=3 (no re-probe)');

  print('ALL PASS');
}
