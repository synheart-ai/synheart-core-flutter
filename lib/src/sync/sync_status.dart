/// Local Device Sync state, read from the runtime with no network call.
///
/// Built from the runtime's `sync_status`. Runtime 0.39.0 and later report
/// every field; on an older runtime the fields it never sent stay `null`
/// (absent, not zero). The device roster is not part of this: it lives on the
/// server, so read it with `Synheart.syncListDevices()`.
class SyncStatus {
  const SyncStatus({
    required this.enabled,
    this.syncSpaceId,
    this.pendingCount,
    this.lastSuccessMs,
    this.srkReady,
    this.accountOwned,
  });

  /// The sync engine is built.
  final bool enabled;

  /// The sync space this device is in, or `null` when it is in none.
  final String? syncSpaceId;

  /// Local artifacts waiting for the next push. `null` on a runtime older
  /// than 0.39.0.
  final int? pendingCount;

  /// Unix ms of the last successful sync cycle since the engine was built.
  /// `null` before the first success; it does not survive a restart.
  final int? lastSuccessMs;

  /// The space key is unlocked, so pairing and pull can run. `null` on a
  /// runtime older than 0.39.0.
  final bool? srkReady;

  /// The space is bound to a cloud account. `null` on a runtime older than
  /// 0.39.0.
  final bool? accountOwned;

  /// This device is in a sync space.
  bool get hasActiveSpace => syncSpaceId != null;

  /// Parses the runtime's `sync_status` payload. Missing or mistyped fields
  /// become `null`; a missing `enabled` reads as `false`.
  factory SyncStatus.fromMap(Map<String, dynamic> map) {
    int? asInt(Object? v) => v is num ? v.toInt() : null;
    final spaceId = map['sync_space_id'];
    return SyncStatus(
      enabled: map['enabled'] == true,
      syncSpaceId: spaceId is String && spaceId.isNotEmpty ? spaceId : null,
      pendingCount: asInt(map['pending_count']),
      lastSuccessMs: asInt(map['last_success_ms']),
      srkReady: map['srk_ready'] is bool ? map['srk_ready'] as bool : null,
      accountOwned: map['account_owned'] is bool
          ? map['account_owned'] as bool
          : null,
    );
  }

  @override
  String toString() =>
      'SyncStatus(enabled: $enabled, syncSpaceId: $syncSpaceId, '
      'pendingCount: $pendingCount, lastSuccessMs: $lastSuccessMs, '
      'srkReady: $srkReady, accountOwned: $accountOwned)';
}

/// The server's verdict on a pairing token this device minted.
enum SyncPairingState {
  /// The code is valid and nobody has used it yet. Keep polling.
  waiting,

  /// Another device joined with the code. Stop polling.
  joined,

  /// The code expired unused. Stop polling and offer a new code.
  expired,

  /// The server sent a state this SDK does not know. Treat it as still
  /// pending: keep the code on screen, keep polling until `expiresAt`, and
  /// claim neither success nor failure.
  unknown;

  static SyncPairingState parse(Object? raw) => switch (raw) {
    'waiting' => waiting,
    'joined' => joined,
    'expired' => expired,
    _ => unknown,
  };

  /// Polling can stop: the pairing reached a final state.
  bool get isTerminal => this == joined || this == expired;
}

/// The device that joined with a pairing code.
class SyncPairedDevice {
  const SyncPairedDevice({required this.deviceId, this.deviceName});

  final String deviceId;
  final String? deviceName;
}

/// Pairing status for a token from `Synheart.syncGeneratePairing()`.
///
/// Read it with `Synheart.syncPairingStatus(token)` while the pairing code is
/// on screen, every 2–3 seconds, and stop when [state] is terminal
/// ([SyncPairingState.joined] or [SyncPairingState.expired]) or [expiresAt]
/// has passed.
class SyncPairingStatus {
  const SyncPairingStatus({
    required this.state,
    this.syncSpaceId,
    this.joinedDevice,
    this.joinedAt,
    this.expiresAt,
  });

  final SyncPairingState state;

  /// The space the code invites into.
  final String? syncSpaceId;

  /// The device that joined, once [state] is [SyncPairingState.joined].
  final SyncPairedDevice? joinedDevice;

  /// When the other device joined.
  final DateTime? joinedAt;

  /// When the code stops working. Bound the polling loop on it.
  final DateTime? expiresAt;

  /// The code is past its expiry, whatever the server last said.
  bool isExpiredAt(DateTime now) =>
      state == SyncPairingState.expired ||
      (expiresAt != null && !now.isBefore(expiresAt!));

  /// Parses the runtime's `sync_pairing_status` payload.
  factory SyncPairingStatus.fromMap(Map<String, dynamic> map) {
    DateTime? asTime(Object? v) => v is String ? DateTime.tryParse(v) : null;
    final device = map['joined_device'];
    final spaceId = map['sync_space_id'];
    return SyncPairingStatus(
      state: SyncPairingState.parse(map['status']),
      syncSpaceId: spaceId is String && spaceId.isNotEmpty ? spaceId : null,
      joinedDevice: device is Map && device['device_id'] is String
          ? SyncPairedDevice(
              deviceId: device['device_id'] as String,
              deviceName: device['device_name'] is String
                  ? device['device_name'] as String
                  : null,
            )
          : null,
      joinedAt: asTime(map['joined_at']),
      expiresAt: asTime(map['expires_at']),
    );
  }

  @override
  String toString() =>
      'SyncPairingStatus(state: ${state.name}, syncSpaceId: $syncSpaceId, '
      'joinedDevice: ${joinedDevice?.deviceId}, expiresAt: $expiresAt)';
}
