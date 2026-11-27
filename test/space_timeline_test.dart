import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/synheart_core.dart';

void main() {
  group('SpaceTimeline.fromMap', () {
    final data = <String, dynamic>{
      'tier': 'half_hour',
      'bucket_ms': 1800000,
      'point': [
        'bucket_start_ms',
        'n',
        'mean',
        'min',
        'max',
        'mean_confidence',
      ],
      'series': [
        {
          'origin': 'dev_7f3a',
          'this_device': true,
          'members': {
            'focus': [
              [1795564800000, 30, 0.62, 0.41, 0.80, 0.71],
              [1795566600000, 12, 0.5, 0.3, 0.7, 0.6],
            ],
          },
        },
        {
          'origin': 'dev_91bc',
          'this_device': false,
          'members': {
            'stress': [
              [1795564800000, 4, 0.18, 0.05, 0.33, 0.88],
            ],
          },
        },
      ],
    };

    test('reads tier, bucket and one series per device', () {
      final t = SpaceTimeline.fromMap(data);
      expect(t.tier, SpaceTimelineTier.halfHour);
      expect(t.bucketMs, 1800000);
      expect(t.series.map((s) => s.origin), ['dev_7f3a', 'dev_91bc']);
      expect(t.series.first.thisDevice, isTrue);
      expect(t.series.last.thisDevice, isFalse);
    });

    test('reads a point by the names in `point`', () {
      final p = SpaceTimeline.fromMap(
        data,
      ).series.first.members['focus']!.first;
      expect(p.start, DateTime.utc(2026, 11, 25));
      expect(p.count, 30);
      expect(p.mean, 0.62);
      expect(p.min, 0.41);
      expect(p.max, 0.80);
      expect(p.meanConfidence, 0.71);
    });

    test('a reordered point list still maps each value', () {
      final reordered = <String, dynamic>{
        'tier': 'minute',
        'bucket_ms': 60000,
        'point': [
          'mean',
          'bucket_start_ms',
          'n',
          'min',
          'max',
          'mean_confidence',
        ],
        'series': [
          {
            'origin': 'local',
            'this_device': true,
            'members': {
              'focus': [
                [0.4, 1795564800000, 1, 0.4, 0.4, 0.9],
              ],
            },
          },
        ],
      };
      final p = SpaceTimeline.fromMap(
        reordered,
      ).series.single.members['focus']!.single;
      expect(p.mean, 0.4);
      expect(p.count, 1);
      expect(p.start.millisecondsSinceEpoch, 1795564800000);
    });

    test('skips malformed points and keeps a gap, never a zero', () {
      final t = SpaceTimeline.fromMap({
        'tier': 'day',
        'bucket_ms': 86400000,
        'series': [
          {
            'origin': 'dev_a',
            'this_device': true,
            'members': {
              'focus': [
                'not a point',
                [null, 1, 0.5, 0.5, 0.5, 0.5],
                [1795564800000, 2, 0.5, 0.4, 0.6, 0.7],
              ],
            },
          },
        ],
      });
      expect(t.series.single.members['focus'], hasLength(1));
    });

    test('an unknown tier parses as unknown', () {
      expect(
        SpaceTimeline.fromMap({
          'tier': 'week',
          'bucket_ms': 1,
          'series': [],
        }).tier,
        SpaceTimelineTier.unknown,
      );
    });
  });
}
