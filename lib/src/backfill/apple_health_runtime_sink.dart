// SPDX-License-Identifier: Apache-2.0
//
// Apple Health runtime ingest sink.
//
// Drop-in `AppleXmlIngestSink` for `AppleHealthXmlImport` (in
// `synheart_wear`) that:
//
//   1. Records every sample's idempotency key in the runtime's
//      backfill SQLite (via `AppleXmlBackfillSink` → the FFI
//      `synheart_core_backfill_*` symbols). This is the dedup index
//      that lets users re-import the same `export.zip` cheaply.
//
//   2. Aggregates samples per day into the dimensions the runtime SRM
//      consumes (`resting_hr`, `sleep_need`, `deep_sleep_min`,
//      `rem_sleep_min`) and replays them via
//      `Synheart.srmPushWearableDaily` on `finalize`. The Synheart
//      Runtime's wearable-daily ingest path then synthesizes a
//      per-window FeatureSet for each value that
//      maps to a live SRM key (`resting_hr` → `hrv.hr_mean_bpm`),
//      so the visible 11-baseline readout populates from the import
//      without a live wearable session.
//
// This class is the high-level "do the right thing on an Apple Health
// export" API. Apps should not build the pieces themselves.
//
// ```dart
// final sink = AppleHealthRuntimeSink(dbPath: '/path/to/backfill.db');
// final importer = AppleHealthXmlImport(xmlBytes: bytes, sink: sink);
// final result = await importer.parse();
// ```

import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:synheart_wear/synheart_wear.dart';

import '../core_runtime/ffi_bindings.dart' show SynheartCoreFFI;
import '../models/daily_metric.dart';
import '../synheart.dart' show Synheart;
import 'apple_xml_backfill_sink.dart';

/// Callback signature for pushing a daily wearable value. Mirrors
/// [Synheart.srmPushWearableDaily]'s named parameters so a plain
/// function reference can be used directly. Injectable so tests can
/// substitute a recorder without booting the whole runtime.
typedef PushDailyCallback =
    int Function({
      required String provider,
      required String metric,
      required DateTime date,
      required double value,
      bool vendorSummary,
    });

/// Callback signature for refreshing the wearable reference after a batch.
/// Mirrors [Synheart.srmRefreshWearableReference]'s shape (no required args).
typedef TriggerRecomputeCallback = void Function();

/// The key the backfill sinks file a day under: the local calendar date of
/// [epochMs], as days since 1970-01-01. The runtime files daily values under
/// the person's local date, so a night that ends at 02:00 local must not land
/// on the UTC date (the previous day east of UTC).
int localDayKey(int epochMs) {
  final l = DateTime.fromMillisecondsSinceEpoch(epochMs);
  return DateTime.utc(l.year, l.month, l.day).millisecondsSinceEpoch ~/
      86_400_000;
}

/// The local calendar date a [localDayKey] stands for. Only its year, month
/// and day mean anything.
DateTime dateOfLocalDayKey(int key) =>
    DateTime.fromMillisecondsSinceEpoch(key * 86_400_000, isUtc: true);

/// High-level `AppleXmlIngestSink` that bridges an Apple Health
/// `export.zip` import to the runtime SRM.
///
/// Composes:
/// - [AppleXmlBackfillSink] for FFI-side idempotency.
/// - [AppleHealthDailyAggregator] for in-memory per-day rollup.
/// - On `finalize`: replays the rollup into [Synheart.srmPushWearableDaily]
///   and triggers a recompute so the next inference window picks up
///   fresh personal baselines.
class AppleHealthRuntimeSink implements AppleXmlIngestSink {
  AppleHealthRuntimeSink({
    required this.dbPath,
    SynheartCoreFFI? ffi,
    PushDailyCallback? pushDaily,
    TriggerRecomputeCallback? triggerRecompute,
  }) : _backfill = AppleXmlBackfillSink(
         ffi: ffi ?? SynheartCoreFFI.load(),
         dbPath: dbPath,
       ),
       _pushDaily = pushDaily ?? _defaultPushDaily,
       _triggerRecompute = triggerRecompute ?? _defaultTriggerRecompute;

  /// Filesystem path to the backfill SQLite DB. Pass `":memory:"`
  /// for ephemeral imports.
  final String dbPath;

