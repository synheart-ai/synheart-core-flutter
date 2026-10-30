// Typed Dart models for the batch sleep scorer.
//
// Mirrors the JSON shapes produced by the Synheart Runtime's
// `SleepScore` computation. Field names use snake_case JSON keys
// for cross-language portability. See the Synheart Runtime
// sleep-score integration spec for semantics.

import 'dart:convert';

/// Canonical sleep stage.
enum SleepStage {
  awake('awake'),
  light('light'),
  deep('deep'),
  rem('rem'),
  unknown('unknown');

  final String wire;
  const SleepStage(this.wire);

  static SleepStage fromWire(String s) => SleepStage.values.firstWhere(
    (v) => v.wire == s,
    orElse: () => SleepStage.unknown,
  );
}

/// Which pipeline path produced a score.
enum SleepPath {
  stage('stage'),
  aggregated('aggregated'),
  vendorScore('vendor_score'),
  proxy('proxy');

  final String wire;
  const SleepPath(this.wire);

  static SleepPath fromWire(String s) => SleepPath.values.firstWhere(
    (v) => v.wire == s,
    orElse: () => SleepPath.proxy,
  );
}

/// Mode derived from history length (0→cold, 1–6→short, ≥7→stable in
/// Kotlin-parity v2.0.0).
enum SleepScoreMode {
  coldStart('cold_start'),
  shortHistory('short_history'),
  stable('stable');

  final String wire;
  const SleepScoreMode(this.wire);

  static SleepScoreMode fromWire(String s) => SleepScoreMode.values.firstWhere(
    (v) => v.wire == s,
    orElse: () => SleepScoreMode.coldStart,
  );
}

/// Reason a score was absent or degraded.
enum SleepScoreReason {
  noSleepData('no_sleep_data'),
  insufficientData('insufficient_data'),
  proxyFallback('proxy_fallback'),
  vendorPassthrough('vendor_passthrough');

  final String wire;
  const SleepScoreReason(this.wire);

  static SleepScoreReason? fromWire(String? s) {
    if (s == null) return null;
    for (final v in SleepScoreReason.values) {
      if (v.wire == s) return v;
    }
    return null;
  }
}

/// Discrete, structured drivers of the sleep score, as emitted by the runtime.
///
/// Each value carries a stable [wire] identifier; [fromWire] maps the runtime's
/// JSON strings back to the enum. A factor is present only when its underlying
/// signal was actually measured — never for imputed or missing data — so a
/// consumer can rely on it as ground truth when explaining a score.
enum SleepFactor {
  durationShort('duration_short'),
  durationAmple('duration_ample'),
  deepLow('deep_low'),
  remLow('rem_low'),
  fragmented('fragmented'),
  latencyLong('latency_long'),
  scheduleInconsistent('schedule_inconsistent'),
  belowPersonalBaseline('below_personal_baseline'),
  sleepHrElevated('sleep_hr_elevated'),
  sleepDebt('sleep_debt');

  final String wire;
  const SleepFactor(this.wire);

  static SleepFactor? fromWire(String s) {
    for (final v in SleepFactor.values) {
      if (v.wire == s) return v;
    }
    return null;
  }
}

/// A contiguous stage interval. Half-open: `[startMs, endMs)`.
class StageSegment {
  final SleepStage stage;
  final int startMs;
  final int endMs;

  const StageSegment({
    required this.stage,
    required this.startMs,
    required this.endMs,
  });

  Map<String, Object?> toJson() => {
    'stage': stage.wire,
    'start_ms': startMs,
    'end_ms': endMs,
  };
}

/// Aggregate per-night totals for vendors that don't expose a timeline.
///
/// Stage durations ([deepSleepMinutes], [remSleepMinutes]) are
/// nullable: pass `null` when the source genuinely cannot distinguish
/// stages (self-report, basic Health Connect). The engine then scores
/// on duration + continuity only instead of treating zero deep/REM as
/// "absurdly poor stage profile" and tanking the result.
class AggregatedTotals {
  final double totalSleepMinutes;
  final double? deepSleepMinutes;
  final double? remSleepMinutes;
  final double awakeMinutes;
  final int? awakenings;
  final double? timeInBedMinutes;

  /// Sleep onset latency in minutes — time from lights-out to first sleep.
  /// Optional: many aggregate sources don't report it. Surfaces the
  /// `latencyLong` explanation factor; does not (yet) feed the numeric score.
  final double? sleepLatencyMinutes;

