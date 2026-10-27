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

import 'package:synheart_wear/synheart_wear.dart';

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

  /// Distinct days that produced at least one push (i.e. days where
  /// either sleep or overnight HR/HRV came back from the read).
  /// Always 0 on iOS / when no permissions / when no data found.
  final int daysIngested;

  /// Total `srmPushWearableDaily` calls fired across all days. Each
  /// day can contribute up to 5 (resting HR, overnight RMSSD, sleep
  /// duration, deep and REM minutes) depending on what the platform
  /// returned.
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
/// Aggregations match the Apple Health path:
/// - `hrv_rmssd` from [HealthAdapter.fetchOvernightPhysiology] (which
///   already normalises Android RMSSD ↔ iOS SDNN-as-RMSSD).
/// - `resting_hr` from the same overnight summary.
/// - `sleep_need` (seconds) / `deep_sleep_min` / `rem_sleep_min` from
///   [HealthAdapter.fetchSleepNights].
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

    // Two parallel reads — different record types, no shared state.
    // Health Connect's read is rate-limited per-process so running
    // them in parallel is fine and saves wall time.
    final futures = await Future.wait<Object>([
      HealthAdapter.fetchSleepNights(
        start: start,
        end: end,
        bypassThrottle: true,
      ),
      HealthAdapter.fetchOvernightPhysiology(
        start: start,
        end: end,
        bypassThrottle: true,
      ),
    ]);
    final sleep = futures[0] as Map<DateTime, SleepNightSummary>;
    final overnight = futures[1] as Map<DateTime, OvernightPhysiologySummary>;

    // Union of distinct days seen in either stream. Some days will
    // have only sleep, others only overnight HR/HRV (e.g. user wore
    // the watch but the sleep classifier didn't fire).
    final allDays = <DateTime>{...sleep.keys, ...overnight.keys};

    var dimensionsPushed = 0;
    var daysIngested = 0;
    for (final day in allDays) {
      // `day` is the local wake date the adapter keys nights by; only its
      // calendar fields are read.
      void push(String metric, double value) {
        _pushDaily(
          provider: _provider,
          metric: metric,
          date: day,
          value: value,
          vendorSummary: true,
        );
        dimensionsPushed += 1;
      }

      var dayDidPush = false;

      final sleepNight = sleep[day];
      if (sleepNight != null && sleepNight.totalAsleepMinutes > 0) {
        push(DailyMetric.sleepDurationS, sleepNight.totalAsleepMinutes * 60.0);
        dayDidPush = true;
        final deep = sleepNight.deepMinutes;
        if (deep != null && deep > 0) push(DailyMetric.sleepDeepMin, deep);
        final rem = sleepNight.remMinutes;
        if (rem != null && rem > 0) push(DailyMetric.sleepRemMin, rem);
      }

      final overnightSummary = overnight[day];
      if (overnightSummary != null) {
        final rmssd = overnightSummary.hrvRmssdMs;
        if (rmssd != null && rmssd > 0) {
          push(DailyMetric.overnightRmssdMs, rmssd);
          dayDidPush = true;
        }
        final restingHr = overnightSummary.restingHrBpm;
        if (restingHr != null && restingHr > 0) {
          push(DailyMetric.restingHrBpm, restingHr);
          dayDidPush = true;
        }
      }

      if (dayDidPush) daysIngested += 1;
    }

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