  final AppleXmlBackfillSink _backfill;
  final PushDailyCallback _pushDaily;
  final TriggerRecomputeCallback _triggerRecompute;
  final AppleHealthDailyAggregator _aggregator = AppleHealthDailyAggregator();

  /// Whether the underlying runtime exposes the backfill FFI symbols.
  /// False when the loaded native runtime lacks the backfill symbols.
  bool get isAvailable => _backfill.isAvailable;

  /// Resolve a durable filesystem path for the backfill SQLite DB.
  ///
  /// Lives under `getApplicationSupportDirectory()` so the file
  /// survives across app launches — iOS cleans `Directory.systemTemp`
  /// at unpredictable times, which breaks the dedup index that lets
  /// re-imports of the same `export.zip` skip already-processed
  /// samples cheaply.
  ///
  /// Default file name is `synheart_backfill.db`; pass [fileName] to
  /// override (e.g. for app-private namespacing if you ship multiple
  /// imports per user).
  ///
  /// Apps usually want this as the source of truth and should
  /// construct the sink with:
  /// ```dart
  /// final sink = AppleHealthRuntimeSink(
  ///   dbPath: await AppleHealthRuntimeSink.defaultDbPath(),
  /// );
  /// ```
  static Future<String> defaultDbPath({
    String fileName = 'synheart_backfill.db',
  }) async {
    final dir = await getApplicationSupportDirectory();
    // `getApplicationSupportDirectory` is documented as guaranteed
    // to exist on iOS / Android, but the underlying platform call
    // can no-op on macOS sandbox edge cases. `createSync(recursive:
    // true)` is idempotent and safe to call regardless.
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return p.join(dir.path, fileName);
  }

  @override
  Future<void> open(String importId) => _backfill.open(importId);

  @override
  Future<BatchResult> insertBatch(List<AppleHealthSample> samples) async {
    // Aggregate BEFORE the FFI call so a partial import still
    // contributes to baselines: even if the runtime call below
    // throws, we keep the rollup so `finalize` can drain what we
    // have. The FFI insert below is for idempotency bookkeeping.
    for (final s in samples) {
      _aggregator.add(s);
    }
    final json = jsonEncode(samples.map(_sampleToJson).toList());
    final r = await _backfill.insertBatchJson(json);
    return BatchResult(inserted: r.inserted, skipped: r.skippedAsDuplicate);
  }

  @override
  Future<ImportResult> finalize() async {
    final r = await _backfill.finalize();
    _aggregator.replayInto(_pushDaily);
    if (_aggregator.hasAnyEntries) {
      _triggerRecompute();
    }
    return ImportResult(
      importId: r.importId,
      totalSamples: r.totalSamples,
      inserted: r.inserted,
      skippedAsDuplicate: r.skippedAsDuplicate,
      skippedAsUnknown: 0,
      durationMs: r.durationMs,
    );
  }

  Map<String, dynamic> _sampleToJson(AppleHealthSample s) => {
    'metric': s.metric.raw,
    'source': s.source,
    'start_ms': s.startMs,
    'end_ms': s.endMs,
    'value': _valueToJson(s.value),
  };

  Map<String, dynamic> _valueToJson(SampleValue v) {
    if (v is QuantityValue) {
      return {'kind': 'quantity', 'value': v.value};
    } else if (v is SleepStageValue) {
      return {'kind': 'sleep', 'stage': v.stage.raw};
    }
    throw StateError('unhandled SampleValue: $v');
  }

  static int _defaultPushDaily({
    required String provider,
    required String metric,
    required DateTime date,
    required double value,
    bool vendorSummary = true,
  }) => Synheart.srmPushWearableDaily(
    provider: provider,
    metric: metric,
    date: date,
    value: value,
    vendorSummary: vendorSummary,
  );

  static void _defaultTriggerRecompute() {
    Synheart.srmRefreshWearableReference();
  }
}

