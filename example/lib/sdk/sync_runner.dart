import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:synheart_core/synheart_core.dart';

/// Cross-device sync: one person's baselines carried between their devices.
///
/// Split out of [SynheartController] for the same reason [MobileHostRunner]
/// is: it is a separate flow with its own state, and inlining it would bury
/// the lifecycle the controller documents. It is still SDK code — screens read
/// from here and call methods here, never `package:synheart_core` directly.
///
/// The flow a host implements, in order:
///
///   1. [refresh]          — readiness per operation, plus the local status
///   2. [createSpace]      — first device; keep the recovery key it returns
///   3. [generatePairing]  — first device mints a short-lived code …
///   4. [joinSpace]        — … the second device redeems it
///   5. [syncNow]          — push and pull a cycle on either device
///
/// What sync carries is baseline snapshots only. HSI windows and session
/// summaries stay on the device that produced them, so a second device does
/// not start showing the first one's history.
///
/// Prerequisites, in the order [checkSyncReadiness] reports them: the
/// `synsync` feature activated, cloud-upload consent granted, the capability
/// allowed, sync configured in the runtime, the device registered
/// (attestation), and — for everything but create, join and recover — an
/// active space. Pairing and sync also need the space key unlocked.
///
/// Sync is a paid-plan feature, and that gate is not on the list above: the
/// SDK and runtime know nothing about plans. A host checks its own entitlement
/// before offering sync, the same way it checks consent. This example has no
/// account sign-in and so no entitlement to check, which means a server that
/// enforces the plan refuses it.
///
/// That refusal is hard to recognise today. The server answers 402, but the
/// runtime reports it as a generic `SERVER` failure marked retryable, so it
/// looks like an outage. [_describe] says so rather than leave a tester
/// retrying something that will never succeed.
class SyncRunner {
  SyncRunner({required this.onChanged});

  /// Called whenever anything a UI renders changes.
  final VoidCallback onChanged;

  /// The operations whose readiness the screen shows. Each has its own
  /// prerequisites, so one "sync ready" flag would hide why a button is off.
  static const operations = [
    SyncOperation.createSpace,
    SyncOperation.joinSpace,
    SyncOperation.recoverSpace,
    SyncOperation.generatePairing,
    SyncOperation.syncNow,
    SyncOperation.listDevices,
  ];

  /// How often a shown pairing code is checked. The documented range is
  /// 2–3 s: fast enough that the first device notices the join while the
  /// person is still looking at it, slow enough not to hammer the server for
  /// the code's whole lifetime.
  static const pollInterval = Duration(seconds: 3);

  // ── State the UI renders ───────────────────────────────────────────────

  final Map<SyncOperation, SyncReadiness> readiness = {};
  SyncStatus? status;
  bool pairingStatusAvailable = false;

  /// The operation in flight, for a progress label. One at a time: the
  /// runtime serializes sync calls per handle anyway.
  String? busy;

  /// The last failure, formatted for display. Native failures carry the
  /// runtime's own code and message rather than a generic "failed".
  String? lastError;

  /// The last successful result worth showing, e.g. a cycle's counts.
  String? lastResult;

  String? recoveryKey;
  String? createdSpaceId;

  List<Map<String, dynamic>> devices = const [];
  bool devicesLoaded = false;

  // Pairing, on the device showing the code.
  String? pairingToken;
  DateTime? pairingMintedAt;

  /// Local fallback bound from `expires_in`, for when the server's
  /// `expires_at` has not been read yet or did not parse.
  DateTime? pairingLocalExpiry;
  SyncPairingStatus? pairingStatus;
  DateTime? pairingCheckedAt;
  int pairingPolls = 0;

  /// Why polling stopped, once it has: joined, expired, or unsupported.
  String? pairingStopReason;

  Timer? _pollTimer;
  bool _pollInFlight = false;

  bool get isPolling => _pollTimer != null;

  // ── Reads ──────────────────────────────────────────────────────────────

