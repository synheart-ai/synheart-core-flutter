import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;

import '../../core/logger.dart';
import '../../models/readiness_score.dart';
import '../../models/recovery_score.dart';
import '../../models/sleep_questionnaire.dart';
import '../../models/sleep_score.dart';
import '../../resilience/synheart_resilience.dart' show HrvSample, SleepWindow;
import '../../models/daily_metric.dart';
import 'daily_score_ledger.dart';
import '../../synheart.dart';
import 'baselines_snapshot.dart';

/// Stable identity for every baseline data lane. Keep these wire
/// strings in sync with `Baselines.lastSource` and the engine's
/// per-provider switch — host apps store the enum, the engine sees
/// the string.
enum BaselineSource {
  whoop('whoop'),
  garmin('garmin'),

  /// Platform health store. Resolves to Apple Health on iOS or Health
  /// Connect on Android — the host UI surfaces this as "Device" and
  /// the wire id stays stable for storage.
  device('device'),

  /// Self-reported questionnaire. Available only when the user is in
  /// Research mode.
  selfReport('self_report');

  final String wire;
  const BaselineSource(this.wire);

  static BaselineSource? fromWire(String? s) {
    if (s == null) return null;
    for (final v in BaselineSource.values) {
      if (v.wire == s) return v;
    }
    return null;
  }

  /// Human-readable label for the source, with platform-aware label
  /// for [device].
  String get label {
    switch (this) {
      case BaselineSource.whoop:
        return 'WHOOP';
      case BaselineSource.garmin:
        return 'Garmin';
      case BaselineSource.device:
        return 'Device';
      case BaselineSource.selfReport:
        return 'Self-Log';
    }
  }

  /// Subtitle hint exposing what `device` actually maps to.
  String? get sublabel {
    switch (this) {
      case BaselineSource.device:
        return Platform.isIOS ? 'Apple Health' : 'Health Connect';
      default:
        return null;
    }
  }

  /// The provider id passed to the engine when this lane ingests a
  /// payload. For [device] the SDK chooses `apple_health` or
  /// `health_connect` based on the running platform.
  String get engineProvider {
    switch (this) {
      case BaselineSource.device:
        return Platform.isIOS ? 'apple_health' : 'health_connect';
      default:
        return wire;
    }
  }
}

/// Host-facing facade over the sleep-score baseline surface.
///
/// Wraps the three primitives already exposed on [Synheart]:
/// `computeSleepScore`, `attachSleepScore`, `wearableReference` — and
/// adds:
///   • vendor-payload → `NightRaw` normalization (WHOOP + Garmin),
///   • an in-memory cache of the most recent [SleepScoreResult] and
///     [WearableReferenceView],
///   • a broadcast [Stream] of [BaselinesSnapshot] that fires on every
///     successful ingest.
///
/// Any consumer app (pulse-focus, future SDK hosts) can drive a
/// "Baselines" / SRM page by calling [ingestVendorSleep] from its
/// vendor-event plumbing and reading [snapshot] / [updates] from the
/// UI layer. The facade deliberately holds no configuration state of
/// its own — `Synheart.initialize(...)` is the single initialization
/// point; [Baselines] is safe to use as soon as the runtime is up.
class Baselines {
  Baselines._();

  static final StreamController<BaselinesSnapshot> _ctrl =
      StreamController<BaselinesSnapshot>.broadcast();

  static SleepScoreResult? _latestScore;
  static WearableReferenceView? _latestReference;
  static String? _lastSource;

  /// Variant id (e.g. `whoop`, `whoop_score`, `apple_health`) that
  /// produced the current [_latestScore]. Always equal to [_lastSource]
  /// when the winner was the aggregated path; differs when the winner
  /// was a vendor-passthrough variant whose id carries the `_score`
  /// suffix. Surfaced via [lastVariantId] for any UI that wants to
  /// distinguish "computed from WHOOP stages" vs "WHOOP's own number".
  static String? _lastVariantId;
  static DateTime? _lastIngestAt;

  /// Per-calendar-night dedupe: maps `wake_calendar_date` to the
  /// provider that first claimed it this process. Hosts run pulls
  /// in priority order (WHOOP → Garmin → Device → self-report), so
  /// the first attach for a given night wins; later sources see
  /// the entry and skip — preventing the same calendar night from
  /// landing in the Path-B ring twice when a user has both WHOOP
  /// and Apple Health enabled, for example.
  static final Map<int, String> _attachedKeys = <int, String>{};

  /// Path of the score currently claiming each wake day. Parallel to
  /// [_attachedKeys] — kept so the priority-evict comparison can
  /// weigh `(path, provider)` together: a computed score from any
  /// provider beats a vendor passthrough from a higher-rank provider,
  /// because synheart's value is consistent constants across users.
  static final Map<int, SleepPath> _attachedPaths = <int, SleepPath>{};

  /// What was last queued for upload per daily score kind, and whether a
  /// frame carried it. Persisted in [exportRecoveryStateJson], so a relaunch
  /// that re-pulls a month of nights does not attach them all again. See
  /// [DailyScoreLedger].
  static final DailyScoreLedger _ledger = DailyScoreLedger();

  /// Per-vendor score history keyed by `wake_calendar_date`. Every
  /// call to [ingestVendorSleep] that produces a non-null result
  /// records into this map, even when the dedupe gate skips the
  /// engine attach — so the UI can surface "WHOOP says 64, Apple
  /// Health says 78 for the same night" without changing the ring
  /// or the priority winner.
  ///
  /// Capped at [_maxPriors] most-recent nights to keep memory
  /// bounded; the ring + priors caps already enforce the same
  /// horizon.
  static final Map<int, Map<String, SleepScoreResult>> _scoresByNight =
      <int, Map<String, SleepScoreResult>>{};

  /// Local mirror of the Path-B 7-night ring. Hydrated lazily from
  /// the engine's persisted longitudinal snapshot on first read of
  /// this process, then maintained in lockstep with [ingestVendorSleep]
  /// attaches. The mirror exists so [reset] can immediately reflect
  /// the cold-start state in the user-facing snapshot without
  /// waiting for the next async tick from the engine.
  static final List<int> _localRing = <int>[];

  /// Wake days parallel to [_localRing]. Used by the priority-evict
  /// path to swap a specific night's ring entry when a higher-priority
  /// provider arrives after a lower-priority one already attached.
  /// `-1` = unknown (hydrated from a persisted snapshot which only
  /// stores scores, no wake-day tags) — eviction skips those slots
  /// since we can't tell which night they belong to.
  static final List<int> _localRingDays = <int>[];

  /// Recent `NightRaw` inputs in attach order (oldest → newest).
  /// Capped at [_maxPriors] = 40 nights, which covers every decay
  /// window the engine applies. Fed into `compute_sleep_score` as
  /// `priors_newest_first` so the scoring mode advances past
  /// cold_start once we have ≥1 prior night, and reaches stable at
  /// ≥7 priors. Without this, every score request looked like a
  /// first-ever night to the engine.
  static const int _maxPriors = 40;
  static final List<NightRaw> _recentNights = <NightRaw>[];

  /// Per-night overnight physiology (HR + HRV), aligned 1-to-1 with
  /// [_recentNights]. Populated from the same vendor payload that drove
  /// the sleep-score attach so Recovery Score Stage 2 / 3 can read
  /// trend / deviation against priors. Entries are
  /// [OvernightPhysiology] with all fields nullable — when the vendor
  /// emits sleep without a paired physiology event, we still need a
  /// placeholder to keep the index aligned with [_recentNights].
  static final List<OvernightPhysiology> _recentOvernight =
      <OvernightPhysiology>[];

  /// The most recent [RecoveryScoreResult], or null if none has been
  /// computed in this process yet (or the user has sleep-only data —
  /// recovery requires HR or HRV).
  static RecoveryScoreResult? _latestRecoveryScore;

  /// The most recent [ReadinessScoreResult]. Computed each time a
  /// fresh Recovery Score lands; layers fatigue + history context on
  /// the Recovery anchor.
  static ReadinessScoreResult? _latestReadinessScore;

  /// Recent Recovery Score history for fatigue trend computation.
  /// Newest at the back, capped at 7 entries (the engine slope is
  /// computed against the most recent 3–7).
  static final List<int> _recentRecoveryScores = <int>[];

  /// Per-calendar-day max strain in `[0, 1]` from vendor workouts.
  /// Used to compute the acute:chronic ratio + consecutive
  /// high-strain-day count for the Readiness Score's acute-load and
  /// history contexts. Capped at the last 28 days (the chronic
  /// window). Hosts feed this via [attachVendorWorkout].
  static final Map<int, double> _strainByDay = <int, double>{};

  /// Per-calendar-day overnight physiology, populated by
  /// [attachOvernightPhysiology] from any source — independent of
  /// which provider attached the sleep night for that day.
  ///
  /// This decouples Sleep ingest (provider-specific) from Recovery
  /// computation (cross-provider): when Apple Health attaches a
  /// sleep night and WHOOP later lands a recovery record for the
  /// same day, the Recovery / Readiness path picks it up.
  static final Map<int, OvernightPhysiology> _overnightByDay =
      <int, OvernightPhysiology>{};

  /// True after the next `compute_sleep_score` call should use the
  /// in-memory priors. New nights append after a successful attach.
  /// `reset()` clears it.

  /// Set true the first time the local ring has been hydrated from
  /// the engine snapshot, OR after [reset]. Suppresses re-hydration
  /// from a stale post-wipe snapshot.
  static bool _ringHydrated = false;

  /// Nights ring persisted in the host recovery blob (see
  /// export/loadRecoveryStateJson). Cold-start fallback for [_readRecentRing]
  /// when the native (subject-scoped) longitudinal snapshot is empty — e.g.
  /// signed-out / per-device subject — so `nightsLoggedCount` survives a launch
  /// and Home / Sleep & Recovery don't drop to the "needs more nights" empty
  /// state even though the latest scores were restored.
  static List<int>? _persistedRecentRing;

  /// True between a [reset] call and the next manual (force) pull.
  /// Auto-pull paths consult this and skip — otherwise on iOS the
  /// orchestrator would silently re-ingest the same Apple Health
  /// nights right after the user hit "Clean data", making the wipe
  /// look like a no-op. Cleared by [acknowledgeManualPull].
  static bool _suppressAutoPull = false;

  /// True when a wipe has been performed and the host has not yet
  /// confirmed an explicit pull. UI/orchestrators should treat this
  /// as a hint to require a manual "Pull now" before auto-fetching
  /// historical data again.
  static bool get autoPullSuppressed => _suppressAutoPull;

  /// Called by orchestrators when they intentionally fire a manual
  /// pull after a wipe, so subsequent auto-pulls resume normally.
  static void acknowledgeManualPull() {
    _suppressAutoPull = false;
  }

  // ─── Ingest batching ──────────────────────────────────────────────
  //
  // Recovery + Readiness are derived scores that the SDK historically
  // recomputed after every [ingestVendorSleep]. A 30-day vendor pull
  // (3 providers × 30 nights × ~2 variants) fires `_settleDerivedScores`
  // ~180 times — each one a 4-FFI-hop cascade — even though only the
  // final state is user-visible. The batching API lets a host wrap a
  // multi-source pull so the cascade defers to a single end-of-batch
  // settle against the latest attached night.
  //
  // Per-night `_pushDailyToRuntimeSrm` keeps firing inside a batch:
  // SRM dedupes by `day_index` and that's where the longitudinal
  // *learning* happens. Only the visible derived scores defer.
  //
  // Live wear-stream events (per-tick `processVendorEvent`) run
  // outside any batch (`_batchDepth == 0`) and keep their per-event
  // settle, which is the right behavior for real-time data.
  static int _batchDepth = 0;
  static bool _pendingDerivedSettle = false;

  /// Open an ingest batch. Each call must be paired with
  /// [endIngestBatch]. Nesting is supported via the depth counter.
  /// Prefer [runIngestBatch] in new code — it guarantees pairing
  /// even on exception.
  static void beginIngestBatch() {
    _batchDepth++;
  }

