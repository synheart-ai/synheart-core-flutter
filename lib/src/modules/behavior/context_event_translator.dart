import 'package:synheart_behavior/synheart_behavior.dart' as sb;

import '../../models/behavior_event_input.dart' show ScrollDirection;
import '../../models/context_event_input.dart';

/// Translates a `synheart_behavior` native event into a **context** event.
///
/// ## What this exists to feed
///
/// The context window computes the person-relative deviations that Cognitive
/// Load's friction index (CFI) actually reads, and it computes them from
/// keyboard / pointer / shortcut events on its own buffer — nothing else. Of
/// CFI's six specified sub-components only three are wired in the engine at
/// all, and all three come from here:
///
/// | CFI sub-component | context feature | needs |
/// |---|---|---|
/// | hesitation | `pause_elevation` | any physical input (idle clock) |
/// | correction | `err_elevation` = `N_corr / N_key` | **keyboard** events, both corrections *and* the keystrokes they corrected |
/// | scroll instability | `scroll_deviation` | `Mouse`/`Scroll` with a direction |
///
/// Before this existed the mobile stack pushed no context events at all, so
/// those three deviations were structurally zero on every window and CFI had no
/// inputs on any platform. That is separate from — and additional to — the
/// behaviour channel, which feeds the interaction adapter and session-runtime.
/// Both are needed; neither substitutes for the other.
///
/// ## Why a tap is deliberately dropped
///
/// Android's `InputSignalCollector` emits **every keystroke as
/// `eventType: "tap"`** (it has no key-event visibility, so a keystroke and a
/// screen tap are indistinguishable at this boundary). Forwarding taps as
/// `LeftClick` would therefore be wrong twice over:
///
/// * `N_click` inflates with every character typed, and
/// * `N_key` — the *denominator* of `err_rate` — stays at zero while a host's
///   text-field layer pushes corrections, spiking the error rate to its
///   ceiling on the first backspace.
///
/// The runtime states the rule directly: "A tap that is not text entry has no
/// context event — it still counts as interaction through `record_interaction`."
/// So taps are dropped here and reach the engine on the behaviour channel only.
///
/// **Keyboard evidence enters exclusively from the host's text layer**, via
/// [ContextEventInput.textChange] / [ContextEventInput.keyboard], where
/// insertions and deletions are actually distinguishable. That gives one source
/// per event class and no way to double-count.
///
/// Returns `null` for anything with no honest context representation, so the
/// caller skips the push rather than inventing evidence.
ContextEventInput? translateNativeContextEvent(sb.BehaviorEvent event) {
  final tsMs = _timestampMs(event.timestamp);
  final m = event.metrics;

  switch (event.eventType) {
    case sb.BehaviorEventType.scroll:
      // Direction is the load-bearing field: the window uses it only to count
      // *reversals* (`R_scrollChange`), so a scroll with no direction adds to
      // the rate but can never contribute instability. Native reports it on
      // both platforms.
      return ContextEventInput.mouse(
        tsMs,
        MouseEventType.scroll,
        scrollDirection: _scrollDirection(m['direction']),
        scrollMagnitude: _scrollMagnitude(_double(m['velocity'])),
      );

    case sb.BehaviorEventType.swipe:
      // A swipe is a pointer displacement, not a scroll: it carries a distance
      // and has no scroll axis to reverse. `delta_magnitude` is a magnitude,
      // never a coordinate.
      return ContextEventInput.mouse(
        tsMs,
        MouseEventType.move,
        deltaMagnitude: _double(m['velocity']),
      );

    case sb.BehaviorEventType.typing:
      // iOS only — see the class doc for why Android never produces this.
      // A native typing event is one keystroke and carries no insert/delete
      // classification, so it is a plain tap: reporting it as a correction
      // would fabricate the numerator of `err_rate`.
      return ContextEventInput.keyboard(tsMs, KeyboardEventType.typingTap);

    case sb.BehaviorEventType.tap:
      // Keystroke-ambiguous on Android. Dropped on purpose — see class doc.
      return null;

    case sb.BehaviorEventType.clipboard:
      // The native event reports that the clipboard was touched, not whether it
      // was a copy, a cut or a paste. `ShortcutType` needs one of the three and
      // they are not interchangeable — `Cut` is destructive, `Copy` is not — so
      // this is dropped rather than guessed. A host that knows which action
      // occurred should push `ContextEventInput.shortcut` itself.
      return null;

    case sb.BehaviorEventType.notification:
    case sb.BehaviorEventType.call:
    case sb.BehaviorEventType.app_switch:
      // Interruptions and attention boundaries, not input evidence. They reach
      // the engine on the behaviour channel, where they belong.
      return null;

    // Forward-compat: a newer synheart_behavior may add variants this SDK does
    // not map. Dropping is the safe default — an unrecognised event guessed
    // into a keyboard or pointer class corrupts a rate denominator.
    // ignore: unreachable_switch_default
    default:
      return null;
  }
}

/// Parse the native ISO-8601 timestamp, falling back to now.
///
/// Matches `translateNativeBehaviorEvent`: the context channel is
/// counted-and-accepted rather than gated on monotonicity, so a bad parse would
/// land a mis-stamped event rather than being rejected. Now is the least-wrong
/// stamp for an event being handled this instant.
int _timestampMs(String iso) =>
    DateTime.tryParse(iso)?.millisecondsSinceEpoch ??
    DateTime.now().millisecondsSinceEpoch;

double? _double(Object? v) => v is num ? v.toDouble() : null;

ScrollDirection? _scrollDirection(Object? v) => switch (v) {
  'up' => ScrollDirection.up,
  'down' => ScrollDirection.down,
  'left' => ScrollDirection.left,
  'right' => ScrollDirection.right,
  _ => null,
};

// Scroll-velocity bucket boundaries, in logical pixels/second.
//
// PRIOR, not spec. The context runtime takes a three-level bucket
// (Small = 1, Medium = 2, Large = 3 by weight) and the RulePack does not
// prescribe where a touch fling falls between them — the weights were derived
// on desktop wheel notches. These are ordinary Flutter fling velocities split
// into thirds and are calibration-pending: they affect total scroll *distance*
// (`d_scroll`), not the direction-change ratio that drives scroll instability,
// so a wrong bucket costs magnitude resolution rather than a wrong reversal
// count. Revisit against a labelled mobile capture.
const double _scrollMediumVelocity = 300.0;
const double _scrollLargeVelocity = 1200.0;

/// Bucket a native fling velocity. An unreported velocity stays absent rather
/// than defaulting to [ScrollMagnitude.small] — a declared `Small` is a
/// measured claim, and the runtime renormalises a `null` out instead.
ScrollMagnitude? _scrollMagnitude(double? velocity) {
  if (velocity == null) return null;
  final v = velocity.abs();
  if (v >= _scrollLargeVelocity) return ScrollMagnitude.large;
  if (v >= _scrollMediumVelocity) return ScrollMagnitude.medium;
  return ScrollMagnitude.small;
}