/// Per-day rollup of Apple Health samples → daily aggregates that the
/// runtime SRM understands.
///
/// Apple Health exports millions of per-second / per-minute samples;
/// the SRM consumes per-day aggregates. This class is the bridge,
/// extracted from [AppleHealthRuntimeSink] so callers can compose
/// their own pipelines (e.g. a debug tool that only logs aggregates,
/// a test harness that asserts on the rollup, or a vendor sync that
/// wants to apply the same shape to non-Apple data).
///
/// **Aggregations**, by [DailyMetric] name:
///
/// - **`restingHeartRate` samples** (Apple's vendor-computed daily
///   resting HR) → daily mean → `cardiac.resting_hr_bpm`, as a vendor
///   summary. When present for a day, the proxy below is *not* used for
///   that day: vendor wins.
///
/// - **HR samples in [40, 100] BPM** → daily mean →
///   `cardiac.resting_hr_bpm`, as a value computed in-app. Fallback for
///   days with no `restingHeartRate` sample (early imports, non-Watch
///   sources). The filter is a coarse exercise/artefact reject.
///
/// - **Sleep stages** → minutes per category per night, each block
///   attributed to the local date of its `endMs`:
///     - `sleep.duration_s` = `(asleep + light + deep + rem)` in seconds
///     - `sleep.deep_min` / `sleep.rem_min` = stage minutes
///
/// - **The main night** (asleep blocks merged across wakes shorter than
///   90 minutes, filed under the date it ends on; the longest wins over
///   a nap) → `sleep.midpoint_h`, its local midpoint, and
///   `cardiac.overnight_hr_bpm`, the mean of the HR samples taken inside
///   its asleep blocks. Both computed in-app.
///
/// - **HRV (SDNN)** → daily mean → `cardiac.overnight_sdnn_ms`. Never
///   pushed as RMSSD: same heart, structurally different distributions.
///
/// - **Steps / calories / spo2 / temperature** are still recorded by
///   the FFI dedup index but not aggregated here.
class AppleHealthDailyAggregator {
  // Day-index → vendor-computed daily resting HR running mean.
  // Populated from `HKQuantityTypeIdentifierRestingHeartRate`.
  // Preferred over `_hrProxyByDay` when both are present for a day.
  final Map<int, _RunningMean> _restingHrByDay = {};
  // Day-index → filtered HR proxy running mean (fallback path when
  // vendor-computed resting HR isn't available for that day).
  final Map<int, _RunningMean> _hrProxyByDay = {};
  // Day-index → SDNN running mean.
  final Map<int, _RunningMean> _sdnnByDay = {};
  // Day-index → sleep stage minutes (keyed by SleepStage.raw).
  final Map<int, Map<String, double>> _sleepByDay = {};
  // Every asleep stage block, `(startMs, endMs)`, grouped into nights on
  // replay: a night's stages straddle midnight, so per-day keys would split
  // it. Gives the night's timing (`sleep.midpoint_h`) and which heart-rate
  // samples were taken asleep (`cardiac.overnight_hr_bpm`).
  final List<(int, int)> _asleepSpans = [];
  // Five-minute bucket (`startMs ~/ _hrBucketMs`) → HR running mean. Kept
  // in buckets because the export streams HR before or after the sleep
  // records that say which samples were asleep.
  final Map<int, _RunningMean> _hrByBucket = {};

  static const _hrBucketMs = 5 * 60_000;
  static const _asleepStages = {
    SleepStage.asleep,
    SleepStage.light,
    SleepStage.deep,
    SleepStage.rem,
  };
  // Blocks closer than this belong to one night (a wake-up in the night);
  // further apart, a separate sleep (a nap).
  static const _nightGapMs = 90 * 60_000;
  // Fewer asleep HR samples than this is too thin for a nightly mean.
  static const _minAsleepHrSamples = 6;

  bool get hasAnyEntries =>
      _restingHrByDay.isNotEmpty ||
      _hrProxyByDay.isNotEmpty ||
      _sdnnByDay.isNotEmpty ||
      _sleepByDay.isNotEmpty;

  /// Distinct days seen so far across all metric streams. Useful for
  /// diagnostics; the SRM only ever sees one resting_hr value per day
  /// regardless of how many streams contributed (vendor wins).
  int get distinctDayCount => ({
    ..._restingHrByDay.keys,
    ..._hrProxyByDay.keys,
    ..._sdnnByDay.keys,
    ..._sleepByDay.keys,
  }).length;

