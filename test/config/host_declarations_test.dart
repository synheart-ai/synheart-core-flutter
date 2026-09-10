import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/src/config/host_declarations.dart';
import 'package:synheart_core/src/config/runtime_config_map.dart';
import 'package:synheart_core/src/config/synheart_config.dart';

/// Guards the four host declarations on their way into `synheart_core_new`.
///
/// The property that matters most is the **absence** of a key. Undeclared and
/// declared-as-default are different states to the runtime: undeclared
/// reproduces pre-0.16.0 behaviour exactly, whereas declaring `device_class`
/// folds into the SRM `config_hash` and invalidates every persisted baseline
/// (`ERR_SRM_CONFIG_MISMATCH`, then a 30-observation re-warm across 3 days).
/// A default that leaked a key into this map would reset every field user's
/// baselines on upgrade, silently.
void main() {
  SynheartConfig configWith({
    HostDeclarations declarations = const HostDeclarations(),
    List<ExtraHead> extraHeads = const [],
    int? windowMs,
  }) => SynheartConfig(
    appId: 'app',
    subjectId: 'sub_test',
    hostDeclarations: declarations,
    extraHeads: extraHeads,
    windowMs: windowMs,
  );

  group('undeclared is the default', () {
    test('emits none of the four keys', () {
      final map = buildRuntimeConfigMap(configWith());

      expect(map.containsKey('sensing'), isFalse);
      expect(map.containsKey('device_class'), isFalse);
      expect(map.containsKey('mask_profile'), isFalse);
      expect(map.containsKey('cfi_structural_components'), isFalse);
    });

    test('emits no extra_heads and no window_ms', () {
      final map = buildRuntimeConfigMap(configWith());

      expect(map.containsKey('extra_heads'), isFalse);
      expect(map.containsKey('window_ms'), isFalse);
    });
  });

  group('explicit declarations', () {
    test('"auto" passes through as the string the runtime resolves', () {
      final map = buildRuntimeConfigMap(
        configWith(declarations: HostDeclarations.auto),
      );

      expect(map['sensing'], 'auto');
      expect(map['device_class'], 'auto');
      expect(map['mask_profile'], 'auto');
      expect(map['cfi_structural_components'], 4);
    });

    test('typed enums serialize to their wire strings', () {
      final map = buildRuntimeConfigMap(
        configWith(
          declarations: const HostDeclarations(
            deviceClass: DeviceClass.phone,
            maskProfile: MaskProfile.mobile,
          ),
        ),
      );

      expect(map['device_class'], 'phone');
      expect(map['mask_profile'], 'mobile');
      expect(map.containsKey('sensing'), isFalse);
    });

    test('a sensing object always carries mode', () {
      // An object with no valid `mode` is dropped wholesale by the runtime,
      // leaving the host silently undeclared — so mode is non-optional here.
      final map = buildRuntimeConfigMap(
        configWith(
          declarations: const HostDeclarations(
            sensing: SensingProfile(
              mode: SensingMode.continuous,
              latenessBudgetMs: 120000,
              streams: SensingStreams(cardiac: true, screenState: true),
            ),
          ),
        ),
      );

      expect(map['sensing'], {
        'mode': 'continuous',
        'lateness_budget_ms': 120000,
        'streams': {'cardiac': true, 'screen_state': true},
      });
    });

    test('an unnamed stream is omitted, which declares it unavailable', () {
      // The roster is closed: not naming a stream is a positive claim that the
      // host cannot see it, distinct from predating the field entirely.
      final json = const SensingStreams(cardiac: true).toJson();

      expect(json, {'cardiac': true});
      expect(json.containsKey('notification_responses'), isFalse);
    });

    test('a stream declared false is kept', () {
      expect(const SensingStreams(pointer: false).toJson(), {'pointer': false});
    });
  });

  group('extra heads and window', () {
    test('kinematic heads serialize to their engine names', () {
      final map = buildRuntimeConfigMap(
        configWith(
          extraHeads: const [
            ExtraHead.locomotionState,
            ExtraHead.posturalState,
          ],
        ),
      );

      expect(map['extra_heads'], ['locomotion_state', 'postural_state']);
    });

    test('a non-positive window_ms is not sent', () {
      expect(
        buildRuntimeConfigMap(configWith(windowMs: 0)).containsKey('window_ms'),
        isFalse,
      );
      expect(
        buildRuntimeConfigMap(configWith(windowMs: 30000))['window_ms'],
        30000,
      );
    });
  });

  test('an unsupported declaration type is rejected loudly', () {
    expect(
      () => const HostDeclarations(deviceClass: 42).toJson(),
      throwsArgumentError,
    );
  });
}