  const AggregatedTotals({
    required this.totalSleepMinutes,
    this.deepSleepMinutes,
    this.remSleepMinutes,
    required this.awakeMinutes,
    this.awakenings,
    this.timeInBedMinutes,
    this.sleepLatencyMinutes,
  });

  Map<String, Object?> toJson() => {
    'total_sleep_minutes': totalSleepMinutes,
    if (deepSleepMinutes != null) 'deep_sleep_minutes': deepSleepMinutes,
    if (remSleepMinutes != null) 'rem_sleep_minutes': remSleepMinutes,
    'awake_minutes': awakeMinutes,
    'awakenings': awakenings,
    'time_in_bed_minutes': timeInBedMinutes,
    if (sleepLatencyMinutes != null)
      'sleep_latency_minutes': sleepLatencyMinutes,
  };
}

/// The three vendor-input shapes. The runtime's `NightInput` is a tagged enum
/// (`kind: segmented | aggregated | vendor_score`).
sealed class NightInput {
  const NightInput();

  Map<String, Object?> toJson();
}

class SegmentedNight extends NightInput {
  final int sessionStartMs;
  final int sessionEndMs;
  final String zoneId;
  final List<StageSegment> segments;

  const SegmentedNight({
    required this.sessionStartMs,
    required this.sessionEndMs,
    required this.zoneId,
    required this.segments,
  });

  @override
  Map<String, Object?> toJson() => {
    'kind': 'segmented',
    'session_start_ms': sessionStartMs,
    'session_end_ms': sessionEndMs,
    'zone_id': zoneId,
    'segments': segments.map((s) => s.toJson()).toList(),
  };
}

class AggregatedNight extends NightInput {
  final int? sessionStartMs;
  final int? sessionEndMs;
  final AggregatedTotals totals;

  const AggregatedNight({
    this.sessionStartMs,
    this.sessionEndMs,
    required this.totals,
  });

  @override
  Map<String, Object?> toJson() => {
    'kind': 'aggregated',
    'session_start_ms': sessionStartMs,
    'session_end_ms': sessionEndMs,
    'totals': totals.toJson(),
  };
}

class VendorScoreNight extends NightInput {
  final int score;
  const VendorScoreNight({required this.score});

  @override
  Map<String, Object?> toJson() => {'kind': 'vendor_score', 'score': score};
}

/// One night's raw input + optional session-window HR.
class NightRaw {
  final int wakeCalendarDate;
  final NightInput detail;
  final double? avgHrBpm;

  const NightRaw({
    required this.wakeCalendarDate,
    required this.detail,
    this.avgHrBpm,
  });

  Map<String, Object?> toJson() => {
    'wake_calendar_date': wakeCalendarDate,
    'detail': detail.toJson(),
    'avg_hr_bpm': avgHrBpm,
  };
}

/// One of the personal baselines' daily references: its value and the
/// runtime's confidence in it, `0..1`.
class DailyRef {
  final double value;
  final double confidence;

  const DailyRef({required this.value, required this.confidence});

  /// Null unless [json] is an object with numeric `value` and `confidence`.
  static DailyRef? fromJson(Object? json) {
    if (json is! Map) return null;
    final v = json['value'];
    final c = json['confidence'];
    if (v is! num || c is! num) return null;
    return DailyRef(value: v.toDouble(), confidence: c.toDouble());
  }

  Map<String, Object?> toJson() => {'value': value, 'confidence': confidence};
}

/// The personal baselines the Sleep Score reads, from
/// [Synheart.dailySleepBaselines]. A reference is null until the baselines
/// hold enough nights for it; which ones exist sets the score's mode.
class SleepBaselines {
  /// Typical sleep midpoint, local hour of day `0..24` (`sleep.midpoint_h`).
  final DailyRef? midpointH;

  /// Typical whole-night mean heart rate, bpm (`cardiac.overnight_hr_bpm`).
  final DailyRef? overnightHrBpm;

  /// Typical nightly deep-sleep minutes (`sleep.deep_min`).
  final DailyRef? deepMin;

  /// Typical nightly REM minutes (`sleep.rem_min`).
  final DailyRef? remMin;

  const SleepBaselines({
    this.midpointH,
    this.overnightHrBpm,
    this.deepMin,
    this.remMin,
  });

