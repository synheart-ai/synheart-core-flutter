// Exercises the runtime's structured error contract through the real bridge
// and the real native library, on the host VM (no device, no plugins).
//
// Needs a runtime built with `synheart_core_last_error_json` (ABI 2.0+) at
// `example/synheart/vendor/runtime/<platform>/`; skipped when none is there,
// so CI without a vendored runtime is unaffected.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/src/config/runtime_config_map.dart';
import 'package:synheart_core/synheart_core.dart';

String? _vendoredRuntime() {
  final name = Platform.isWindows
      ? 'windows/synheart_core_runtime.dll'
      : Platform.isMacOS
      ? 'macos/libsynheart_core_runtime.dylib'
      : 'linux/libsynheart_core_runtime.so';
  final f = File('example/synheart/vendor/runtime/$name');
  return f.existsSync() ? f.path : null;
}

void main() {
  final runtime = _vendoredRuntime();
  final skip = runtime == null ? 'no vendored runtime under example/' : null;

  late Directory dataDir;
  late Directory previousCwd;
  CoreRuntimeBridge? bridge;

  setUpAll(() {
    if (skip != null) return;
    previousCwd = Directory.current;
    // The desktop loader resolves `synheart/vendor/runtime/` from the cwd.
    Directory.current = Directory('example');
    dataDir = Directory.systemTemp.createTempSync('synheart_err_');
    bridge = CoreRuntimeBridge.create(
      buildRuntimeConfigMap(
        SynheartConfig(
          appId: 'ai.synheart.example.errors',
          subjectId: 'host_test',
          deviceId: 'host_device',
          allowUnsignedCapabilities: true,
          wearConfig: const WearConfig(),
        ),
        dataDir: dataDir.path,
      ),
    );
  });

  tearDownAll(() {
    if (skip != null) return;
    bridge?.dispose();
    Directory.current = previousCwd;
    try {
      dataDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('the bridge opens a handle on the vendored runtime', () {
    expect(bridge, isNotNull, reason: '${CoreRuntimeBridge.lastCreateError}');
  }, skip: skip);

  test('a failed action leaves a structured error naming the fix', () {
    final ok = bridge!.stopSession();
    expect(ok, isFalse);

    final e = bridge!.lastError;
    expect(e, isNotNull, reason: 'runtime predates ABI 2.0?');
    expect(e!.code, 'NO_ACTIVE_SESSION');
    expect(e.op, 'synheart_core_stop_session');
    expect(e.ownerKind, NativeErrorOwner.app);
    expect(e.recoveryKind, NativeErrorRecovery.startSessionFirst);
    expect(e.recoveryCall, 'synheart_core_start_session');
    expect(e.errorId, matches(RegExp(r'^[0-9a-f]{8}$')));
    expect(e.hint!.length, lessThanOrEqualTo(110));
  }, skip: skip);

  test('a getter with nothing to return is not mistaken for a failure', () {
    // Clear the previous error by succeeding, then read an empty getter.
    expect(bridge!.currentSession(), isNull);
    final before = bridge!.lastError;
    // No new failure was recorded: the last error is still the stop_session
    // one from the previous test (or null if run alone), never a new op.
    expect(before?.op, anyOf(isNull, 'synheart_core_stop_session'));
  }, skip: skip);

  test('a rejected config explains itself before any handle exists', () {
    final b = CoreRuntimeBridge.create(const {'app_id': ''});
    expect(b, isNull);
    final e = CoreRuntimeBridge.lastCreateError;
    expect(e, isNotNull);
    expect(e!.op, 'synheart_core_new');
    expect(e.code, anyOf('CONFIGURATION_INVALID', 'INVALID_ARGUMENT'));
    expect(e.recoveryKind, NativeErrorRecovery.fixConfiguration);
  }, skip: skip);
}
