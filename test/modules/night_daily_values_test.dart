import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/src/models/daily_metric.dart';
import 'package:synheart_core/src/models/recovery_score.dart';
import 'package:synheart_core/src/modules/baselines/baselines.dart';

void main() {
  final wake = DateTime.utc(2026, 11, 2);
  final today = DateTime(2026, 11, 3);

  Map<String, double> values(
    OvernightPhysiology o, {
    DateTime? on,
    double? midpointH,
  }) => Baselines.nightDailyValues(
    overnight: o,
    wakeDate: on ?? wake,
    today: today,
    midpointH: midpointH,
  );

  group('heart rate', () {
    test('a resting-HR record and the mean HR asleep stay apart', () {
      final v = values(
        const OvernightPhysiology(
          overnightHrBpm: 54,
          asleepHrBpm: 54,
          restingHrBpm: 58,
        ),
      );
      expect(v[DailyMetric.overnightHrBpm], 54);
      expect(v[DailyMetric.restingHrBpm], 58);
    });

    test('one overnight figure goes to both', () {
      final v = values(const OvernightPhysiology(overnightHrBpm: 55));
      expect(v[DailyMetric.overnightHrBpm], 55);
      expect(v[DailyMetric.restingHrBpm], 55);
    });

    test('a daytime resting HR alone fills resting only', () {
      final v = values(
        const OvernightPhysiology(overnightHrBpm: 61, restingHrBpm: 61),
      );
      expect(v.containsKey(DailyMetric.overnightHrBpm), isFalse);
      expect(v[DailyMetric.restingHrBpm], 61);
    });

    test('WHOOP-style figure measured asleep goes to both', () {
      final v = values(
        const OvernightPhysiology(
          overnightHrBpm: 50,
          restingHrBpm: 50,
          asleepHrBpm: 50,
        ),
      );
      expect(v[DailyMetric.overnightHrBpm], 50);
      expect(v[DailyMetric.restingHrBpm], 50);
    });
  });

  group('steps', () {
    test('pushed for a day that is over', () {
      final v = values(const OvernightPhysiology(stepsCount: 8000));
      expect(v[DailyMetric.stepsCount], 8000);
    });

    test('not pushed for today, whose total is still growing', () {
      final v = values(
        const OvernightPhysiology(stepsCount: 1200),
        on: DateTime.utc(2026, 11, 3),
      );
      expect(v.containsKey(DailyMetric.stepsCount), isFalse);
    });
  });

  test('a midnight midpoint is a value; a missing one is not pushed', () {
    expect(
      values(
        const OvernightPhysiology(),
        midpointH: 0,
      )[DailyMetric.sleepMidpointH],
      0,
    );
    expect(
      values(
        const OvernightPhysiology(),
      ).containsKey(DailyMetric.sleepMidpointH),
      isFalse,
    );
  });
}