  static SleepBaselines fromJson(Map<String, dynamic> json) => SleepBaselines(
    midpointH: DailyRef.fromJson(json['midpoint_h']),
    overnightHrBpm: DailyRef.fromJson(json['overnight_hr_bpm']),
    deepMin: DailyRef.fromJson(json['deep_min']),
    remMin: DailyRef.fromJson(json['rem_min']),
  );

  Map<String, Object?> toJson() => {
    'midpoint_h': midpointH?.toJson(),
    'overnight_hr_bpm': overnightHrBpm?.toJson(),
    'deep_min': deepMin?.toJson(),
    'rem_min': remMin?.toJson(),
  };
}

/// Full input to the scorer.
class SleepScoreInput {
  final NightRaw tonight;

  /// Prior nights, newest first. Only the two newest are read, for the
  /// sleep-debt chain; the personal baselines come from [baselines].
  final List<NightRaw> priorsNewestFirst;

  /// Tonight's sleep midpoint, local hour of day `0..24`: the value pushed as
  /// `sleep.midpoint_h`. Null when the night has no start and end time, which
  /// leaves consistency out of the score; never derive it from totals.
  final double? tonightMidpointH;

  /// The personal baselines as of tonight, from
  /// [Synheart.dailySleepBaselines]. Without them the score stays in its
  /// cold-start mode.
  final SleepBaselines? baselines;

  final String pipelineVersion;

  const SleepScoreInput({
    required this.tonight,
    this.priorsNewestFirst = const [],
    this.tonightMidpointH,
    this.baselines,
    this.pipelineVersion = '',
  });

  Map<String, Object?> toJson() => {
    'tonight': tonight.toJson(),
    'priors_newest_first': priorsNewestFirst.map((p) => p.toJson()).toList(),
    'tonight_midpoint_h': tonightMidpointH,
    if (baselines != null) 'baselines': baselines!.toJson(),
    'pipeline_version': pipelineVersion,
  };

  String toJsonString() => jsonEncode(toJson());
}

/// Per-component breakdown; fields populated per-path.
class SleepScoreBreakdown {
  final int? duration;
  final int? quality;
  final int? continuity;
  final int? consistency;
  final int? personalization;
  final int? vendorScore;
  final int? proxyHr;

  const SleepScoreBreakdown({
    this.duration,
    this.quality,
    this.continuity,
    this.consistency,
    this.personalization,
    this.vendorScore,
    this.proxyHr,
  });

  factory SleepScoreBreakdown.fromJson(Map<String, Object?> json) =>
      SleepScoreBreakdown(
        duration: (json['duration'] as num?)?.toInt(),
        quality: (json['quality'] as num?)?.toInt(),
        continuity: (json['continuity'] as num?)?.toInt(),
        consistency: (json['consistency'] as num?)?.toInt(),
        personalization: (json['personalization'] as num?)?.toInt(),
        vendorScore: (json['vendor_score'] as num?)?.toInt(),
        proxyHr: (json['proxy_hr'] as num?)?.toInt(),
      );
}

class SleepScoreAdjust {
  final int debtPenalty;
  final int hrAdjustment;

  const SleepScoreAdjust({
    required this.debtPenalty,
    required this.hrAdjustment,
  });

  factory SleepScoreAdjust.fromJson(Map<String, Object?> json) =>
      SleepScoreAdjust(
        debtPenalty: (json['debt_penalty'] as num?)?.toInt() ?? 0,
        hrAdjustment: (json['hr_adjustment'] as num?)?.toInt() ?? 0,
      );
}

class ComponentWeights {
  final double duration;
  final double quality;
  final double continuity;
  final double consistency;
  final double personalization;

  const ComponentWeights({
    this.duration = 0,
    this.quality = 0,
    this.continuity = 0,
    this.consistency = 0,
    this.personalization = 0,
  });

  factory ComponentWeights.fromJson(Map<String, Object?> json) =>
      ComponentWeights(
        duration: (json['duration'] as num?)?.toDouble() ?? 0,
        quality: (json['quality'] as num?)?.toDouble() ?? 0,
        continuity: (json['continuity'] as num?)?.toDouble() ?? 0,
        consistency: (json['consistency'] as num?)?.toDouble() ?? 0,
        personalization: (json['personalization'] as num?)?.toDouble() ?? 0,
      );
}

