import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Enforces the rule that **cardiac is the only simulated source**.
///
/// This reads source files rather than exercising behaviour, which is unusual
/// enough to justify. The rule it protects is not expressible as an assertion
/// on output: the failure mode is a *new* fabricated stream being pushed, and
/// nothing observable from Dart distinguishes an invented GPS trace or screen
/// state from a real one — that indistinguishability is precisely why the rule
/// exists. A simulated heart rate reads as a stand-in for absent hardware; a
/// simulated location reads as a location.
///
/// So the guard is placed where the decision is made: at the call sites. If a
/// future change genuinely needs one of these, the fix is to wire a real
/// platform source and update this test in the same commit — deliberately,
/// not by accident.
void main() {
  String read(String path) {
    final file = File(path);
    expect(
      file.existsSync(),
      isTrue,
      reason: '$path moved — update this guard rather than deleting it',
    );
    return file.readAsStringSync();
  }

  /// Strip `//` comments and doc comments so a prohibition *discussed* in a
  /// comment is not mistaken for one being violated. Every file here explains
  /// at length why these calls are absent.
  String code(String source) => source
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  test('the host runner pushes no fabricated non-cardiac signal', () {
    final runner = code(read('lib/sdk/mobile_host_runner.dart'));

    // Speed would have to come from the simulator's activity episode; there is
    // no real location stream in this example.
    expect(
      runner.contains('pushSpeed('),
      isFalse,
      reason:
          'push_speed can only be fed an invented speed here. Wire a real '
          'location source first.',
    );

    // The context channel IS used — for real keystrokes from the typing probe
    // (`ContextEventInput.textChange`) and real gestures via the SDK. What is
    // banned is constructing a context event from nothing: the pulled version
    // had a button that invented a `Shortcut/Paste` on tap.
    expect(
      runner.contains('ShortcutType.'),
      isFalse,
      reason:
          'a hand-made shortcut event is fabricated context evidence. The '
          'channel is observable from real typing and scrolling already.',
    );
    expect(
      runner.contains('ContextEventInput.mouse(') ||
          runner.contains('ContextEventInput.shortcut('),
      isFalse,
      reason:
          'the runner must not construct pointer or shortcut context events — '
          'those come from real gestures via the SDK translator.',
    );
  });

  test('the example declares no phoneConfig', () {
    // Declaring it starts PhoneModule, whose four collectors are Random()
    // generators for motion, screen state, app focus and notifications.
    final controller = code(read('lib/sdk/synheart_controller.dart'));
    expect(
      controller.contains('phoneConfig:'),
      isFalse,
      reason:
          'PhoneModule fabricates motion, screen state, app focus and '
          'notifications. Replace its collectors with real ones before '
          'enabling it.',
    );
  });

  test('the cardiac simulator exposes no non-cardiac field', () {
    final source = code(read('lib/sdk/synthetic_cardiac_source.dart'));
    for (final banned in const ['speedMps', 'screenState', 'appFocus']) {
      expect(
        source.contains(banned),
        isFalse,
        reason: '$banned is not cardiac and must not be simulated',
      );
    }
  });
}
