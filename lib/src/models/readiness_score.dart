// Typed Dart models for the daily readiness scorer.
//
// Mirrors the JSON shapes of the engine's `synheart_readiness_score` crate
// (engine v0.12.0 onwards, so every runtime this SDK supports). Field names
// use snake_case JSON keys for cross-language portability.
//
// Readiness is the decision layer that runs after Sleep and Recovery for the
// day, and answers:
//
//     "How much demand can the user take today?"
//
// It blends Recovery (0.50), Sleep (0.25) and how far overnight HR / HRV sit
// from the person's baseline (0.25). Without overnight physiology the
// alignment weight moves onto Recovery and Sleep and confidence drops.

import 'dart:convert';

/// Discrete readiness band. The Dart names are the action each band
/// recommends; [wire] is the engine's name for the band.
enum ReadinessBand {
  /// 0–39, "Low Readiness": rest, reduce difficulty, avoid high strain.
  rest('low'),

  /// 40–59, "Reduced Readiness": light activity, lower load, more breaks.
  light('reduced'),

  /// 60–79, "Normal Readiness": standard task / training schedule.
  normal('normal'),

  /// 80–100, "High Readiness": may tolerate higher demand.
  push('high');

  final String wire;
  const ReadinessBand(this.wire);

  /// The band for [s], or the band [score] falls in when [s] is missing or
  /// unknown — the engine derives the band from the score with the same
  /// breakpoints, so this never invents one.
  static ReadinessBand fromWire(String? s, {required int score}) {
    for (final v in ReadinessBand.values) {
      if (v.wire == s) return v;
    }
    return fromScore(score);
  }

  /// The band a `0..=100` score falls in (breakpoints 40 / 60 / 80).
  static ReadinessBand fromScore(int score) {
    if (score < 40) return ReadinessBand.rest;
    if (score < 60) return ReadinessBand.light;
    if (score < 80) return ReadinessBand.normal;
    return ReadinessBand.push;
  }

  String get label {
    switch (this) {
      case ReadinessBand.rest:
        return 'Rest';
      case ReadinessBand.light:
        return 'Light';
      case ReadinessBand.normal:
        return 'Normal';
      case ReadinessBand.push:
        return 'Push';
    }
  }

  /// The engine's one-line recommendation for the band.
  String get recommendation {
    switch (this) {
      case ReadinessBand.rest:
        return 'Rest, reduce difficulty, avoid high strain';
      case ReadinessBand.light:
        return 'Light activity, lower cognitive load, more breaks';
      case ReadinessBand.normal:
        return 'Standard task / training schedule';
      case ReadinessBand.push:
        return 'You may tolerate higher demand';
    }
  }
}

/// Discrete reasons surfaced for "why is your readiness X?" panels.
enum ReadinessFactor {
  strongRecovery('strong_recovery'),
  lowRecovery('low_recovery'),
  poorSleep('poor_sleep'),
  goodSleep('good_sleep'),
  hrvAboveBaseline('hrv_above_baseline'),
  hrvBelowBaseline('hrv_below_baseline'),
  restingHrElevated('resting_hr_elevated'),

  /// The HR/HRV baseline is immature (under 2 days) or absent.
  baselineImmature('baseline_immature'),
  recoveryColdStart('recovery_cold_start'),
  sleepColdStart('sleep_cold_start'),

  /// No overnight HR/HRV: readiness is a Recovery + Sleep blend.
  scoresOnly('scores_only');

  final String wire;
  const ReadinessFactor(this.wire);

  static ReadinessFactor? fromWire(String s) {
    for (final v in ReadinessFactor.values) {
      if (v.wire == s) return v;
    }
    return null;
  }
}

/// Overnight physiology against the person's baselines, for the
/// baseline-alignment term. All four values are required; pass no
/// [OvernightAlignment] at all when any is unavailable.
class OvernightAlignment {
  /// Mean HR during sleep (bpm).
  final double hrSleepBpm;

  /// Personal rolling resting HR baseline (bpm).
  final double hrBaseBpm;

  /// Mean RMSSD during sleep (ms).
  final double rmssdSleepMs;

  /// Personal rolling resting RMSSD baseline (ms).
  final double rmssdBaseMs;

  const OvernightAlignment({
    required this.hrSleepBpm,
    required this.hrBaseBpm,
    required this.rmssdSleepMs,
    required this.rmssdBaseMs,
  });

  Map<String, Object?> toJson() => {
    'hr_sleep_bpm': hrSleepBpm,
    'hr_base_bpm': hrBaseBpm,
    'rmssd_sleep_ms': rmssdSleepMs,
    'rmssd_base_ms': rmssdBaseMs,
  };
}

/// Top-level input bundle. Recovery and Sleep are both required: readiness
/// runs after both are known for the day.
class ReadinessScoreInput {
  /// Today's Recovery Score, `0..=100`.
  final int recoveryScore;

  /// Today's Sleep Score, `0..=100`.
  final int sleepScore;

