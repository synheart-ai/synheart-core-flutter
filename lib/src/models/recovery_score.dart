// Typed Dart models for the daily recovery scorer.
//
// Mirrors the JSON shapes produced by the Synheart Runtime's
// `RecoveryScore` computation. Field names use snake_case JSON
// keys for cross-language portability.
//
// Three-stage scoring:
//   - Stage 1 (FirstDay):     1 night of sleep + (HR or HRV)
//   - Stage 2 (ShortHistory): ≥ 3 nights with HR/HRV trends
//   - Stage 3 (Personalized): ≥ 7 nights + stable wearable baselines

import 'dart:convert';

/// Which staged-history mode the engine used to compute the score.
enum RecoveryStage {
  firstDay('first_day'),
  shortHistory('short_history'),
  personalized('personalized');

  final String wire;
  const RecoveryStage(this.wire);

  static RecoveryStage fromWire(String s) => RecoveryStage.values.firstWhere(
    (v) => v.wire == s,
    orElse: () => RecoveryStage.firstDay,
  );
}

/// User-facing label for the score's confidence regime.
enum RecoveryScoreMode {
  estimate('estimate'),
  trended('trended'),
  personalized('personalized');

  final String wire;
  const RecoveryScoreMode(this.wire);

  static RecoveryScoreMode fromWire(String s) => RecoveryScoreMode.values
      .firstWhere((v) => v.wire == s, orElse: () => RecoveryScoreMode.estimate);
}

/// Discrete reasons surfaced for "why is your recovery score X?" panels.
enum RecoveryFactor {
  hrvAboveBaseline('hrv_above_baseline'),
  hrvBelowBaseline('hrv_below_baseline'),
  restingHrElevated('resting_hr_elevated'),
  strongSleepQuality('strong_sleep_quality'),
  fragmentedSleep('fragmented_sleep'),
  inconsistentSchedule('inconsistent_schedule'),
  highStrainYesterday('high_strain_yesterday'),
  earlyEstimate('early_estimate'),
  shortHistoryTrend('short_history_trend'),
  personalizedBaseline('personalized_baseline');

  final String wire;
  const RecoveryFactor(this.wire);

  static RecoveryFactor? fromWire(String s) {
    for (final v in RecoveryFactor.values) {
      if (v.wire == s) return v;
    }
    return null;
  }
}

/// Aggregate sleep totals for one night. Stage durations are nullable
/// (self-report / basic Health Connect can't break stages out).
class NightSummary {
  final int wakeCalendarDate;
  final double totalSleepMinutes;
  final double? deepSleepMinutes;
  final double? remSleepMinutes;
  final double? wasoMinutes;
  final int? awakeningCount;
  final double? sleepEfficiency;
  final double? bedtimeMidpointHours;

  const NightSummary({
    required this.wakeCalendarDate,
    required this.totalSleepMinutes,
    this.deepSleepMinutes,
    this.remSleepMinutes,
    this.wasoMinutes,
    this.awakeningCount,
    this.sleepEfficiency,
    this.bedtimeMidpointHours,
  });

  Map<String, Object?> toJson() => {
    'wake_calendar_date': wakeCalendarDate,
    'total_sleep_minutes': totalSleepMinutes,
    'deep_sleep_minutes': deepSleepMinutes,
    'rem_sleep_minutes': remSleepMinutes,
    'waso_minutes': wasoMinutes,
    'awakening_count': awakeningCount,
    'sleep_efficiency': sleepEfficiency,
    'bedtime_midpoint_hours': bedtimeMidpointHours,
  };
}

/// Per-night overnight physiology (HR + HRV). At least one of the two
/// must be present for the engine to emit a score.
class OvernightPhysiology {
  final double? hrvRmssdMs;
  final double? hrvSdnnMs;
  final double? hrStdBpm;
  final double? stepsCount;
  final double? overnightHrBpm;
  final double? respiratoryRateBrpm;
  final double? spo2Pct;

  const OvernightPhysiology({
    this.hrvRmssdMs,
    this.hrvSdnnMs,
    this.hrStdBpm,
    this.stepsCount,
    this.overnightHrBpm,
    this.respiratoryRateBrpm,
    this.spo2Pct,
  });

