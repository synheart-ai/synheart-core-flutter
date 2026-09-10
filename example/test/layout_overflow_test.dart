import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:example/widgets/ui.dart';

/// Renders the shared building blocks at a narrow width with content long
/// enough to force wrapping, and fails on a `RenderFlex` overflow.
///
/// Worth having because an overflow is not a crash. It paints a yellow-striped
/// bar in debug and prints to the log, and in a release build it silently
/// clips — so the "unsaved" pill next to a long consent title simply
/// disappears off the edge of the screen and nothing tells you. The only
/// reason we caught the real one was a device log scrolling past.
///
/// `flutter_test` turns the overflow into a thrown assertion, which is exactly
/// the signal that is missing at runtime.
void main() {
  /// Pump [child] inside a hard-constrained box, so the test does not depend
  /// on the default 800x600 test surface being generous.
  Future<void> pumpNarrow(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(width: 320, child: child),
          ),
        ),
      ),
    );
  }

  group('ConsentToggle', () {
    // The titles on the Setup screen name config keys — `device_class`,
    // `mask_profile`, `cfi_structural_components` — so they are long by nature.
    const longTitle =
        'Declare sensing, device_class, mask_profile, cfi_structural_components';

    testWidgets('a long title wraps rather than overflowing', (tester) async {
      await pumpNarrow(
        tester,
        ConsentToggle(
          title: longTitle,
          description:
              'A description long enough to wrap across several '
              'lines, which is the normal case for these toggles.',
          value: true,
          onChanged: (_) {},
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long title still fits beside the unsaved pill', (
      tester,
    ) async {
      // The failing case from the device: `enforced` disagreeing with `value`
      // adds the pill to the same row as the title, and the title had nowhere
      // to give.
      await pumpNarrow(
        tester,
        ConsentToggle(
          title: longTitle,
          description: 'Pending edit, so the unsaved pill is present.',
          value: true,
          enforced: false,
          onChanged: (_) {},
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('unsaved'), findsOneWidget);
    });

    testWidgets('a disabled toggle with a long title is fine too', (
      tester,
    ) async {
      // `onChanged: null` is the locked-while-initialized state.
      await pumpNarrow(
        tester,
        const ConsentToggle(
          title: longTitle,
          description: 'Locked while initialized.',
          value: false,
          onChanged: null,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('the other shared blocks', () {
    testWidgets('KeyValueRow takes a long unbroken value', (tester) async {
      await pumpNarrow(
        tester,
        const KeyValueRow(
          'config_id',
          'cfg_9f2b1c7d4e8a0b6f3d5c1e9a7b2f4d8c6a0e3b5d7f9c1a3e5b7d9f1c3a5e7b9d',
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('SectionCard header takes a long title and a pill', (
      tester,
    ) async {
      await pumpNarrow(
        tester,
        const SectionCard(
          title: 'Simulated cardiac source with a deliberately long title',
          subtitle: 'And a subtitle that also runs on for a while.',
          trailing: StatusPill('streaming', tone: PillTone.warn),
          children: [KeyValueRow('beats', '4212')],
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('ErrorBanner takes a long message', (tester) async {
      await pumpNarrow(
        tester,
        const ErrorBanner(
          'The sensing foreground service did not start. The tick loop will '
          'stop when Android stops scheduling this process, and no windows '
          'will close until it returns to the foreground.',
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
