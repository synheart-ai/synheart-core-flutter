import 'package:synheart_behavior/synheart_behavior.dart' as sb;

import '../../models/behavior_event_input.dart';

/// Translates a `synheart_behavior` native event into the engine's rich form.
///
/// ## What this exists to stop
///
/// The native collectors capture more than the engine was receiving. Android's
/// `GestureCollector` emits `velocity`, `direction` and `direction_reversal`
/// on every scroll, and iOS's emits the same four keys — but the SDK's own
/// conversion reduced a scroll to a bare velocity scalar, and then the legacy
/// `push_behavior(ts, code, value)` reduced that to one `double`. Direction and
/// reversal were captured on both platforms and discarded before the engine
/// ever saw them. The same held for the notification source app and both app
/// ids on an app switch.
///
/// This function keeps the payload intact all the way to
/// `synheart_core_push_behavior_event`.
///
/// ## Absent is not zero
///
/// Every field is forwarded only when the native side actually reported it.
/// A missing velocity stays missing rather than becoming `0.0`, because the
/// engine withholds a null and renormalises it out whereas a zero is a
/// measured stillness that moves the score.
///
/// Returns `null` for an event the engine has no variant for, so the caller
/// skips the push entirely rather than inventing one.
BehaviorEventInput? translateNativeBehaviorEvent(sb.BehaviorEvent event) {
  final tsMs = _timestampMs(event.timestamp);
  final m = event.metrics;

  switch (event.eventType) {
    case sb.BehaviorEventType.tap:
      return BehaviorEventInput.touch(
        tsMs,
        durationMs: _int(m['tap_duration_ms']),
        longPress: _bool(m['long_press']),
      );

    case sb.BehaviorEventType.scroll:
      return BehaviorEventInput.scroll(
        tsMs,
        velocity: _double(m['velocity']),
        direction: _scrollDirection(m['direction']),
        directionReversal: _bool(m['direction_reversal']),
      );

    case sb.BehaviorEventType.swipe:
      return BehaviorEventInput.swipe(
        tsMs,
        velocity: _double(m['velocity']),
        direction: _scrollDirection(m['direction']),
      );

    case sb.BehaviorEventType.notification:
      return BehaviorEventInput.notification(
        tsMs,
        action: _interruptionAction(m['action']),
        sourceApp: _string(m['source_app']),
      );

    case sb.BehaviorEventType.call:
      return BehaviorEventInput.call(
        tsMs,
        action: _interruptionAction(m['action']),
      );

    case sb.BehaviorEventType.app_switch:
      // Android can name both sides once `UsageStatsManager` is wired; today
      // the collector reports only a background duration, so both ids come
      // through null and the engine records the switch without identity. iOS
      // has no API for this at all.
      return BehaviorEventInput.appSwitch(
        tsMs,
        fromApp: _string(m['from_app']),
        toApp: _string(m['to_app']),
      );

    case sb.BehaviorEventType.typing:
      // Deliberately not translated here.
      //
      // A native `typing` event is a single keystroke notification, and the
      // engine's `Typing` variant expects a windowed `TypingSessionData`
      // summary. Mapping one keystroke onto that variant would emit a session
      // whose every field is null — worse than nothing, because it lands in
      // the typing feature group as an observation with no evidence. The host
      // aggregates keystrokes into 10 s micro-windows and pushes
      // `BehaviorEventInput.typing` itself; the raw keystroke keeps taking the
      // legacy touch path so the two are never double-counted.
      return null;

    case sb.BehaviorEventType.clipboard:
      // No engine variant. Dropped rather than approximated.
      return null;

    // Forward-compat: a newer synheart_behavior may add variants this SDK does
    // not map. Unknown kinds are dropped by the runtime anyway, so guessing
    // here would only fabricate interaction evidence.
    // ignore: unreachable_switch_default
    default:
      return null;
  }
}

/// Parse the native ISO-8601 timestamp, falling back to now.
///
/// The fallback matters: the engine's `rr`/`hr`/`accel` channels reject a
/// backwards timestamp, but `behavior` is counted-and-accepted, so a bad parse
/// here would land a mis-stamped event rather than being rejected. Now is the
/// least-wrong stamp for an event we are handling this instant.
int _timestampMs(String iso) =>
    DateTime.tryParse(iso)?.millisecondsSinceEpoch ??
    DateTime.now().millisecondsSinceEpoch;

double? _double(Object? v) => v is num ? v.toDouble() : null;

int? _int(Object? v) => v is num ? v.toInt() : null;

bool? _bool(Object? v) => v is bool ? v : null;

String? _string(Object? v) => v is String && v.isNotEmpty ? v : null;

ScrollDirection? _scrollDirection(Object? v) => switch (v) {
  'up' => ScrollDirection.up,
  'down' => ScrollDirection.down,
  'left' => ScrollDirection.left,
  'right' => ScrollDirection.right,
  _ => null,
};

/// Map the native action string onto the engine's four-value vocabulary.
///
/// `received` is intentionally unmapped. The native collectors emit it when a
/// notification arrives and the person has not yet done anything, which is not
/// one of the engine's actions — those describe a *response*. Sending `null`
/// records the arrival with an unknown response, which is what actually
/// happened; picking `ignored` would assert a response 30 seconds before the
/// collector decides whether it was one.
InterruptionAction? _interruptionAction(Object? v) => switch (v) {
  'ignored' => InterruptionAction.ignored,
  'opened' => InterruptionAction.opened,
  'answered' => InterruptionAction.answered,
  'dismissed' => InterruptionAction.dismissed,
  _ => null,
};
