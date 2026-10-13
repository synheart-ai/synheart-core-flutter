// Ensures `synheart_runtime.json` — read by the synheart CLI to validate a
// project — matches the constants the SDK actually enforces.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/synheart_core.dart';

void main() {
  test('synheart_runtime.json matches RuntimeCompat', () {
    final json =
        jsonDecode(File('synheart_runtime.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(json, {
      'schema': 1,
      'runtime': {
        'package': 'synheart-core-runtime',
        'abi': RuntimeCompat.requiredAbi,
        // The highest ABI major these bindings accept. Without it a reader of
        // the manifest sees only `abi: 1.0` and can reject a runtime on ABI
        // 2.x that the SDK itself loads.
        'abi_max_major': RuntimeCompat.maxAbiMajor,
        'minimum': RuntimeCompat.minimum,
        'written_against': RuntimeCompat.writtenAgainst,
      },
    });
  });

  test('requiredAbi agrees with its major and minor parts', () {
    expect(
      RuntimeCompat.requiredAbi,
      '${RuntimeCompat.requiredAbiMajor}.${RuntimeCompat.requiredAbiMinor}',
    );
  });

  test('.pubignore does not exclude synheart_runtime.json', () {
    final lines = File('.pubignore').readAsLinesSync();
    expect(lines.where((l) => l.contains('synheart_runtime')), isEmpty);
  });
}
