/// Typed payloads for `synheart_core_push_context_event`.
///
/// This is the **context evidence** channel, and it is a different thing from
/// [BehaviorEventInput] even though a single user action often produces one of
/// each. The two land in different places inside the runtime and are consumed
/// by different code:
///
/// | Channel | Runtime entry | Feeds |
/// |---|---|---|
/// | [BehaviorEventInput] via `push_behavior_event` | `record_interaction` | the interaction adapter (digital axes) **and** session-runtime's behavioural feature group |
/// | [ContextEventInput] via `push_context_event` | `record_context_event_json` | the person-relative context window — `context.deviation.*`, which is where CFI's wired sub-components come from |
///
/// Sending both for one action is **not** a double count: they are separate
/// buffers with separate consumers. Sending the *same* event twice on the
/// *same* channel is, and the runtime says so explicitly — `record_event` and
/// `record_desktop_event` write to one buffer, so a host must feed each event
/// exactly once.
///
/// ## Why this type exists
///
/// The runtime deserializes this channel into `synheart_context_runtime::
/// DesktopEvent` — a privacy-preserving keyboard / pointer / shortcut event.
/// It is **not** an app-category channel: there is no app-category variant, and
/// a `{ts_ms, app_id, category}` object does not parse. App identity travels on
/// [BehaviorEventInput.appForeground] instead.
///
/// A payload that does not parse returns non-zero and buffers nothing, and the
/// failure is indistinguishable from "this runtime was built without the
/// `app-context` cargo feature" (which compiles the symbol as an inert stub
/// that always returns `1`). So the wire shape is not a place to guess — the
/// factories below are pinned to the runtime's documented form by
/// `test/context_event_input_test.dart`.
///
/// ## Wire shape
///
/// An externally-tagged enum — the variant name is the single top-level key:
///
/// ```json
/// { "Keyboard": { "timestamp_ms": 1712345678000, "is_key_down": true, "event_type": "TypingTap" } }
/// { "Mouse":    { "timestamp_ms": 1712345679000, "event_type": "Scroll", "delta_magnitude": null,
///                 "scroll_direction": "Down", "scroll_magnitude": "Medium" } }
/// { "Shortcut": { "timestamp_ms": 1712345680000, "shortcut_type": "Undo" } }
/// ```
///
/// Note the explicit `"delta_magnitude": null`. Unlike [BehaviorEventInput],
/// which strips null keys, this channel emits **every** field of the variant it
/// sends — the Rust side is a struct variant, not a bag of optionals, and an
/// omitted key is a parse risk rather than a declared absence. Absence is
/// expressed as `null`, which deserializes to `None`.
///
/// ## Privacy invariant
///
/// No typed characters, key codes, cursor coordinates, window titles, URLs or
/// screen content are representable here, by construction. The enums below are
/// the entire vocabulary: a *classification* of the keystroke, never its
/// content. Do not smuggle content into a field.
library;

import 'behavior_event_input.dart' show ScrollDirection;

/// The context channel spells directions `Up`/`Down`/`Left`/`Right`, where the
/// behaviour channel spells them lowercase. One concept, two wire vocabularies —
/// so the SDK keeps one public [ScrollDirection] and maps here rather than
/// exporting a near-identical second enum for callers to pick between.
extension _ContextScrollDirectionWire on ScrollDirection {
  String get contextWire => switch (this) {
    ScrollDirection.up => 'Up',
    ScrollDirection.down => 'Down',
    ScrollDirection.left => 'Left',
    ScrollDirection.right => 'Right',
  };
}

/// Keyboard event classification.
///
/// Everything except [modifierKey] and [functionKey] counts toward `N_key`,
/// the **denominator** of the context window's error rate
/// (`err_rate = N_corr / N_key`). [backspace] and [delete] additionally count
/// toward `N_corr`, the numerator.
///
/// That relationship is why a host must not route non-text taps here: pushing
/// corrections without the keystrokes they corrected leaves `N_key` at zero and
/// spikes `err_rate` to its ceiling.
enum KeyboardEventType {
  /// A character-producing keystroke. The ordinary case.
  typingTap('TypingTap'),

  /// Arrow keys, home/end, page up/down.
  navigationKey('NavigationKey'),

  /// Counts as a correction.
  backspace('Backspace'),

  /// Counts as a correction. A soft keyboard usually cannot tell this from
  /// [backspace]; both count identically, so report [backspace] and do not
  /// invent the split.
  delete('Delete'),

  enter('Enter'),
  tab('Tab'),
  escape('Escape'),
  modifierKey('ModifierKey'),
  functionKey('FunctionKey');

  final String wire;
  const KeyboardEventType(this.wire);
}