/// The canonical output of the batch scorer.
class SleepScoreResult {
  final int? score;
  final double? scoreNormalized;
  final double confidence;
  final SleepPath path;
  final SleepScoreMode mode;
  final SleepScoreBreakdown components;
  final SleepScoreAdjust adjustments;
  final ComponentWeights effectiveWeights;
  final SleepScoreReason? reason;
  final int priorNightCount;
  final String pipelineVersion;
  final String modelId;
  final String constantsHash;

  /// Structured drivers of this score (see [SleepFactor]). Empty on
  /// vendor-passthrough and proxy paths. Does not affect [score].
  final List<SleepFactor> explanation;

  const SleepScoreResult({
    this.score,
    this.scoreNormalized,
    required this.confidence,
    required this.path,
    required this.mode,
    required this.components,
    required this.adjustments,
    required this.effectiveWeights,
    this.reason,
    required this.priorNightCount,
    required this.pipelineVersion,
    required this.modelId,
    required this.constantsHash,
    this.explanation = const [],
  });

  factory SleepScoreResult.fromJson(Map<String, Object?> json) {
    final rawExpl = (json['explanation'] as List?) ?? const [];
    final factors = <SleepFactor>[];
    for (final e in rawExpl) {
      if (e is String) {
        final f = SleepFactor.fromWire(e);
        if (f != null) factors.add(f);
      }
    }
    return SleepScoreResult(
      score: (json['score'] as num?)?.toInt(),
      scoreNormalized: (json['score_normalized'] as num?)?.toDouble(),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      path: SleepPath.fromWire(json['path'] as String? ?? 'proxy'),
      mode: SleepScoreMode.fromWire(json['mode'] as String? ?? 'cold_start'),
      components: SleepScoreBreakdown.fromJson(
        (json['components'] as Map?)?.cast<String, Object?>() ?? {},
      ),
      adjustments: SleepScoreAdjust.fromJson(
        (json['adjustments'] as Map?)?.cast<String, Object?>() ?? {},
      ),
      effectiveWeights: ComponentWeights.fromJson(
        (json['effective_weights'] as Map?)?.cast<String, Object?>() ?? {},
      ),
      reason: SleepScoreReason.fromWire(json['reason'] as String?),
      priorNightCount: (json['prior_night_count'] as num?)?.toInt() ?? 0,
      pipelineVersion: json['pipeline_version'] as String? ?? '',
      modelId: json['model_id'] as String? ?? '',
      constantsHash: json['constants_hash'] as String? ?? '',
      explanation: factors,
    );
  }

  factory SleepScoreResult.fromJsonString(String s) =>
      SleepScoreResult.fromJson(jsonDecode(s) as Map<String, Object?>);
}

/// WearableReference view over the Longitudinal SRM engine output.
///
/// Surfaces the high-signal fields typed (status, Path-B median) and
/// keeps the raw maps accessible for UI that wants to walk every
/// dimension — useful for a baselines page that renders the full SRM.
class WearableReferenceView {
  final String status;
  final String? modelVersion;
  final int? recentSleepScoreMedian;

  /// Per-dimension numeric values (e.g. `hrv_rmssd_ms`,
  /// `resting_hr_bpm`). Values are num — callers coerce as needed.
  final Map<String, num> dimensions;

  /// Per-dimension confidence ∈ [0,1].
  final Map<String, double> confidence;

  const WearableReferenceView({
    required this.status,
    this.modelVersion,
    this.recentSleepScoreMedian,
    this.dimensions = const {},
    this.confidence = const {},
  });

  factory WearableReferenceView.fromJson(Map<String, Object?> json) {
    final dimsRaw =
        (json['dimensions'] as Map?)?.cast<String, Object?>() ?? const {};
    final confRaw =
        (json['confidence'] as Map?)?.cast<String, Object?>() ?? const {};

    final dims = <String, num>{};
    for (final e in dimsRaw.entries) {
      final v = e.value;
      if (v is num) dims[e.key] = v;
    }
    final conf = <String, double>{};
    for (final e in confRaw.entries) {
      final v = e.value;
      if (v is num) conf[e.key] = v.toDouble();
    }

    return WearableReferenceView(
      status: json['status'] as String? ?? 'Empty',
      modelVersion: json['model_version'] as String?,
      recentSleepScoreMedian: (dimsRaw['recent_sleep_score_median'] as num?)
          ?.toInt(),
      dimensions: dims,
      confidence: conf,
    );
  }

  factory WearableReferenceView.fromJsonString(String s) =>
      WearableReferenceView.fromJson(jsonDecode(s) as Map<String, Object?>);
}
