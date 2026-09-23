import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/src/core_runtime/runtime_compat.dart';

void main() {
  group('RuntimeCompat.compare', () {
    test('orders dotted numeric versions', () {
      expect(RuntimeCompat.compare('0.31.1', '0.31.0'), greaterThan(0));
      expect(RuntimeCompat.compare('0.30.1', '0.31.0'), lessThan(0));
      expect(RuntimeCompat.compare('0.31.1', '0.31.1'), 0);
      expect(RuntimeCompat.compare('1.0.0', '0.99.99'), greaterThan(0));
    });
    test('treats a missing component as zero and ignores suffixes', () {
      expect(RuntimeCompat.compare('0.31', '0.31.0'), 0);
      expect(RuntimeCompat.compare('0.31.1-rc1', '0.31.1'), 0);
      expect(RuntimeCompat.compare('0.31.10', '0.31.9'), greaterThan(0));
    });
  });

  group('RuntimeCompat.check', () {
    test('ok at or above writtenAgainst', () {
      final r = RuntimeCompat.check({
        'core_runtime': RuntimeCompat.writtenAgainst,
      });
      expect(r.status, RuntimeCompatStatus.ok);
      expect(r.isAcceptable, isTrue);
    });
    test('older between minimum and writtenAgainst, still acceptable', () {
      final r = RuntimeCompat.check({'core_runtime': '0.30.0'});
      expect(r.status, RuntimeCompatStatus.older);
      expect(r.isAcceptable, isTrue);
      expect(r.message, contains('0.30.0'));
    });
    test('tooOld below minimum is refused', () {
      final r = RuntimeCompat.check({'core_runtime': '0.19.2'});
      expect(r.status, RuntimeCompatStatus.tooOld);
      expect(r.isAcceptable, isFalse);
    });
    test('unknown when build_info has no version, still acceptable', () {
      expect(RuntimeCompat.check(null).status, RuntimeCompatStatus.unknown);
      expect(RuntimeCompat.check({}).isAcceptable, isTrue);
    });
  });
}