  /// `true` if at least one of HR or HRV is reported. SDNN, hr-std,
  /// and steps are *not* consulted: the Recovery formula keys off
  /// RMSSD (or its iOS SDNN-as-RMSSD legacy mapping); the others
  /// only warm baseline dimensions and shouldn't spuriously trigger
  /// Recovery on a night that lacks the signals it actually needs.
  bool get hasSignal => hrvRmssdMs != null || overnightHrBpm != null;

  Map<String, Object?> toJson() => {
    'hrv_rmssd_ms': hrvRmssdMs,
    'hrv_sdnn_ms': hrvSdnnMs,
    'hr_std_bpm': hrStdBpm,
    'steps_count': stepsCount,
    'overnight_hr_bpm': overnightHrBpm,
    'respiratory_rate_brpm': respiratoryRateBrpm,
    'spo2_pct': spo2Pct,
  };
}

/// Stage-3 personal baselines pulled from the longitudinal SRM. Pass
/// `null` (on `RecoveryScoreInput.baselines`) if the user doesn't have
/// stable references yet — the engine will dispatch to Stage 1 or 2.
class BaselineRefs {
  final double hrvRmssdMs;
  final double hrvConfidence;
  final double restingHrBpm;
  final double rhrConfidence;

  const BaselineRefs({
    required this.hrvRmssdMs,
    required this.hrvConfidence,
    required this.restingHrBpm,
    required this.rhrConfidence,
  });

  /// Null unless [json] carries all four fields as numbers.
  static BaselineRefs? fromJson(Map<String, dynamic> json) {
    final hrv = json['hrv_rmssd_ms'];
    final hrvConf = json['hrv_confidence'];
    final rhr = json['resting_hr_bpm'];
    final rhrConf = json['rhr_confidence'];
    if (hrv is! num || hrvConf is! num || rhr is! num || rhrConf is! num) {
      return null;
    }
    return BaselineRefs(
      hrvRmssdMs: hrv.toDouble(),
      hrvConfidence: hrvConf.toDouble(),
      restingHrBpm: rhr.toDouble(),
      rhrConfidence: rhrConf.toDouble(),
    );
  }

  /// Maturity of the overnight HR/HRV baselines, `0..1`: the lower of the two
  /// confidences. Readiness reads it as its `baseline_maturity`.
  double get maturity {
    final m = hrvConfidence < rhrConfidence ? hrvConfidence : rhrConfidence;
    return m.isFinite ? m.clamp(0.0, 1.0) : 0.0;
  }

  Map<String, Object?> toJson() => {
    'hrv_rmssd_ms': hrvRmssdMs,
    'hrv_confidence': hrvConfidence,
    'resting_hr_bpm': restingHrBpm,
    'rhr_confidence': rhrConfidence,
  };
}

/// Strain context for Stage 3's strain-adjustment component. Any
/// signal may be `null`; the engine uses whichever is present in
/// priority order (`previous_day_strain` → activity composite →
/// `sleep_debt_hours`).
class StrainContext {
  final double? previousDayStrain;
  final int? workoutMinutes;
  final int? stepCount;
  final int? activeMinutes;
  final double? sleepDebtHours;

  const StrainContext({
    this.previousDayStrain,
    this.workoutMinutes,
    this.stepCount,
    this.activeMinutes,
    this.sleepDebtHours,
  });

  Map<String, Object?> toJson() => {
    'previous_day_strain': previousDayStrain,
    'workout_minutes': workoutMinutes,
    'step_count': stepCount,
    'active_minutes': activeMinutes,
    'sleep_debt_hours': sleepDebtHours,
  };
}

/// Top-level input bundle for the Recovery Score scorer.
class RecoveryScoreInput {
  /// Sleep summary for the most recent night.
  final NightSummary tonight;

  /// Prior nights' sleep summaries, newest at the back.
  final List<NightSummary> priors;

  /// Tonight's overnight physiology.
  final OvernightPhysiology overnight;

  /// Per-night physiology aligned 1-to-1 with [priors].
  final List<OvernightPhysiology> priorsOvernight;

