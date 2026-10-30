// SPDX-License-Identifier: Apache-2.0
//
// Health Connect (Android) historical-read backfill.
//
// Android's "Apple Health export.zip" doesn't exist — Health Connect
// is an API-only system database with no user-facing export gesture.
// What it DOES offer is a permission-gated `getHealthDataFromTypes`
// read with a `(start, end)` window, which lets us pull as far back
// as the system retained the data for that record type.
//
// Retention is per-record-type and outside our control. As of 2026:
//   - Heart rate samples: typically 30 days of high-resolution data
//   - Sleep sessions: 1–2 years
//   - Steps / activity: years
//
// So an Android user gets less historical context than an iOS user
// importing a years-old `export.zip`. There's no platform fix for
// that — we just pull what's there.
//
// On iOS this class is a no-op fast-return: HealthKit historical
// data lives behind the Apple Health export.zip path
// (`AppleHealthRuntimeSink`), and the cross-platform `HealthAdapter`
// reads only return the same window we'd already get live. Calling
// here on iOS is harmless but pointless.
//
// ## Usage
//
// ```dart
// final sink = HealthConnectRuntimeSink();
// final result = await sink.backfill(daysBack: 365);
// // result.daysIngested = number of (day, dimension) tuples pushed
// ```

import 'dart:async';
import 'dart:io';

import 'package:synheart_wear/synheart_wear.dart' hide SynheartLogger;

import '../core/logger.dart';
import '../synheart.dart' show Synheart;
import '../models/daily_metric.dart';
import 'apple_health_runtime_sink.dart'
    show PushDailyCallback, TriggerRecomputeCallback;

/// Outcome of a Health Connect historical pull.
class HealthConnectBackfillResult {
  const HealthConnectBackfillResult({
    required this.requestedDaysBack,
    required this.daysIngested,
    required this.dimensionsPushed,
    required this.skipped,
    required this.skipReason,
    required this.durationMs,
  });

  /// Days of history we asked the platform for.
  final int requestedDaysBack;

  /// Distinct days with at least one value the runtime accepted.
  /// Always 0 on iOS, without permissions, with no data, or with no
  /// session running (the runtime refuses daily values without a pipeline).
  final int daysIngested;

  /// Values the runtime accepted across all days; refused pushes are not
  /// counted. Each day can contribute up to 8 (resting and overnight
  /// HR, overnight RMSSD, sleep duration, midpoint, deep and REM minutes,
  /// active minutes) depending on what the
  /// platform returned.
  final int dimensionsPushed;

  /// True when the call short-circuited (wrong platform, no
  /// permissions, no SDK available). [skipReason] explains why.
  final bool skipped;
  final String? skipReason;

  /// Wall-clock time the read + replay took. Health Connect can be
  /// slow (10s+ for a year of HR samples on cold cache) — surface
  /// this so callers can decide between blocking UI vs. background.
  final int durationMs;
}

/// High-level "bring your Health Connect history" call. Mirrors the
/// shape of [AppleHealthRuntimeSink] (Apple zip import) so the two
/// platforms have parallel public APIs even though the underlying
/// data sources are different.
///
/// Aggregations, by [DailyMetric] name:
/// - `cardiac.overnight_rmssd_ms` from
///   [HealthAdapter.fetchOvernightPhysiology].
/// - `cardiac.overnight_hr_bpm`, the mean HR inside the night's asleep span,
///   and `cardiac.resting_hr_bpm`, Health Connect's resting-HR record or,
///   without one, the same asleep mean.
/// - `sleep.duration_s` / `sleep.deep_min` / `sleep.rem_min` from
///   [HealthAdapter.fetchSleepNights], and `sleep.midpoint_h` from the
///   night's recorded start and end (never derived from totals).
/// - `motion.active_min` from [HealthAdapter.fetchActiveMinutes], for days
///   that are over.
///
/// All values land via `Synheart.srmPushWearableDaily`, which feeds
/// the longitudinal SRM directly and the live SRM via the Synheart
/// Runtime's wearable-daily ingest path.
class HealthConnectRuntimeSink {
  HealthConnectRuntimeSink({
    PushDailyCallback? pushDaily,
    TriggerRecomputeCallback? triggerRecompute,
  }) : _pushDaily = pushDaily ?? _defaultPushDaily,
       _triggerRecompute = triggerRecompute ?? _defaultTriggerRecompute;