  /// Close an ingest batch. When the depth returns to zero and any
  /// per-night ingest deferred a derived-score recompute, fires a
  /// single [_settleDerivedScores] against the latest attached night.
  static void endIngestBatch() {
    if (_batchDepth == 0) {
      SynheartLogger.stream(
        'Baselines: endIngestBatch called with depth=0; ignoring',
      );
      return;
    }
    _batchDepth--;
    if (_batchDepth == 0 && _pendingDerivedSettle) {
      _pendingDerivedSettle = false;
      _settleLatestDerivedScores();
    }
  }

  /// Run [body] inside an ingest batch. Guarantees [endIngestBatch]
  /// fires even if [body] throws.
  static Future<T> runIngestBatch<T>(Future<T> Function() body) async {
    beginIngestBatch();
    try {
      return await body();
    } finally {
      endIngestBatch();
    }
  }

  /// Test-only view into the batch counter so unit tests can assert
  /// lifecycle invariants without exercising the FFI Recovery cascade.
  @visibleForTesting
  static int get debugBatchDepth => _batchDepth;

  /// Test-only view into the pending-settle flag.
  @visibleForTesting
  static bool get debugPendingDerivedSettle => _pendingDerivedSettle;

  /// Test-only reset for batch state. Use in `tearDown` to keep tests
  /// isolated from one another.
  @visibleForTesting
  static void debugResetBatchState() {
    _batchDepth = 0;
    _pendingDerivedSettle = false;
  }

  /// Internal: find the most-recent attached night by wake_calendar_date
  /// and settle Recovery + Readiness against it. Called once per batch
  /// at end-of-pull. No-op when no priors carry overnight signal.
  static void _settleLatestDerivedScores() {
    if (_recentNights.isEmpty) return;
    var bestIdx = -1;
    var bestWake = -1;
    for (var i = 0; i < _recentNights.length; i++) {
      final wake = _recentNights[i].wakeCalendarDate;
      if (wake > bestWake) {
        bestWake = wake;
        bestIdx = i;
      }
    }
    if (bestIdx < 0) return;
    final raw = _recentNights[bestIdx];
    final overnight = bestIdx < _recentOvernight.length
        ? _recentOvernight[bestIdx]
        : const OvernightPhysiology();
    if (!overnight.hasSignal) return;
    SynheartLogger.stream(
      'Baselines: batch settle latest_wake=$bestWake '
      'priors=${_recentNights.length - 1}',
    );
    _settleDerivedScores(raw, overnight);
  }

  /// Days-since-epoch anchor used by the engine's `wake_calendar_date`
  /// field. Keeps the absolute value in an i32-safe range regardless
  /// of what year the device clock reports.
  static final int _wakeDayAnchor =
      DateTime.utc(2025, 1, 1).millisecondsSinceEpoch ~/ 86400000;

  /// Broadcast stream of baseline snapshots; emits after every
  /// successful [ingestVendorSleep] call.
  static Stream<BaselinesSnapshot> get updates => _ctrl.stream;

  /// The most recent [SleepScoreResult], or null if none has been
  /// ingested in this process.
  static SleepScoreResult? get latestSleepScore => _latestScore;

  /// The most recent [RecoveryScoreResult] computed alongside the
  /// sleep ingest, or null. Computed by [ingestVendorSleep] when
  /// the payload carries overnight HR or HRV in addition to sleep
  /// totals, and attached into the engine via
  /// [Synheart.attachRecoveryScoreToday] so personalization Stage 2
  /// blends today's score into the per-window recovery composite.
  static RecoveryScoreResult? get latestRecoveryScore => _latestRecoveryScore;

  /// The most recent [ReadinessScoreResult]. Combines today's Recovery
  /// with fatigue (sleep debt + recovery slope) and history
  /// (consecutive overload) to surface a Rest/Light/Normal/Push
  /// action band. Null until the first Recovery Score is computed.
  static ReadinessScoreResult? get latestReadinessScore =>
      _latestReadinessScore;

  /// The most recent [WearableReferenceView], or null if the engine
  /// has not yet produced one.
  static WearableReferenceView? get reference => _latestReference;

  /// Provider id of the source that produced [latestSleepScore].
  /// Possible values include `whoop`, `garmin`, `apple_health`,
  /// `health_connect`, `self_report`, or null when no score has been
  /// ingested in this process.
  static String? get lastSource => _lastSource;

  /// Full variant id for the currently-displayed score — `whoop`,
  /// `whoop_score`, `apple_health`, etc. Use this when the UI needs
  /// to distinguish a recompute from a vendor passthrough; use
  /// [lastSource] when only the bare provider matters.
  static String? get lastVariantId => _lastVariantId;

  /// Total number of nights currently being used as priors for the
  /// scorer. Capped at [_maxPriors] (40). This is the "how many days
  /// of data feed your score" surface — distinct from the 7-deep
  /// Path-B ring driving the median, and from the engine's
  /// `prior_night_count` (which only reflects what was attached
  /// *before* the latest score). Counts every successful attach in
  /// this process.
  static int get totalNightsLearned => _recentNights.length;

  /// Per-night `SleepWindow{startMs, endMs}` list derived from the
  /// vendor sleep payloads ingested via [ingestVendorSleep]. Used by
  /// the resilience tile (and any other consumer that needs night
  /// boundaries) so callers don't have to re-query the canonical
  /// event store.
  ///
  /// `VendorScoreNight` (Whoop's score-only path) doesn't carry
  /// timestamps — those nights are skipped silently. The returned
  /// list is a snapshot; mutations don't affect the internal ledger.
  static List<SleepWindow> get recentSleepWindows {
    final out = <SleepWindow>[];
    for (final n in _recentNights) {
      final detail = n.detail;
      switch (detail) {
        case AggregatedNight(:final sessionStartMs, :final sessionEndMs):
          if (sessionStartMs != null && sessionEndMs != null) {
            out.add(SleepWindow(startMs: sessionStartMs, endMs: sessionEndMs));
          }
        case SegmentedNight(:final sessionStartMs, :final sessionEndMs):
          out.add(SleepWindow(startMs: sessionStartMs, endMs: sessionEndMs));
        case VendorScoreNight():
          // Score-only payload — no boundaries to surface.
          break;
      }
    }
    return out;
  }

  /// Per-night HRV RMSSD samples derived from the same payloads.
  /// Each [HrvSample.tsMs] is the midnight (UTC) of the wake calendar
  /// date — coarse but stable, and resilience scoring keys on
  /// distinct days, not exact instants. Nights without an HRV
  /// reading (sleep-only payloads, self-report) are skipped.
  static List<HrvSample> get recentHrvSamples {
    final out = <HrvSample>[];
    final n = _recentOvernight.length < _recentNights.length
        ? _recentOvernight.length
        : _recentNights.length;
    for (var i = 0; i < n; i++) {
      final rmssd = _recentOvernight[i].hrvRmssdMs;
      if (rmssd == null) continue;
      // wake_calendar_date is days since 1970-01-01 (UTC). Convert to
      // a midnight-UTC instant. Resilience filters by distinct day so
      // the absolute instant within the day doesn't matter.
      final tsMs = _recentNights[i].wakeCalendarDate * 86_400_000;
      out.add(HrvSample(tsMs: tsMs, rmssdMs: rmssd));
    }
    return out;
  }

  /// Timestamp of the last successful ingest in this process, set on
  /// every `ingestVendorSleep` that produces a score. Hosts use this
  /// to render an honest "last sync" line — the `BaselinesSourcesPrefs`
  /// timestamps can be wiped by `prefs.clear()` while the engine's
  /// persisted ring survives, leaving "never synced yet" on a screen
  /// that's clearly populated.
  static DateTime? get lastIngestAt => _lastIngestAt;

  /// Point-in-time snapshot of the current baseline state, from the cached
  /// scores and the local mirror of the Path-B ring.
  static BaselinesSnapshot get snapshot => BaselinesSnapshot(
    reference: _latestReference,
    latestSleepScore: _latestScore,
    latestRecoveryScore: _latestRecoveryScore,
    latestReadinessScore: _latestReadinessScore,
    recentSleepScores: _readRecentRing(),
    capturedAtMs: DateTime.now().millisecondsSinceEpoch,
  );

  static List<int> _readRecentRing() {
    if (!_ringHydrated) {
      // First read this process: seed the local mirror from the ring the
      // host persisted with [exportRecoveryStateJson]. The engine keeps its
      // own copy inside the sealed baseline snapshot, which is opaque, so
      // the host copy is the readable one; the runtime restores the engine's
      // at startup, so the two stay in step. Skipped after [reset].
      if (_localRing.isEmpty &&
          _persistedRecentRing != null &&
          _persistedRecentRing!.isNotEmpty) {
        _localRing
          ..clear()
          ..addAll(_persistedRecentRing!);
        _localRingDays
          ..clear()
          ..addAll(List<int>.filled(_localRing.length, -1));
      }
      _ringHydrated = true;
    }
    return List<int>.unmodifiable(_localRing);
  }

  static void _appendToRing(int score, int wakeDay) {
    // Mirror the engine's 7-deep FIFO ring so the displayed list
    // stays bounded.
    _localRing.add(score);
    _localRingDays.add(wakeDay);
    while (_localRing.length > 7) {
      _localRing.removeAt(0);
      if (_localRingDays.isNotEmpty) {
        _localRingDays.removeAt(0);
      }
    }
  }

  /// Replaces the ring entry for [wakeDay] with [newScore]. No-op when
  /// the day isn't tagged in the ring (older than the 7-entry window
  /// or hydrated from a persisted snapshot without wake-day tags).
  static void _replaceRingForDay(int wakeDay, int newScore) {
    for (var i = _localRingDays.length - 1; i >= 0; i--) {
      if (_localRingDays[i] == wakeDay && i < _localRing.length) {
        _localRing[i] = newScore;
        return;
      }
    }
  }

  /// Provider rank — lower wins. WHOOP and Garmin lead because their
  /// stage classifiers are more precise than the platform health
  /// stores; phone/strap-driven device sleep follows; self-report is
  /// last because it's user-entered totals. Anything unknown sits
  /// below self-report so a typo can't outrank a real source.
  static int _providerRank(String provider) {
    switch (provider) {
      case 'whoop':
        return 0;
      case 'garmin':
        return 1;
      case 'apple_health':
      case 'health_connect':
        return 2;
      case 'self_report':
        return 4;
      default:
        // ble_hrm, sdk_wear, sensor — anything driven from the phone
        // pairing without a vendor-side classifier.
        return 3;
    }
  }

  /// Path rank — lower wins. `stage` is the richest input (per-epoch
  /// classification), `aggregated` collapses to stage totals, both
  /// run through *our* engine and produce comparable scores
  /// (`constants_hash`-stamped). `vendorScore` is the vendor's
  /// proprietary number passed through untouched — accepted only
  /// when no provider gave us anything to compute. `proxy` is a
  /// last-resort estimate.
  static int _pathRank(SleepPath path) {
    switch (path) {
      case SleepPath.stage:
        return 0;
      case SleepPath.aggregated:
        return 1;
      case SleepPath.vendorScore:
        return 2;
      case SleepPath.proxy:
        return 3;
    }
  }

  /// Two-axis priority: path rank dominates, provider rank breaks
  /// ties within the same path. Lower is better. So
  /// `(aggregated, apple_health)` = 12 beats `(vendorScore, whoop)` =
  /// 20, because we'd rather run *our* engine over Apple Health's
  /// stages than accept WHOOP's proprietary number passthrough.
  static int _variantRank(SleepPath path, String provider) {
    return _pathRank(path) * 10 + _providerRank(provider);
  }

  static void _recordNightScore(
    int wakeDay,
    String provider,
    SleepScoreResult result,
  ) {
    _scoresByNight.putIfAbsent(wakeDay, () => <String, SleepScoreResult>{});
    _scoresByNight[wakeDay]![provider] = result;
    // Cap at the same horizon as the priors history so memory stays
    // bounded across long-running sessions. Drop oldest wake days.
    while (_scoresByNight.length > _maxPriors) {
      final oldest = _scoresByNight.keys.reduce((a, b) => a < b ? a : b);
      _scoresByNight.remove(oldest);
    }
  }