  /// Re-read readiness for every operation and the local status. No network.
  Future<void> refresh() async {
    for (final op in operations) {
      readiness[op] = await Synheart.checkSyncReadiness(operation: op);
    }
    pairingStatusAvailable = Synheart.syncPairingStatusAvailable;
    try {
      status = Synheart.syncStatus();
    } on SynheartNativeException catch (e) {
      // STORAGE_UNAVAILABLE and similar: the status is unknown, not empty.
      status = null;
      lastError = _describe('syncStatus', e);
    }
    onChanged();
  }

  // ── Space lifecycle ────────────────────────────────────────────────────

  /// First device: create the space. The recovery key is the only way back in
  /// if every device is lost, so a real host makes the person save it.
  Future<void> createSpace({String? deviceName}) =>
      _run('createSpace', () async {
        final r = await Synheart.syncCreateSpace(deviceName: deviceName);
        if (r == null) return 'Runtime bridge not ready.';
        createdSpaceId = r['sync_space_id'] as String?;
        recoveryKey = r['recovery_key'] as String?;
        return 'Space created: ${createdSpaceId ?? '—'}';
      });

  /// Second device: redeem a code from the first.
  Future<void> joinSpace(String token, {String? deviceName}) =>
      _run('joinSpace', () async {
        final r = await Synheart.syncJoinSpace(
          pairingToken: token.trim(),
          deviceName: deviceName,
        );
        if (r == null) return 'Runtime bridge not ready.';
        return 'Joined: ${r['sync_space_id'] ?? '—'} (${r['status'] ?? '—'})';
      });

  /// A fresh device with no paired sibling: rejoin with the recovery key.
  Future<void> recoverSpace(String key, String spaceId) => _run(
    'recoverSpace',
    () async {
      final r = await Synheart.syncRecoverSpace(
        recoveryKey: key.trim(),
        spaceId: spaceId.trim(),
      );
      if (r == null) return 'Runtime bridge not ready.';
      return 'Recovered: ${r['sync_space_id'] ?? '—'} (${r['status'] ?? '—'})';
    },
  );

  Future<void> leaveSpace() => _run('leaveSpace', () async {
    final r = await Synheart.syncLeaveSpace();
    return r == null ? 'Runtime bridge not ready.' : 'Left the space.';
  });

  Future<void> deleteSpace() => _run('deleteSpace', () async {
    final r = await Synheart.syncDeleteSpace();
    if (r == null) return 'Runtime bridge not ready.';
    recoveryKey = null;
    createdSpaceId = null;
    return 'Space deleted.';
  });

  /// "Start over on this device": local state only, the server is untouched.
  Future<void> clearLocalSpace() => _run('clearLocalSpace', () async {
    final r = await Synheart.syncClearLocalSpace();
    return r == null
        ? 'Runtime bridge not ready.'
        : 'Local space state cleared.';
  });

  Future<void> syncNow() => _run('syncNow', () async {
    final r = await Synheart.syncNow();
    return 'Cycle done: pushed ${r.pushed}, pulled ${r.pulled}.';
  });

  // ── Devices ────────────────────────────────────────────────────────────

  /// The roster lives on the server; `SyncStatus` deliberately carries no
  /// device count. This is the call behind a "paired with N devices" line.
  Future<void> listDevices() => _run('listDevices', () async {
    final r = await Synheart.syncListDevices();
    if (r == null) return 'Runtime bridge not ready.';
    devices = ((r['devices'] as List?) ?? const [])
        .whereType<Map>()
        .map((d) => d.cast<String, dynamic>())
        .toList();
    devicesLoaded = true;
    return '${devices.length} device(s) in the space.';
  });

  Future<void> revokeDevice(String deviceId) => _run('revokeDevice', () async {
    final r = await Synheart.syncRevokeDevice(deviceId: deviceId);
    if (r == null) return 'Runtime bridge not ready.';
    devices = devices.where((d) => d['device_id'] != deviceId).toList();
    return 'Revoked $deviceId.';
  });

  // ── Pairing ────────────────────────────────────────────────────────────

