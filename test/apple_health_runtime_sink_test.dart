// SPDX-License-Identifier: Apache-2.0
//
// Unit tests for `AppleHealthDailyAggregator` — the per-day rollup
// that turns Apple Health samples into the daily aggregates the
// runtime SRM consumes.
//
// `AppleHealthRuntimeSink` itself isn't covered here: it composes
// `AppleXmlBackfillSink` (FFI) with the aggregator, so it requires a
// live runtime to test end-to-end. The aggregator is the part with
// real logic worth testing in isolation.

import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/synheart_core.dart';
// Prefixed because `synheart_core` re-exports a different `SleepStage`
// (from `models/sleep_score.dart`). The aggregator's API takes the
// Apple-Health-flavoured one defined in `synheart_wear`, so we lock
// that to a prefix and only refer to it via `wear.SleepStage`.
import 'package:synheart_wear/synheart_wear.dart' as wear;

void main() {
  group('AppleHealthDailyAggregator', () {
    late AppleHealthDailyAggregator agg;
    late List<_Pushed> pushed;

    setUp(() {
      agg = AppleHealthDailyAggregator();
      pushed = <_Pushed>[];
    });

    int capture({
      required String provider,
      required String metric,
      required DateTime date,
      required double value,
      bool vendorSummary = true,
    }) {
      expect(provider, 'apple_health');
      pushed.add(_Pushed(metric, _dayOf(date), value, vendorSummary));
      return 0;
    }

    wear.AppleHealthSample hr(int day, double bpm) => wear.AppleHealthSample(
      metric: wear.AppleHealthMetric.heartRate,
      source: 'Apple Watch',
      startMs: _localMs(day, 12),
      endMs: _localMs(day, 12),
      value: wear.QuantityValue(bpm),
    );

    wear.AppleHealthSample sleep(
      int dayEndOn,
      wear.SleepStage stage,
      int durationMin,
    ) => wear.AppleHealthSample(
      metric: wear.AppleHealthMetric.sleepStage,
      source: 'Apple Watch',
      // Block ends at 07:00 of the target day.
      endMs: _localMs(dayEndOn, 7),
      startMs: _localMs(dayEndOn, 7) - durationMin * 60_000,
      value: wear.SleepStageValue(stage),
    );

    test('starts empty', () {
      expect(agg.hasAnyEntries, isFalse);
      expect(agg.distinctDayCount, 0);
      agg.replayInto(capture);
      expect(pushed, isEmpty);
    });

    test('hr in [40,100] → resting_hr daily mean', () {
      // Day 100: HR samples 60, 70, 80 → mean 70
      agg.add(hr(100, 60));
      agg.add(hr(100, 70));
      agg.add(hr(100, 80));
      agg.replayInto(capture);
      final restingHr = pushed
          .where((p) => p.dim == DailyMetric.restingHrBpm)
          .toList();
      expect(restingHr, hasLength(1));
      expect(restingHr.first.day, 100);
      expect(restingHr.first.value, closeTo(70.0, 1e-9));
      expect(
        restingHr.first.vendorSummary,
        isFalse,
      ); // proxy, lower than vendor
      expect(
        restingHr.first.vendorSummary,
        isFalse,
      ); // raw observation derived in-app
    });

    test('hr filter rejects sub-40 (sensor artefact) and >100 (exercise)', () {
      // Day 100: 30 (drop), 60, 150 (drop), 80 → mean 70
      agg.add(hr(100, 30));
      agg.add(hr(100, 60));
      agg.add(hr(100, 150));
      agg.add(hr(100, 80));
      agg.replayInto(capture);
      final restingHr = pushed.singleWhere(
        (p) => p.dim == DailyMetric.restingHrBpm,
      );
      expect(restingHr.value, closeTo(70.0, 1e-9));
    });

    test('hr aggregates per-day independently', () {
      agg.add(hr(100, 60));
      agg.add(hr(100, 80));
      agg.add(hr(101, 50));
      agg.add(hr(101, 70));
      agg.replayInto(capture);
      final day100 = pushed.singleWhere(
        (p) => p.dim == DailyMetric.restingHrBpm && p.day == 100,
      );
      final day101 = pushed.singleWhere(
        (p) => p.dim == DailyMetric.restingHrBpm && p.day == 101,
      );
      expect(day100.value, closeTo(70.0, 1e-9));
      expect(day101.value, closeTo(60.0, 1e-9));
    });

    test('hr running mean is numerically stable on many samples', () {
      // 100k samples uniform around 60 should produce a mean very
      // close to 60 even with the running-mean accumulator.
      for (var i = 0; i < 100_000; i++) {
        agg.add(hr(100, 60.0 + (i % 7).toDouble() - 3.0));
      }
      agg.replayInto(capture);
      final restingHr = pushed.singleWhere(
        (p) => p.dim == DailyMetric.restingHrBpm,
      );
      // Mean of {-3,-2,-1,0,1,2,3} = 0, so daily mean ≈ 60.
      expect(restingHr.value, closeTo(60.0, 0.01));
    });

    test('sleep stages → sleep_need / deep_sleep_min / rem_sleep_min', () {
      // One night ending day 200: 60min light + 90min deep + 75min rem
      agg.add(sleep(200, wear.SleepStage.light, 60));
      agg.add(sleep(200, wear.SleepStage.deep, 90));
      agg.add(sleep(200, wear.SleepStage.rem, 75));
      agg.replayInto(capture);

      final sleepNeed = pushed.singleWhere(
        (p) => p.dim == DailyMetric.sleepDurationS,
      );
      // sleep_need = (60 + 90 + 75) min × 60 s/min = 13_500 s
      expect(sleepNeed.day, 200);
      expect(sleepNeed.value, closeTo(13_500.0, 1e-6));

      final deepMin = pushed.singleWhere(
        (p) => p.dim == DailyMetric.sleepDeepMin,
      );
      expect(deepMin.value, closeTo(90.0, 1e-6));

      final remMin = pushed.singleWhere(
        (p) => p.dim == DailyMetric.sleepRemMin,
      );
      expect(remMin.value, closeTo(75.0, 1e-6));
    });

    test('sleep block attributed to wake-up day (endMs), not bedtime day', () {
      // Block: 23:30 day 199 → 06:30 day 200, deep stage, 7 hours.
      // Should land on day 200.
      final sample = wear.AppleHealthSample(
        metric: wear.AppleHealthMetric.sleepStage,
        source: 'Apple Watch',
        startMs: _localMs(199, 23, 30),
        endMs: _localMs(200, 6, 30),
        value: const wear.SleepStageValue(wear.SleepStage.deep),
      );
      agg.add(sample);
      agg.replayInto(capture);
      final deepMin = pushed.singleWhere(
        (p) => p.dim == DailyMetric.sleepDeepMin,
      );
      expect(deepMin.day, 200);
      expect(deepMin.value, closeTo(7 * 60.0, 1e-6));
    });

    test('sleep with zero duration is ignored', () {
      final ts = _localMs(200, 7);
      agg.add(
        wear.AppleHealthSample(
          metric: wear.AppleHealthMetric.sleepStage,
          source: 'Apple Watch',
          startMs: ts,
          endMs: ts, // duration 0
          value: const wear.SleepStageValue(wear.SleepStage.deep),
        ),
      );
      agg.replayInto(capture);
      expect(pushed, isEmpty);
    });

    test('no sleep stages → no sleep_need / deep / rem pushes', () {
      agg.add(hr(100, 60));
      agg.replayInto(capture);
      // Only resting_hr should appear.
      expect(pushed.map((p) => p.dim).toSet(), {DailyMetric.restingHrBpm});
    });

    test('non-mapped metrics are silently ignored', () {
      // steps / calories / spo2 / temperature have no SRM mapping
      // and should not generate any pushes. (hrvSdnn DOES map now —
      // see the dedicated SDNN tests below.)
      for (final m in [
        wear.AppleHealthMetric.steps,
        wear.AppleHealthMetric.calories,
        wear.AppleHealthMetric.spo2,
        wear.AppleHealthMetric.temperature,
      ]) {
        agg.add(
          wear.AppleHealthSample(
            metric: m,
            source: 'Apple Watch',
            startMs: _localMs(100, 0),
            endMs: _localMs(100, 0),
            value: const wear.QuantityValue(50.0),
          ),
        );
      }
      agg.replayInto(capture);
      expect(pushed, isEmpty);
      expect(agg.hasAnyEntries, isFalse);
    });

    // ── SDNN aggregation (Apple Health → hrv_sdnn) ─────────────────────

    wear.AppleHealthSample sdnn(int day, double ms) => wear.AppleHealthSample(
      metric: wear.AppleHealthMetric.hrvSdnn,
      source: 'Apple Watch',
      startMs: _localMs(day, 12),
      endMs: _localMs(day, 12, 5),
      value: wear.QuantityValue(ms),
    );

    test('sdnn samples → hrv_sdnn daily mean', () {
      // Day 100: SDNN 40, 50, 60 → mean 50
      agg.add(sdnn(100, 40));
      agg.add(sdnn(100, 50));
      agg.add(sdnn(100, 60));
      agg.replayInto(capture);
      final hrvSdnn = pushed
          .where((p) => p.dim == DailyMetric.overnightSdnnMs)
          .toList();
      expect(hrvSdnn, hasLength(1));
      expect(hrvSdnn.first.day, 100);
      expect(hrvSdnn.first.value, closeTo(50.0, 1e-9));
      expect(hrvSdnn.first.vendorSummary, isTrue); // vendor-grade
      expect(hrvSdnn.first.vendorSummary, isTrue); // vendor-derived
    });

    test('sdnn filter rejects sub-5 (sensor error) and >250 (impossible)', () {
      // 3 (drop), 40, 300 (drop), 60 → mean 50
      agg.add(sdnn(100, 3));
      agg.add(sdnn(100, 40));
      agg.add(sdnn(100, 300));
      agg.add(sdnn(100, 60));
      agg.replayInto(capture);
      final hrvSdnn = pushed.singleWhere(
        (p) => p.dim == DailyMetric.overnightSdnnMs,
      );
      expect(hrvSdnn.value, closeTo(50.0, 1e-9));
    });

    test('sdnn does NOT map to overnight RMSSD', () {
      // SDNN ≠ RMSSD; we never push SDNN under the rmssd key.
      agg.add(sdnn(100, 50));
      agg.replayInto(capture);
      expect(
        pushed.where((p) => p.dim == DailyMetric.overnightRmssdMs),
        isEmpty,
      );
      expect(
        pushed.where((p) => p.dim == DailyMetric.overnightSdnnMs),
        hasLength(1),
      );
    });

    test('sdnn aggregates per-day independently', () {
      agg.add(sdnn(100, 40));
      agg.add(sdnn(100, 60));
      agg.add(sdnn(101, 30));
      agg.add(sdnn(101, 70));
      agg.replayInto(capture);
      final day100 = pushed.singleWhere(
        (p) => p.dim == DailyMetric.overnightSdnnMs && p.day == 100,
      );
      final day101 = pushed.singleWhere(
        (p) => p.dim == DailyMetric.overnightSdnnMs && p.day == 101,
      );
      expect(day100.value, closeTo(50.0, 1e-9));
      expect(day101.value, closeTo(50.0, 1e-9));
    });

    test('sdnn alone flips hasAnyEntries true and counts a day', () {
      expect(agg.hasAnyEntries, isFalse);
      agg.add(sdnn(100, 50));
      expect(agg.hasAnyEntries, isTrue);
      expect(agg.distinctDayCount, 1);
    });

    // ── Vendor-computed resting HR (HKQuantityTypeIdentifierRestingHeartRate)

    wear.AppleHealthSample restingHr(int day, double bpm) =>
        wear.AppleHealthSample(
          metric: wear.AppleHealthMetric.restingHeartRate,
          source: 'Apple Watch',
          startMs: _localMs(day, 4), // 4am, after sleep
          endMs: _localMs(day, 4),
          value: wear.QuantityValue(bpm),
        );

    test(
      'vendor-computed restingHeartRate → resting_hr, vendor confidence',
      () {
        agg.add(restingHr(100, 52));
        agg.replayInto(capture);
        final r = pushed.singleWhere((p) => p.dim == DailyMetric.restingHrBpm);
        expect(r.day, 100);
        expect(r.value, closeTo(52.0, 1e-9));
        expect(r.vendorSummary, isTrue); // vendor-derived
        expect(r.vendorSummary, isTrue); // vendor summary
      },
    );

    test('vendor restingHeartRate WINS over proxy on the same day', () {
      // Day 100: noisy proxy (lots of HR samples) AND a vendor
      // restingHeartRate. The vendor value is the source of truth —
      // proxy must NOT also be pushed for that day (would
      // double-count toward distinct days).
      agg.add(hr(100, 70));
      agg.add(hr(100, 80));
      agg.add(restingHr(100, 52));
      agg.replayInto(capture);
      final restingPushes = pushed
          .where((p) => p.dim == DailyMetric.restingHrBpm)
          .toList();
      expect(restingPushes, hasLength(1));
      expect(restingPushes.first.value, closeTo(52.0, 1e-9));
      expect(restingPushes.first.vendorSummary, isTrue);
    });

    test('proxy fallback fires on days WITHOUT vendor restingHeartRate', () {
      // Day 100: only vendor → vendor wins
      // Day 101: only proxy → proxy fires
      // Day 102: both → vendor wins
      agg.add(restingHr(100, 50));
      agg.add(hr(101, 60));
      agg.add(hr(101, 80));
      agg.add(hr(102, 100));
      agg.add(restingHr(102, 55));
      agg.replayInto(capture);

      final byDay = {
        for (final p in pushed.where((p) => p.dim == DailyMetric.restingHrBpm))
          p.day: p,
      };

      expect(byDay[100]!.value, closeTo(50.0, 1e-9));
      expect(byDay[100]!.vendorSummary, isTrue); // vendor

      expect(byDay[101]!.value, closeTo(70.0, 1e-9));
      expect(byDay[101]!.vendorSummary, isFalse); // proxy

      expect(byDay[102]!.value, closeTo(55.0, 1e-9));
      expect(byDay[102]!.vendorSummary, isTrue); // vendor wins despite proxy
    });

    test('vendor restingHeartRate filter rejects out-of-band values', () {
      // Same outer [40, 100] guard as the proxy. A vendor row at 30
      // or 200 is corrupted export data, not a real signal.
      agg.add(restingHr(100, 30));
      agg.add(restingHr(100, 200));
      agg.add(restingHr(100, 55));
      agg.replayInto(capture);
      final r = pushed.singleWhere((p) => p.dim == DailyMetric.restingHrBpm);
      expect(r.value, closeTo(55.0, 1e-9));
    });

    test('vendor restingHeartRate counts toward distinctDayCount', () {
      agg.add(restingHr(100, 55));
      agg.add(restingHr(101, 56));
      expect(agg.distinctDayCount, 2);
      expect(agg.hasAnyEntries, isTrue);
    });

    test('hasAnyEntries flips true once any HR or sleep is recorded', () {
      expect(agg.hasAnyEntries, isFalse);
      agg.add(hr(100, 60));
      expect(agg.hasAnyEntries, isTrue);
    });

    test('distinctDayCount counts the union of HR and sleep days', () {
      agg.add(hr(100, 60));
      agg.add(hr(101, 70));
      agg.add(sleep(101, wear.SleepStage.deep, 60)); // overlaps day 101
      agg.add(sleep(102, wear.SleepStage.deep, 60));
      expect(agg.distinctDayCount, 3); // {100, 101, 102}
    });

    group('main night', () {
      wear.AppleHealthSample block(
        int startMs,
        int endMs, [
        wear.SleepStage stage = wear.SleepStage.light,
      ]) => wear.AppleHealthSample(
        metric: wear.AppleHealthMetric.sleepStage,
        source: 'Apple Watch',
        startMs: startMs,
        endMs: endMs,
        value: wear.SleepStageValue(stage),
      );

      wear.AppleHealthSample hrAt(int ms, double bpm) => wear.AppleHealthSample(
        metric: wear.AppleHealthMetric.heartRate,
        source: 'Apple Watch',
        startMs: ms,
        endMs: ms,
        value: wear.QuantityValue(bpm),
      );

      // 23:00 day 199 → 07:00 day 200, awake 05:00–05:30.
      void addNight() {
        agg.add(block(_localMs(199, 23), _localMs(200, 3)));
        agg.add(
          block(_localMs(200, 3), _localMs(200, 5), wear.SleepStage.deep),
        );
        agg.add(
          block(_localMs(200, 5), _localMs(200, 5, 30), wear.SleepStage.awake),
        );
        agg.add(
          block(_localMs(200, 5, 30), _localMs(200, 7), wear.SleepStage.rem),
        );
      }

      _Pushed only(String metric) => pushed.singleWhere((p) => p.dim == metric);

      test('pushes the midpoint and the asleep mean HR on the wake day', () {
        addNight();
        for (final (h, m, bpm) in [
          (23, 30, 50.0),
          (1, 0, 52.0),
          (2, 0, 48.0),
          (4, 0, 54.0),
          (6, 0, 56.0),
          (6, 30, 46.0),
        ]) {
          agg.add(hrAt(_localMs(h == 23 ? 199 : 200, h, m), bpm));
        }
        // Awake in the night and in the day: not asleep HR.
        agg.add(hrAt(_localMs(200, 5, 10), 90));
        agg.add(hrAt(_localMs(200, 12), 80));
        agg.replayInto(capture);

        final mid = only(DailyMetric.sleepMidpointH);
        expect(mid.day, 200);
        expect(mid.value, closeTo(3.0, 1e-9));
        expect(mid.vendorSummary, isFalse);
        final hr = only(DailyMetric.overnightHrBpm);
        expect(hr.day, 200);
        expect(hr.value, closeTo(51.0, 1e-9));
        expect(hr.vendorSummary, isFalse);
      });

      test('a nap on the wake day does not replace the night', () {
        addNight();
        agg.add(block(_localMs(200, 14), _localMs(200, 14, 40)));
        agg.replayInto(capture);
        expect(only(DailyMetric.sleepMidpointH).value, closeTo(3.0, 1e-9));
      });

      test('asleep HR below the resting-proxy floor still counts', () {
        addNight();
        for (final h in [0, 1, 2, 3, 4, 6]) {
          agg.add(hrAt(_localMs(200, h, 15), 38));
        }
        agg.replayInto(capture);
        expect(only(DailyMetric.overnightHrBpm).value, closeTo(38.0, 1e-9));
        // The proxy keeps its own [40, 100] filter.
        expect(pushed.where((p) => p.dim == DailyMetric.restingHrBpm), isEmpty);
      });

      test('too few asleep HR samples push no overnight HR', () {
        addNight();
        agg.add(hrAt(_localMs(200, 1), 52));
        agg.replayInto(capture);
        expect(
          pushed.where((p) => p.dim == DailyMetric.overnightHrBpm),
          isEmpty,
        );
        expect(only(DailyMetric.sleepMidpointH).day, 200);
      });

      test('HR without any sleep pushes no midpoint or overnight HR', () {
        agg.add(hr(100, 60));
        agg.replayInto(capture);
        expect(pushed.map((p) => p.dim).toSet(), {DailyMetric.restingHrBpm});
      });
    });

    test('30-day backfill produces 30 resting_hr pushes', () {
      // The user's actual scenario: Apple Health export with HR
      // samples spanning 30 days. Each day's filtered mean lands as
      // a resting_hr push. The runtime's Slice 1 bridge then
      // synthesizes a FeatureSet per push, so after 30 days the
      // live SRM's hrv.hr_mean_bpm baseline transitions out of
      // Empty.
      for (var d = 100; d < 130; d++) {
        agg.add(hr(d, 58.0 + (d % 5)));
        agg.add(hr(d, 62.0 + (d % 5)));
      }
      agg.replayInto(capture);
      final restingHr = pushed
          .where((p) => p.dim == DailyMetric.restingHrBpm)
          .toList();
      expect(restingHr, hasLength(30));
      expect(restingHr.map((p) => p.day).toSet().length, 30);
    });
  });
}

/// Epoch ms of [hour]:[minute] local time on the local calendar date [day]
/// days after 1970-01-01. Built from local fields so a sample keys to [day] in
/// every time zone, the way the aggregator keys by the person's local date.
int _localMs(int day, int hour, [int minute = 0]) =>
    DateTime(1970, 1, 1 + day, hour, minute).millisecondsSinceEpoch;

/// The day number of a local calendar [date], matching [_localMs].
int _dayOf(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch ~/
    86_400_000;

class _Pushed {
  _Pushed(this.dim, this.day, this.value, this.vendorSummary);

  final String dim;
  final int day;
  final double value;
  final bool vendorSummary;
}
