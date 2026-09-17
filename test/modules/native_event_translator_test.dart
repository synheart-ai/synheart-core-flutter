import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_behavior/synheart_behavior.dart' as sb;
import 'package:synheart_core/src/modules/behavior/native_event_translator.dart';

/// Guards the native → engine translation.
///
/// The regression these exist for: the native collectors on both platforms
/// already emit `velocity`, `direction` and `direction_reversal` on a scroll,
/// but the SDK reduced that to a bare velocity and then the legacy int-coded
/// FFI reduced *that* to one double. Direction and reversal were captured and
/// thrown away before the engine saw them. Same story for the notification's
/// source app.
final _fixedTs = DateTime.utc(2026, 9, 7, 10, 15, 23, 456);

sb.BehaviorEvent native(
  sb.BehaviorEventType type,
  Map<String, dynamic> metrics,
) => sb.BehaviorEvent(
  eventId: 'e1',
  sessionId: 'current',
  timestamp: _fixedTs,
  eventType: type,
  metrics: metrics,
);

void main() {
  final tsMs = _fixedTs.millisecondsSinceEpoch;

  group('scroll keeps every captured field', () {
    test('direction and reversal survive the translation', () {
      final out = translateNativeBehaviorEvent(
        native(sb.BehaviorEventType.scroll, {
          'velocity': 842.0,
          'acceleration': 1200.0,
          'direction': 'down',
          'direction_reversal': true,
        }),
      );

      expect(out, isNotNull);
      expect(out!.kind, 'scroll');
      expect(out.tsMs, tsMs);
      expect(out.data, {
        'velocity': 842.0,
        'direction': 'down',
        'direction_reversal': true,
      });
    });

    test('an unmeasured velocity stays absent rather than becoming zero', () {
      final out = translateNativeBehaviorEvent(
        native(sb.BehaviorEventType.scroll, {'direction': 'up'}),
      );

      expect(out!.data, {'direction': 'up'});
      expect(out.data.containsKey('velocity'), isFalse);
    });

    test('an unrecognised direction is dropped, not guessed', () {
      final out = translateNativeBehaviorEvent(
        native(sb.BehaviorEventType.scroll, {'direction': 'sideways'}),
      );

      expect(out!.data.containsKey('direction'), isFalse);
    });
  });

  group('notification attribution', () {
    test('source_app and a real action both reach the engine', () {
      final out = translateNativeBehaviorEvent(
        native(sb.BehaviorEventType.notification, {
          'action': 'opened',
          'source': 'notification',
          'source_app': 'com.whatsapp',
        }),
      );

      expect(out!.kind, 'notification');
      expect(out.data, {'action': 'opened', 'source_app': 'com.whatsapp'});
    });

    test('"received" is not mapped onto a response action', () {
      // The engine's four actions describe what the person *did*. The
      // collector emits "received" on arrival, before it knows — mapping that
      // to `ignored` would assert a response 30s before the collector decides.
      final out = translateNativeBehaviorEvent(
        native(sb.BehaviorEventType.notification, {
          'action': 'received',
          'source_app': 'com.slack',
        }),
      );

      expect(out!.data, {'source_app': 'com.slack'});
    });

    test('an unattributable notification still records the arrival', () {
      final out = translateNativeBehaviorEvent(
        native(sb.BehaviorEventType.notification, {'action': 'ignored'}),
      );

      expect(out!.data, {'action': 'ignored'});
    });
  });

  group('taps and swipes', () {
    test('tap carries duration and long-press', () {
      final out = translateNativeBehaviorEvent(
        native(sb.BehaviorEventType.tap, {
          'tap_duration_ms': 420,
          'long_press': true,
          'x': 100.0,
          'y': 200.0,
        }),
      );

      // Coordinates are deliberately not forwarded — the engine has no field
      // for them and they are the most identifying thing in the payload.
      expect(out!.kind, 'touch');
      expect(out.data, {'duration_ms': 420, 'long_press': true});
    });

    test('swipe keeps direction alongside velocity', () {
      final out = translateNativeBehaviorEvent(
        native(sb.BehaviorEventType.swipe, {
          'velocity': 3100.0,
          'direction': 'left',
          'distance_px': 400.0,
        }),
      );

      expect(out!.data, {'velocity': 3100.0, 'direction': 'left'});
    });
  });

  group('kinds with no engine variant are dropped', () {
    test('a single keystroke is not fabricated into a typing session', () {
      // A native `typing` event is one keystroke; the engine's Typing variant
      // wants a windowed summary. Emitting one with every field null would be
      // an observation with no evidence behind it.
      expect(
        translateNativeBehaviorEvent(
          native(sb.BehaviorEventType.typing, const {}),
        ),
        isNull,
      );
    });

    test('clipboard is dropped', () {
      expect(
        translateNativeBehaviorEvent(
          native(sb.BehaviorEventType.clipboard, const {'action': 'copy'}),
        ),
        isNull,
      );
    });
  });

  group('app_switch', () {
    test('reports both ids when the platform can name them', () {
      final out = translateNativeBehaviorEvent(
        native(sb.BehaviorEventType.app_switch, {
          'from_app': 'com.google.android.gm',
          'to_app': 'com.slack',
        }),
      );

      expect(out!.data, {
        'from_app': 'com.google.android.gm',
        'to_app': 'com.slack',
      });
    });

    test('records the switch even with no identity available', () {
      // Today's collector reports only a background duration. The switch still
      // matters to the digital axis, so it is recorded without identity rather
      // than dropped.
      final out = translateNativeBehaviorEvent(
        native(sb.BehaviorEventType.app_switch, {
          'background_duration_ms': 4200,
        }),
      );

      expect(out!.kind, 'app_switch');
      expect(out.data, isEmpty);
    });
  });
}