  /// Per-vendor scores for the most-recent calendar night that has
  /// multi-source coverage (so the swipe-card can actually render
  /// alternates), falling back to the absolute latest night when no
  /// night has more than one provider yet. Keyed by the engine
  /// provider/variant id (`whoop`, `whoop_score`, `garmin`,
  /// `apple_health`, `health_connect`, `self_report`).
  ///
  /// Why "most-recent multi-source" rather than strictly "most
  /// recent": Health Connect / Apple Health typically lag a vendor
  /// like WHOOP by one calendar night (the platform writes the sleep
  /// session at session end + sync delay). With strict "most recent",
  /// tonight = WHOOP-only → swipe collapses to single page even
  /// though yesterday has both. Preferring the latest multi-source
  /// night keeps the swipe alive whenever the user has overlapping
  /// coverage, and the card header still shows the correct date for
  /// that night (the page reads `wake_calendar_date` from the result).
  static Map<String, SleepScoreResult> get tonightAlternates {
    if (_scoresByNight.isEmpty) return const {};
    final sortedNights = _scoresByNight.keys.toList()
      ..sort((a, b) => b.compareTo(a));
    for (final night in sortedNights) {
      final entries = _scoresByNight[night];
      if (entries != null && entries.length > 1) {
        return Map<String, SleepScoreResult>.unmodifiable(entries);
      }
    }
    return Map<String, SleepScoreResult>.unmodifiable(
      _scoresByNight[sortedNights.first] ?? const {},
    );
  }