  /// Mint a code and start watching it.
  ///
  /// Without pairing status the device showing the code has no way to learn
  /// that the other device joined: the roster is not a substitute, because it
  /// cannot tell "not yet" from "joined with a different code". So the code is
  /// polled until the server calls it joined or expired, or it runs out.
  Future<void> generatePairing() => _run('generatePairing', () async {
    stopPolling();
    final r = await Synheart.syncGeneratePairing();
    if (r == null) return 'Runtime bridge not ready.';
    final token = r['token'] as String?;
    if (token == null || token.isEmpty) return 'No token in the response.';
    final expiresIn = r['expires_in'];
    pairingToken = token;
    pairingMintedAt = DateTime.now();
    pairingLocalExpiry = expiresIn is num
        ? pairingMintedAt!.add(Duration(seconds: expiresIn.toInt()))
        : null;
    pairingStatus = null;
    pairingCheckedAt = null;
    pairingPolls = 0;
    pairingStopReason = null;
    if (!Synheart.syncPairingStatusAvailable) {
      // Honest absence: the code still works, this device just cannot see
      // the join. Say so rather than show a spinner that never resolves.
      pairingStopReason =
          'This runtime cannot report pairing status '
          '(no synheart_core_sync_pairing_status).';
      return 'Code minted. Status unavailable on this runtime.';
    }
    _pollTimer = Timer.periodic(pollInterval, (_) => pollPairing());
    unawaited(pollPairing());
    return 'Code minted. Watching for a join…';
  });

  /// One status read. Public so the screen can offer a manual check.
  Future<void> pollPairing() async {
    final token = pairingToken;
    if (token == null || _pollInFlight) return;
    _pollInFlight = true;
    try {
      final s = await Synheart.syncPairingStatus(token);
      pairingPolls++;
      pairingCheckedAt = DateTime.now();
      if (s == null) {
        _stop('Runtime bridge not ready, or pairing status unsupported.');
        return;
      }
      pairingStatus = s;
      if (s.state == SyncPairingState.joined) {
        final who =
            s.joinedDevice?.deviceName ?? s.joinedDevice?.deviceId ?? '—';
        _stop('Joined by $who.');
        // The roster and status both changed; show it without a tap.
        unawaited(listDevices());
        unawaited(refresh());
        return;
      }
      if (s.isExpiredAt(DateTime.now()) || _pastLocalExpiry()) {
        _stop('Code expired unused. Mint a new one.');
        return;
      }
      // waiting or unknown: keep going. `unknown` is a state the server sent
      // that this SDK does not know — not a failure and not a join.
    } on SynheartNativeException catch (e) {
      // A network blip is not the end of the code; keep polling until it
      // expires, and show the failure meanwhile.
      lastError = _describe('syncPairingStatus', e);
      if (_pastLocalExpiry()) _stop('Code expired.');
    } finally {
      _pollInFlight = false;
      onChanged();
    }
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  bool _pastLocalExpiry() {
    final at = pairingLocalExpiry;
    return at != null && !DateTime.now().isBefore(at);
  }

  void _stop(String reason) {
    stopPolling();
    pairingStopReason = reason;
  }

  void dispose() => stopPolling();

  // ── Plumbing ───────────────────────────────────────────────────────────

  Future<void> _run(String op, Future<String> Function() body) async {
    if (busy != null) return;
    busy = op;
    lastError = null;
    onChanged();
    try {
      lastResult = await body();
    } on SynheartNativeException catch (e) {
      lastError = _describe(op, e);
    } catch (e) {
      lastError = '$op: $e';
    } finally {
      busy = null;
      onChanged();
    }
    // Every operation can move readiness (a space appears, the key unlocks).
    if (op != 'listDevices') await refresh();
  }

  static String _describe(String op, SynheartNativeException e) {
    final buf = StringBuffer('$op failed: ${e.code}\n${e.message}');
    final recovery = e.error.recovery;
    if (recovery != null) buf.write('\nrecovery: $recovery');
    if (e.errorId != null) buf.write('\nerror id: ${e.errorId}');
    if (e.code == 'SERVER') {
      // A paid-plan refusal (HTTP 402) currently arrives as this code, so it
      // cannot be told apart from an outage here. Name both causes.
      buf.write(
        '\n\nSERVER covers both an outage and an account without the paid '
        'plan sync requires; the runtime does not yet tell them apart. If it '
        'repeats, check the plan before retrying.',
      );
    }
    return buf.toString();
  }
}
