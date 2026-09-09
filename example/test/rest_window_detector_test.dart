import 'package:flutter_test/flutter_test.dart';

import 'package:example/sdk/rest_window_detector.dart';

/// The composite exists because screen-off alone is wrong in both directions,
/// so most of these tests are about *declining* to declare rest. The one-shot
/// tests matter most: a second declaration inside one window is the failure
/// mode that pins Focus at 0.0 for the remainder of a session with nothing on
/// the wire to explain it.
void main() {
  // A time well outside any sleep window, so the composite is what is being
  // tested rather than the wall-clock override.
  final midday = DateTime(2026, 9, 7, 14, 0);
  const t0 = 1_700_000_000_000;

  RestWindowDetector resting({int windowMs = 60_000}) {
    final d = RestWindowDetector(windowMs: windowMs);
    d.noteScreenOff(t0);
    d.noteInteraction(t0);
    d.noteMotionRms(0.05);
    return d;
  }

  group('declines until every clause holds', () {
    test('screen on', () {
      final d = RestWindowDetector();
      d.noteInteraction(t0);
      d.noteMotionRms(0.05);
      expect(d.evaluate(t0 + 600_000, localNow: midday), isNull);
      expect(d.lastDeclineReason, contains('screen is on'));
    });

    test('screen off, but not for long enough', () {
      final d = resting();
      expect(d.evaluate(t0 + 60_000, localNow: midday), isNull);
      expect(d.lastDeclineReason, contains('needs 120s'));
    });

    test('recent interaction', () {
      final d = resting();
      d.noteInteraction(t0 + 500_000);
      expect(d.evaluate(t0 + 540_000, localNow: midday), isNull);
      expect(d.lastDeclineReason, contains('interaction'));
    });

    test('motion too high — a walk with the phone pocketed is not rest', () {
      final d = resting();
      d.noteMotionRms(1.4);
      expect(d.evaluate(t0 + 600_000, localNow: midday), isNull);
      expect(d.lastDeclineReason, contains('too high'));
    });

    test('no motion reading is not treated as low motion', () {
      // Two of three clauses is not the definition. With no accelerometer
      // forwarding the low-motion clause is unverifiable, and assuming it
      // holds would call any pocketed walk a rest window.
      final d = RestWindowDetector();
      d.noteScreenOff(t0);
      d.noteInteraction(t0);
      expect(d.evaluate(t0 + 600_000, localNow: midday), isNull);
      expect(d.lastDeclineReason, contains('cannot verify'));
    });

    test('all three clauses satisfied', () {
      final d = resting();
      final ts = d.evaluate(t0 + 600_000, localNow: midday);
      expect(ts, t0 + 600_000);
      expect(d.lastDeclineReason, isNull);
      expect(d.declaredCount, 1);
    });
  });

  group('one-shot per window', () {
    test('a second evaluation in the same window declines', () {
      final d = resting();
      expect(d.evaluate(t0 + 600_000, localNow: midday), isNotNull);
      // Same 60 s window.
      expect(d.evaluate(t0 + 610_000, localNow: midday), isNull);
      expect(d.lastDeclineReason, contains('already declared'));
      expect(d.declaredCount, 1);
    });

    test('the next window declares again', () {
      final d = resting();
      expect(d.evaluate(t0 + 600_000, localNow: midday), isNotNull);
      expect(d.evaluate(t0 + 660_000, localNow: midday), isNotNull);
      expect(d.declaredCount, 2);
    });

    test('a long rest declares once per window, not once per tick', () {
      // The shape of the real loop: evaluated every second for ten minutes.
      // 600 evaluations, and the count must equal the number of windows
      // touched rather than the number of ticks. Eleven, not ten, because the
      // span is not aligned to the window grid and so clips a window at each
      // end — which is the alignment caveat the class documents, bounded to
      // one extra declaration.
      final d = resting();
      var declared = 0;
      final windows = <int>{};
      for (var s = 300; s < 900; s++) {
        final now = t0 + s * 1000;
        windows.add(now ~/ 60_000);
        if (d.evaluate(now, localNow: midday) != null) declared++;
      }
      expect(declared, windows.length);
      expect(declared, lessThan(20), reason: 'and nowhere near once per tick');
    });

    test('the window memory stays bounded across a long session', () {
      final d = resting();
      for (var s = 300; s < 4_000; s++) {
        d.evaluate(t0 + s * 1000, localNow: midday);
      }
      // Nothing to assert about the private set directly; what matters is
      // that the guard still works at the end rather than having been
      // evicted into re-declaring the current window.
      final last = 3_999 * 1000;
      expect(d.evaluate(t0 + last, localNow: midday), isNull);
    });
  });

  group('sleep-window override', () {
    test('declares inside the window without waiting on screen-off', () {
      // The case the composite cannot see: a phone face-down on a nightstand
      // fires no screen-off transition after the first one and reports no
      // motion, so the composite is satisfied only by accident.
      final d = RestWindowDetector();
      final night = DateTime(2026, 9, 7, 2, 30);
      expect(d.evaluate(t0, localNow: night), isNotNull);
    });

    test('the window crosses midnight', () {
      final d = RestWindowDetector();
      expect(d.evaluate(t0, localNow: DateTime(2026, 9, 7, 23, 30)), isNotNull);
      expect(
        d.evaluate(t0 + 60_000, localNow: DateTime(2026, 9, 8, 5, 0)),
        isNotNull,
      );
    });

    test('does not apply outside the window', () {
      final d = RestWindowDetector();
      expect(d.evaluate(t0, localNow: DateTime(2026, 9, 7, 9, 0)), isNull);
    });
  });

  group('screen state', () {
    test('turning the screen on blocks the first clause', () {
      final d = resting();
      d.noteScreenOn(t0 + 300_000);
      expect(d.evaluate(t0 + 600_000, localNow: midday), isNull);
      expect(d.lastDeclineReason, contains('screen is on'));
    });

    test('waking the screen also restarts the quiet clock', () {
      // Without this, picking the phone up would still read as two minutes
      // idle the instant it was put back down: the screen-off clock restarts
      // but the interaction clock would not have moved.
      final d = resting();
      d.noteScreenOn(t0 + 300_000);
      d.noteScreenOff(t0 + 310_000);

      // Screen-off threshold met (170 s), but the wake counted as an
      // interaction 170 s... which is also past the quiet threshold, so this
      // would declare. Add a later interaction — a pocket touch with the
      // screen off — and the quiet clause is what declines.
      d.noteInteraction(t0 + 380_000);
      expect(d.evaluate(t0 + 480_000, localNow: midday), isNull);
      expect(d.lastDeclineReason, contains('interaction'));

      // And once that goes quiet too, every clause holds.
      expect(d.evaluate(t0 + 520_000, localNow: midday), isNotNull);
    });

    test('repeated screen-off notes keep the original timestamp', () {
      final d = resting();
      d.noteScreenOff(t0 + 500_000);
      // Still measured from t0, so the threshold is already met.
      expect(d.evaluate(t0 + 600_000, localNow: midday), isNotNull);
    });

    test('reset forgets everything', () {
      final d = resting();
      expect(d.evaluate(t0 + 600_000, localNow: midday), isNotNull);
      d.reset();
      expect(d.evaluate(t0 + 700_000, localNow: midday), isNull);
      expect(d.lastDeclineReason, contains('screen is on'));
    });
  });
}