  final PushDailyCallback _pushDaily;
  final TriggerRecomputeCallback _triggerRecompute;

  /// Pull `daysBack` days of historical sleep + overnight physiology
  /// from Health Connect (Android) and push them into the runtime
  /// SRM. Default is 365 days; the actual window is bounded by
  /// platform retention (30 days for HR, longer for sleep).
  ///
  /// On iOS this is a no-op (call [AppleHealthRuntimeSink] for the
  /// `export.zip` path instead). Returns a result with
  /// `skipped: true` and a reason so callers can surface a sensible
  /// message.
  Future<HealthConnectBackfillResult> backfill({int daysBack = 365}) async {
    final stopwatch = Stopwatch()..start();

    if (!Platform.isAndroid) {
      return HealthConnectBackfillResult(
        requestedDaysBack: daysBack,
        daysIngested: 0,
        dimensionsPushed: 0,
        skipped: true,
        skipReason:
            'Health Connect import is Android-only. '
            'Use AppleHealthRuntimeSink with export.zip on iOS.',
        durationMs: stopwatch.elapsedMilliseconds,
      );
    }

    if (daysBack <= 0) {
      return HealthConnectBackfillResult(
        requestedDaysBack: daysBack,
        daysIngested: 0,
        dimensionsPushed: 0,
        skipped: true,
        skipReason: 'daysBack must be positive',
        durationMs: stopwatch.elapsedMilliseconds,
      );
    }

    final available = await HealthAdapter.isAvailable();
    if (!available) {
      return HealthConnectBackfillResult(
        requestedDaysBack: daysBack,
        daysIngested: 0,
        dimensionsPushed: 0,
        skipped: true,
        skipReason: 'Health Connect not available on this device',
        durationMs: stopwatch.elapsedMilliseconds,
      );
    }

    // Align the window to local-day boundaries so the bucketing
    // inside HealthAdapter (which uses local-day keys) matches what
    // we ask for. The end is "right now" — Health Connect tolerates
    // mid-day end times and just returns whatever's available.
    final now = DateTime.now();
    final end = now;
    final start = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: daysBack));

    // Sleep first: the overnight read needs each night's asleep span to
    // average the heart rate measured inside it.
    final sleep = await HealthAdapter.fetchSleepNights(
      start: start,
      end: end,
      bypassThrottle: true,
    );
    final overnight = await HealthAdapter.fetchOvernightPhysiology(
      start: start,
      end: end,
      bypassThrottle: true,
      sleepNights: sleep,
    );
    final activeMinutes = await HealthAdapter.fetchActiveMinutes(
      start: start,
      end: end,
      bypassThrottle: true,
    );
    // Active minutes only for days that are over: today's count is still
    // growing, and Strain reads the closed day.
    final today = DateTime(now.year, now.month, now.day);

    // Union of distinct days seen in either stream. Some days will
    // have only sleep, others only overnight HR/HRV (e.g. user wore
    // the watch but the sleep classifier didn't fire).
    final allDays = <DateTime>{
      ...sleep.keys,
      ...overnight.keys,
      ...activeMinutes.keys.where((d) => d.isBefore(today)),
    };

    var dimensionsPushed = 0;
    var daysIngested = 0;
    // Accepted count and value range per metric, for the summary line below.
    final accepted = <String, (int, double, double)>{};
    for (final day in allDays) {
      // `day` is the local wake date the adapter keys nights by; only its
      // calendar fields are read.
      var dayDidPush = false;
      // Counts only what the runtime accepted: a refused value (no running
      // session, out of bounds) is not ingested, and a count that said so
      // would hide it.
      void push(String metric, double value) {
        final rc = _pushDaily(
          provider: _provider,
          metric: metric,
          date: day,
          value: value,
          vendorSummary: true,
        );
        if (rc != 0) return;
        dimensionsPushed += 1;
        dayDidPush = true;
        final (n, lo, hi) = accepted[metric] ?? (0, value, value);
        accepted[metric] = (
          n + 1,
          value < lo ? value : lo,
          value > hi ? value : hi,
        );
      }

      final sleepNight = sleep[day];
      if (sleepNight != null && sleepNight.totalAsleepMinutes > 0) {
        push(DailyMetric.sleepDurationS, sleepNight.totalAsleepMinutes * 60.0);
        final deep = sleepNight.deepMinutes;
        if (deep != null && deep > 0) push(DailyMetric.sleepDeepMin, deep);
        final rem = sleepNight.remMinutes;
        if (rem != null && rem > 0) push(DailyMetric.sleepRemMin, rem);
        // Only from the night's recorded span; 0.0 is midnight, a value.
        final from = sleepNight.sleepStart;
        final to = sleepNight.sleepEnd;
        if (from != null && to != null && to.isAfter(from)) {
          push(DailyMetric.sleepMidpointH, _midpointHoursLocal(from, to));
        }
      }

      final overnightSummary = overnight[day];
      if (overnightSummary != null) {
        final rmssd = overnightSummary.hrvRmssdMs;
        if (rmssd != null && rmssd > 0) {
          push(DailyMetric.overnightRmssdMs, rmssd);
        }
        // The asleep mean feeds the Sleep Score's HR term. Resting HR is
        // the platform's own record; without one, the asleep figure is the
        // night's only heart rate and stands in for it, so Recovery and
        // Readiness keep a resting-HR baseline (the runtime's rule for a
        // source with one overnight figure).
        final asleepHr = overnightSummary.overnightHrBpm;
        if (asleepHr != null && asleepHr > 0) {
          push(DailyMetric.overnightHrBpm, asleepHr);
        }
        final restingHr = overnightSummary.restingHrBpm ?? asleepHr;
        if (restingHr != null && restingHr > 0) {
          push(DailyMetric.restingHrBpm, restingHr);
        }
      }

      final active = activeMinutes[day];
      if (active != null && active > 0 && day.isBefore(today)) {
        push(DailyMetric.activeMin, active);
      }

      if (dayDidPush) daysIngested += 1;
    }

    SynheartLogger.log(
      'HealthConnect backfill: ${sleep.length} nights, ${overnight.length} '
      'HR/HRV days, ${activeMinutes.length} exercise days read; accepted '
      '${accepted.isEmpty ? 'none' : accepted.entries.map((e) => '${e.key} ×${e.value.$1} [${e.value.$2.toStringAsFixed(1)}–${e.value.$3.toStringAsFixed(1)}]').join(', ')}',
    );
    if (dimensionsPushed > 0) {
      _triggerRecompute();
    }

    stopwatch.stop();
    return HealthConnectBackfillResult(
      requestedDaysBack: daysBack,
      daysIngested: daysIngested,
      dimensionsPushed: dimensionsPushed,
      skipped: false,
      skipReason: null,
      durationMs: stopwatch.elapsedMilliseconds,
    );
  }

  static const _provider = 'health_connect';

  /// Local-time midpoint of a night in hours since midnight, `[0, 24)`.
  static double _midpointHoursLocal(DateTime from, DateTime to) {
    final mid = DateTime.fromMillisecondsSinceEpoch(
      (from.millisecondsSinceEpoch + to.millisecondsSinceEpoch) ~/ 2,
    );
    return mid.hour + mid.minute / 60.0 + mid.second / 3600.0;
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
