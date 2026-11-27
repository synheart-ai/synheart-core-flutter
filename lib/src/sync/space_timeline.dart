/// The runtime's per-device HSI history, bucketed for charts
/// (`synheart_core_space_timeline`, core-runtime 0.47.0 and later).
///
/// One [SpaceTimelineSeries] per device in the sync space: this device, plus
/// every other device whose windows arrived while sharing was on. A bucket with
/// no windows is absent from [SpaceTimelineSeries.members], not zero, so a chart
/// should draw a gap there.
library;

/// Bucket width the runtime picked for a query.
enum SpaceTimelineTier {
  minute,
  halfHour,
  day,

  /// A tier this SDK does not know yet. [SpaceTimeline.bucketMs] still holds
  /// the width.
  unknown;

  static SpaceTimelineTier parse(Object? raw) => switch (raw) {
    'minute' => minute,
    'half_hour' => halfHour,
    'day' => day,
    _ => unknown,
  };
}

/// One bucket of one member: the windows that ended inside it.
class SpaceTimelinePoint {
  const SpaceTimelinePoint({
    required this.start,
    required this.count,
    required this.mean,
    required this.min,
    required this.max,
    required this.meanConfidence,
  });

  /// Bucket start (UTC).
  final DateTime start;

  /// Number of windows in the bucket.
  final int count;
  final double mean;
  final double min;
  final double max;
  final double meanConfidence;
}

/// One device's buckets, by member (for example `focus` or `stress`).
class SpaceTimelineSeries {
  const SpaceTimelineSeries({
    required this.origin,
    required this.thisDevice,
    required this.members,
  });

  /// The device's sync device id, or `local` on a device with neither a
  /// registered nor an HMAC device id.
  final String origin;

  /// True for the device the query ran on.
  final bool thisDevice;

  /// Points per member, in time order.
  final Map<String, List<SpaceTimelinePoint>> members;
}

/// Result of [Synheart.spaceTimeline].
class SpaceTimeline {
  const SpaceTimeline({
    required this.tier,
    required this.bucketMs,
    required this.series,
  });

  final SpaceTimelineTier tier;

  /// Bucket width in milliseconds.
  final int bucketMs;

  /// One entry per device.
  final List<SpaceTimelineSeries> series;

  /// Parses the envelope's `data`. Point arrays are read by the names in its
  /// `point` list, so a reordered or longer point keeps working.
  factory SpaceTimeline.fromMap(Map<String, dynamic> data) {
    final names =
        (data['point'] as List?)?.cast<Object?>() ??
        const ['bucket_start_ms', 'n', 'mean', 'min', 'max', 'mean_confidence'];
    int at(String name) => names.indexOf(name);
    final iStart = at('bucket_start_ms');
    final iN = at('n');
    final iMean = at('mean');
    final iMin = at('min');
    final iMax = at('max');
    final iConf = at('mean_confidence');

    double numAt(List<Object?> p, int i) =>
        i >= 0 && i < p.length && p[i] is num ? (p[i] as num).toDouble() : 0;

    SpaceTimelinePoint? point(Object? raw) {
      if (raw is! List) return null;
      final p = raw.cast<Object?>();
      if (iStart < 0 || iStart >= p.length || p[iStart] is! num) return null;
      return SpaceTimelinePoint(
        start: DateTime.fromMillisecondsSinceEpoch(
          (p[iStart] as num).toInt(),
          isUtc: true,
        ),
        count: numAt(p, iN).toInt(),
        mean: numAt(p, iMean),
        min: numAt(p, iMin),
        max: numAt(p, iMax),
        meanConfidence: numAt(p, iConf),
      );
    }

    final series = <SpaceTimelineSeries>[];
    for (final raw in (data['series'] as List?) ?? const []) {
      if (raw is! Map) continue;
      final members = <String, List<SpaceTimelinePoint>>{};
      final rawMembers = raw['members'];
      if (rawMembers is Map) {
        rawMembers.forEach((name, points) {
          if (name is! String || points is! List) return;
          members[name] = [
            for (final p in points)
              if (point(p) case final parsed?) parsed,
          ];
        });
      }
      series.add(
        SpaceTimelineSeries(
          origin: raw['origin']?.toString() ?? 'local',
          thisDevice: raw['this_device'] == true,
          members: members,
        ),
      );
    }

    return SpaceTimeline(
      tier: SpaceTimelineTier.parse(data['tier']),
      bucketMs: (data['bucket_ms'] as num?)?.toInt() ?? 0,
      series: series,
    );
  }
}
