import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:example/sdk/synthetic_cardiac_source.dart';

/// These assert the properties that make the simulated trace usable rather
/// than merely non-constant. A generator that passes "not always the same
/// number" while producing white noise across a 40 bpm span is useless to
/// every HRV feature downstream, so the interesting assertions here are about
/// range, autocorrelation and the RSA/exertion relationship — not about any
/// individual sample.
///
/// The source is seeded, so a failure is reproducible rather than flaky.
void main() {
  /// Run [minutes] of virtual time at 1 Hz and collect every packet.
  List<CardiacPacket> run(
    SyntheticCardiacSource source, {
    required int minutes,
    int startMs = 1_700_000_000_000,
  }) {
    final packets = <CardiacPacket>[];
    var now = startMs;
    for (var i = 0; i < minutes * 60; i++) {
      now += 1000;
      packets.addAll(source.advance(now, 1000));
    }
    return packets;
  }

  group('heart rate stays inside a healthy envelope', () {
    test('never leaves the configured bounds over half an hour', () {
      final source = SyntheticCardiacSource(seed: 7);
      final packets = run(source, minutes: 30);

      expect(packets, isNotEmpty);
      for (final p in packets) {
        expect(
          p.bpm,
          inInclusiveRange(45, 135),
          reason: 'a simulated rate outside this band is not a person',
        );
      }
    });

    test('every RR interval is a plausible beat interval', () {
      final source = SyntheticCardiacSource(seed: 11);
      final packets = run(source, minutes: 20);

      final allRr = packets.expand((p) => p.rrMs).toList();
      expect(allRr, isNotEmpty);
      for (final rr in allRr) {
        // The envelope implied by 48–132 bpm, with a little slack.
        expect(rr, inInclusiveRange(440, 1300));
      }
    });

    test('holds across several independent seeds', () {
      // One seed passing could be luck. The envelope is a hard clamp, so this
      // should hold for any seed — and if a future change makes it
      // seed-dependent, that is exactly the regression worth catching.
      for (final seed in [1, 2, 3, 42, 99]) {
        final packets = run(SyntheticCardiacSource(seed: seed), minutes: 10);
        final rates = packets.map((p) => p.bpm).toList();
        expect(rates.every((r) => r > 45 && r < 135), isTrue, reason: '$seed');
      }
    });
  });

  group('the trace has structure, not just spread', () {
    test('rate actually moves', () {
      final source = SyntheticCardiacSource(seed: 3);
      final rates = run(source, minutes: 30).map((p) => p.bpm).toList();

      final lo = rates.reduce(min);
      final hi = rates.reduce(max);
      // A pinned or near-pinned trace is the failure this whole file exists to
      // avoid — a demo showing 62 bpm forever proves nothing about the ingest
      // path having variability to work with.
      expect(
        hi - lo,
        greaterThan(12),
        reason: 'half an hour should include at least one activity episode',
      );
    });

    test('consecutive rates are correlated, not independent draws', () {
      final source = SyntheticCardiacSource(seed: 5);
      final rates = run(source, minutes: 25).map((p) => p.bpm).toList();

      // Mean absolute second-by-second change, against the spread of the
      // whole series. Independent uniform draws across the same span would
      // give a step size on the order of the span itself; a mean-reverting
      // walk gives a step far smaller.
      var stepSum = 0.0;
      for (var i = 1; i < rates.length; i++) {
        stepSum += (rates[i] - rates[i - 1]).abs();
      }
      final meanStep = stepSum / (rates.length - 1);
      final span = rates.reduce(max) - rates.reduce(min);

      expect(
        meanStep,
        lessThan(span / 4),
        reason:
            'a second-to-second jump comparable to the whole range means the '
            'series is noise, and every HRV feature read off it is an '
            'artifact of the generator',
      );
      expect(meanStep, greaterThan(0.0), reason: 'and it must not be flat');
    });

    test('visits more than one activity episode', () {
      final source = SyntheticCardiacSource(seed: 13);
      final labels = run(source, minutes: 40).map((p) => p.activityLabel);
      expect(labels.toSet().length, greaterThan(1));
    });
  });

  group('HRV behaves the way HRV does', () {
    test('RMSSD lands in a physiological band', () {
      final source = SyntheticCardiacSource(seed: 17);
      final rmssds = run(
        source,
        minutes: 30,
      ).map((p) => p.rmssdMs).whereType<double>().toList();

      expect(rmssds, isNotEmpty);
      final mean = rmssds.reduce((a, b) => a + b) / rmssds.length;
      // Wide on purpose: the point is that it is neither ~0 (no variability
      // at all) nor absurd (hundreds of ms, which no healthy adult sustains).
      expect(mean, inInclusiveRange(8, 120));
    });

    test('variability falls as rate rises', () {
      // RSA is suppressed by vagal withdrawal during exertion. Without this
      // relationship a simulated 110 bpm carries resting-level HRV, which is
      // a physiological impossibility to anything reading both.
      final source = SyntheticCardiacSource(seed: 23);
      final samples = run(
        source,
        minutes: 60,
      ).where((p) => p.rmssdMs != null).toList();

      final rates = samples.map((p) => p.bpm).toList()..sort();
      final lowCut = rates[(rates.length * 0.25).floor()];
      final highCut = rates[(rates.length * 0.75).floor()];

      final restingRmssd = samples
          .where((p) => p.bpm <= lowCut)
          .map((p) => p.rmssdMs!)
          .toList();
      final activeRmssd = samples
          .where((p) => p.bpm >= highCut)
          .map((p) => p.rmssdMs!)
          .toList();

      expect(restingRmssd, isNotEmpty);
      expect(activeRmssd, isNotEmpty);

      final restMean =
          restingRmssd.reduce((a, b) => a + b) / restingRmssd.length;
      final activeMean =
          activeRmssd.reduce((a, b) => a + b) / activeRmssd.length;

      expect(
        activeMean,
        lessThan(restMean),
        reason:
            'RMSSD must be lower in the upper rate quartile than the lower '
            'one; equal or inverted means RSA suppression is not wired up',
      );
    });
  });

  group('packet shape matches a BLE notification', () {
    test('carries one or more intervals under a single anchor', () {
      final source = SyntheticCardiacSource(seed: 29);
      final packets = run(source, minutes: 5);

      for (final p in packets) {
        expect(p.rrMs, isNotEmpty);
        // At resting rate a one-second notification carries one or two beats.
        // More than a handful means the beat generator is over-producing.
        expect(p.rrMs.length, lessThanOrEqualTo(4));
      }
    });

    test('anchors advance monotonically', () {
      // The rr/hr channels reject a backwards timestamp — their maths
      // accumulates forward, and a backdated sample corrupts HRV and the
      // dropout count. A generator that emits a non-monotonic anchor would
      // have every packet after it silently dropped.
      final source = SyntheticCardiacSource(seed: 31);
      final anchors = run(
        source,
        minutes: 15,
      ).map((p) => p.anchorTsMs).toList();

      for (var i = 1; i < anchors.length; i++) {
        expect(anchors[i], greaterThanOrEqualTo(anchors[i - 1]));
      }
    });

    test('beat rate roughly matches the reported rate', () {
      // Cross-check between the two things being pushed: if the number of
      // beats produced does not agree with the bpm reported alongside them,
      // one of the two is fiction independent of the other.
      final source = SyntheticCardiacSource(seed: 37);
      const minutes = 20;
      final packets = run(source, minutes: minutes);

      final beats = packets.fold<int>(0, (n, p) => n + p.rrMs.length);
      final beatsPerMinute = beats / minutes;

      final reported =
          packets.map((p) => p.bpm).reduce((a, b) => a + b) / packets.length;

      expect((beatsPerMinute - reported).abs(), lessThan(6.0));
    });

    test('a starved caller owes beats rather than losing the clock', () {
      // One 30 s advance should produce roughly 30 s of beats, not one.
      final source = SyntheticCardiacSource(seed: 41);
      final packets = source.advance(1_700_000_030_000, 30_000);
      final beats = packets.fold<int>(0, (n, p) => n + p.rrMs.length);
      expect(beats, greaterThan(20));
    });

    test('the beat generator is bounded against an absurd gap', () {
      // A day-long gap must not mint a day of beats. A real monitor would
      // have missed them, and the runtime records the dropout honestly.
      final source = SyntheticCardiacSource(seed: 43);
      final packets = source.advance(1_700_086_400_000, 86_400_000);
      final beats = packets.fold<int>(0, (n, p) => n + p.rrMs.length);
      expect(beats, lessThanOrEqualTo(512));
    });
  });

  test('the packet carries cardiac and an episode label, nothing else', () {
    final packets = run(SyntheticCardiacSource(seed: 47), minutes: 2);
    expect(packets, isNotEmpty);
    final p = packets.first;
    expect(p.rrMs, isNotEmpty);
    expect(p.bpm, greaterThan(0));
    expect(p.activityLabel, isNotEmpty);
  });

  test('a zero or negative advance produces nothing', () {
    final source = SyntheticCardiacSource(seed: 53);
    expect(source.advance(1_700_000_000_000, 0), isEmpty);
    expect(source.advance(1_700_000_000_000, -1000), isEmpty);
  });

  test('same seed, same trace', () {
    final a = run(
      SyntheticCardiacSource(seed: 61),
      minutes: 5,
    ).map((p) => p.bpm).toList();
    final b = run(
      SyntheticCardiacSource(seed: 61),
      minutes: 5,
    ).map((p) => p.bpm).toList();
    expect(a, equals(b));
  });
}
