import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/src/config/runtime_config_map.dart';
import 'package:synheart_core/synheart_core.dart';

/// Pins what the SDK sends across C ABI 4.0 (runtime 0.42) that no native
/// call can check for it: the per-sample UTC offset, the daily metric names,
/// and the two declarations the SDK makes on the host's behalf.
void main() {
  group('utcOffsetMinAt', () {
    test('is the offset in force at the sample, not now', () {
      // A winter and a summer instant: on a zone with daylight saving the two
      // differ, and each must come back as its own.
      for (final t in [
        DateTime.utc(2026, 1, 15, 12),
        DateTime.utc(2026, 7, 15, 12),
      ]) {
        final ms = t.millisecondsSinceEpoch;
        expect(
          CoreRuntimeBridge.utcOffsetMinAt(ms),
          DateTime.fromMillisecondsSinceEpoch(ms).timeZoneOffset.inMinutes,
        );
      }
    });

    test('stays within the runtime bound of ±840', () {
      final m = CoreRuntimeBridge.utcOffsetMinAt(
        DateTime.now().millisecondsSinceEpoch,
      );
      expect(m, inInclusiveRange(-840, 840));
    });
  });

  group('DailyMetric', () {
    test('names exactly the fifteen metrics C ABI 4.2 accepts', () {
      // The runtime refuses any other name with 1004, including the names
      // these replaced, so this set is the contract.
      expect(DailyMetric.all, {
        'sleep.duration_s',
        'sleep.midpoint_h',
        'cardiac.overnight_rmssd_ms',
        'cardiac.rest_rmssd_ms',
        'cardiac.overnight_hr_bpm',
        'cardiac.overnight_sdnn_ms',
        'cardiac.resting_hr_bpm',
        'vendor.recovery_frac',
        'sleep.deep_min',
        'sleep.rem_min',
        'vendor.strain_frac',
        'motion.steps_count',
        'motion.active_min',
        'cardiac.hrr_load_au',
        'cardiac.overnight_hr_sd_bpm',
      });
    });
  });

  group('declarations the SDK makes for the host', () {
    SynheartConfig config({BehaviorConfig? behavior}) => SynheartConfig(
      appId: 'app',
      subjectId: 'sub_test',
      behaviorConfig: behavior,
    );

    test('no behaviour module: input_observable false', () {
      // A host that captures no input has input-free windows; left "auto" a
      // phone would never certify a window as rest.
      expect(buildRuntimeConfigMap(config())['input_observable'], isFalse);
    });

    test('a behaviour module leaves input_observable to the runtime', () {
      final map = buildRuntimeConfigMap(
        config(behavior: const BehaviorConfig()),
      );
      expect(map.containsKey('input_observable'), isFalse);
    });

    test('device_class defaults to "auto"', () {
      expect(buildRuntimeConfigMap(config())['device_class'], 'auto');
    });
  });
}
