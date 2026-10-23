import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/synheart_core.dart';

void main() {
  group('SyncStatus.fromMap', () {
    test('parses the runtime 0.39 shape', () {
      final status = SyncStatus.fromMap({
        'enabled': true,
        'sync_space_id': 'space-1',
        'pending_count': 4,
        'last_success_ms': 1700000000000,
        'srk_ready': true,
        'account_owned': false,
      });

      expect(status.enabled, isTrue);
      expect(status.syncSpaceId, 'space-1');
      expect(status.hasActiveSpace, isTrue);
      expect(status.pendingCount, 4);
      expect(status.lastSuccessMs, 1700000000000);
      expect(status.srkReady, isTrue);
      expect(status.accountOwned, isFalse);
    });

    test('keeps fields an older runtime never sent as null, not zero', () {
      final status = SyncStatus.fromMap({
        'enabled': true,
        'sync_space_id': null,
        'device_count': 0,
      });

      expect(status.enabled, isTrue);
      expect(status.syncSpaceId, isNull);
      expect(status.hasActiveSpace, isFalse);
      expect(status.pendingCount, isNull);
      expect(status.lastSuccessMs, isNull);
      expect(status.srkReady, isNull);
      expect(status.accountOwned, isNull);
    });

    test('accepts numbers decoded as doubles', () {
      final status = SyncStatus.fromMap({
        'enabled': false,
        'pending_count': 2.0,
      });

      expect(status.pendingCount, 2);
    });
  });

  group('SyncPairingStatus.fromMap', () {
    test('parses a joined pairing', () {
      final status = SyncPairingStatus.fromMap({
        'status': 'joined',
        'sync_space_id': 'space-1',
        'joined_device': {'device_id': 'dev-2', 'device_name': 'Tablet'},
        'joined_at': '2026-10-22T10:00:05Z',
        'expires_at': '2026-10-22T10:05:00Z',
      });

      expect(status.state, SyncPairingState.joined);
      expect(status.state.isTerminal, isTrue);
      expect(status.syncSpaceId, 'space-1');
      expect(status.joinedDevice?.deviceId, 'dev-2');
      expect(status.joinedDevice?.deviceName, 'Tablet');
      expect(status.joinedAt, DateTime.utc(2026, 10, 22, 10, 0, 5));
      expect(status.expiresAt, DateTime.utc(2026, 10, 22, 10, 5));
    });

    test('waiting is not terminal and has no joined device', () {
      final status = SyncPairingStatus.fromMap({
        'status': 'waiting',
        'sync_space_id': 'space-1',
        'joined_device': null,
        'joined_at': null,
        'expires_at': '2026-10-22T10:05:00Z',
      });

      expect(status.state, SyncPairingState.waiting);
      expect(status.state.isTerminal, isFalse);
      expect(status.joinedDevice, isNull);
      expect(status.joinedAt, isNull);
    });

    test('an unrecognised state reads as unknown and keeps polling', () {
      final status = SyncPairingStatus.fromMap({'status': 'reticulating'});

      expect(status.state, SyncPairingState.unknown);
      expect(status.state.isTerminal, isFalse);
    });

    test('expired is terminal', () {
      final status = SyncPairingStatus.fromMap({'status': 'expired'});

      expect(status.state.isTerminal, isTrue);
      expect(status.isExpiredAt(DateTime.utc(2000)), isTrue);
    });

    test('isExpiredAt bounds polling on expires_at', () {
      final status = SyncPairingStatus.fromMap({
        'status': 'unknown',
        'expires_at': '2026-10-22T10:05:00Z',
      });

      expect(status.isExpiredAt(DateTime.utc(2026, 10, 22, 10, 4)), isFalse);
      expect(status.isExpiredAt(DateTime.utc(2026, 10, 22, 10, 5)), isTrue);
    });
  });
}