  /// Ingest a vendor sleep event payload, run the batch scorer, and
  /// attach the result so the next HSI window carries the
  /// `sleep_score` axis and the Path-B 7-night ring is updated.
  ///
  /// `provider` — vendor id (`"whoop"`, `"garmin"`, etc.).
  ///
  /// `payload` — the same map passed to
  /// [Synheart.processVendorEvent]; typically the vendor's merged
  /// metrics + meta. May carry the raw vendor item under
  /// `whoop_data` / `garmin_data`.
  ///
  /// Returns the computed [SleepScoreResult], or `null` if the
  /// payload carried nothing scorable.
  static Future<SleepScoreResult?> ingestVendorSleep({
    required String provider,
    required Map<String, dynamic> payload,
  }) async {
    try {
      final variants = _buildNightVariants(
        provider: provider,
        payload: payload,
      );
      if (variants.isEmpty) {
        SynheartLogger.stream(
          'Baselines: no scorable sleep data in $provider payload',
        );
        return null;
      }

      // Score every variant. The first variant in the list is the
      // priority view (aggregated > vendor_score) and is the one that
      // claims the per-night dedupe slot + attaches into the engine
      // ring. Lower-priority variants only record their result for
      // the swipe-card UI.
      // The personal baselines the score reads, as of the last reference
      // refresh. The refresh builds from the dates before today, and every
      // earlier night was pushed and refreshed when it arrived, so reading
      // here, before tonight's own push, is the order the runtime expects.
      // Shared by every variant: they score the same night.
      final sleepBaselines = Synheart.dailySleepBaselines();

      SleepScoreResult? primary;
      for (var i = 0; i < variants.length; i++) {
        final v = variants[i];
        final input = SleepScoreInput(
          tonight: v.raw,
          // Priors are shared across variants of the same night —
          // they're a function of *prior* nights' rich context, not
          // of which view we're scoring tonight. Reversed so the
          // engine sees newest-first. Only the two newest are read
          // (sleep debt); the baselines carry the rest.
          priorsNewestFirst: _recentNights.reversed.toList(growable: false),
          tonightMidpointH: _sleepMidpointH(v.raw),
          baselines: sleepBaselines,
        );
        // The full JSON dump (priors array + per-night sleep details) is
        // both noisy and contains PII; emit only a summary at stream-level
        // and keep the full payload out of logs entirely. Recover it via
        // the engine input if needed by re-running with a local print.
        SynheartLogger.stream(
          'Baselines: scoreInput[${v.variantId}] '
          'nights=${_recentNights.length} '
          'latestWake=${v.raw.wakeCalendarDate}',
        );
        final result = Synheart.computeSleepScore(input);
        if (result == null) {
          SynheartLogger.stream(
            'Baselines: engine returned null for ${v.variantId}',
          );
          continue;
        }

        final wakeDay = v.raw.wakeCalendarDate;
        // Always record per-variant — the alternates UI iterates
        // these to render swipe pages, even when the attach is
        // skipped.
        _recordNightScore(wakeDay, v.variantId, result);

        // Only the priority variant (i == 0) is allowed to claim the
        // night and feed the engine ring. Secondary variants always
        // skip the attach — their result is for display only.
        if (i == 0) {
          final claimer = _attachedKeys[wakeDay];
          // Three cases:
          //   1. No claimer yet → attach this provider's score and
          //      record the claim. First-write wins for downstream
          //      side effects (ring append, prior bookkeeping,
          //      Recovery Score trigger).
          //   2. Claimer is THIS provider → same-source replay. The
          //      vendor recomputed an earlier night (Whoop does this
          //      after sleep-staging settles ~24h post-wake). Refresh
          //      the engine's attached score so the corrected value
          //      lands, but skip the prior-bookkeeping side effects
          //      (ring append, recovery trigger) which already
          //      happened on the original attach. Silent.
          //   3. Claimer is a DIFFERENT provider → another source
          //      already won this night; this provider's score is
          //      display-only. Log + skip.
          // Track whether this i==0 path actually changed engine
          // state, so the summary log below only fires for meaningful
          // events. `null` = display-only (different-source skip);
          // a string = "attached" or "refreshed" reason for the log.
          String? attachOutcome;
          if (claimer == null) {
            final (rc, queued) = _queueSleepScore(wakeDay, result);
            if (rc != 0) {
              SynheartLogger.stream('Baselines: attachSleepScore rc=$rc');
            } else {
              // Not queued: a night an earlier launch already sent. Rebuild
              // everything local, but leave the engine ring and the mirror
              // alone; both were restored from the snapshot with it.
              attachOutcome = queued ? 'attached' : 'restored';
              _attachedKeys[wakeDay] = provider;
              _attachedPaths[wakeDay] = result.path;
              if (!_ringHydrated) {
                _readRecentRing();
              }
              if (queued && result.score != null) {
                _appendToRing(
                  result.score!,
                  _absDayFromWakeCalendar(v.raw.wakeCalendarDate),
                );
              }
              _recentNights.add(v.raw);
              // Capture overnight physiology, preferring any
              // cross-provider entry already attached for this
              // calendar day (e.g. WHOOP recovery landed before the
              // Apple Health sleep ingest), then falling back to
              // whatever the current sleep payload itself carries.
              final extracted = _extractOvernightPhysiology(provider, payload);
              final dayKey = _absDayFromWakeCalendar(v.raw.wakeCalendarDate);
              final crossProvider = _overnightByDay[dayKey];
              final tonightOvernight = OvernightPhysiology(
                hrvRmssdMs: extracted.hrvRmssdMs ?? crossProvider?.hrvRmssdMs,
                hrvSdnnMs: extracted.hrvSdnnMs ?? crossProvider?.hrvSdnnMs,
                hrStdBpm: extracted.hrStdBpm ?? crossProvider?.hrStdBpm,
                stepsCount: extracted.stepsCount ?? crossProvider?.stepsCount,
                overnightHrBpm:
                    extracted.overnightHrBpm ?? crossProvider?.overnightHrBpm,
                respiratoryRateBrpm: extracted.respiratoryRateBrpm,
                spo2Pct: extracted.spo2Pct,
              );
              _recentOvernight.add(tonightOvernight);
              while (_recentNights.length > _maxPriors) {
                _recentNights.removeAt(0);
                if (_recentOvernight.isNotEmpty) {
                  _recentOvernight.removeAt(0);
                }
              }
              // Push to the runtime SRM. Routes the same daily values
              // (HRV, resting HR, sleep totals) into the longitudinal
              // SRM and — via the engine bridge — into the live SRM.
              // Without this, only the initial OAuth backfill warmed
              // the runtime SRM; subsequent daily refreshes only
              // updated the Dart-side `Baselines` rings, leaving the
              // visible baselines stuck on whatever the first sync
              // captured.
              _pushDailyToRuntimeSrm(
                provider: provider,
                wakeDayIndex: dayKey,
                overnight: tonightOvernight,
                raw: v.raw,
              );
              // Recovery Score: only emits
              // when overnight HR or HRV is present. Skip silently
              // when the payload is sleep-only (e.g. self-report).
              SynheartLogger.stream(
                'Baselines: sleep attach day=$dayKey '
                'provider=$provider '
                'hrv=${tonightOvernight.hrvRmssdMs ?? '-'} '
                'rhr=${tonightOvernight.overnightHrBpm ?? '-'} '
                '(extracted hrv=${extracted.hrvRmssdMs ?? '-'}, '
                'cross=${crossProvider == null ? 'no' : 'yes'})',
              );
              if (tonightOvernight.hasSignal) {
                if (_batchDepth > 0) {
                  _pendingDerivedSettle = true;
                } else {
                  _settleDerivedScores(v.raw, tonightOvernight);
                }
              }
            }
          } else if (claimer == provider) {
            // Same-source refresh — overwrite the attached score
            // without touching prior bookkeeping. Logged so a
            // corrected score landing is visible in telemetry.
            final (rc, queued) = _queueSleepScore(wakeDay, result);
            if (rc != 0) {
              SynheartLogger.stream(
                'Baselines: same-source refresh attachSleepScore rc=$rc',
              );
            } else {
              // An unchanged replay is silent: nothing new reached the engine.
              if (queued) attachOutcome = 'refreshed';
              // Same provider may have changed paths (e.g. WHOOP
              // upgrades from vendor-only at session-end to
              // aggregated 24h later when sleep-staging settles).
              // Keep `_attachedPaths` in lockstep so future
              // priority-evict comparisons reflect current state.
              _attachedPaths[wakeDay] = result.path;
              // The refined attach may carry corrected stage totals
              // (Whoop refines deep/REM ~24h post-wake) and tweaked
              // overnight HRV/RHR. Push the latest values so the
              // runtime SRM doesn't keep stale baselines from the
              // initial attach.
              final extracted = _extractOvernightPhysiology(provider, payload);
              final dayKey = _absDayFromWakeCalendar(v.raw.wakeCalendarDate);
              _pushDailyToRuntimeSrm(
                provider: provider,
                wakeDayIndex: dayKey,
                overnight: OvernightPhysiology(
                  hrvRmssdMs: extracted.hrvRmssdMs,
                  hrvSdnnMs: extracted.hrvSdnnMs,
                  hrStdBpm: extracted.hrStdBpm,
                  stepsCount: extracted.stepsCount,
                  overnightHrBpm: extracted.overnightHrBpm,
                  respiratoryRateBrpm: extracted.respiratoryRateBrpm,
                  spo2Pct: extracted.spo2Pct,
                ),
                raw: v.raw,
              );
            }
          } else {
            // Different-source. First-write doesn't always win — if
            // this variant outranks the existing claimer's variant,
            // evict and re-attach. Comparison is path-first (a
            // computed score from any provider beats a vendor
            // passthrough from any provider, because passthroughs
            // bypass our engine), then provider-rank within the same
            // path (WHOOP-aggregated beats Apple-Health-aggregated).
            // Lower-priority arrivals stay display-only, recorded
            // into the alternates map via `_recordNightScore` above.
            final claimerPath = _attachedPaths[wakeDay] ?? SleepPath.proxy;
            final newRank = _variantRank(result.path, provider);
            final claimerRank = _variantRank(claimerPath, claimer);
            if (newRank < claimerRank) {
              final (rc, _) = _queueSleepScore(wakeDay, result);
              if (rc != 0) {
                SynheartLogger.stream(
                  'Baselines: priority-evict attachSleepScore rc=$rc',
                );
              } else {
                attachOutcome = 'evicted-$claimer';
                _attachedKeys[wakeDay] = provider;
                _attachedPaths[wakeDay] = result.path;

                // Prune the demoted claimer's entry from the per-night
                // map so `tonightAlternates` no longer surfaces it —
                // the user shouldn't see "DEVICE / 95 / computed"
                // floating around after WHOOP took the slot. Keep
                // anything that *outranks* the new winner (rare —
                // would only happen if a third, even-stronger variant
                // already exists, which can't be the prior claimer or
                // we wouldn't have evicted; cheap to express anyway).
                // The new winner's own variants (e.g. `whoop` and
                // `whoop_score` for the same provider) collapse to
                // the same provider via `_score` suffix stripping and
                // stay regardless of rank — alternates UI compares
                // them side-by-side.
                final entries = _scoresByNight[wakeDay];
                if (entries != null) {
                  entries.removeWhere((variantId, scoreResult) {
                    final base = variantId.endsWith('_score')
                        ? variantId.substring(
                            0,
                            variantId.length - '_score'.length,
                          )
                        : variantId;
                    if (base == provider) return false;
                    return _variantRank(scoreResult.path, base) >= newRank;
                  });
                }

                // Replace the ring slot for this wake day so the
                // longitudinal view reflects the higher-priority
                // score, not the demoted one. The ring's length
                // doesn't change — eviction is a swap, not an append.
                if (result.score != null) {
                  _replaceRingForDay(
                    _absDayFromWakeCalendar(v.raw.wakeCalendarDate),
                    result.score!,
                  );
                }

                // Replace the priors entry for this night so future
                // scores on later nights see the higher-priority view
                // in `priorsNewestFirst`, not the demoted one. Walk
                // from the end since the most recent attaches are at
                // the back.
                final wakeDate = v.raw.wakeCalendarDate;
                for (var i = _recentNights.length - 1; i >= 0; i--) {
                  if (_recentNights[i].wakeCalendarDate == wakeDate) {
                    _recentNights[i] = v.raw;
                    break;
                  }
                }

                // Refresh overnight physiology from the new payload,
                // merging any cross-provider entry already attached
                // for this day so we don't lose HRV from a different
                // source if the new payload is sleep-only.
                final extracted = _extractOvernightPhysiology(
                  provider,
                  payload,
                );
                final dayKey = _absDayFromWakeCalendar(v.raw.wakeCalendarDate);
                final crossProvider = _overnightByDay[dayKey];
                final tonightOvernight = OvernightPhysiology(
                  hrvRmssdMs: extracted.hrvRmssdMs ?? crossProvider?.hrvRmssdMs,
                  hrvSdnnMs: extracted.hrvSdnnMs ?? crossProvider?.hrvSdnnMs,
                  hrStdBpm: extracted.hrStdBpm ?? crossProvider?.hrStdBpm,
                  stepsCount: extracted.stepsCount ?? crossProvider?.stepsCount,
                  overnightHrBpm:
                      extracted.overnightHrBpm ?? crossProvider?.overnightHrBpm,
                  respiratoryRateBrpm: extracted.respiratoryRateBrpm,
                  spo2Pct: extracted.spo2Pct,
                );
                for (var i = _recentNights.length - 1; i >= 0; i--) {
                  if (_recentNights[i].wakeCalendarDate == wakeDate) {
                    if (i < _recentOvernight.length) {
                      _recentOvernight[i] = tonightOvernight;
                    }
                    break;
                  }
                }

                SynheartLogger.stream(
                  'Baselines: priority-evict day=$dayKey '
                  '$claimer→$provider score=${result.score} '
                  'hrv=${tonightOvernight.hrvRmssdMs ?? '-'} '
                  'rhr=${tonightOvernight.overnightHrBpm ?? '-'}',
                );

                // The new higher-priority provider may have better
                // stage totals + overnight values than the demoted
                // claimer pushed earlier. Re-push so the runtime
                // SRM's daily slot for this day reflects the
                // winning view (longitudinal SRM dedupes by
                // day_index, so this overwrites cleanly).
                _pushDailyToRuntimeSrm(
                  provider: provider,
                  wakeDayIndex: dayKey,
                  overnight: tonightOvernight,
                  raw: v.raw,
                );

                // Re-trigger Recovery — sleep score and overnight
                // physiology may both have changed under the new
                // higher-priority view.
                if (tonightOvernight.hasSignal) {
                  if (_batchDepth > 0) {
                    _pendingDerivedSettle = true;
                  } else {
                    _settleDerivedScores(v.raw, tonightOvernight);
                  }
                }
              }
            }
            // else: lower-priority arrival — the result is already in
            // `_scoresByNight` (alternates UI) and stays display-only.
          }

          // `primary` is the return value of this ingest call —
          // always set so the immediate caller sees what was
          // computed, regardless of whether it actually attached.
          primary = result;

          // The remaining fields are user-visible state that should
          // only update when the engine actually accepted this
          // score. On a different-source skip (e.g. Apple Health
          // behind Whoop) the previous attach's values must stick;
          // letting `_latestScore = result` overwrite would replace
          // Whoop's 79 with Apple Health's display-only 89 in the
          // "Tonight" UI even though Whoop is the source the engine
          // ring is actually using.
          if (attachOutcome != null) {
            _latestScore = result;
            _latestReference = Synheart.wearableReference;
            _lastSource = provider;
            _lastVariantId = v.variantId;
            _lastIngestAt = DateTime.now();

            // Per-night summary — gated behind kDebugMode because a
            // 30-day vendor pull would otherwise emit 30 of these
            // (~90 with secondary variants). The host's pull
            // orchestrator already prints a single end-of-pull line
            // (`SleepSyncService <provider>: nights=N enriched=...`).
            // Priority-evict and attach-rc errors keep their own
            // dedicated unconditional logs above.
            if (kDebugMode) {
              SynheartLogger.stream(
                'Baselines: ${v.variantId} $attachOutcome score=${result.score} '
                'path=${result.path.wire} mode=${result.mode.wire} '
                'priors=${_recentNights.length - 1} '
                'constants=${result.constantsHash}',
              );
            }
          }
        }
      }

      if (!_ctrl.isClosed) _ctrl.add(snapshot);
      return primary;
    } catch (e, st) {
      SynheartLogger.stream(
        'Baselines ingest failed: $e',
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  /// Ingest a self-reported sleep questionnaire, derive aggregated
  /// totals, and route through [ingestVendorSleep] under the
  /// `self_report` provider. Returns the computed result.
  ///
  /// Subjective quality / felt-rested fields are passed through the
  /// payload for UI display but the scorer ignores them — we don't
  /// fabricate stage durations from subjective signals.
  static Future<SleepScoreResult?> ingestSelfReportedSleep(
    SleepQuestionnaireAnswers answers,
  ) {
    return ingestVendorSleep(
      provider: 'self_report',
      payload: answers.toIngestPayload(),
    );
  }

  /// Drop every in-memory baseline cache: latest score, last source,
  /// reference, dedupe map, local ring mirror. The persisted Path-B
  /// ring lives in the core-runtime's longitudinal snapshot; that
  /// gets wiped by `Synheart.wipeLocalData` (which also calls this
  /// method to keep the SDK and engine state in lockstep).
  ///
  /// The next read of `_readRecentRing` will re-hydrate from the
  /// engine snapshot. After a wipe, the engine drops its in-memory
  /// Pipeline on `stop_session`, and the lazy-recreate path produces
  /// an empty snapshot, so re-hydration after reset() is safe.
  ///
  /// Emits a final empty snapshot so any listening UI can redraw to
  /// the cold-start state without a separate refresh.
  static void reset() {
    _latestScore = null;
    _latestReference = null;
    _latestRecoveryScore = null;
    _latestReadinessScore = null;
    _lastSource = null;
    _lastVariantId = null;
    _attachedKeys.clear();
    _attachedPaths.clear();
    _ledger.clear();
    _localRing.clear();
    _localRingDays.clear();
    _recentNights.clear();
    _recentOvernight.clear();
    _recentRecoveryScores.clear();
    _strainByDay.clear();
    _overnightByDay.clear();
    _scoresByNight.clear();
    _lastIngestAt = null;
    // Force rehydration on the next snapshot read; the engine will
    // return an empty ring per the runtime regression test linked above.
    _ringHydrated = false;
    _suppressAutoPull = true;
    Synheart.clearRecoveryScoreToday();
    if (!_ctrl.isClosed) _ctrl.add(snapshot);
  }

  /// Force-refresh the cached [reference] by re-reading it from the
  /// runtime and emit a new snapshot. Useful after the host persists
  /// a longitudinal snapshot and reloads it.
  static BaselinesSnapshot refreshReference() {
    _latestReference = Synheart.wearableReference;
    final s = snapshot;
    if (!_ctrl.isClosed) _ctrl.add(s);
    return s;
  }

  // ── Vendor → NightRaw normalization ─────────────────────────────

  /// Returns every scorable variant for a payload, in priority order.
  ///
  /// WHOOP / Garmin can produce **two** views of the same night:
  ///   - `aggregated` (stage totals → engine recomputes a composite)
  ///   - `vendor_score` (vendor's own number → passthrough)
  ///
  /// Both are emitted when the data supports both, so the swipe-card
  /// UI can show the user "WHOOP says 64, our recompute from your
  /// stages says 71" side by side. The first variant in the list
  /// claims the per-night dedupe slot; subsequent variants are
  /// recorded into [_scoresByNight] for display but skip the engine
  /// attach.
  ///
  /// Apple Health / Health Connect / self-report only produce one
  /// variant (totals), so the list has length 1 there.
  static List<({String variantId, NightRaw raw})> _buildNightVariants({
    required String provider,
    required Map<String, dynamic> payload,
  }) {
    final timestampMs = _extractTimestampMs(payload);
    final wakeDay = _calendarDayFromMs(timestampMs);
    final hr = _numDouble(payload['avg_hr_bpm']) ?? _numDouble(payload['hr']);

    final raw = switch (provider) {
      'whoop' => payload['whoop_data'] as Map<String, dynamic>?,
      'garmin' => payload['garmin_data'] as Map<String, dynamic>?,
      'self_report' => payload['self_report_data'] as Map<String, dynamic>?,
      'apple_health' => payload['apple_health_data'] as Map<String, dynamic>?,
      'health_connect' =>
        payload['health_connect_data'] as Map<String, dynamic>?,
      _ => null,
    };

    final variants = <({String variantId, NightRaw raw})>[];

    final aggregated = _buildAggregated(provider, raw);
    if (aggregated != null) {
      variants.add((
        variantId: provider,
        raw: NightRaw(
          wakeCalendarDate: wakeDay,
          detail: aggregated,
          avgHrBpm: hr,
        ),
      ));
    }

    final vendorScore = _extractVendorScore(provider, raw, payload);
    if (vendorScore != null) {
      // When aggregated already covered this provider, the vendor
      // passthrough becomes a *secondary* variant — useful for the
      // user to compare WHOOP's own number against our recompute.
      // When aggregated wasn't possible (e.g. WHOOP returned a score
      // but no stage_summary), the vendor passthrough is the *only*
      // variant and uses the bare provider id.
      final variantId = aggregated == null ? provider : '${provider}_score';
      variants.add((
        variantId: variantId,
        raw: NightRaw(
          wakeCalendarDate: wakeDay,
          detail: VendorScoreNight(score: vendorScore),
          avgHrBpm: hr,
        ),
      ));
    }

    return variants;
  }

  static AggregatedNight? _buildAggregated(
    String provider,
    Map<String, dynamic>? raw,
  ) {
    if (raw == null) return null;

    switch (provider) {
      case 'whoop':
        final score = raw['score'];
        if (score is! Map) return null;
        final stage = score['stage_summary'];
        if (stage is! Map) return null;
        final deepMs = _num(stage['total_slow_wave_sleep_time_milli']) ?? 0;
        final remMs = _num(stage['total_rem_sleep_time_milli']) ?? 0;
        final lightMs = _num(stage['total_light_sleep_time_milli']) ?? 0;
        final awakeMs = _num(stage['total_awake_time_milli']) ?? 0;
        final awakenings = _num(stage['disturbance_count'])?.toInt() ?? 0;
        // WHOOP API v2 dropped the top-level total_sleep_time_milli;
        // reconstruct from the stage breakdown (light + rem + deep).
        // Fall back to in_bed − awake when stages are absent. Without
        // this every WHOOP night collapses to vendor_score and gets
        // evicted by any computed source on the same calendar day.
        final inBedMs = _num(stage['total_in_bed_time_milli']) ?? 0;
        final totalMs =
            _num(stage['total_sleep_time_milli']) ??
            (deepMs + remMs + lightMs > 0
                ? deepMs + remMs + lightMs
                : (inBedMs - awakeMs).clamp(0, double.infinity).toDouble());
        if (totalMs <= 0) return null;
        final tibMs = inBedMs > 0 ? inBedMs : totalMs + awakeMs;
        final sessionStart =
            _num(raw['start'])?.toInt() ?? _parseIsoMs(raw['start']);
        final sessionEnd = _num(raw['end'])?.toInt() ?? _parseIsoMs(raw['end']);
        return AggregatedNight(
          sessionStartMs: sessionStart,
          sessionEndMs: sessionEnd,
          totals: AggregatedTotals(
            totalSleepMinutes: totalMs / 60000.0,
            deepSleepMinutes: deepMs / 60000.0,
            remSleepMinutes: remMs / 60000.0,
            awakeMinutes: awakeMs / 60000.0,
            awakenings: awakenings,
            timeInBedMinutes: tibMs / 60000.0,
          ),
        );

      case 'self_report':
      case 'apple_health':
      case 'health_connect':
        // All three carry the same flat-totals shape. Stage durations
        // are passed as null when missing — that signals "stages
        // unknown" to the engine, which falls back to scoring on
        // duration + continuity instead of treating absent fields as
        // zero deep/REM (which would tank the score).
        final totalSleep = _num(raw['total_sleep_minutes']);
        if (totalSleep == null || totalSleep <= 0) return null;
        return AggregatedNight(
          sessionStartMs: _num(raw['session_start_ms'])?.toInt(),
          sessionEndMs: _num(raw['session_end_ms'])?.toInt(),
          totals: AggregatedTotals(
            totalSleepMinutes: totalSleep.toDouble(),
            deepSleepMinutes: _num(raw['deep_sleep_minutes'])?.toDouble(),
            remSleepMinutes: _num(raw['rem_sleep_minutes'])?.toDouble(),
            awakeMinutes: (_num(raw['awake_minutes']) ?? 0).toDouble(),
            awakenings: _num(raw['awakenings'])?.toInt() ?? 0,
            timeInBedMinutes: (_num(raw['time_in_bed_minutes']) ?? totalSleep)
                .toDouble(),
            sleepLatencyMinutes: _num(raw['sleep_latency_minutes'])?.toDouble(),
          ),
        );

      case 'garmin':
        final totalS = _num(raw['durationInSeconds']);
        if (totalS == null || totalS <= 0) return null;
        final deepS = _num(raw['deepSleepDurationInSeconds']) ?? 0;
        final remS = _num(raw['remSleepInSeconds']) ?? 0;
        final awakeS = _num(raw['awakeDurationInSeconds']) ?? 0;
        final totalSleepS = (totalS - awakeS).clamp(0.0, totalS.toDouble());
        final sessionStart = _num(raw['startTimeInSeconds'])?.toInt();
        final sessionEnd = sessionStart != null
            ? sessionStart + totalS.toInt()
            : null;
        return AggregatedNight(
          sessionStartMs: sessionStart != null ? sessionStart * 1000 : null,
          sessionEndMs: sessionEnd != null ? sessionEnd * 1000 : null,
          totals: AggregatedTotals(
            totalSleepMinutes: totalSleepS / 60.0,
            deepSleepMinutes: deepS / 60.0,
            remSleepMinutes: remS / 60.0,
            awakeMinutes: awakeS / 60.0,
            awakenings: 0,
            timeInBedMinutes: totalS / 60.0,
          ),
        );
    }
    return null;
  }

  static int? _extractVendorScore(
    String provider,
    Map<String, dynamic>? raw,
    Map<String, dynamic> payload,
  ) {
    final direct = _num(payload['sleep_score']);
    if (direct != null) return direct.round().clamp(0, 100);

    switch (provider) {
      case 'whoop':
        final score = raw?['score'];
        if (score is Map) {
          final perf = _num(score['sleep_performance_percentage']);
          if (perf != null) return perf.round().clamp(0, 100);
        }
      case 'garmin':
        final q = _num(
          raw?['overallSleepScore'] ??
              (raw?['sleepScores'] as Map?)?['overall']?['value'],
        );
        if (q != null) return q.round().clamp(0, 100);
    }
    return null;
  }

  static int _calendarDayFromMs(int ms) {
    final day = ms ~/ 86400000;
    return day - _wakeDayAnchor + 20100;
  }

  static int _extractTimestampMs(Map<String, dynamic> payload) {
    final ts = payload['timestamp'];
    if (ts is String) {
      final parsed = DateTime.tryParse(ts);
      if (parsed != null) return parsed.millisecondsSinceEpoch;
    }
    if (ts is int) return ts;
    final ms = _num(payload['observed_at_ms']);
    if (ms != null) return ms.toInt();
    return DateTime.now().millisecondsSinceEpoch;
  }

  static int? _parseIsoMs(Object? v) {
    if (v is! String) return null;
    return DateTime.tryParse(v)?.millisecondsSinceEpoch;
  }

  static num? _num(Object? v) {
    if (v == null) return null;
    if (v is num) return v;
    if (v is String) return num.tryParse(v);
    return null;
  }

  static double? _numDouble(Object? v) => _num(v)?.toDouble();

  // ─── Recovery Score ───────────────────────────────────────────────

  /// Extract overnight HR + HRV from a vendor payload. Different
  /// providers nest these fields differently — this helper centralizes
  /// the lookup so [ingestVendorSleep] stays declarative.
  ///
  /// All four fields are nullable; a payload with no physiology returns
  /// an empty [OvernightPhysiology] (and the engine then refuses to
  /// emit a Recovery Score per the "no sleep-only recovery" invariant).
  static OvernightPhysiology _extractOvernightPhysiology(
    String provider,
    Map<String, dynamic> payload,
  ) {
    // Top-level keys land here when a host or processor flattened them
    // (e.g. `wearable_event_processor` does this for WHOOP recovery
    // events). Fall through to provider-nested locations otherwise.
    double? hrv = _numDouble(payload['hrv_rmssd_ms']);
    double? sdnn = _numDouble(payload['hrv_sdnn_ms']);
    double? hrStd = _numDouble(payload['hr_std_bpm']);
    double? steps = _numDouble(payload['steps_count']);
    double? hr =
        _numDouble(payload['avg_hr_bpm']) ??
        _numDouble(payload['resting_hr_bpm']) ??
        _numDouble(payload['hr']);
    double? rr = _numDouble(payload['respiratory_rate_brpm']);
    double? spo2 = _numDouble(payload['spo2_pct']);

    final raw = switch (provider) {
      'whoop' => payload['whoop_data'] as Map<String, dynamic>?,
      'garmin' => payload['garmin_data'] as Map<String, dynamic>?,
      'apple_health' => payload['apple_health_data'] as Map<String, dynamic>?,
      'health_connect' =>
        payload['health_connect_data'] as Map<String, dynamic>?,
      _ => null,
    };
    if (raw != null) {
      // WHOOP: recovery numbers live under `score` in the recovery
      // event, but vendor backfills sometimes pre-flatten the map.
      final score = raw['score'] is Map ? raw['score'] as Map : raw;
      hrv ??=
          _numDouble(score['hrv_rmssd_milli']) ??
          _numDouble(score['hrv_rmssd_ms']);
      sdnn ??= _numDouble(score['hrv_sdnn_ms']);
      hr ??=
          _numDouble(score['resting_heart_rate']) ??
          _numDouble(score['avg_hr_bpm']);
      rr ??=
          _numDouble(score['respiratory_rate_brpm']) ??
          _numDouble(score['respiratory_rate']);
      spo2 ??=
          _numDouble(score['spo2_percentage']) ?? _numDouble(score['spo2_pct']);
    }

    return OvernightPhysiology(
      hrvRmssdMs: hrv,
      hrvSdnnMs: sdnn,
      hrStdBpm: hrStd,
      stepsCount: steps,
      overnightHrBpm: hr,
      respiratoryRateBrpm: rr,
      spo2Pct: spo2,
    );
  }

  /// Convert a [NightRaw] (the sleep-score input) back into a
  /// Recovery-Score [NightSummary] by reading the aggregated totals.
  /// Returns `null` for vendor-score-only nights (no aggregated data).
  static NightSummary? _nightSummaryFromRaw(NightRaw nr) {
    final detail = nr.detail;
    if (detail is! AggregatedNight) {
      // Vendor-score-only nights have no totals to reason about; the
      // engine treats sleep_quality / continuity as neutral (50) when
      // stages are absent, so produce a minimal summary so trends
      // still align by date.
      return NightSummary(
        wakeCalendarDate: nr.wakeCalendarDate,
        totalSleepMinutes: 0.0,
      );
    }
    final t = detail.totals;
    final efficiency = (t.timeInBedMinutes != null && t.timeInBedMinutes! > 0)
        ? t.totalSleepMinutes / t.timeInBedMinutes!
        : null;
    final midpointHours =
        (detail.sessionStartMs != null && detail.sessionEndMs != null)
        ? _midpointHoursLocal(detail.sessionStartMs!, detail.sessionEndMs!)
        : null;
    return NightSummary(
      wakeCalendarDate: nr.wakeCalendarDate,
      totalSleepMinutes: t.totalSleepMinutes,
      deepSleepMinutes: t.deepSleepMinutes,
      remSleepMinutes: t.remSleepMinutes,
      wasoMinutes: t.awakeMinutes,
      awakeningCount: t.awakenings,
      sleepEfficiency: efficiency,
      bedtimeMidpointHours: midpointHours,
    );
  }

  /// The night's local sleep midpoint in hours, from its session start and
  /// end, or null when the source gives no timing. Never derived from totals:
  /// a null leaves the Sleep Score's consistency out, with no penalty.
  static double? _sleepMidpointH(NightRaw raw) {
    final detail = raw.detail;
    if (detail is SegmentedNight) {
      return _midpointHoursLocal(detail.sessionStartMs, detail.sessionEndMs);
    }
    if (detail is AggregatedNight &&
        detail.sessionStartMs != null &&
        detail.sessionEndMs != null) {
      return _midpointHoursLocal(detail.sessionStartMs!, detail.sessionEndMs!);
    }
    return null;
  }

  /// Local-time midpoint of the sleep session, in hours (0..24). Used
  /// for the Recovery Score's circular consistency check.
  static double _midpointHoursLocal(int startMs, int endMs) {
    final mid = DateTime.fromMillisecondsSinceEpoch(
      (startMs + endMs) ~/ 2,
      isUtc: false,
    );
    return mid.hour + mid.minute / 60.0 + mid.second / 3600.0;
  }

  /// Attach [result] for [wakeDay] so it rides the next emitted HSI, unless
  /// the ledger says that would resend or regress it. Returns the attach
  /// status (`0` also when skipped) and whether it was queued.
  static (int, bool) _queueSleepScore(int wakeDay, SleepScoreResult result) {
    if (!_ledger.shouldQueue(DailyScoreKind.sleep, wakeDay, result.score)) {
      return (0, false);
    }
    final rc = Synheart.attachSleepScore(result);
    if (rc == 0) {
      _ledger.noteQueued(DailyScoreKind.sleep, wakeDay, result.score);
    }
    return (rc, true);
  }

  /// Compute the Recovery Score for the night ending on [day], and queue it
  /// for upload when the ledger allows. Computing first is what lets the
  /// ledger compare scores; the attach computes again from the same input,
  /// because the runtime cannot take a result back.
  static RecoveryScoreResult? _scoreRecovery(
    int day,
    RecoveryScoreInput input,
  ) {
    final result = Synheart.computeRecoveryScore(input);
    if (result == null) return null;
    if (!Synheart.attachRecoveryScoreAvailable) {
      _logUpload('recovery', day, 'unsupported by this runtime');
    } else if (!_ledger.shouldQueue(
      DailyScoreKind.recovery,
      day,
      result.score,
    )) {
      _logUpload('recovery', day, 'already queued or sent');
    } else if (Synheart.attachRecoveryScore(input) != null) {
      _ledger.noteQueued(DailyScoreKind.recovery, day, result.score);
      _logUpload('recovery', day, 'queued');
    } else {
      _logUpload('recovery', day, 'attach failed');
    }
    return result;
  }

  /// Readiness counterpart of [_scoreRecovery].
  static ReadinessScoreResult? _scoreReadiness(
    int day,
    ReadinessScoreInput input,
  ) {
    final result = Synheart.computeReadinessScore(input);
    if (result == null) return null;
    if (!Synheart.attachReadinessScoreAvailable) {
      _logUpload('readiness', day, 'unsupported by this runtime');
    } else if (!_ledger.shouldQueue(
      DailyScoreKind.readiness,
      day,
      result.score,
    )) {
      _logUpload('readiness', day, 'already queued or sent');
    } else if (Synheart.attachReadinessScore(input) != null) {
      _ledger.noteQueued(DailyScoreKind.readiness, day, result.score);
      _logUpload('readiness', day, 'queued');
    } else {
      _logUpload('readiness', day, 'attach failed');
    }
    return result;
  }

  static void _logUpload(String kind, int day, String outcome) =>
      SynheartLogger.stream('Baselines: $kind upload day=$day: $outcome');

  /// Called with every emitted HSI frame, so the ledger knows which queued
  /// scores a frame has carried. A delivery is announced on [updates] like
  /// any other change, so a host persisting [exportRecoveryStateJson] from
  /// there records it; unrecorded, the next launch would send it again.
  static void noteHsiFrame(String hsiJson) {
    if (_ledger.noteFrame(hsiJson) && !_ctrl.isClosed) _ctrl.add(snapshot);
  }

  /// Recompute and attach the *derived* daily scores — Recovery and
  /// Readiness — for [tonightRaw]. Called from [ingestVendorSleep]
  /// (per-night when not batched) and from [endIngestBatch] (once at
  /// pull-completion, against the latest attached night).
  ///
  /// Side effects, in order:
  ///   1. Compute Recovery against tonight's overnight + priors
  ///   2. Cache it in `_latestRecoveryScore` and FFI-attach via
  ///      `Synheart.attachRecoveryScoreToday` (feeds personalization
  ///      Stage 2)
  ///   3. Append to the 7-entry recovery ring (used for slope)
  ///   4. Cascade into [_computeReadiness] so Readiness stays in sync
  ///      with the same physiology read
  ///
  /// Sleep-only nights (no overnight HR/HRV in the payload) are
  /// short-circuited at the call site — the engine refuses to emit a
  /// score in that case anyway (no sleep-only recovery).
  static void _settleDerivedScores(
    NightRaw tonightRaw,
    OvernightPhysiology tonightOvernight,
  ) {
    try {
      final tonight = _nightSummaryFromRaw(tonightRaw);
      if (tonight == null) return;
      // Drop the just-appended (current) entry from the priors —
      // _recentNights has already been mutated by the caller, so
      // the last index is "tonight" and everything before it is the
      // history.
      final priorNights = <NightSummary>[];
      final priorOvernight = <OvernightPhysiology>[];
      for (var i = 0; i < _recentNights.length - 1; i++) {
        final ns = _nightSummaryFromRaw(_recentNights[i]);
        if (ns == null) continue;
        priorNights.add(ns);
        priorOvernight.add(
          i < _recentOvernight.length
              ? _recentOvernight[i]
              : const OvernightPhysiology(),
        );
      }

      final input = RecoveryScoreInput(
        tonight: tonight,
        priors: priorNights,
        overnight: tonightOvernight,
        priorsOvernight: priorOvernight,
        // The runtime's own daily references, read after the night's push
        // and refresh. Null until overnight RMSSD and resting HR both have
        // one, and the engine then scores stage 1 or 2.
        baselines: Synheart.dailyBaselineRefs(),
      );

      final day = tonightRaw.wakeCalendarDate;
      final result = _scoreRecovery(day, input);
      if (result == null) {
        // Engine refused (sleep-only) or runtime not ready. Leave the
        // previously-attached score (if any) alone — it represents the
        // last *successful* compute, not "today's missing one".
        SynheartLogger.stream(
          'Baselines: recovery score skipped (no engine result)',
        );
        return;
      }
      _latestRecoveryScore = result;
      final rc = Synheart.attachRecoveryScoreToday(result.score);
      SynheartLogger.stream(
        'Baselines: recovery=${result.score} stage=${result.stage.wire} '
        'attach_rc=$rc',
      );

      // Feed the Readiness Score immediately after Recovery so the
      // user-facing "what should I do today?" surface stays in sync
      // with the latest physiology read.
      _appendRecoveryScore(result.score);
      _computeReadiness(result, day: day, overnight: tonightOvernight);
    } catch (e, st) {
      SynheartLogger.stream(
        'Baselines: recovery compute failed: $e',
        error: e,
        stackTrace: st,
      );
    }
  }

  // ─── Readiness Score ──────────────────────────────────────────────

  /// Bounded ring of the last 7 Recovery Scores, persisted with the rest of
  /// the Recovery state.
  static void _appendRecoveryScore(int score) {
    _recentRecoveryScores.add(score);
    while (_recentRecoveryScores.length > 7) {
      _recentRecoveryScores.removeAt(0);
    }
  }

  /// Attach overnight physiology (HRV / RHR) for a given calendar
  /// day. Independent of which provider drove the sleep ingest for
  /// that day — solves the common case where Apple Health attached
  /// the sleep totals but WHOOP / Garmin holds the HRV.
  ///
  /// Re-runs Recovery + Readiness on the most-recent attached sleep
  /// night whenever new physiology lands for it, so cards populate
  /// the moment fresh data flows in (no need to re-pull sleep).
  ///
  /// Either field may be `null` — the engine treats absence as "no
  /// signal" rather than synthesizing a neutral value.
  static void attachOvernightPhysiology({
    required DateTime occurredAt,
    double? hrvRmssdMs,
    double? restingHrBpm,
  }) {
    final day = _epochDay(occurredAt);
    final next = OvernightPhysiology(
      hrvRmssdMs: hrvRmssdMs,
      overnightHrBpm: restingHrBpm,
    );
    if (!next.hasSignal) return;
    // Merge into any existing entry rather than overwrite — recovery
    // events from different vendors should additively populate the
    // record (Whoop recovery for HRV, Apple Health for RHR, etc.).
    final prev = _overnightByDay[day];
    _overnightByDay[day] = OvernightPhysiology(
      hrvRmssdMs: hrvRmssdMs ?? prev?.hrvRmssdMs,
      overnightHrBpm: restingHrBpm ?? prev?.overnightHrBpm,
    );

    // Trim to the prior-window horizon so the map doesn't unbounded-grow.
    if (_overnightByDay.length > _maxPriors + 7) {
      final cutoff = day - (_maxPriors + 7);
      _overnightByDay.removeWhere((d, _) => d < cutoff);
    }

    // Re-align any prior-night entries whose day matches this
    // physiology, then if the most-recent attached sleep night gained
    // new physiology trigger a fresh Recovery + Readiness compute so
    // the cards populate immediately.
    SynheartLogger.stream(
      'Baselines: attachOvernightPhysiology day=$day '
      'hrv=${hrvRmssdMs ?? '-'} rhr=${restingHrBpm ?? '-'} '
      '(nights=${_recentNights.length})',
    );
    var tonightUpdated = false;
    for (var i = 0; i < _recentNights.length; i++) {
      final nightDay = _absDayFromWakeCalendar(
        _recentNights[i].wakeCalendarDate,
      );
      if (nightDay != day) continue;
      if (i < _recentOvernight.length) {
        _recentOvernight[i] = _overnightByDay[day]!;
      } else {
        // Defensive: fill any gap so indices stay aligned.
        while (_recentOvernight.length <= i) {
          _recentOvernight.add(const OvernightPhysiology());
        }
        _recentOvernight[i] = _overnightByDay[day]!;
      }
      if (i == _recentNights.length - 1) tonightUpdated = true;
    }
    if (tonightUpdated) {
      if (_batchDepth > 0) {
        _pendingDerivedSettle = true;
      } else {
        _settleDerivedScores(_recentNights.last, _overnightByDay[day]!);
      }
      if (!_ctrl.isClosed) _ctrl.add(snapshot);
    }
  }

  /// Record a vendor workout's normalized strain (`[0, 1]`) for a
  /// given calendar day. The history is kept and persisted, but the current
  /// Readiness model does not use workload: it blends Recovery, Sleep and
  /// overnight HR/HRV against baseline only, so a workout no longer moves
  /// readiness.
  ///
  /// Hosts feed this from their workout backfill / live-event paths
  /// (e.g. WHOOP cycles, Garmin activities). When multiple workouts
  /// land on the same day we keep the *max* strain so a high-effort
  /// session isn't masked by a recovery walk.
  ///
  /// `strain01` is clamped to `[0, 1]`; values outside the range
  /// (e.g. WHOOP raw strain on a 21-point scale) should be normalized
  /// before this call (the SDK's vendor-mapper already does this for
  /// the `recovery_score` SRM dimension, mirror that pattern).
  ///
  /// Returns the latest Readiness Score, unchanged by the workout, or null
  /// when none has been computed yet.
  static ReadinessScoreResult? attachVendorWorkout({
    required DateTime occurredAt,
    required double strain01,
  }) {
    final clamped = strain01.isNaN
        ? 0.0
        : (strain01 < 0.0 ? 0.0 : (strain01 > 1.0 ? 1.0 : strain01));
    final day = _epochDay(occurredAt);
    final prev = _strainByDay[day] ?? 0.0;
    if (clamped > prev) {
      _strainByDay[day] = clamped;
    }
    _trimStrainHistory();
    return _latestReadinessScore;
  }

  /// Day-key compatible with [_calendarDayFromMs] / [Synheart.epochDayFor]:
  /// UTC days since epoch.
  static int _epochDay(DateTime t) => t.millisecondsSinceEpoch ~/ 86400000;

  /// Backfill `_recentOvernight[i]` slots from the canonical event
  /// store. Walks `_recentNights` and, for any slot still missing
  /// HRV / resting-HR, queries `recovery.updated` events from any
  /// provider and attaches the values for the matching calendar day.
  ///
  /// Solves the lockstep gap surfaced by the resilience pipeline:
  /// vendor sleep events arrive on one cadence and the matching
  /// recovery events on another. Today's flow only fills overnight
  /// physiology when the recovery payload arrives WHILE
  /// `_recentNights[i]` exists for the same day; if recovery
  /// already landed in the canonical store before the sleep
  /// payload was ingested (or vice-versa for an older night), the
  /// slot stayed empty and downstream consumers (resilience,
  /// recovery score on priors) lost the data.
  ///
  /// Idempotent: calls [attachOvernightPhysiology] for each match,
  /// which merges with whatever's already there. Best-effort —
  /// returns silently when the runtime isn't initialised or the
  /// query fails.
  ///
  /// Cost: one event-store query per call; intended to be invoked
  /// from `ResilienceData.snapshot()` and similar read paths, not
  /// on every UI tick.
  static Future<void> hydrateOvernightFromEventStore({
    Duration window = const Duration(days: 30),
  }) async {
    if (_recentNights.isEmpty) return;
    try {
      final now = DateTime.now();
      final from = now.subtract(window);
      final events = Synheart.queryVendorEvents(
        type: 'recovery.summary.recorded',
        start: from,
        end: now,
        limit: 200,
      );
      if (events == null || events.isEmpty) return;

      // Walk events; for each, extract the recovery's effective
      // calendar day (vendor-specific) and HRV / resting HR from
      // its raw payload. Hand off to attachOvernightPhysiology so
      // the existing merge + lockstep-fill logic runs.
      var attached = 0;
      for (final ev in events) {
        if (ev is! Map) continue;
        final provider = ev['provider']?.toString() ?? '';
        final payload = ev['payload'] is Map
            ? Map<String, dynamic>.from(ev['payload'] as Map)
            : <String, dynamic>{};
        final observedAtMs = (ev['observed_at_ms'] as num?)?.toInt();
        if (observedAtMs == null) continue;

        // Pull HRV + resting HR using the same shape-aware logic the
        // sleep-side ingest uses. Prefer top-level fields (flattened
        // by `wearable_event_processor`); fall back to raw vendor
        // blob nested under `<provider>_data`.
        double? hrv = _numDouble(payload['hrv_rmssd_ms']);
        double? rhr =
            _numDouble(payload['resting_hr_bpm']) ??
            _numDouble(payload['resting_heart_rate']);
        final rawKey = '${provider}_data';
        final raw = payload[rawKey];
        if (raw is Map) {
          final score = raw['score'] is Map ? raw['score'] as Map : raw;
          hrv ??=
              _numDouble(score['hrv_rmssd_milli']) ??
              _numDouble(score['hrv_rmssd_ms']);
          rhr ??=
              _numDouble(score['resting_heart_rate']) ??
              _numDouble(score['resting_hr']);
        }
        if (hrv == null && rhr == null) continue;

        attachOvernightPhysiology(
          occurredAt: DateTime.fromMillisecondsSinceEpoch(observedAtMs),
          hrvRmssdMs: hrv,
          restingHrBpm: rhr,
        );
        attached++;
      }
      if (attached > 0) {
        SynheartLogger.stream(
          'Baselines: hydrateOvernightFromEventStore attached '
          '$attached/${events.length} recovery records',
        );
      }
    } catch (e, st) {
      SynheartLogger.stream(
        'Baselines: hydrateOvernightFromEventStore failed: $e',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Backfill the sleep ring + score map from canonical event-store
  /// `sleep.summary.recorded` events. For each event in the window
  /// that hasn't already been ingested via the live RAMEN/wear path,
  /// rebuild a vendor sleep payload from its canonical fields and
  /// route it through [ingestVendorSleep] — the same code path the
  /// live wear-event handler uses, so dedup, priority eviction, and
  /// downstream Recovery/Readiness triggers all fire identically.
  ///
  /// Idempotent: events already represented in `_attachedKeys` (by
  /// wake calendar day + provider) are skipped. Best-effort — silent
  /// on runtime/storage errors.
  ///
  /// Solves the desync that resilience already fixed for HRV: vendor
  /// sleep summaries land in the canonical store via the wear stream,
  /// but Sleep/Recovery/Readiness only saw them when a *live* sleep
  /// ingest fired in this process. After app restart or while the
  /// stream was disconnected, the store had data the cards didn't.
  static Future<void> hydrateSleepFromEventStore({
    Duration window = const Duration(days: 30),
  }) async {
    try {
      final now = DateTime.now();
      final from = now.subtract(window);
      final events = Synheart.queryVendorEvents(
        type: 'sleep.summary.recorded',
        start: from,
        end: now,
        limit: 200,
      );
      if (events == null || events.isEmpty) return;

      // Process oldest-first so priors accumulate in attach order
      // (sleep_score's mode_for(prior_count) depends on it).
      final ordered = events.toList()
        ..sort((a, b) {
          final am = a is Map ? (a['observed_at_ms'] as num?)?.toInt() ?? 0 : 0;
          final bm = b is Map ? (b['observed_at_ms'] as num?)?.toInt() ?? 0 : 0;
          return am.compareTo(bm);
        });

      var ingested = 0;
      for (final ev in ordered) {
        if (ev is! Map) continue;
        final provider = ev['provider']?.toString() ?? '';
        if (provider.isEmpty) continue;
        final observedAtMs = (ev['observed_at_ms'] as num?)?.toInt();
        if (observedAtMs == null) continue;
        final payload = ev['payload'] is Map
            ? Map<String, dynamic>.from(ev['payload'] as Map)
            : <String, dynamic>{};

        // Skip if this calendar day is already claimed *by this same
        // provider*. Cross-provider claims are intentionally allowed
        // through so the priority-evict path in [ingestVendorSleep]
        // can flip the night to a higher-rank source if the canonical
        // store has one we hadn't seen live.
        final wakeDay = _calendarDayFromMs(observedAtMs);
        if (_attachedKeys[wakeDay] == provider) continue;

        // Hand the vendor blob back as the live wear handler would.
        // Provider-nested keys (`whoop_data`, `garmin_data`, …) drive
        // the variant/aggregation logic in `_buildNightVariants`; the
        // canonical store keeps these intact under `payload`.
        await ingestVendorSleep(provider: provider, payload: payload);
        ingested++;
      }
      if (ingested > 0) {
        SynheartLogger.stream(
          'Baselines: hydrateSleepFromEventStore ingested '
          '$ingested/${events.length} sleep records',
        );
      }
    } catch (e, st) {
      SynheartLogger.stream(
        'Baselines: hydrateSleepFromEventStore failed: $e',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Run both [hydrateSleepFromEventStore] and
  /// [hydrateOvernightFromEventStore] in the right order: sleep first
  /// so [_recentNights] is populated, then overnight physiology so
  /// the parallel `_recentOvernight[i]` slots get filled with HRV /
  /// resting-HR for the same wake days.
  ///
  /// Wire this to your app-foreground hook (e.g. `WidgetsBindingObserver
  /// .didChangeAppLifecycleState == resumed`) so newly-pulled vendor
  /// data lands on the cards without waiting for the next live event.
  ///
  /// Wrapped in [runIngestBatch] so a post-restart hydration of up to
  /// ~200 events doesn't fire Recovery / Readiness ~200 times — only
  /// once at the end, against the latest replayed night. This is the
  /// cross-session counterpart to the orchestrator's pull batching:
  /// without it, every relaunch with vendor data in the canonical
  /// store would burn the same FFI cascade we already collapsed for
  /// orchestrator-driven pulls.
  static Future<void> hydrateFromEventStore({
    Duration window = const Duration(days: 30),
  }) async {
    await runIngestBatch(() async {
      await hydrateSleepFromEventStore(window: window);
      await hydrateOvernightFromEventStore(window: window);
    });
  }

  /// Recover the absolute UTC-days-since-epoch key from a stored
  /// `wakeCalendarDate`. The encoding is
  /// `wakeCalendarDate = (ms ÷ 86400000) − _wakeDayAnchor + 20100`
  /// so the inverse is what this returns. Use everywhere we need to
  /// Write one night's vendor-derived metrics into the personal baselines,
  /// under the night's wake date, from [provider].
  ///
  /// Writing a date again replaces it, so this is safe to call more than
  /// once for a night (initial attach, same-source refresh and
  /// priority-evict all route here). Ends with one reference refresh so the
  /// next window reads the new values.
  ///
  /// [wakeDayIndex] is the UTC day of the night's timestamp (see
  /// [_absDayFromWakeCalendar]). Hosts pass the wake day's local noon as
  /// that timestamp, which falls on the same UTC date in every zone within
  /// ±12 h, so its calendar fields are the person's local wake date.
  ///
  /// Totals come from an `AggregatedNight` (via `raw.detail`);
  /// `SegmentedNight` and `VendorScoreNight` carry none, so only their
  /// overnight HR/HRV (from the per-provider extractor) is written.
  static void _pushDailyToRuntimeSrm({
    required String provider,
    required int wakeDayIndex,
    required OvernightPhysiology overnight,
    required NightRaw raw,
  }) {
    final date = DateTime.fromMillisecondsSinceEpoch(
      wakeDayIndex * 86400000,
      isUtc: true,
    );
    var pushed = false;
    // A zero is no measurement for every metric here except the midpoint,
    // where 0.0 is midnight.
    void push(String metric, double? value, {bool zeroIsValue = false}) {
      if (value == null || value < 0 || (value == 0 && !zeroIsValue)) return;
      final rc = Synheart.srmPushWearableDaily(
        provider: provider,
        metric: metric,
        date: date,
        value: value,
      );
      // 5002 (out of bounds / stream not permitted) is the runtime refusing
      // one value, not a failure of the night; log it and go on.
      if (rc != 0) {
        SynheartLogger.stream(
          'Baselines: daily $metric for $provider refused (rc=$rc)',
        );
      }
      pushed = true;
    }

    // Apple Health (HKHeartRateVariabilitySDNN) is the SDNN source;
    // WHOOP/Garmin/Health Connect ship RMSSD.
    push(DailyMetric.overnightSdnnMs, overnight.hrvSdnnMs);
    push(DailyMetric.overnightHrSdBpm, overnight.hrStdBpm);
    push(DailyMetric.stepsCount, overnight.stepsCount);
    push(DailyMetric.overnightRmssdMs, overnight.hrvRmssdMs);
    // One overnight heart-rate figure feeds both baselines: the night's mean
    // HR is the Sleep Score's HR baseline, and without a resting-HR baseline
    // Recovery cannot personalise nor Readiness align. A source with a
    // separate resting HR would push that one as `restingHrBpm` instead.
    push(DailyMetric.overnightHrBpm, overnight.overnightHrBpm);
    push(DailyMetric.restingHrBpm, overnight.overnightHrBpm);
    // Only a night with a start and end has a midpoint; never derived.
    push(DailyMetric.sleepMidpointH, _sleepMidpointH(raw), zeroIsValue: true);

    final detail = raw.detail;
    if (detail is AggregatedNight) {
      final totals = detail.totals;
      push(DailyMetric.sleepDurationS, totals.totalSleepMinutes * 60.0);
      push(DailyMetric.sleepDeepMin, totals.deepSleepMinutes);
      push(DailyMetric.sleepRemMin, totals.remSleepMinutes);
    }

    // One refresh per night, as of today: the reference is built from the
    // dates before today, so today's windows are never judged against
    // today's own values (the runtime's "no day in its own baseline").
    if (pushed) Synheart.srmRefreshWearableReference();
  }

  /// match a sleep night against a same-day overnight-physiology
  /// record (`_overnightByDay` is keyed by absolute days).
  static int _absDayFromWakeCalendar(int wakeCalendarDate) =>
      wakeCalendarDate + _wakeDayAnchor - 20100;

  /// Drop strain entries older than the chronic window (28 days from
  /// the newest entry).
  static void _trimStrainHistory() {
    if (_strainByDay.isEmpty) return;
    final newest = _strainByDay.keys.reduce((a, b) => a > b ? a : b);
    _strainByDay.removeWhere((day, _) => day < newest - 28);
  }

  /// Compute and stash today's Readiness Score from the Recovery Score just
  /// settled for the night ending on [day], that night's Sleep Score, and
  /// the night's HR/HRV against the person's baselines.
  ///
  /// Readiness needs both scores. A night whose Sleep Score abstained gets
  /// no readiness rather than one built on a made-up sleep value.
  static void _computeReadiness(
    RecoveryScoreResult recovery, {
    required int day,
    required OvernightPhysiology overnight,
  }) {
    try {
      final sleep = _attachedSleepFor(day);
      final sleepScore = sleep?.score;
      if (sleep == null || sleepScore == null) {
        SynheartLogger.stream(
          'Baselines: readiness skipped (no sleep score for night $day)',
        );
        return;
      }
      final base = Synheart.dailyBaselineRefs();
      final hrSleep = overnight.overnightHrBpm;
      final rmssdSleep = overnight.hrvRmssdMs;
      final input = ReadinessScoreInput(
        recoveryScore: recovery.score,
        sleepScore: sleepScore,
        // All four or none: the engine redistributes the alignment weight
        // onto Recovery and Sleep when it is absent, which is honest; a
        // partial alignment would not be.
        alignment: base != null && hrSleep != null && rmssdSleep != null
            ? OvernightAlignment(
                hrSleepBpm: hrSleep,
                hrBaseBpm: base.restingHrBpm,
                rmssdSleepMs: rmssdSleep,
                rmssdBaseMs: base.hrvRmssdMs,
              )
            : null,
        recoveryColdStart: recovery.stage == RecoveryStage.firstDay,
        sleepColdStart: sleep.mode == SleepScoreMode.coldStart,
        baselineMaturity: base?.maturity ?? 0,
      );
      final result = _scoreReadiness(day, input);
      if (result == null) {
        SynheartLogger.stream(
          'Baselines: readiness skipped (engine returned null)',
        );
        return;
      }
      _latestReadinessScore = result;
      SynheartLogger.stream(
        'Baselines: readiness=${result.score} band=${result.band.wire} '
        'conf=${result.confidence.toStringAsFixed(2)} '
        'alignment=${input.alignment == null ? 'none' : 'yes'}',
      );
    } catch (e, st) {
      SynheartLogger.stream(
        'Baselines: readiness compute failed: $e',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// The Sleep Score that claimed the night ending on [day]: the winning
  /// provider's variant, as recorded for the alternates UI.
  static SleepScoreResult? _attachedSleepFor(int day) {
    final provider = _attachedKeys[day];
    final byVariant = _scoresByNight[day];
    if (provider == null || byVariant == null) return null;
    final path = _attachedPaths[day];
    for (final id in [provider, '${provider}_score']) {
      final r = byVariant[id];
      if (r != null && (path == null || r.path == path)) return r;
    }
    return byVariant[provider];
  }

  /// Public host hook to compute a Readiness Score from the host's own
  /// input (e.g. its own baselines for the alignment term). Returns the
  /// result and stashes it as the new [latestReadinessScore]. It is not
  /// queued for upload; [Synheart.attachReadinessScore] does that.
  static ReadinessScoreResult? computeReadinessWith({
    required ReadinessScoreInput input,
  }) {
    final result = Synheart.computeReadinessScore(input);
    if (result != null) {
      _latestReadinessScore = result;
      if (!_ctrl.isClosed) _ctrl.add(snapshot);
    }
    return result;
  }

  // ─── Recovery / Readiness persistence ──────────────────────────────

  /// Snapshot the in-memory Recovery + Readiness state as a JSON
  /// string. Hosts persist this (e.g. SharedPreferences) so a fresh
  /// app launch doesn't blank the cards while waiting for tomorrow's
  /// pull. The host owns the storage layer; the SDK ships dep-free.
  ///
  /// Encoded fields:
  /// - `recent_recovery_scores`: last 7 score values (newest at back)
  /// - `latest_recovery`: full result JSON, or null
  /// - `latest_readiness`: full result JSON, or null
  /// - `strain_by_day`: `{epochDay: strain01}` for the last 28 days
  /// - `latest_sleep`: full [SleepScoreResult] JSON for the most recent
  ///   ingested night, or null. The runtime's longitudinal snapshot
  ///   persists the Path-B *ring* (the bare score values driving the
  ///   median), but not the rich per-night [SleepScoreResult] (path,
  ///   mode, components, confidence). Recovery / Readiness already
  ///   round-trip their full results here; Sleep was the one derived
  ///   surface missing it — so on a cold start the ring repopulated
  ///   `nightsLoggedCount`/`recentMedian` while `latestSleepScore`
  ///   stayed null and the Sleep ring read empty. Persisting it here
  ///   closes that asymmetry.
  /// - `last_sleep_source` / `last_sleep_variant`: the provider +
  ///   variant id that produced `latest_sleep`, so the Sleep card's
  ///   source badge and the `tonightAlternates` winner survive too.
  /// - `last_ingest_at_ms`: epoch-ms of the last successful ingest.
  /// - `daily_upload_ledger`: the last night queued for upload per daily
  ///   score kind and whether a frame carried it, so a relaunch neither
  ///   resends nor re-rings nights already sent ([DailyScoreLedger]).
  static String exportRecoveryStateJson() {
    final map = <String, Object?>{
      'recent_recovery_scores': _recentRecoveryScores.toList(growable: false),
      // Persist the nights ring too so `nightsLoggedCount` survives a cold
      // launch independent of the native (subject-scoped) longitudinal store.
      'recent_sleep_score_ring': _readRecentRing(),
      'latest_recovery': _latestRecoveryScore == null
          ? null
          : _recoveryToJson(_latestRecoveryScore!),
      'latest_readiness': _latestReadinessScore == null
          ? null
          : _readinessToJson(_latestReadinessScore!),
      'strain_by_day': _strainByDay.map((k, v) => MapEntry(k.toString(), v)),
      'latest_sleep': _latestScore == null
          ? null
          : _sleepScoreToJson(_latestScore!),
      'last_sleep_source': _lastSource,
      'last_sleep_variant': _lastVariantId,
      'last_ingest_at_ms': _lastIngestAt?.millisecondsSinceEpoch,
      'daily_upload_ledger': _ledger.toJson(),
    };
    return jsonEncode(map);
  }

  /// Restore Recovery + Readiness state from a snapshot produced by
  /// [exportRecoveryStateJson]. Silently ignores malformed payloads.
  ///
  /// Re-feeds the engine's day-scoped Recovery anchor via
  /// [Synheart.attachRecoveryScoreToday] so personalization Stage 2
  /// keeps blending today's score after a relaunch — without this
  /// the engine sees a fresh "no recovery" state until the next pull.
  static void loadRecoveryStateJson(String json) {
    try {
      final raw = jsonDecode(json);
      if (raw is! Map<String, Object?>) return;

      _ledger.loadJson(raw['daily_upload_ledger']);

      final scores = raw['recent_recovery_scores'];
      if (scores is List) {
        _recentRecoveryScores
          ..clear()
          ..addAll(scores.whereType<num>().map((n) => n.toInt()));
        while (_recentRecoveryScores.length > 7) {
          _recentRecoveryScores.removeAt(0);
        }
      }

      // Restore the persisted nights ring as the cold-start fallback for
      // [_readRecentRing] (used when the native longitudinal snapshot is
      // empty). If the ring was already read empty this process, seed it now
      // so the restored nights surface without waiting for a [reset].
      final ring = raw['recent_sleep_score_ring'];
      if (ring is List) {
        _persistedRecentRing = ring
            .whereType<num>()
            .map((n) => n.toInt())
            .toList();
        if (_localRing.isEmpty && _persistedRecentRing!.isNotEmpty) {
          _localRing
            ..clear()
            ..addAll(_persistedRecentRing!);
          _localRingDays
            ..clear()
            ..addAll(List<int>.filled(_localRing.length, -1));
        }
      }

      final recovery = raw['latest_recovery'];
      if (recovery is Map<String, Object?>) {
        try {
          _latestRecoveryScore = RecoveryScoreResult.fromJson(recovery);
          // Re-attach so the engine sees today's anchor again.
          Synheart.attachRecoveryScoreToday(_latestRecoveryScore!.score);
        } catch (_) {
          _latestRecoveryScore = null;
        }
      }

      final readiness = raw['latest_readiness'];
      if (readiness is Map<String, Object?>) {
        try {
          _latestReadinessScore = ReadinessScoreResult.fromJson(readiness);
        } catch (_) {
          _latestReadinessScore = null;
        }
      }

      final strain = raw['strain_by_day'];
      if (strain is Map) {
        _strainByDay.clear();
        for (final entry in strain.entries) {
          final day = int.tryParse(entry.key.toString());
          final v = entry.value;
          if (day != null && v is num) {
            _strainByDay[day] = v.toDouble();
          }
        }
        _trimStrainHistory();
      }

      // Latest sleep score — restored on every launch so the Sleep ring
      // / `_SleepCard` show the last logged night immediately, the same
      // way `latest_recovery` / `latest_readiness` above repopulate
      // Recovery / Readiness. Without this, `_latestScore` (a static
      // field only ever set by a live `ingestVendorSleep`) stays null on
      // a cold start even though the runtime restored the Path-B ring.
      //
      // The honest cold-start path is preserved: a brand-new user has no
      // persisted `latest_sleep`, so this is a no-op and the Sleep ring
      // stays empty — we never fabricate a score.
      final sleep = raw['latest_sleep'];
      if (sleep is Map) {
        try {
          final restored = SleepScoreResult.fromJson(
            sleep.cast<String, Object?>(),
          );
          _latestScore = restored;
          // Re-seed the alternates map so the `_SleepCard` winner-pick
          // (which prefers `tonightAlternates`) finds the restored
          // score under its provider key instead of falling through to
          // an empty map. Keyed by the persisted variant id, falling
          // back to the bare source, then to a stable sentinel.
          final variant = raw['last_sleep_variant'];
          final source = raw['last_sleep_source'];
          final variantKey = (variant is String && variant.isNotEmpty)
              ? variant
              : (source is String && source.isNotEmpty ? source : 'restored');
          // Use the night's prior count as a coarse, stable day key —
          // the exact wake day isn't persisted here, but the alternates
          // lookup only needs a single most-recent bucket to surface
          // the restored score. A live ingest later re-keys by the real
          // wake day, so this placeholder never lingers.
          _scoresByNight
            ..clear()
            ..[restored.priorNightCount] = <String, SleepScoreResult>{
              variantKey: restored,
            };
        } catch (e, st) {
          // Don't silently drop — if SleepScoreResult.fromJson schema
          // changes between SDK versions, an old persisted blob will
          // fail here and the user loses their score with no signal.
          SynheartLogger.stream(
            'Baselines: latest_sleep decode failed — dropping persisted '
            'score (likely a schema change between SDK versions)',
            error: e,
            stackTrace: st,
          );
          _latestScore = null;
        }
      }

      final lastSource = raw['last_sleep_source'];
      if (lastSource is String && lastSource.isNotEmpty) {
        _lastSource = lastSource;
      }
      final lastVariant = raw['last_sleep_variant'];
      if (lastVariant is String && lastVariant.isNotEmpty) {
        _lastVariantId = lastVariant;
      }
      final ingestMs = raw['last_ingest_at_ms'];
      if (ingestMs is num) {
        _lastIngestAt = DateTime.fromMillisecondsSinceEpoch(ingestMs.toInt());
      }

      if (!_ctrl.isClosed) _ctrl.add(snapshot);
    } catch (e, st) {
      SynheartLogger.stream(
        'Baselines: loadRecoveryStateJson failed: $e',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Serialize a [SleepScoreResult] into a map that [SleepScoreResult]
  /// `.fromJson` round-trips exactly. The model ships `fromJson` but no
  /// `toJson`, so the encoding lives here next to the Recovery /
  /// Readiness encoders — the wire keys match what `fromJson` reads.
  static Map<String, Object?> _sleepScoreToJson(SleepScoreResult s) => {
    // Bump when the wire format changes (e.g. Path.wire renames, new
    // required component fields). loadRecoveryStateJson can branch on
    // this to migrate or reject old blobs.
    'schema_version': 1,
    'score': s.score,
    'score_normalized': s.scoreNormalized,
    'confidence': s.confidence,
    'path': s.path.wire,
    'mode': s.mode.wire,
    'components': {
      'duration': s.components.duration,
      'quality': s.components.quality,
      'continuity': s.components.continuity,
      'consistency': s.components.consistency,
      'personalization': s.components.personalization,
      'vendor_score': s.components.vendorScore,
      'proxy_hr': s.components.proxyHr,
    },
    'adjustments': {
      'debt_penalty': s.adjustments.debtPenalty,
      'hr_adjustment': s.adjustments.hrAdjustment,
    },
    'effective_weights': {
      'duration': s.effectiveWeights.duration,
      'quality': s.effectiveWeights.quality,
      'continuity': s.effectiveWeights.continuity,
      'consistency': s.effectiveWeights.consistency,
      'personalization': s.effectiveWeights.personalization,
    },
    'reason': s.reason?.wire,
    'prior_night_count': s.priorNightCount,
    'pipeline_version': s.pipelineVersion,
    'model_id': s.modelId,
    'constants_hash': s.constantsHash,
  };

  static Map<String, Object?> _recoveryToJson(RecoveryScoreResult r) => {
    'score': r.score,
    'stage': r.stage.wire,
    'mode': r.mode.wire,
    'components': {
      'sleep_quality': r.components.sleepQuality,
      'continuity': r.components.continuity,
      'consistency': r.components.consistency,
      'overnight_hr_level': r.components.overnightHrLevel,
      'hrv_level': r.components.hrvLevel,
      'hrv_trend': r.components.hrvTrend,
      'hr_trend': r.components.hrTrend,
      'hrv_deviation': r.components.hrvDeviation,
      'rhr_deviation': r.components.rhrDeviation,
      'strain_adjustment': r.components.strainAdjustment,
    },
    'confidence': r.confidence,
    'explanation': r.explanation.map((f) => f.wire).toList(growable: false),
    'model_id': r.modelId,
    'model_version': r.modelVersion,
    'pipeline_version': r.pipelineVersion,
  };

  static Map<String, Object?> _readinessToJson(ReadinessScoreResult r) =>
      r.toJson();
}
