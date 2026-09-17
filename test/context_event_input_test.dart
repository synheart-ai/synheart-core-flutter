import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/synheart_core.dart';

/// Golden tests for the `push_context_event` wire shape.
///
/// These exist because getting this wrong is **silent**. The runtime
/// deserializes into an externally-tagged Rust enum
/// (`synheart_context_runtime::DesktopEvent`); a payload that does not parse
/// buffers nothing and returns `1` — the same code a runtime built without the
/// `app-context` cargo feature returns for everything. So a wrong key or a
/// wrong enum casing looks exactly like "this build has no context layer", and
/// the only visible symptom is that CFI and the context deviation terms sit at
/// zero forever.
///
/// The literals below are copied from the runtime's own documented form
/// (`core-runtime`'s `EngineModule::record_context_event_json`). Do not
/// "tidy" them to match Dart naming — they are the other side of an FFI
/// contract, and `DesktopEvent` carries no serde rename attributes, so the
/// Rust variant and field spellings are the wire spellings verbatim.
void main() {
  group('ContextEventInput wire shape', () {
    test('keyboard matches the runtime-documented form', () {
      final event = ContextEventInput.keyboard(
        1712345678000,
        KeyboardEventType.typingTap,
      );

      expect(event.toJson(), <String, dynamic>{
        'Keyboard': <String, dynamic>{
          'timestamp_ms': 1712345678000,
          'is_key_down': true,
          'event_type': 'TypingTap',
        },
      });
    });

    test('mouse scroll matches the runtime-documented form', () {
      final event = ContextEventInput.mouse(
        1712345679000,
        MouseEventType.scroll,
        scrollDirection: ScrollDirection.down,
        scrollMagnitude: ScrollMagnitude.medium,
      );

      expect(event.toJson(), <String, dynamic>{
        'Mouse': <String, dynamic>{
          'timestamp_ms': 1712345679000,
          'event_type': 'Scroll',
          'delta_magnitude': null,
          'scroll_direction': 'Down',
          'scroll_magnitude': 'Medium',
        },
      });
    });

    test('shortcut matches the runtime-documented form', () {
      final event = ContextEventInput.shortcut(
        1712345680000,
        ShortcutType.undo,
      );

      expect(event.toJson(), <String, dynamic>{
        'Shortcut': <String, dynamic>{
          'timestamp_ms': 1712345680000,
          'shortcut_type': 'Undo',
        },
      });
    });

    test('a variant is a single top-level key — external tagging', () {
      // Internally-tagged (`{"type": "Keyboard", ...}`) or untagged forms do
      // not deserialize into `DesktopEvent`. The shape of the envelope is the
      // contract, not just the field names.
      for (final event in <ContextEventInput>[
        ContextEventInput.keyboard(1, KeyboardEventType.backspace),
        ContextEventInput.mouse(2, MouseEventType.leftClick),
        ContextEventInput.shortcut(3, ShortcutType.paste),
      ]) {
        final json = event.toJson();
        expect(json.keys, hasLength(1));
        expect(
          json.keys.single,
          isIn(<String>['Keyboard', 'Mouse', 'Shortcut']),
        );
        expect(json.values.single, isA<Map<String, dynamic>>());
      }
    });

    test('mouse always emits every field, absent ones as explicit null', () {
      // `Mouse` is a Rust struct variant, not a bag of optionals. Omitting a
      // key is a parse risk; `null` is the declared-absence form and
      // deserializes to `None`. This is the one place the SDK does NOT strip
      // nulls — `BehaviorEventInput` does the opposite, deliberately.
      final event = ContextEventInput.mouse(10, MouseEventType.leftClick);
      final fields = event.toJson()['Mouse'] as Map<String, dynamic>;

      expect(
        fields.keys,
        containsAll(<String>[
          'timestamp_ms',
          'event_type',
          'delta_magnitude',
          'scroll_direction',
          'scroll_magnitude',
        ]),
      );
      expect(fields['delta_magnitude'], isNull);
      expect(fields['scroll_direction'], isNull);
      expect(fields['scroll_magnitude'], isNull);

      // And they survive JSON encoding as nulls rather than being dropped.
      expect(jsonEncode(event.toJson()), contains('"delta_magnitude":null'));
    });

    test('every enum value uses the Rust variant spelling', () {
      // PascalCase, matching the Rust variants verbatim. A snake_case or
      // lowercase spelling fails to parse and the failure is invisible.
      expect(
        KeyboardEventType.values.map((e) => e.wire),
        containsAll(<String>[
          'TypingTap',
          'NavigationKey',
          'Backspace',
          'Delete',
          'Enter',
          'Tab',
          'Escape',
          'ModifierKey',
          'FunctionKey',
        ]),
      );
      expect(
        MouseEventType.values.map((e) => e.wire),
        containsAll(<String>['Move', 'LeftClick', 'RightClick', 'Scroll']),
      );
      expect(
        ScrollMagnitude.values.map((e) => e.wire),
        containsAll(<String>['Small', 'Medium', 'Large']),
      );
      expect(
        ShortcutType.values.map((e) => e.wire),
        containsAll(<String>[
          'Copy',
          'Paste',
          'Cut',
          'Undo',
          'Redo',
          'SelectAll',
          'Save',
        ]),
      );
    });

    test('textChange sends corrections AND the keystrokes they correct', () {
      // `err_rate = N_corr / N_key`. A host that reports only deletions leaves
      // the denominator at zero and spikes the error rate to its ceiling on
      // the first backspace, so this convenience covers both directions.
      final insertion = ContextEventInput.textChange(100, isDeletion: false);
      final deletion = ContextEventInput.textChange(200, isDeletion: true);

      expect(
        (insertion.toJson()['Keyboard'] as Map)['event_type'],
        'TypingTap',
      );
      expect((deletion.toJson()['Keyboard'] as Map)['event_type'], 'Backspace');
    });
  });

  group('BehaviorEventInput.appForeground', () {
    test('uses the resolve kind and the app key the runtime reads', () {
      // The runtime reads `data.app` on `kind: "app_foreground"`, routing it to
      // `note_app_resolved` — which, unlike `app_switch`, does not bump the
      // switch count. `app` (not `app_id`) is the key; a misspelling costs the
      // whole field with no error.
      final event = BehaviorEventInput.appForeground(
        1712345678000,
        'com.google.android.gm',
      );

      expect(event.toJson(), <String, dynamic>{
        'ts_ms': 1712345678000,
        'kind': 'app_foreground',
        'value': 0.0,
        'data': <String, dynamic>{'app': 'com.google.android.gm'},
      });
    });

    test('is distinct from appSwitch, which uses from_app / to_app', () {
      final switched = BehaviorEventInput.appSwitch(1, toApp: 'com.example.a');
      final data = switched.toJson()['data'] as Map<String, dynamic>;

      expect(switched.toJson()['kind'], 'app_switch');
      expect(data.containsKey('to_app'), isTrue);
      expect(data.containsKey('app'), isFalse);
    });
  });
}