/// Pointer event classification.
///
/// On a touch host: a scroll gesture is [scroll], a fling or drag is [move],
/// and a tap that *is* a discrete pointer action is [leftClick]. A tap that is
/// text entry is not a pointer event at all — send [KeyboardEventType.typingTap]
/// instead, or the keystroke inflates `N_click` and never reaches `N_key`.
enum MouseEventType {
  /// Carries `delta_magnitude` — a distance, never a coordinate.
  move('Move'),
  leftClick('LeftClick'),
  rightClick('RightClick'),

  /// Carries `scroll_direction` and `scroll_magnitude`. Direction is used only
  /// to count *changes* of direction (`R_scrollChange`); absolute position is
  /// never represented.
  scroll('Scroll');

  final String wire;
  const MouseEventType(this.wire);
}

/// Coarse scroll magnitude bucket. Weighted `Small` = 1, `Medium` = 2,
/// `Large` = 3 when the window accumulates total scroll distance.
enum ScrollMagnitude {
  small('Small'),
  medium('Medium'),
  large('Large');

  final String wire;
  const ScrollMagnitude(this.wire);
}

/// Recognised editing shortcut. On a touch host these arrive as long-press
/// menu actions or toolbar taps rather than key chords.
enum ShortcutType {
  copy('Copy'),
  paste('Paste'),
  cut('Cut'),

  /// Counts toward `N_corr` alongside backspace and delete.
  undo('Undo'),

  redo('Redo'),
  selectAll('SelectAll'),
  save('Save');

  final String wire;
  const ShortcutType(this.wire);
}

/// One privacy-preserving context event, ready for
/// [Synheart.pushContextEvent].
///
/// Construct via the three factories. There is no raw constructor on purpose:
/// the top-level variant key and the field set that goes with it are the part a
/// host cannot get wrong and still see a useful error.
class ContextEventInput {
  /// The externally-tagged variant name — `Keyboard`, `Mouse` or `Shortcut`.
  final String variant;

  /// The variant's fields, complete. Absent values are present as `null`.
  final Map<String, dynamic> fields;

  const ContextEventInput._(this.variant, this.fields);

  /// A keystroke, classified but never identified.
  ///
  /// [isKeyDown] distinguishes a press from a release: only presses count as
  /// physical input for the window's idle clock, because a release is the tail
  /// of a press already counted. A host that sees only committed text changes
  /// (a Flutter `TextField`, most soft keyboards) has no release to report and
  /// should leave this `true`.
  factory ContextEventInput.keyboard(
    int tsMs,
    KeyboardEventType eventType, {
    bool isKeyDown = true,
  }) => ContextEventInput._('Keyboard', <String, dynamic>{
    'timestamp_ms': tsMs,
    'is_key_down': isKeyDown,
    'event_type': eventType.wire,
  });

  /// A pointer event.
  ///
  /// Pass [deltaMagnitude] for [MouseEventType.move] (a distance in logical
  /// pixels, not a coordinate), and [scrollDirection] / [scrollMagnitude] for
  /// [MouseEventType.scroll]. Unused fields are emitted as `null` rather than
  /// omitted — see the library doc.
  factory ContextEventInput.mouse(
    int tsMs,
    MouseEventType eventType, {
    double? deltaMagnitude,
    ScrollDirection? scrollDirection,
    ScrollMagnitude? scrollMagnitude,
  }) => ContextEventInput._('Mouse', <String, dynamic>{
    'timestamp_ms': tsMs,
    'event_type': eventType.wire,
    'delta_magnitude': deltaMagnitude,
    'scroll_direction': scrollDirection?.contextWire,
    'scroll_magnitude': scrollMagnitude?.wire,
  });

  /// An editing shortcut.
  factory ContextEventInput.shortcut(int tsMs, ShortcutType shortcutType) =>
      ContextEventInput._('Shortcut', <String, dynamic>{
        'timestamp_ms': tsMs,
        'shortcut_type': shortcutType.wire,
      });

  /// Convenience for the commonest pair a text field can report: an insertion
  /// is a [KeyboardEventType.typingTap], a deletion a
  /// [KeyboardEventType.backspace].
  ///
  /// This is the call that gives the context window an error *rate* rather
  /// than an error count with no denominator, so send it for **both**
  /// directions — corrections alone are worse than nothing.
  factory ContextEventInput.textChange(int tsMs, {required bool isDeletion}) =>
      ContextEventInput.keyboard(
        tsMs,
        isDeletion ? KeyboardEventType.backspace : KeyboardEventType.typingTap,
      );

  /// Epoch milliseconds, on the same clock as every other `push_*`.
  int get tsMs => fields['timestamp_ms'] as int;

  Map<String, dynamic> toJson() => <String, dynamic>{variant: fields};

  @override
  String toString() => 'ContextEventInput($variant, $fields)';
}
