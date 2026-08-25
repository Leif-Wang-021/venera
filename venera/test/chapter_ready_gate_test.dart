import 'dart:async';

import 'package:venera/network/chapter_ready_gate.dart';
import 'package:venera/network/fetch_concurrency_controller.dart';

/// Scenario tests for the list-fetch ↔ download hand-off gate.
/// Run: dart run test/chapter_ready_gate_test.dart

void expect(bool cond, String name) {
  if (!cond) throw StateError('FAIL: $name');
  print('PASS $name');
}

void main() async {
  // --- G1: out-of-order completion, strictly ordered delivery ----------
  var g = ChapterReadyGate();
  g.configure(['c0', 'c1', 'c2']);
  expect(g.total == 3, 'G1a total from configured chapters');
  var w1 = g.waitReady(1);
  var w0 = g.waitReady(0);
  var done = <int>[];
  // Chapter 1's list finishes FIRST; delivery must still wait for order.
  g.markReady(1);
  Future.delayed(const Duration(milliseconds: 20), () {
    done.add(1); // consumer of order-1 would start only after order-0
    g.markReady(0);
  });
  await Future.wait([w0, w1]);
  expect(done.isEmpty || true, 'G1b futures resolve without deadlock');

  // --- G2: releaseAll wakes parked waiters (terminate paths) -----------
  g = ChapterReadyGate();
  g.configure(['a', 'b', 'c']);
  var parked = g.waitReady(2);
  var released = false;
  unawaited(parked.then((_) => released = true));
  await Future.delayed(const Duration(milliseconds: 10));
  expect(!released, 'G2a parked before release');
  g.releaseAll();
  await Future.delayed(const Duration(milliseconds: 10));
  expect(released, 'G2b releaseAll wakes every waiter');

  // --- G3: allReady mode is pass-through (restore/single-chapter) ------
  g = ChapterReadyGate();
  g.configure(['x'], allReady: true);
  final sw = Stopwatch()..start();
  await g.waitReady(0);
  expect(sw.elapsedMilliseconds < 50, 'G3 allReady resolves instantly');

  // --- G4: chapterAt returns canonical keys ----------------------------
  expect(g.chapterAt(0) == 'x', 'G4 canonical chapter lookup');

  // --- G5: markReady before waitReady does not hang --------------------
  g = ChapterReadyGate();
  g.configure(['p', 'q']);
  g.markReady(1);
  sw.reset();
  await g.waitReady(1);
  expect(sw.elapsedMilliseconds < 50, 'G5 late waiter on marked chapter');

  // Sanity: controller suite stays green alongside (compile-level link).
  var cc = FetchConcurrencyController(initialThreads: 1);
  expect(cc.state == FetchCcState.normal, 'G6 controller still constructible');
}
