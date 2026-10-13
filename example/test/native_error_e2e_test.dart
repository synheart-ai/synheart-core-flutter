// The example app's own controller and Runtime screen against the real native
// library in `synheart/vendor/runtime/<platform>/`: the "Probe" button must
// surface the runtime's structured error end to end. Platform plugins are
// mocked (data dir, preferences); the runtime is not.
//
// Skipped when no runtime is vendored, so CI without one is unaffected.
import 'dart:io';

import 'package:example/screens/diagnostics_screen.dart';
import 'package:example/sdk/synheart_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synheart_core/synheart_core.dart';

bool _runtimeVendored() {
  final name = Platform.isWindows
      ? 'windows/synheart_core_runtime.dll'
      : Platform.isMacOS
      ? 'macos/libsynheart_core_runtime.dylib'
      : 'linux/libsynheart_core_runtime.so';
  return File('synheart/vendor/runtime/$name').existsSync();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = _runtimeVendored() ? null : 'no vendored runtime';

  late Directory dataDir;

  setUpAll(() {
    if (skip != null) return;
    dataDir = Directory.systemTemp.createTempSync('synheart_example_e2e_');
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => dataDir.path,
        );
  });

  testWidgets(
    'the Runtime screen probe shows the runtime\'s structured error',
    (tester) async {
      final controller = SynheartController();
      await tester.runAsync(controller.initialize);
      expect(
        controller.diagnostics['isAvailable'],
        isTrue,
        reason: 'runtime did not load: ${Synheart.runtimeError}',
      );

      // Tall enough that the whole Runtime screen fits without scrolling.
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(home: DiagnosticsScreen()),
        ),
      );

      final probe = find.text('Probe: stop a session that is not running');
      await tester.ensureVisible(probe);
      await tester.pumpAndSettle();
      // The tap is a fake-async gesture; the native call it starts is real
      // I/O, so let it finish outside the fake clock before repainting.
      await tester.tap(probe);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();

      final e = controller.lastNativeError;
      expect(e, isNotNull);
      expect(e!.code, 'NO_ACTIVE_SESSION');
      expect(e.op, 'synheart_core_stop_session');
      expect(e.recoveryCall, 'synheart_core_start_session');

      // What a developer sees on screen, not just in the model.
      expect(find.text('NO_ACTIVE_SESSION'), findsWidgets);
      expect(find.text('synheart_core_start_session'), findsOneWidget);
      expect(find.text(e.errorId!), findsOneWidget);
    },
    skip: skip != null,
  );
}
