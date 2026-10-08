// End-to-end check of the runtime's structured error contract against the
// real native library (`synheart/vendor/runtime/<platform>/`), not a mock.
//
//   flutter test integration_test/native_error_test.dart -d windows
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synheart_core/synheart_core.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await Synheart.initialize(
      config: SynheartConfig(
        appId: 'ai.synheart.example.errors',
        subjectId: 'it_${DateTime.now().millisecondsSinceEpoch}',
        appVersion: '1.0.0',
        appName: 'Synheart Core Example',
        deviceId: 'it_device',
        mode: SynheartMode.personal,
        allowUnsignedCapabilities: true,
        wearConfig: const WearConfig(),
      ),
      autoStart: false,
    );
  });

  testWidgets('the native runtime is loaded and speaks ABI 2', (_) async {
    expect(Synheart.runtimeError, isNull, reason: '${Synheart.runtimeError}');
    final abi = Synheart.buildInfo?['abi'] as String?;
    expect(abi, startsWith('2.'), reason: 'vendored runtime predates ABI 2.0');
  });

  testWidgets('a failed call explains itself through lastNativeError', (
    _,
  ) async {
    expect(Synheart.isSessionRunning, isFalse);

    // Stopping a session that is not running: a known, side-effect-free
    // failure. The runtime returns non-zero and leaves the structured reason.
    await Synheart.stopSession();

    final e = Synheart.lastNativeError;
    expect(e, isNotNull, reason: 'runtime reported no structured error');
    expect(e!.code, 'NO_ACTIVE_SESSION');
    expect(e.op, 'synheart_core_stop_session');
    expect(e.ownerKind, NativeErrorOwner.app);
    expect(e.recoveryKind, NativeErrorRecovery.startSessionFirst);
    expect(e.recoveryCall, 'synheart_core_start_session');
    expect(e.retryable, isFalse);
    expect(e.errorId, matches(RegExp(r'^[0-9a-f]{8}$')));
    expect(e.hint, isNotNull);
    expect(e.hint!.length, lessThanOrEqualTo(110));
    // The internal detail stays in the native log, never in the payload.
    expect(e.toString(), isNot(contains('\\')));
  });
}
