import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/synheart_core.dart';

/// Pins the daily score inputs to the C ABI 4.2 contract: the Sleep Score's
/// `tonight_midpoint_h` and `baselines`, and the baseline objects the runtime
/// returns from `daily_sleep_baselines_json` / `daily_baseline_refs_json`.
void main() {
  group('SleepBaselines', () {
    test('parses the runtime object, a missing reference staying null', () {
      final b = SleepBaselines.fromJson(
        jsonDecode('''
        {"midpoint_h": {"value": 3.25, "confidence": 0.8},
         "overnight_hr_bpm": {"value": 56, "confidence": 0.6},
         "deep_min": null}
        ''')
            as Map<String, dynamic>,
      );
      expect(b.midpointH!.value, 3.25);
      expect(b.midpointH!.confidence, 0.8);
      expect(b.overnightHrBpm!.value, 56.0);
      expect(b.deepMin, isNull);
      expect(b.remMin, isNull);
    });

    test('a malformed reference is dropped rather than guessed', () {
      final b = SleepBaselines.fromJson({
        'midpoint_h': {'value': 'x', 'confidence': 0.5},
        'rem_min': {'value': 90},
      });
      expect(b.midpointH, isNull);
      expect(b.remMin, isNull);
    });
  });

  group('SleepScoreInput.toJson', () {
    const night = NightRaw(
      wakeCalendarDate: 20755,
      detail: AggregatedNight(
        totals: AggregatedTotals(totalSleepMinutes: 420, awakeMinutes: 20),
      ),
    );

    test('carries tonight_midpoint_h and the baselines', () {
      final json = const SleepScoreInput(
        tonight: night,
        tonightMidpointH: 3.5,
        baselines: SleepBaselines(
          midpointH: DailyRef(value: 3.25, confidence: 0.8),
        ),
      ).toJson();
      expect(json['tonight_midpoint_h'], 3.5);
      expect(json['baselines'], {
        'midpoint_h': {'value': 3.25, 'confidence': 0.8},
        'overnight_hr_bpm': null,
        'deep_min': null,
        'rem_min': null,
      });
    });

    test('a night without timing sends a null midpoint', () {
      final json = const SleepScoreInput(tonight: night).toJson();
      expect(json.containsKey('tonight_midpoint_h'), isTrue);
      expect(json['tonight_midpoint_h'], isNull);
      // Absent, the engine defaults the baselines (cold start).
      expect(json.containsKey('baselines'), isFalse);
    });
  });

  group('BaselineRefs', () {
    test('parses the runtime object', () {
      final r = BaselineRefs.fromJson({
        'hrv_rmssd_ms': 48,
        'hrv_confidence': 0.7,
        'resting_hr_bpm': 55.5,
        'rhr_confidence': 0.4,
      })!;
      expect(r.hrvRmssdMs, 48.0);
      expect(r.restingHrBpm, 55.5);
    });

    test('is null unless all four fields are numbers', () {
      expect(
        BaselineRefs.fromJson({'hrv_rmssd_ms': 48, 'hrv_confidence': 0.7}),
        isNull,
      );
    });

    test('maturity is the lower confidence, within 0..1', () {
      const r = BaselineRefs(
        hrvRmssdMs: 48,
        hrvConfidence: 0.7,
        restingHrBpm: 55,
        rhrConfidence: 0.4,
      );
      expect(r.maturity, 0.4);
      const over = BaselineRefs(
        hrvRmssdMs: 48,
        hrvConfidence: 1.4,
        restingHrBpm: 55,
        rhrConfidence: 1.2,
      );
      expect(over.maturity, 1.0);
    });
  });
}
