import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/synheart_core.dart';

/// The runtime reports every failure as one error object: inside a sync
/// envelope, and from `synheart_core_last_error_json` for calls that return
/// null, `false` or a failure code. Shapes below are the runtime's own
/// examples.
void main() {
  group('SynheartNativeError.fromMap', () {
    test('parses the full error object', () {
      final e = SynheartNativeError.fromMap(
        jsonDecode('''
        {
          "code": "INVALID_ARGUMENT",
          "message": "An unexpected error occurred.",
          "retryable": false,
          "owner": "app",
          "recovery": "fix_call",
          "hint": "An argument was rejected; detail.argument and reason say which and how, when known.",
          "op": "synheart_core_edge_ingest_batch",
          "error_id": "3f9a01c2",
          "reason": "malformed",
          "detail": { "argument": "batch_json" }
        }
      ''')
            as Map<String, dynamic>,
      );

      expect(e.code, 'INVALID_ARGUMENT');
      expect(e.ownerKind, NativeErrorOwner.app);
      expect(e.recoveryKind, NativeErrorRecovery.fixCall);
      expect(e.reason, 'malformed');
      expect(e.argument, 'batch_json');
      expect(e.op, 'synheart_core_edge_ingest_batch');
      expect(e.errorId, '3f9a01c2');
      expect(e.recoveryCall, isNull);
      expect(e.isRuntimeBug, isFalse);
    });

    test('consent errors carry the consent to grant and the call', () {
      final e = SynheartNativeError.fromMap(const {
        'code': 'CONSENT_REQUIRED',
        'message': 'Your permission is needed before this can continue.',
        'retryable': false,
        'owner': 'user',
        'recovery': 'grant_consent',
        'recovery_call': 'synheart_core_grant_consent',
        'reason': 'biosignals',
      });
      expect(e.recoveryKind, NativeErrorRecovery.grantConsent);
      expect(e.recoveryCall, 'synheart_core_grant_consent');
      expect(e.reason, 'biosignals');
    });

    test('a runtime defect carries the report bundle', () {
      final e = SynheartNativeError.fromMap(const {
        'code': 'INTERNAL',
        'message': 'An unexpected error occurred.',
        'owner': 'runtime',
        'recovery': 'report_bug',
        'error_id': '0a1b2c3d',
        'report': {'runtime_version': '0.37.0', 'abi': '2.0'},
      });
      expect(e.isRuntimeBug, isTrue);
      expect(e.report?['abi'], '2.0');
    });

    test(
      'an older runtime that sends only the first three keys still parses',
      () {
        final e = SynheartNativeError.fromMap(const {
          'code': 'NETWORK',
          'message': 'Network error.',
          'retryable': true,
        });
        expect(e.retryable, isTrue);
        expect(e.ownerKind, NativeErrorOwner.unknown);
        expect(e.recoveryKind, NativeErrorRecovery.unknown);
        expect(e.argument, isNull);
        expect(e.errorId, isNull);
      },
    );

    test('unrecognised tokens map to unknown instead of throwing', () {
      final e = SynheartNativeError.fromMap(const {
        'code': 'SOMETHING_NEW',
        'owner': 'martians',
        'recovery': 'pray',
        'retry_after_ms': 1500.0,
      });
      expect(e.ownerKind, NativeErrorOwner.unknown);
      expect(e.recoveryKind, NativeErrorRecovery.unknown);
      expect(e.message, isNotEmpty);
      expect(e.retryAfterMs, 1500);
    });

    test('every recovery token the runtime emits is known', () {
      const tokens = [
        'retry',
        'wait_for_device_unlock',
        'fix_call',
        'fix_configuration',
        'reenter_input',
        'sign_in',
        'register_device',
        'reattest_device',
        'sign_out_then_register',
        'grant_consent',
        'generate_new_pairing_code',
        'rejoin_space',
        'start_session_first',
        'end_session_first',
        'use_supported_build',
        'report_bug',
        'none',
      ];
      for (final t in tokens) {
        expect(
          NativeErrorRecovery.parse(t),
          isNot(NativeErrorRecovery.unknown),
          reason: t,
        );
      }
    });

    test('toString carries what a crash log needs', () {
      final s = SynheartNativeError.fromMap(const {
        'code': 'INVALID_ARGUMENT',
        'reason': 'null',
        'detail': {'argument': 'event_json'},
        'op': 'synheart_core_push_behavior_event',
        'error_id': 'deadbeef',
      }).toString();
      expect(s, contains('INVALID_ARGUMENT'));
      expect(s, contains('event_json'));
      expect(s, contains('synheart_core_push_behavior_event'));
      expect(s, contains('deadbeef'));
    });
  });

  group('compatibility names', () {
    test('SyncNativeError is the same type', () {
      const SyncNativeError e = SynheartNativeError(code: 'X', message: 'm');
      expect(e, isA<SynheartNativeError>());
    });

    test('SyncNativeException is caught as SynheartNativeException', () {
      Object? caught;
      try {
        throw SyncNativeException(SynheartNativeError.unknown());
      } on SynheartNativeException catch (e) {
        caught = e;
      }
      expect(caught, isA<SyncNativeException>());
    });
  });
}
