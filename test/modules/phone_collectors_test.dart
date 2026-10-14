import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/src/config/synheart_config.dart';
import 'package:synheart_core/src/config/synheart_mode.dart';
import 'package:synheart_core/src/modules/phone/phone_collectors.dart';

void main() {
  group('phone collectors emit nothing they did not measure', () {
    test('no source, no samples — in any of the four collectors', () async {
      final motion = MotionCollector();
      final screen = ScreenStateTracker();
      final apps = AppFocusTracker();
      final notifications = NotificationTracker();
      var emitted = 0;
      final subs = [
        motion.motionStream.listen((_) => emitted++),
        screen.screenStream.listen((_) => emitted++),
        apps.appSwitchStream.listen((_) => emitted++),
        notifications.notificationStream.listen((_) => emitted++),
      ];
      await motion.start();
      await screen.start();
      await apps.start();
      await notifications.start();
      // The old mocks fired every 100 ms (motion) and immediately (screen).
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(emitted, 0);
      for (final s in subs) {
        await s.cancel();
      }
      await motion.dispose();
      await screen.dispose();
      await apps.dispose();
      await notifications.dispose();
    });
  });

  group('resolvedEmitRawMotionSamples', () {
    test('off by default', () {
      expect(SynheartConfig().resolvedEmitRawMotionSamples, isFalse);
    });

    test('explicit opt-in turns it on', () {
      final cfg = SynheartConfig(
        behaviorConfig: const BehaviorConfig(emitRawMotionSamples: true),
      );
      expect(cfg.resolvedEmitRawMotionSamples, isTrue);
    });

    test('research mode turns it on', () {
      final cfg = SynheartConfig(mode: SynheartMode.research);
      expect(cfg.resolvedEmitRawMotionSamples, isTrue);
    });

    test('the single-visit research baseline turns it on', () {
      final cfg = SynheartConfig(researchBaseline: true);
      expect(cfg.resolvedEmitRawMotionSamples, isTrue);
    });
  });
}
