import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/src/modules/baselines/daily_score_ledger.dart';
import 'package:synheart_core/synheart_core.dart';

String _frame(List<String> readings) => jsonEncode({
  'axes': {
    'physiological': [
      for (final r in readings) {'name': r, 'score': 0.7},
    ],
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DailyScoreLedger.shouldQueue', () {
    const sleep = DailyScoreKind.sleep;

    test('queues anything when nothing was queued yet', () {
      expect(DailyScoreLedger().shouldQueue(sleep, 100, 80), isTrue);
    });

    test('never queues a night older than the last one queued', () {
      // The runtime holds one slot per kind: an older night would replace
      // the newer one and reach the cloud as today's score.
      final l = DailyScoreLedger()..noteQueued(sleep, 100, 80);
      expect(l.shouldQueue(sleep, 99, 80), isFalse);
      l.noteFrame(_frame(['sleep_score']));
      expect(l.shouldQueue(sleep, 99, 55), isFalse);
    });

    test('queues a newer night', () {
      final l = DailyScoreLedger()..noteQueued(sleep, 100, 80);
      expect(l.shouldQueue(sleep, 101, 80), isTrue);
    });

    test('does not re-queue a score this process already queued', () {
      // The runtime still holds it; another attach would only push the
      // night onto the sleep ring again.
      final l = DailyScoreLedger()..noteQueued(sleep, 100, 80);
      expect(l.shouldQueue(sleep, 100, 80), isFalse);
    });

    test('re-queues after a relaunch only if no frame carried it', () {
      // The runtime's copy died with the process.
      final undelivered = DailyScoreLedger()..noteQueued(sleep, 100, 80);
      final relaunched = DailyScoreLedger()
        ..loadJson(jsonDecode(jsonEncode(undelivered.toJson())));
      expect(relaunched.shouldQueue(sleep, 100, 80), isTrue);

      final delivered = DailyScoreLedger()
        ..noteQueued(sleep, 100, 80)
        ..noteFrame(_frame(['sleep_score']));
      final relaunched2 = DailyScoreLedger()
        ..loadJson(jsonDecode(jsonEncode(delivered.toJson())));
      expect(relaunched2.shouldQueue(sleep, 100, 80), isFalse);
    });

    test('queues a corrected score for the same night', () {
      final l = DailyScoreLedger()
        ..noteQueued(sleep, 100, 80)
        ..noteFrame(_frame(['sleep_score']));
      expect(l.shouldQueue(sleep, 100, 82), isTrue);
    });

    test('kinds are independent', () {
      final l = DailyScoreLedger()
        ..noteQueued(DailyScoreKind.recovery, 100, 60)
        ..noteFrame(_frame(['recovery']));
      expect(l.shouldQueue(DailyScoreKind.recovery, 100, 60), isFalse);
      expect(l.shouldQueue(DailyScoreKind.readiness, 100, 60), isTrue);
      expect(l.shouldQueue(DailyScoreKind.sleep, 99, 60), isTrue);
    });
  });

  group('DailyScoreLedger.noteFrame', () {
    test('reports whether a frame changed anything', () {
      final l = DailyScoreLedger()..noteQueued(DailyScoreKind.sleep, 100, 80);
      expect(l.noteFrame(_frame(['hr_resting'])), isFalse);
      expect(l.noteFrame(_frame(['sleep_score'])), isTrue);
      expect(l.noteFrame(_frame(['sleep_score'])), isFalse);
    });

    test('marks only the kinds the frame carries', () {
      final l = DailyScoreLedger()
        ..noteQueued(DailyScoreKind.sleep, 100, 80)
        ..noteQueued(DailyScoreKind.recovery, 100, 60)
        ..noteFrame(_frame(['recovery', 'hr_resting']));
      expect(l.lastDelivered(DailyScoreKind.recovery), isTrue);
      expect(l.lastDelivered(DailyScoreKind.sleep), isFalse);
    });

    test('ignores a reading name outside axes.physiological', () {
      final l = DailyScoreLedger()..noteQueued(DailyScoreKind.sleep, 100, 80);
      l.noteFrame(
        jsonEncode({
          'axes': {
            'affect': [
              {'name': 'sleep_score'},
            ],
          },
        }),
      );
      expect(l.lastDelivered(DailyScoreKind.sleep), isFalse);
    });

    test('tolerates malformed frames', () {
      final l = DailyScoreLedger()..noteQueued(DailyScoreKind.sleep, 100, 80);
      l.noteFrame('{"sleep_score": not json');
      l.noteFrame('[]');
      expect(l.lastDelivered(DailyScoreKind.sleep), isFalse);
    });
  });

  group('DailyScoreLedger persistence', () {
    test('round-trips through toJson / loadJson', () {
      final a = DailyScoreLedger()
        ..noteQueued(DailyScoreKind.sleep, 100, 80)
        ..noteQueued(DailyScoreKind.readiness, 99, null)
        ..noteFrame(_frame(['sleep_score']));
      final b = DailyScoreLedger()
        ..loadJson(jsonDecode(jsonEncode(a.toJson())));
      expect(b.lastQueuedDay(DailyScoreKind.sleep), 100);
      expect(b.lastDelivered(DailyScoreKind.sleep), isTrue);
      expect(b.lastQueuedDay(DailyScoreKind.readiness), 99);
      expect(b.lastDelivered(DailyScoreKind.readiness), isFalse);
      expect(b.shouldQueue(DailyScoreKind.sleep, 100, 80), isFalse);
    });

    test('a missing or malformed blob loads empty', () {
      final l = DailyScoreLedger()..noteQueued(DailyScoreKind.sleep, 1, 1);
      l.loadJson(null);
      expect(l.lastQueuedDay(DailyScoreKind.sleep), isNull);
      l.loadJson({
        'sleep_score': {'day': 'x'},
      });
      expect(l.lastQueuedDay(DailyScoreKind.sleep), isNull);
    });

    test('Baselines carries the ledger in its persisted state', () {
      Baselines.reset();
      Baselines.loadRecoveryStateJson(
        jsonEncode({
          'daily_upload_ledger': {
            'sleep_score': {'day': 100, 'score': 80, 'delivered': true},
          },
        }),
      );
      final exported =
          jsonDecode(Baselines.exportRecoveryStateJson())
              as Map<String, dynamic>;
      expect(exported['daily_upload_ledger'], {
        'sleep_score': {'day': 100, 'score': 80, 'delivered': true},
      });
      Baselines.reset();
      final cleared =
          jsonDecode(Baselines.exportRecoveryStateJson())
              as Map<String, dynamic>;
      expect(cleared['daily_upload_ledger'], isEmpty);
    });
  });
}
