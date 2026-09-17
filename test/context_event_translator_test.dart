import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_behavior/synheart_behavior.dart' as sb;
import 'package:synheart_core/src/modules/behavior/context_event_translator.dart';

sb.BehaviorEvent _event(
  sb.BehaviorEventType type, {
  Map<String, dynamic> metrics = const <String, dynamic>{},
}) => sb.BehaviorEvent(
  sessionId: 'sess',
  // The constructor takes a DateTime and stores it as an ISO-8601 string;
  // the translator parses it back. Pinning an exact instant keeps the
  // round-trip honest.
  timestamp: DateTime.fromMillisecondsSinceEpoch(1712345678000, isUtc: true),
  eventType: type,
  metrics: metrics,
);

void main() {
  group('translateNativeContextEvent', () {
    test('a tap is dropped — it is keystroke-ambiguous on Android', () {
      // Android's InputSignalCollector emits every keystroke as `tap`, so
      // forwarding taps as LeftClick would inflate N_click with typing AND
      // leave N_key (the denominator of err_rate = N_corr / N_key) at zero
      // while the host pushes corrections. The runtime states the rule: "a tap
      // that is not text entry has no context event". Keyboard evidence comes
      // from the host's text layer, which can actually classify it.
      expect(
        translateNativeContextEvent(_event(sb.BehaviorEventType.tap)),
        isNull,
      );
    });

    test('a scroll becomes a Mouse/Scroll carrying its direction', () {
      final result = translateNativeContextEvent(
        _event(
          sb.BehaviorEventType.scroll,
          metrics: <String, dynamic>{'direction': 'down', 'velocity': 500.0},
        ),
      );

      final fields = result!.toJson()['Mouse'] as Map<String, dynamic>;
      expect(fields['event_type'], 'Scroll');
      // Direction is load-bearing: the window uses it only to count reversals,
      // so a scroll without one adds to the rate but can never contribute
      // scroll instability.
      expect(fields['scroll_direction'], 'Down');
      expect(fields['scroll_magnitude'], 'Medium');
      expect(fields['delta_magnitude'], isNull);
    });

    test('scroll velocity buckets across the three magnitudes', () {
      String? magnitudeFor(double velocity) {
        final e = translateNativeContextEvent(
          _event(
            sb.BehaviorEventType.scroll,
            metrics: <String, dynamic>{'direction': 'up', 'velocity': velocity},
          ),
        )!;
        return (e.toJson()['Mouse'] as Map<String, dynamic>)['scroll_magnitude']
            as String?;
      }

      expect(magnitudeFor(50.0), 'Small');
      expect(magnitudeFor(600.0), 'Medium');
      expect(magnitudeFor(2000.0), 'Large');
      // Sign is irrelevant — direction is a separate field.
      expect(magnitudeFor(-2000.0), 'Large');
    });

    test('an unreported velocity leaves magnitude absent, not Small', () {
      final result = translateNativeContextEvent(
        _event(
          sb.BehaviorEventType.scroll,
          metrics: <String, dynamic>{'direction': 'up'},
        ),
      );

      final fields = result!.toJson()['Mouse'] as Map<String, dynamic>;
      // A declared `Small` is a measured claim; the runtime renormalises a
      // null out instead of counting it as the lightest possible scroll.
      expect(fields['scroll_magnitude'], isNull);
      expect(fields['scroll_direction'], 'Up');
    });

    test('a swipe becomes a Mouse/Move carrying a distance', () {
      final result = translateNativeContextEvent(
        _event(
          sb.BehaviorEventType.swipe,
          metrics: <String, dynamic>{'velocity': 800.0, 'direction': 'left'},
        ),
      );

      final fields = result!.toJson()['Mouse'] as Map<String, dynamic>;
      // A swipe is a displacement, not a scroll: it has no axis to reverse, so
      // it must not land in the scroll-instability counter.
      expect(fields['event_type'], 'Move');
      expect(fields['delta_magnitude'], 800.0);
      expect(fields['scroll_direction'], isNull);
    });

    test('a native typing event becomes a plain TypingTap', () {
      // iOS only. It carries no insert/delete classification, so reporting it
      // as a correction would fabricate the numerator of err_rate.
      final result = translateNativeContextEvent(
        _event(sb.BehaviorEventType.typing),
      );

      final fields = result!.toJson()['Keyboard'] as Map<String, dynamic>;
      expect(fields['event_type'], 'TypingTap');
      expect(fields['is_key_down'], isTrue);
    });

    test('interruptions and attention boundaries are not input evidence', () {
      for (final type in <sb.BehaviorEventType>[
        sb.BehaviorEventType.notification,
        sb.BehaviorEventType.call,
        sb.BehaviorEventType.app_switch,
        // Clipboard says the clipboard was touched, not whether it was a copy,
        // a cut or a paste — and Cut is destructive where Copy is not. Dropped
        // rather than guessed.
        sb.BehaviorEventType.clipboard,
      ]) {
        expect(
          translateNativeContextEvent(_event(type)),
          isNull,
          reason: '$type should not produce a context event',
        );
      }
    });

    test('the timestamp survives the hop', () {
      final result = translateNativeContextEvent(
        _event(
          sb.BehaviorEventType.scroll,
          metrics: <String, dynamic>{'direction': 'down'},
        ),
      );
      expect(result!.tsMs, 1712345678000);
    });
  });
}