  void add(AppleHealthSample s) {
    switch (s.metric) {
      case AppleHealthMetric.heartRate:
        final v = s.value;
        if (v is! QuantityValue) return;
        final bpm = v.value;
        // Asleep HR keeps its own, wider bounds: a sleeping heart below 40
        // is real for a fit sleeper, where the resting proxy rejects it.
        if (bpm >= 30.0 && bpm <= 150.0) {
          (_hrByBucket[s.startMs ~/ _hrBucketMs] ??= _RunningMean()).add(bpm);
        }
        if (bpm < 40.0 || bpm > 100.0) return;
        final day = localDayKey(s.startMs);
        (_hrProxyByDay[day] ??= _RunningMean()).add(bpm);
        break;
      case AppleHealthMetric.restingHeartRate:
        final v = s.value;
        if (v is! QuantityValue) return;
        final bpm = v.value;
        // Same outer bounds as the proxy filter: anything outside
        // [40, 100] from the vendor is almost certainly a corrupt
        // export row. Apple's sleep classifier only ever publishes
        // values in roughly [40, 90] for healthy adults.
        if (bpm < 40.0 || bpm > 100.0) return;
        // Apple typically publishes one daily value per day, but we
        // accumulate as a running mean for safety against duplicate
        // exports / multiple sources.
        final day = localDayKey(s.startMs);
        (_restingHrByDay[day] ??= _RunningMean()).add(bpm);
        break;
      case AppleHealthMetric.sleepStage:
        final v = s.value;
        if (v is! SleepStageValue) return;
        final durationMs = s.endMs - s.startMs;
        if (durationMs <= 0) return;
        final minutes = durationMs / 60_000.0;
        final day = localDayKey(s.endMs);
        final stages = _sleepByDay[day] ??= <String, double>{};
        stages[v.stage.raw] = (stages[v.stage.raw] ?? 0.0) + minutes;
        if (_asleepStages.contains(v.stage)) {
          _asleepSpans.add((s.startMs, s.endMs));
        }
        break;
      case AppleHealthMetric.hrvSdnn:
        final v = s.value;
        if (v is! QuantityValue) return;
        final ms = v.value;
        // Sanity bounds: SDNN below 5 ms is almost always a sensor
        // error (real autonomic SDNN is rarely below 10 ms even
        // under sympathetic load). Above 250 ms is essentially
        // impossible from a healthy heart on a watch-grade sensor —
        // treat as artefact.
        if (ms < 5.0 || ms > 250.0) return;
        final day = localDayKey(s.startMs);
        (_sdnnByDay[day] ??= _RunningMean()).add(ms);
        break;
      case AppleHealthMetric.steps:
      case AppleHealthMetric.calories:
      case AppleHealthMetric.spo2:
      case AppleHealthMetric.temperature:
        // No live SRM mapping yet (HRV) or no dimension at all
        // (steps/calories/spo2/temp). Recorded by the FFI dedup
        // index for future rendering, just not aggregated here.
        break;
    }
  }

  /// Drain the rollup via [pushDaily], one call per (local date, metric),
  /// all from provider `apple_health`. A vendor-computed value is pushed as a
  /// provider summary; the resting-HR proxy (filtered daily-mean HR, derived
  /// in-app) as a value computed from raw samples, and only for dates Apple
  /// published no resting HR for.
  void replayInto(PushDailyCallback pushDaily) {
    void push(String metric, int day, double value, {bool summary = true}) =>
        pushDaily(
          provider: _provider,
          metric: metric,
          date: dateOfLocalDayKey(day),
          value: value,
          vendorSummary: summary,
        );

    // Vendor-computed resting HR wins per day.
    for (final entry in _restingHrByDay.entries) {
      final mean = entry.value.mean;
      if (mean == null) continue;
      push(DailyMetric.restingHrBpm, entry.key, mean);
    }
    // Proxy fallback: only for days where the vendor didn't publish a
    // resting HR. Pushing both would replace the vendor value (a date is
    // written once per metric) with the weaker proxy.
    for (final entry in _hrProxyByDay.entries) {
      if (_restingHrByDay.containsKey(entry.key)) continue;
      final mean = entry.value.mean;
      if (mean == null) continue;
      push(DailyMetric.restingHrBpm, entry.key, mean, summary: false);
    }
    // Apple Watch computes SDNN onboard from clean RR, so it is a vendor
    // summary.
    for (final entry in _sdnnByDay.entries) {
      final mean = entry.value.mean;
      if (mean == null) continue;
      push(DailyMetric.overnightSdnnMs, entry.key, mean);
    }
    for (final entry in _sleepByDay.entries) {
      final stages = entry.value;
      final asleep = stages[SleepStage.asleep.raw] ?? 0.0;
      final light = stages[SleepStage.light.raw] ?? 0.0;
      final deep = stages[SleepStage.deep.raw] ?? 0.0;
      final rem = stages[SleepStage.rem.raw] ?? 0.0;
      final totalMinutes = asleep + light + deep + rem;
      if (totalMinutes > 0) {
        push(DailyMetric.sleepDurationS, entry.key, totalMinutes * 60.0);
      }
      if (deep > 0) push(DailyMetric.sleepDeepMin, entry.key, deep);
      if (rem > 0) push(DailyMetric.sleepRemMin, entry.key, rem);
    }
    // Both computed in-app from the stage timings, so neither is a vendor
    // summary. Apple's resting HR is measured awake, so the asleep mean is a
    // separate figure: it feeds only the Sleep Score's HR term.
    for (final entry in _mainNightByWakeDay().entries) {
      final night = entry.value;
      push(
        DailyMetric.sleepMidpointH,
        entry.key,
        _midpointHoursLocal(night.startMs, night.endMs),
        summary: false,
      );
      final hr = _asleepMeanHr(night.spans);
      if (hr != null) {
        push(DailyMetric.overnightHrBpm, entry.key, hr, summary: false);
      }
    }
  }

