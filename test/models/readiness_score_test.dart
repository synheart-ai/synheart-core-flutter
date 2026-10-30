import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/synheart_core.dart';

/// Pins the readiness models to the engine's `synheart_readiness_score`
/// shapes (engine v0.12.0 onwards; `baseline_maturity` from C ABI 4.2). The SDK's model drifted from the engine
/// once and every readiness compute failed with `missing field sleep_score`
/// for months; these keys are the contract.
void main() {
  group('ReadinessScoreInput.toJson', () {
    test('emits exactly the engine input fields', () {
      final json = const ReadinessScoreInput(
        recoveryScore: 46,
        sleepScore: 42,
        recoveryColdStart: true,
        sleepColdStart: true,
        baselineMaturity: 0.4,
      ).toJson();
      expect(json.keys.toSet(), {
        'recovery_score',
        'sleep_score',
        'alignment',
        'recovery_cold_start',
        'sleep_cold_start',
        'baseline_maturity',
      });
      expect(json['recovery_score'], 46);
      expect(json['sleep_score'], 42);
      expect(json['alignment'], isNull);
      expect(json['recovery_cold_start'], isTrue);
      expect(json['baseline_maturity'], 0.4);
      // The ABI 4.2 engine refuses an input that still carries baseline_days.
      expect(json.containsKey('baseline_days'), isFalse);
    });

    test('alignment carries all four values', () {
      final json = const ReadinessScoreInput(
        recoveryScore: 70,
        sleepScore: 80,
        alignment: OvernightAlignment(
          hrSleepBpm: 55,
          hrBaseBpm: 58,
          rmssdSleepMs: 48,
          rmssdBaseMs: 44,
        ),
      ).toJson();
      expect(json['alignment'], {
        'hr_sleep_bpm': 55.0,
        'hr_base_bpm': 58.0,
        'rmssd_sleep_ms': 48.0,
        'rmssd_base_ms': 44.0,
      });
    });

    test('clamps scores to the engine u8 range', () {
      final json = const ReadinessScoreInput(
        recoveryScore: 140,
        sleepScore: -3,
        baselineMaturity: 1.7,
      ).toJson();
      expect(json['recovery_score'], 100);
      expect(json['sleep_score'], 0);
      expect(json['baseline_maturity'], 1.0);
    });

    test('baseline maturity defaults to 0 and drops a non-finite value', () {
      const base = ReadinessScoreInput(recoveryScore: 50, sleepScore: 50);
      expect(base.toJson()['baseline_maturity'], 0.0);
      final nan = const ReadinessScoreInput(
        recoveryScore: 50,
        sleepScore: 50,
        baselineMaturity: double.nan,
      ).toJson();
      expect(nan['baseline_maturity'], 0.0);
    });
  });

  group('ReadinessScoreResult.fromJson', () {
    const engineOutput = '''
    {
      "score": 53,
      "band": "reduced",
      "recovery_anchor": 46,
      "sleep_anchor": 42,
      "components": {
        "recovery": 46.0,
        "sleep": 42.0,
        "baseline_alignment": null,
        "hr_alignment": null,
        "hrv_alignment": null
      },
      "confidence": 0.24,
      "explanation": ["recovery_cold_start", "sleep_cold_start", "scores_only"],
      "model_id": "readiness_v1",
      "model_version": "1.0.0",
      "pipeline_version": "1.0.0"
    }''';

    test('parses the engine output', () {
      final r = ReadinessScoreResult.fromJsonString(engineOutput);
      expect(r.score, 53);
      expect(r.band, ReadinessBand.light);
      expect(r.recoveryAnchor, 46);
      expect(r.sleepAnchor, 42);
      expect(r.components.sleep, 42.0);
      expect(r.components.baselineAlignment, isNull);
      expect(r.explanation, [
        ReadinessFactor.recoveryColdStart,
        ReadinessFactor.sleepColdStart,
        ReadinessFactor.scoresOnly,
      ]);
    });

    test('round-trips through toJson', () {
      final r = ReadinessScoreResult.fromJsonString(engineOutput);
      final back = ReadinessScoreResult.fromJson(
        jsonDecode(jsonEncode(r.toJson())) as Map<String, Object?>,
      );
      expect(back.toJson(), r.toJson());
    });
  });

  group('ReadinessBand', () {
    test('maps the engine band names', () {
      expect(ReadinessBand.fromWire('low', score: 10), ReadinessBand.rest);
      expect(ReadinessBand.fromWire('reduced', score: 50), ReadinessBand.light);
      expect(ReadinessBand.fromWire('normal', score: 70), ReadinessBand.normal);
      expect(ReadinessBand.fromWire('high', score: 90), ReadinessBand.push);
    });

    test('an unknown band follows the score, never a fixed default', () {
      expect(ReadinessBand.fromWire('bogus', score: 85), ReadinessBand.push);
      expect(ReadinessBand.fromWire(null, score: 39), ReadinessBand.rest);
      expect(ReadinessBand.fromWire(null, score: 40), ReadinessBand.light);
      expect(ReadinessBand.fromWire(null, score: 60), ReadinessBand.normal);
    });
  });
}
