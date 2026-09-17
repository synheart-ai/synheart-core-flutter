import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/src/models/behavior_event_input.dart';

/// Guards the wire contract of `synheart_core_push_behavior_event`.
///
/// Two classes of bug live here, and neither one produces an error:
///
///  * **A `0.0` where a `null` belongs.** The engine withholds a null and
///    renormalises it out of the feature set; a zero is a *measured* zero that
///    moves the score. Serializing unset fields as `0` fabricates evidence for
///    every head that reads the typing group.
///  * **A mis-spelled key.** The runtime's payload readers return `None` for a
///    key they don't recognise rather than failing the event, so `from_app_id`
///    instead of `from_app` costs the whole field silently. The expectations
///    below pin the keys to core-runtime's `behavior::engine_event` table.
void main() {
  group('TypingSessionData null contract', () {
    test('omits every unset field rather than defaulting it to zero', () {
      final json = const TypingSessionData(typingTapCount: 12).toJson();

      expect(json, {'typing_tap_count': 12});
      expect(json.containsKey('number_of_backspace'), isFalse);
      expect(json.containsKey('typing_speed_cpm'), isFalse);
      expect(json.containsKey('duration_sec'), isFalse);
    });

    test('keeps a genuinely measured zero', () {
      // Nobody backspaced in this window. That is a real observation and must
      // survive as 0, not vanish into "unmeasured".
      final json = const TypingSessionData(
        typingTapCount: 40,
        numberOfBackspace: 0,
        numberOfDelete: 0,
      ).toJson();

      expect(json['number_of_backspace'], 0);
      expect(json['number_of_delete'], 0);
    });

    test('emits the correction-rate inputs under the engine key names', () {
      // These two are what produce `typing.correction_rate`, which Focus and
      // CFI both read — a rename here blinds the friction index.
      final json = const TypingSessionData(
        numberOfBackspace: 3,
        numberOfDelete: 1,
      ).toJson();

      expect(
        json.keys,
        containsAll(['number_of_backspace', 'number_of_delete']),
      );
    });
  });

  group('BehaviorEventInput kinds and keys', () {
    test('typing is stamped at the window start and carries the session', () {
      final event = BehaviorEventInput.typing(
        1000,
        const TypingSessionData(durationSec: 4.2, typingTapCount: 9),
      );
      final json = event.toJson();

      expect(json['kind'], 'typing');
      expect(json['ts_ms'], 1000);
      expect(json['data'], {'duration_sec': 4.2, 'typing_tap_count': 9});
    });

    test('app_switch uses from_app / to_app, not the *_id suffixes', () {
      final json = BehaviorEventInput.appSwitch(
        5,
        fromApp: 'com.google.android.gm',
        toApp: 'com.slack',
      ).toJson();

      expect(json['data'], {
        'from_app': 'com.google.android.gm',
        'to_app': 'com.slack',
      });
    });

    test('notification uses source_app and a wire-valid action', () {
      final json = BehaviorEventInput.notification(
        7,
        action: InterruptionAction.opened,
        sourceApp: 'com.whatsapp',
      ).toJson();

      expect(json['data'], {'action': 'opened', 'source_app': 'com.whatsapp'});
    });

    test('an iOS notification with no observable action omits it', () {
      // iOS has no API that reports what the person did with a notification.
      // Omitting is the honest encoding; 'ignored' would be a guess.
      final json = BehaviorEventInput.notification(
        7,
        sourceApp: 'com.apple.mobilemail',
      ).toJson();

      expect(json['data'], {'source_app': 'com.apple.mobilemail'});
    });

    test('scroll carries all three fields when they are measured', () {
      final json = BehaviorEventInput.scroll(
        9,
        velocity: 1200.5,
        direction: ScrollDirection.down,
        directionReversal: true,
      ).toJson();

      expect(json['data'], {
        'velocity': 1200.5,
        'direction': 'down',
        'direction_reversal': true,
      });
    });

    test('a payload-less kind omits data entirely', () {
      expect(BehaviorEventInput.screenOff(3).toJson(), {
        'ts_ms': 3,
        'kind': 'screen_off',
        'value': 0.0,
      });
    });

    test('system_failure mirrors the duration into the legacy scalar', () {
      // The int-coded path carried the stall duration in `value`; the runtime
      // still reads it as the fallback, so both must agree.
      final json = BehaviorEventInput.systemFailure(
        11,
        durationSecs: 2.5,
      ).toJson();

      expect(json['value'], 2.5);
      expect(json['data'], {'duration_secs': 2.5});
    });

    test('every factory emits a kind the runtime translates', () {
      // Unknown kinds are dropped by `to_engine_event`, not defaulted — a
      // typo here would silently stop the event reaching the engine.
      const known = {
        'touch',
        'scroll',
        'swipe',
        'app_switch',
        'notification',
        'call',
        'typing',
        'screen_on',
        'screen_off',
        'task_success',
        'task_failure',
        'task_return',
        'task_abandonment',
        'system_failure',
      };
      final produced = <String>{
        BehaviorEventInput.touch(0).kind,
        BehaviorEventInput.scroll(0).kind,
        BehaviorEventInput.swipe(0).kind,
        BehaviorEventInput.appSwitch(0).kind,
        BehaviorEventInput.notification(0).kind,
        BehaviorEventInput.call(0).kind,
        BehaviorEventInput.typing(0, const TypingSessionData()).kind,
        BehaviorEventInput.screenOn(0).kind,
        BehaviorEventInput.screenOff(0).kind,
        BehaviorEventInput.taskSuccess(0).kind,
        BehaviorEventInput.taskFailure(0).kind,
        BehaviorEventInput.taskReturn(0).kind,
        BehaviorEventInput.taskAbandonment(0).kind,
        BehaviorEventInput.systemFailure(0, durationSecs: 1).kind,
      };

      expect(produced, known);
    });
  });
}