  /// Overnight HR/HRV against baselines, or null when either is missing.
  final OvernightAlignment? alignment;

  /// Today's Recovery Score is a cold-start estimate (Recovery stage 1).
  final bool recoveryColdStart;

  /// Today's Sleep Score is a cold-start estimate (Sleep mode 1).
  final bool sleepColdStart;

  /// Days of HR/HRV baseline history accumulated. Under 2 marks the baseline
  /// immature; confidence matures towards 7.
  final int baselineDays;

  const ReadinessScoreInput({
    required this.recoveryScore,
    required this.sleepScore,
    this.alignment,
    this.recoveryColdStart = false,
    this.sleepColdStart = false,
    this.baselineDays = 0,
  });

  Map<String, Object?> toJson() => {
    'recovery_score': recoveryScore.clamp(0, 100),
    'sleep_score': sleepScore.clamp(0, 100),
    'alignment': alignment?.toJson(),
    'recovery_cold_start': recoveryColdStart,
    'sleep_cold_start': sleepColdStart,
    'baseline_days': baselineDays < 0 ? 0 : baselineDays,
  };

  String toJsonString() => jsonEncode(toJson());
}

/// Per-component breakdown, every value on `0..100`. The alignment values
/// are null when overnight HR/HRV or a baseline was unavailable, so "not
/// measured" never reads as a mid-range score.
class ReadinessComponents {
  final double recovery;
  final double sleep;
  final double? baselineAlignment;
  final double? hrAlignment;
  final double? hrvAlignment;

  const ReadinessComponents({
    required this.recovery,
    required this.sleep,
    this.baselineAlignment,
    this.hrAlignment,
    this.hrvAlignment,
  });

  factory ReadinessComponents.fromJson(Map<String, Object?> json) =>
      ReadinessComponents(
        recovery: (json['recovery'] as num?)?.toDouble() ?? 0.0,
        sleep: (json['sleep'] as num?)?.toDouble() ?? 0.0,
        baselineAlignment: (json['baseline_alignment'] as num?)?.toDouble(),
        hrAlignment: (json['hr_alignment'] as num?)?.toDouble(),
        hrvAlignment: (json['hrv_alignment'] as num?)?.toDouble(),
      );

  Map<String, Object?> toJson() => {
    'recovery': recovery,
    'sleep': sleep,
    'baseline_alignment': baselineAlignment,
    'hr_alignment': hrAlignment,
    'hrv_alignment': hrvAlignment,
  };
}

/// Canonical output of the Readiness Score scorer.
class ReadinessScoreResult {
  final int score;
  final ReadinessBand band;

  /// The Recovery Score the result was computed from.
  final int recoveryAnchor;

  /// The Sleep Score the result was computed from.
  final int sleepAnchor;
  final ReadinessComponents components;
  final double confidence;
  final List<ReadinessFactor> explanation;
  final String modelId;
  final String modelVersion;
  final String pipelineVersion;

  const ReadinessScoreResult({
    required this.score,
    required this.band,
    required this.recoveryAnchor,
    required this.sleepAnchor,
    required this.components,
    required this.confidence,
    this.explanation = const [],
    required this.modelId,
    required this.modelVersion,
    required this.pipelineVersion,
  });

  factory ReadinessScoreResult.fromJson(Map<String, Object?> json) {
    final rawExpl = (json['explanation'] as List?) ?? const [];
    final factors = <ReadinessFactor>[];
    for (final e in rawExpl) {
      if (e is String) {
        final f = ReadinessFactor.fromWire(e);
        if (f != null) factors.add(f);
      }
    }
    final score = (json['score'] as num?)?.toInt() ?? 0;
    return ReadinessScoreResult(
      score: score,
      band: ReadinessBand.fromWire(json['band'] as String?, score: score),
      recoveryAnchor: (json['recovery_anchor'] as num?)?.toInt() ?? 0,
      sleepAnchor: (json['sleep_anchor'] as num?)?.toInt() ?? 0,
      components: ReadinessComponents.fromJson(
        (json['components'] as Map?)?.cast<String, Object?>() ?? {},
      ),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      explanation: factors,
      modelId: json['model_id'] as String? ?? '',
      modelVersion: json['model_version'] as String? ?? '',
      pipelineVersion: json['pipeline_version'] as String? ?? '',
    );
  }

  factory ReadinessScoreResult.fromJsonString(String s) =>
      ReadinessScoreResult.fromJson(jsonDecode(s) as Map<String, Object?>);

  /// The engine's JSON shape, for persisting a result and reading it back
  /// with [fromJson].
  Map<String, Object?> toJson() => {
    'score': score,
    'band': band.wire,
    'recovery_anchor': recoveryAnchor,
    'sleep_anchor': sleepAnchor,
    'components': components.toJson(),
    'confidence': confidence,
    'explanation': [for (final f in explanation) f.wire],
    'model_id': modelId,
    'model_version': modelVersion,
    'pipeline_version': pipelineVersion,
  };
}
