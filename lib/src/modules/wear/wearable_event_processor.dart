import 'dart:async';
import '../../core/logger.dart';
import '../../models/canonical_wearable_event.dart';

/// Processes incoming RAMEN vendor events into the SynHeart pipeline:
///   RamenEvent payload → CanonicalWearableEvent → SQLite store → SRM push → runtime
///
/// This is the bridge between the wear SDK's real-time event stream and the
/// core SDK's longitudinal SRM engine. Each vendor event (sleep, recovery,
/// HRV, strain) is normalized, stored immutably, and pushed to the runtime
/// for baseline computation.
class WearableEventProcessor {
  final String _subjectId;
  final String _deviceInstallId;

  WearableEventProcessor({
    required String subjectId,
    required String deviceInstallId,
  }) : _subjectId = subjectId,
       _deviceInstallId = deviceInstallId;

  /// Process a raw vendor event from RAMEN.
  ///
  /// [provider] — e.g. "whoop", "garmin"
  /// [eventType] — e.g. "sleep.updated", "recovery.updated"
  /// [payload] — decoded JSON payload from the EventEnvelope
  /// [eventId] — RAMEN event ID (used for dedup)
  /// [seq] — RAMEN sequence number
  ///
  /// Returns the canonical event if processed, null if skipped (unknown type or dedup).
  Future<CanonicalWearableEvent?> processRamenEvent({
    required String provider,
    required String eventType,
    required Map<String, dynamic> payload,
    required String eventId,
    required int seq,
  }) async {
    // Map RAMEN event type to canonical event type
    final mapping = _mapEventType(provider, eventType);
    if (mapping == null) {
      SynheartLogger.log(
        '[WearableEventProcessor] Unknown event type: $provider/$eventType — skipping',
      );
      return null;
    }

    // Extract timestamps
    final observedAt =
        _extractTimestamp(payload, mapping.observedAtKey) ??
        DateTime.now().toUtc();
    final effectiveStart = _extractTimestamp(
      payload,
      mapping.effectiveStartKey,
    );
    final effectiveEnd = _extractTimestamp(payload, mapping.effectiveEndKey);

    // Extract provider record ID for deterministic dedup
    final providerRecordId = payload[mapping.providerRecordIdKey]?.toString();

    // Extract confidence from payload or use provider default
    final confidence = _extractConfidence(payload, provider);

    // Build canonical event
    final canonicalEventId = CanonicalWearableEvent.computeWearableEventId(
      subjectId: _subjectId,
      type: mapping.canonicalType,
      provider: provider,
      providerRecordId: providerRecordId,
      observedAt: observedAt,
      effectiveStart: effectiveStart,
      effectiveEnd: effectiveEnd,
    );

    // Extract the sub-payload for the canonical event
    final canonicalPayload = mapping.extractPayload(payload);

    final event = CanonicalWearableEvent(
      eventId: canonicalEventId,
      subjectId: _subjectId,
      deviceInstallId: _deviceInstallId,
      eventClass: 'PROVIDER_SUMMARY',
      type: mapping.canonicalType,
      provider: provider,
      providerRecordId: providerRecordId,
      observedAt: observedAt,
      ingestedAt: DateTime.now().toUtc(),
      effectiveStart: effectiveStart,
      effectiveEnd: effectiveEnd,
      payload: canonicalPayload,
      confidence: confidence,
      sourceFidelity: 'provider_summary',
      provenance: {
        'ramen_event_id': eventId,
        'ramen_seq': seq,
        'raw_event_type': eventType,
      },
    );

    SynheartLogger.log(
      '[WearableEventProcessor] Processed $provider/${mapping.canonicalType} '
      '(seq=$seq, confidence=${confidence.toStringAsFixed(2)})',
    );

    return event;
  }

  /// Map RAMEN event types to canonical event types with extraction config.
  _EventMapping? _mapEventType(String provider, String eventType) {
    // Normalize: providers use different event naming
    final key = '$provider:$eventType';
    return _eventMappings[key] ?? _eventMappings[eventType];
  }

