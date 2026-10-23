import 'dart:convert';

/// The daily score kinds [Baselines] queues for upload, named as the runtime
/// names their readings on `axes.physiological`.
enum DailyScoreKind {
  sleep('sleep_score'),
  recovery('recovery'),
  readiness('readiness');

  const DailyScoreKind(this.reading);

  /// The reading name an emitted frame carries the score under.
  final String reading;
}

/// What this device last queued for upload, per daily score kind, and
/// whether an emitted frame has carried it yet.
///
/// A daily score reaches the cloud only by riding an emitted HSI frame, and
/// the runtime holds one pending score per kind: a later attach replaces an
/// earlier one, and the copy lives in memory only. Three things follow, and
/// this ledger exists to get all three right across relaunches:
///
/// - A relaunch re-pulls the last month of nights. Re-attaching each one
///   uploads the newest night a second time and pushes every night onto the
///   engine's 7-night sleep ring again, which has no per-night key.
/// - Attaching an older night after a newer one replaces the newer one in
///   the runtime's single slot, so the cloud gets yesterday's score as
///   today's.
/// - A score queued just before the process died never rode a frame. Its
///   runtime copy died with the process, so it must be queued once more.
///   Within one process the runtime still holds it, and queuing it again
///   only pushes the night onto the sleep ring a second time.
///
/// The rule, per kind: never queue a night older than the last one queued;
/// skip the same night with the same score once a frame has carried it, or
/// while this process queued it; queue anything else (a new night, a
/// corrected score, or one an earlier process queued and no frame carried).
///
/// Days are `wakeCalendarDate` values, so they order chronologically.
class DailyScoreLedger {
  final Map<DailyScoreKind, _Queued> _queued = {};

  /// Whether a score for [day] should be queued now. See the class doc.
  bool shouldQueue(DailyScoreKind kind, int day, int? score) {
    final last = _queued[kind];
    if (last == null) return true;
    if (day < last.day) return false;
    if (day > last.day) return true;
    if (score != last.score) return true;
    return !last.delivered && !last.thisProcess;
  }

  /// Record that a score for [day] was handed to the runtime.
  void noteQueued(DailyScoreKind kind, int day, int? score) {
    _queued[kind] = _Queued(
      day: day,
      score: score,
      delivered: false,
      thisProcess: true,
    );
  }

  /// Mark every kind whose reading [hsiJson] carries as delivered — the same
  /// test the runtime uses to drop its own pending copy. Returns whether
  /// anything changed, so the caller can have the ledger persisted.
  bool noteFrame(String hsiJson) {
    if (_queued.values.every((q) => q.delivered)) return false;
    if (!DailyScoreKind.values.any((k) => hsiJson.contains('"${k.reading}"'))) {
      return false;
    }
    final Object? frame;
    try {
      frame = jsonDecode(hsiJson);
    } catch (_) {
      return false;
    }
    if (frame is! Map) return false;
    final axes = frame['axes'];
    final readings = axes is Map ? axes['physiological'] : null;
    if (readings is! List) return false;
    var changed = false;
    for (final r in readings) {
      final name = r is Map ? r['name'] : null;
      for (final kind in DailyScoreKind.values) {
        final q = _queued[kind];
        if (name == kind.reading && q != null && !q.delivered) {
          q.delivered = true;
          changed = true;
        }
      }
    }
    return changed;
  }

  /// The last day queued for [kind], or null.
  int? lastQueuedDay(DailyScoreKind kind) => _queued[kind]?.day;

  /// Whether a frame has carried the last score queued for [kind].
  bool? lastDelivered(DailyScoreKind kind) => _queued[kind]?.delivered;

  void clear() => _queued.clear();

  Map<String, Object?> toJson() => {
    for (final e in _queued.entries)
      e.key.reading: {
        'day': e.value.day,
        'score': e.value.score,
        'delivered': e.value.delivered,
      },
  };

  /// Replace the ledger with [json] from [toJson]. Malformed entries are
  /// dropped, which only ever means one extra queue, never a lost one.
  void loadJson(Object? json) {
    _queued.clear();
    if (json is! Map) return;
    for (final kind in DailyScoreKind.values) {
      final e = json[kind.reading];
      if (e is! Map) continue;
      final day = e['day'];
      final score = e['score'];
      final delivered = e['delivered'];
      if (day is! int) continue;
      // Loaded from an earlier process: its runtime copy is gone.
      _queued[kind] = _Queued(
        day: day,
        score: score is int ? score : null,
        delivered: delivered == true,
        thisProcess: false,
      );
    }
  }
}

class _Queued {
  _Queued({
    required this.day,
    required this.score,
    required this.delivered,
    required this.thisProcess,
  });

  final int day;
  final int? score;
  bool delivered;

  /// Queued by this process, so the runtime still holds its copy until a
  /// frame carries it. Not persisted: a loaded entry is always from before.
  final bool thisProcess;
}