  /// The main night per wake date: asleep blocks merged across short wakes,
  /// filed under the local date the night ends on, the longest kept where a
  /// date has more than one (a nap).
  Map<int, _Night> _mainNightByWakeDay() {
    final spans = [..._asleepSpans]..sort((a, b) => a.$1.compareTo(b.$1));
    final nights = <_Night>[];
    for (final span in spans) {
      final last = nights.isEmpty ? null : nights.last;
      if (last != null && span.$1 - last.endMs <= _nightGapMs) {
        last.add(span);
      } else {
        nights.add(_Night(span));
      }
    }
    final out = <int, _Night>{};
    for (final night in nights) {
      final day = localDayKey(night.endMs);
      final held = out[day];
      if (held == null || night.asleepMs > held.asleepMs) out[day] = night;
    }
    return out;
  }

  /// Mean heart rate over the five-minute buckets inside the asleep blocks,
  /// weighted by sample count; null below [_minAsleepHrSamples].
  double? _asleepMeanHr(List<(int, int)> spans) {
    final buckets = <int>{};
    for (final (start, end) in spans) {
      for (var b = start ~/ _hrBucketMs; b <= (end - 1) ~/ _hrBucketMs; b++) {
        buckets.add(b);
      }
    }
    var sum = 0.0;
    var n = 0;
    for (final b in buckets) {
      final m = _hrByBucket[b];
      final mean = m?.mean;
      if (m == null || mean == null) continue;
      sum += mean * m.count;
      n += m.count;
    }
    return n < _minAsleepHrSamples ? null : sum / n;
  }

  /// Local-time midpoint of a night in hours since midnight, `[0, 24)`.
  static double _midpointHoursLocal(int startMs, int endMs) {
    final mid = DateTime.fromMillisecondsSinceEpoch((startMs + endMs) ~/ 2);
    return mid.hour + mid.minute / 60.0 + mid.second / 3600.0;
  }

  static const _provider = 'apple_health';
}

/// Welford-style running mean. Avoids accumulator-overflow on
/// millions of HR samples by keeping the mean and the count rather
/// than a raw sum.
class _RunningMean {
  double _mean = 0.0;
  int _n = 0;

  void add(double v) {
    _n += 1;
    _mean += (v - _mean) / _n;
  }

  double? get mean => _n == 0 ? null : _mean;

  int get count => _n;
}

/// One night's asleep blocks, merged in start order.
class _Night {
  _Night((int, int) span) : startMs = span.$1, endMs = span.$2, spans = [span];

  final int startMs;
  int endMs;
  final List<(int, int)> spans;

  int get asleepMs => spans.fold(0, (total, s) => total + (s.$2 - s.$1));

  void add((int, int) span) {
    spans.add(span);
    if (span.$2 > endMs) endMs = span.$2;
  }
}