  DateTime? _extractTimestamp(Map<String, dynamic> payload, String? key) {
    if (key == null) return null;
    final raw = payload[key];
    if (raw == null) return null;
    if (raw is String) return DateTime.tryParse(raw)?.toUtc();
    if (raw is int)
      return DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true);
    return null;
  }

  double _extractConfidence(Map<String, dynamic> payload, String provider) {
    // Some providers include quality/confidence in payload
    final quality = payload['quality'];
    if (quality is Map) {
      final conf = quality['confidence'];
      if (conf is num) return conf.toDouble().clamp(0.0, 1.0);
    }
    // Provider-level defaults (vendor summaries are generally high confidence)
    switch (provider) {
      case 'whoop':
        return 0.90;
      case 'garmin':
        return 0.85;
      case 'oura':
        return 0.88;
      default:
        return 0.75;
    }
  }

  // ─── Event Mapping Registry ─────────────────────────────────────────

  static final _eventMappings = <String, _EventMapping>{
    // WHOOP events
    'whoop:recovery.updated': _EventMapping(
      canonicalType: 'recovery.summary.recorded',
      observedAtKey: 'created_at',
      providerRecordIdKey: 'cycle_id',
      extractPayload: (p) {
        // WHOOP nests its scored fields under `score`. Tolerate both shapes
        // so legacy/flattened payloads still extract.
        final s = p['score'] is Map ? p['score'] as Map : const {};
        final hrvMilli = _asDouble(s['hrv_rmssd_milli']) ?? _asDouble(p['hrv']);
        return {
          'score':
              _asDouble(s['recovery_score']) ?? _asDouble(p['recovery_score']),
          // WHOOP returns HRV in milliseconds-of-RMSSD ("milli"), already in ms;
          // the field name differs from canonical (rmssd_ms vs rmssd_milli).
          'hrv_rmssd_ms': hrvMilli,
          'resting_hr_bpm':
              _asDouble(s['resting_heart_rate']) ??
              _asDouble(p['resting_heart_rate']),
          'spo2_pct':
              _asDouble(s['spo2_percentage']) ??
              _asDouble(p['spo2_percentage']),
          'skin_temp_c': _asDouble(s['skin_temp_celsius']),
        };
      },
    ),
    'whoop:sleep.updated': _EventMapping(
      canonicalType: 'sleep.summary.recorded',
      observedAtKey: 'end',
      effectiveStartKey: 'start',
      effectiveEndKey: 'end',
      providerRecordIdKey: 'id',
      extractPayload: (p) {
        final s = p['score'] is Map ? p['score'] as Map : const {};
        final stage = s['stage_summary'] is Map
            ? s['stage_summary'] as Map
            : const {};
        final inBedMilli =
            _asInt(stage['total_in_bed_time_milli']) ??
            _asInt(p['total_in_bed_time_milli']);
        return {
          'duration_seconds': inBedMilli != null
              ? (inBedMilli / 1000).round()
              : _asInt(p['duration_seconds']),
          'efficiency_pct':
              _asDouble(s['sleep_efficiency_percentage']) ??
              _asDouble(p['sleep_efficiency']),
          'performance_pct': _asDouble(s['sleep_performance_percentage']),
          'consistency_pct': _asDouble(s['sleep_consistency_percentage']),
          'respiratory_rate': _asDouble(s['respiratory_rate']),
          'midpoint_time': p['start'] != null && p['end'] != null
              ? _midpointIso(p['start']?.toString(), p['end']?.toString())
              : null,
        };
      },
    ),
    'whoop:workout.updated': _EventMapping(
      canonicalType: 'workout.summary.recorded',
      observedAtKey: 'end',
      effectiveStartKey: 'start',
      effectiveEndKey: 'end',
      providerRecordIdKey: 'id',
      extractPayload: (p) {
        final s = p['score'] is Map ? p['score'] as Map : const {};
        return {
          'strain_score':
              _asDouble(s['strain']) ??
              _asDouble(p['strain']) ??
              _asDouble(p['score']),
          'duration_seconds': _asInt(p['duration_seconds']),
          'avg_hr_bpm':
              _asDouble(s['average_heart_rate']) ??
              _asDouble(p['average_heart_rate']),
          'max_hr_bpm':
              _asDouble(s['max_heart_rate']) ?? _asDouble(p['max_heart_rate']),
          'calories': _asDouble(s['kilojoule']) ?? _asDouble(p['kilojoule']),
        };
      },
    ),

    // Garmin events
    'garmin:sleep.updated': _EventMapping(
      canonicalType: 'sleep.summary.recorded',
      observedAtKey: 'calendarDate',
      providerRecordIdKey: 'summaryId',
      extractPayload: (p) => {
        'duration_seconds': _asInt(p['durationInSeconds']),
        'deep_sleep_seconds': _asInt(p['deepSleepDurationInSeconds']),
        'light_sleep_seconds': _asInt(p['lightSleepDurationInSeconds']),
        'rem_sleep_seconds': _asInt(p['remSleepInSeconds']),
        'awake_seconds': _asInt(p['awakeDurationInSeconds']),
      },
    ),
    'garmin:recovery.updated': _EventMapping(
      canonicalType: 'recovery.summary.recorded',
      observedAtKey: 'calendarDate',
      providerRecordIdKey: 'summaryId',
      extractPayload: (p) => {
        // Garmin's bodyBatteryChargedValue is already 0–100 — keep the same
        // 0–100 scale as WHOOP so the UI doesn't have to special-case providers.
        'score': _asDouble(p['bodyBatteryChargedValue']),
        'stress_avg': _asDouble(p['averageStressLevel']),
        'resting_hr_bpm': _asDouble(p['restingHeartRateInBeatsPerMinute']),
      },
    ),
    'garmin:hrv.updated': _EventMapping(
      canonicalType: 'hrv.recorded',
      observedAtKey: 'calendarDate',
      providerRecordIdKey: 'summaryId',
      extractPayload: (p) => {
        // Last night's average is the nightly figure; the weekly average is
        // a 7-day mean and is kept apart so it is never read as one night.
        'rmssd_ms': _asDouble(p['lastNightAvg']),
        'weekly_avg_rmssd_ms': _asDouble(p['weeklyAvg']),
        'status': p['hrvStatus'],
      },
    ),

    // Generic fallbacks (provider-agnostic event types)
    'recovery.updated': _EventMapping(
      canonicalType: 'recovery.summary.recorded',
      observedAtKey: 'created_at',
      extractPayload: (p) => {
        'score': _asDouble(p['score']) ?? _asDouble(p['recovery_score']),
      },
    ),
    'sleep.updated': _EventMapping(
      canonicalType: 'sleep.summary.recorded',
      observedAtKey: 'end',
      effectiveStartKey: 'start',
      effectiveEndKey: 'end',
      extractPayload: (p) => {
        'duration_seconds': _asInt(p['duration_seconds']),
        'efficiency_pct': _asDouble(p['efficiency']),
      },
    ),
  };

  static double? _asDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  static int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static String? _midpointIso(String? start, String? end) {
    if (start == null || end == null) return null;
    final s = DateTime.tryParse(start);
    final e = DateTime.tryParse(end);
    if (s == null || e == null) return null;
    final mid = s.add(
      Duration(milliseconds: e.difference(s).inMilliseconds ~/ 2),
    );
    return mid.toUtc().toIso8601String();
  }
}

/// Configuration for mapping a RAMEN event type to a canonical event.
class _EventMapping {
  final String canonicalType;
  final String? observedAtKey;
  final String? effectiveStartKey;
  final String? effectiveEndKey;
  final String? providerRecordIdKey;
  final Map<String, dynamic> Function(Map<String, dynamic>) extractPayload;

  const _EventMapping({
    required this.canonicalType,
    this.observedAtKey,
    this.effectiveStartKey,
    this.effectiveEndKey,
    this.providerRecordIdKey,
    required this.extractPayload,
  });
}
