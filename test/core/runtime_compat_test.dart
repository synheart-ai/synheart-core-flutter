import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/src/core_runtime/runtime_compat.dart';
import 'package:synheart_core/src/core_runtime/runtime_exception.dart';
import 'package:synheart_core/src/version.dart';

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

  group('RuntimeCompat.check ABI', () {
    test('ok when the ABI matches and the version is current', () {
      final r = RuntimeCompat.check({
        'core_runtime': RuntimeCompat.writtenAgainst,
        'abi': '1.1',
      });
      expect(r.status, RuntimeCompatStatus.ok);
      expect(r.abi, '1.1');
    });
    test('a newer minor than required is compatible', () {
      final r = RuntimeCompat.check({'core_runtime': '0.33.0', 'abi': '1.7'});
      expect(r.isAcceptable, isTrue);
    });
    test('ABI 2.x is accepted: it removed nothing these bindings call', () {
      final r = RuntimeCompat.check({'core_runtime': '0.40.0', 'abi': '2.0'});
      expect(r.isAcceptable, isTrue);
      expect(r.abi, '2.0');
    });
    test('a major above the accepted range is incompatible', () {
      final r = RuntimeCompat.check({'core_runtime': '0.40.0', 'abi': '3.0'});
      expect(r.status, RuntimeCompatStatus.incompatibleAbi);
      expect(r.isAcceptable, isFalse);
      expect(r.abi, '3.0');
      expect(
        r.message,
        'Core runtime 0.40.0 (ABI 3.0) is incompatible with synheart_core '
        '$synheartCoreVersion (needs ABI 1.0 to 2.x). Install runtime '
        '${RuntimeCompat.writtenAgainst}: synheart install runtime '
        '--version ${RuntimeCompat.writtenAgainst}',
      );
    });
    test('a lower major is incompatible', () {
      final r = RuntimeCompat.check({'core_runtime': '0.33.0', 'abi': '0.9'});
      expect(r.status, RuntimeCompatStatus.incompatibleAbi);
    });
    test('ABI mismatch wins over an otherwise acceptable version', () {
      final r = RuntimeCompat.check({
        'core_runtime': RuntimeCompat.writtenAgainst,
        'abi': '3.0',
      });
      expect(r.status, RuntimeCompatStatus.incompatibleAbi);
    });
    test('absent abi falls back to version checks', () {
      expect(
        RuntimeCompat.check({'core_runtime': '0.19.2'}).status,
        RuntimeCompatStatus.tooOld,
      );
      final older = RuntimeCompat.check({'core_runtime': '0.30.0'});
      expect(older.status, RuntimeCompatStatus.older);
      expect(older.abi, isNull);
    });
    test('a malformed abi is treated as absent', () {
      final r = RuntimeCompat.check({'core_runtime': '0.30.0', 'abi': 'x'});
      expect(r.status, RuntimeCompatStatus.older);
      expect(r.abi, isNull);
    });
    test('tooOld message names both versions and the exact command', () {
      final r = RuntimeCompat.check({'core_runtime': '0.19.2'});
      expect(r.message, contains('0.19.2'));
      expect(r.message, contains(synheartCoreVersion));
      expect(
        r.message,
        contains(
          'synheart install runtime --version ${RuntimeCompat.writtenAgainst}',
        ),
      );
    });
  });

  group('SynheartRuntimeException', () {
    test('incompatible carries the runtime facts and the fix', () {
      final e = SynheartRuntimeException.incompatible(
        RuntimeCompat.check({'core_runtime': '0.40.0', 'abi': '3.0'}),
      );
      expect(e.kind, SynheartRuntimeErrorKind.incompatible);
      expect(e.runtimeVersion, '0.40.0');
      expect(e.runtimeAbi, '3.0');
      expect(e.requiredAbi, RuntimeCompat.requiredAbi);
      expect(e.recommendedVersion, RuntimeCompat.writtenAgainst);
      expect(e.installCommand, contains('--version 0.36.0'));
      expect(e.toString(), contains('incompatible'));
    });
    test('a library without build info is an incompatible runtime', () {
      final e = SynheartRuntimeException.unidentified(cause: 'raw');
      expect(e.kind, SynheartRuntimeErrorKind.incompatible);
      expect(e.cause, 'raw');
      expect(e.message, contains(e.installCommand));
    });
    test('load failures name the fix and keep the raw cause', () {
      for (final kind in [
        SynheartRuntimeErrorKind.notInstalled,
        SynheartRuntimeErrorKind.wrongArchitecture,
        SynheartRuntimeErrorKind.loadFailed,
      ]) {
        final e = SynheartRuntimeException.loadFailure(kind, cause: 'raw');
        expect(e.kind, kind);
        expect(e.cause, 'raw');
        expect(e.message, contains(e.installCommand));
      }
    });
  });

  group('classifyRuntimeLoadFailure', () {
    SynheartRuntimeErrorKind c(String m, {bool missing = false}) =>
        classifyRuntimeLoadFailure(m, fileMissing: missing);

    test('wrong architecture across loaders', () {
      for (final m in [
        'dlopen failed: incompatible architecture (have x86_64, need arm64)',
        'x.so: wrong ELF class: ELFCLASS32',
        'mach-o, but wrong architecture',
      ]) {
        expect(c(m), SynheartRuntimeErrorKind.wrongArchitecture, reason: m);
      }
    });
    test('architecture wins even when the file is known missing', () {
      expect(
        c('incompatible architecture', missing: true),
        SynheartRuntimeErrorKind.wrongArchitecture,
      );
    });
    test('missing file', () {
      expect(
        c('libx.so: cannot open shared object file: No such file or directory'),
        SynheartRuntimeErrorKind.notInstalled,
      );
      expect(
        c('anything', missing: true),
        SynheartRuntimeErrorKind.notInstalled,
      );
    });
    test('Windows error 193 is loadFailed: it also means a corrupt file', () {
      expect(
        c(
          "Failed to load dynamic library 'a.dll': %1 is not a valid Win32 "
          'application. (error code: 193)',
        ),
        SynheartRuntimeErrorKind.loadFailed,
      );
    });
    test('anything else is loadFailed', () {
      expect(c('symbol lookup error'), SynheartRuntimeErrorKind.loadFailed);
    });
  });
}