  /// Optional stage-3 personal baselines.
  final BaselineRefs? baselines;

  /// Optional strain context.
  final StrainContext? strain;

  const RecoveryScoreInput({
    required this.tonight,
    this.priors = const [],
    required this.overnight,
    this.priorsOvernight = const [],
    this.baselines,
    this.strain,
  });

  Map<String, Object?> toJson() => {
    'tonight': tonight.toJson(),
    'priors': priors.map((p) => p.toJson()).toList(),
    'overnight': overnight.toJson(),
    'priors_overnight': priorsOvernight.map((p) => p.toJson()).toList(),
    'baselines': baselines?.toJson(),
    'strain': strain?.toJson(),
  };

  String toJsonString() => jsonEncode(toJson());
}

/// Per-component breakdown — populated per-stage. Components missing
/// for the active stage are `null`.
class RecoveryComponents {
  final double? sleepQuality;
  final double? continuity;
  final double? consistency;
  final double? overnightHrLevel;
  final double? hrvLevel;
  final double? hrvTrend;
  final double? hrTrend;
  final double? hrvDeviation;
  final double? rhrDeviation;
  final double? strainAdjustment;

  const RecoveryComponents({
    this.sleepQuality,
    this.continuity,
    this.consistency,
    this.overnightHrLevel,
    this.hrvLevel,
    this.hrvTrend,
    this.hrTrend,
    this.hrvDeviation,
    this.rhrDeviation,
    this.strainAdjustment,
  });

  factory RecoveryComponents.fromJson(Map<String, Object?> json) =>
      RecoveryComponents(
        sleepQuality: (json['sleep_quality'] as num?)?.toDouble(),
        continuity: (json['continuity'] as num?)?.toDouble(),
        consistency: (json['consistency'] as num?)?.toDouble(),
        overnightHrLevel: (json['overnight_hr_level'] as num?)?.toDouble(),
        hrvLevel: (json['hrv_level'] as num?)?.toDouble(),
        hrvTrend: (json['hrv_trend'] as num?)?.toDouble(),
        hrTrend: (json['hr_trend'] as num?)?.toDouble(),
        hrvDeviation: (json['hrv_deviation'] as num?)?.toDouble(),
        rhrDeviation: (json['rhr_deviation'] as num?)?.toDouble(),
        strainAdjustment: (json['strain_adjustment'] as num?)?.toDouble(),
      );
}

/// Canonical output of the Recovery Score scorer.
class RecoveryScoreResult {
  final int score;
  final RecoveryStage stage;
  final RecoveryScoreMode mode;
  final RecoveryComponents components;
  final double confidence;
  final List<RecoveryFactor> explanation;
  final String modelId;
  final String modelVersion;
  final String pipelineVersion;

  const RecoveryScoreResult({
    required this.score,
    required this.stage,
    required this.mode,
    required this.components,
    required this.confidence,
    this.explanation = const [],
    required this.modelId,
    required this.modelVersion,
    required this.pipelineVersion,
  });

  factory RecoveryScoreResult.fromJson(Map<String, Object?> json) {
    final rawExpl = (json['explanation'] as List?) ?? const [];
    final factors = <RecoveryFactor>[];
    for (final e in rawExpl) {
      if (e is String) {
        final f = RecoveryFactor.fromWire(e);
        if (f != null) factors.add(f);
      }
    }
    return RecoveryScoreResult(
      score: (json['score'] as num?)?.toInt() ?? 0,
      stage: RecoveryStage.fromWire(json['stage'] as String? ?? 'first_day'),
      mode: RecoveryScoreMode.fromWire(json['mode'] as String? ?? 'estimate'),
      components: RecoveryComponents.fromJson(
        (json['components'] as Map?)?.cast<String, Object?>() ?? {},
      ),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      explanation: factors,
      modelId: json['model_id'] as String? ?? '',
      modelVersion: json['model_version'] as String? ?? '',
      pipelineVersion: json['pipeline_version'] as String? ?? '',
    );
  }

  factory RecoveryScoreResult.fromJsonString(String s) =>
      RecoveryScoreResult.fromJson(jsonDecode(s) as Map<String, Object?>);
}
