import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';
import 'config/api_endpoints.dart';
import 'config/runtime_config_map.dart';
import 'config/synheart_config.dart';
import 'core/bounded_buffer.dart';
import 'core/hsi_delivery_deduper.dart';
import 'core/logger.dart';
import 'modules/base/module_manager.dart';
import 'modules/base/synheart_module.dart';
import 'modules/capabilities/capability_module.dart';
import 'modules/consent/consent_effective_state.dart';
import 'modules/consent/consent_form.dart';
import 'modules/consent/consent_module.dart';
import 'modules/interfaces/capability_provider.dart';
import 'modules/interfaces/consent_provider.dart';
import 'modules/wear/wear_module.dart';
import 'models/accel_placement.dart';
import 'models/behavior_event_input.dart';
import 'models/data_deletion.dart';
import 'models/task_type.dart';
import 'models/focus_kind.dart';
import 'package:synheart_wear/synheart_wear.dart'
    show WorkoutEvent, WorkoutKind, RamenEvent;
import 'modules/wear/wear_source_handler.dart';
import 'modules/phone/phone_module.dart';
import 'modules/behavior/behavior_module.dart';
import 'modules/behavior/behavior_code.dart';
import 'modules/behavior/behavior_events.dart';
import 'modules/breathing/breathing_module.dart';
import 'modules/syni/syni_module.dart';
import 'modules/syni/syni_service_client.dart';
import 'package:syni/agent.dart' show SyniCloudConfig;
import 'models/behavior_session_results.dart';
import 'package:synheart_behavior/synheart_behavior.dart' as sb;
import 'config/synheart_mode.dart';
import 'models/session_handle.dart';
import 'models/hsi_state.dart';
import 'models/metric_event.dart';
import 'config/synheart_errors.dart';
import 'config/synheart_feature.dart';
import 'config/activation_manager.dart';
import 'modules/cloud/device_auth_provider.dart';
import 'core_runtime/core_runtime_bridge.dart';
import 'core_runtime/ffi_bindings.dart' show SynheartCoreFFI;
import 'core_runtime/platform_native_sdk_crypto_callbacks.dart';
import 'sync/sync_readiness.dart';

import 'modules/consent/consent_profile.dart';
import 'modules/consent/consent_token.dart';
import 'modules/consent/consent_ui.dart';
import 'models/canonical_wearable_event.dart';
import 'models/readiness_score.dart';
import 'baseline/baseline_snapshots.dart';
import 'models/recovery_score.dart';
import 'models/sleep_score.dart';
import 'modules/baselines/baselines.dart';
import 'modules/wear/wearable_event_processor.dart';
import 'modules/session/watch_session_module.dart';
import 'modules/behavior/foreground_app_reporter.dart';
import 'models/context_event_input.dart';
import 'package:synheart_session/synheart_session.dart';

/// Synheart Core SDK - Main Entry Point
///
/// This is the main entry point for the Synheart Core SDK.
/// It orchestrates all core modules and optional interpretation modules.
///
/// Core modules:
/// - Capabilities Module (feature gating)
/// - Consent Module (permission management)
/// - Wear Module (biosignal collection)
/// - Phone Module (motion/context)
/// - Behavior Module (interaction patterns)
/// - HSI Runtime (signal fusion & state computation)
/// - Cloud Connector (secure uploads)
///
///
/// Example usage:
/// ```dart
/// // Initialize
/// await Synheart.initialize(
/// userId: 'anon_user_123',
/// );
///
/// // Subscribe to HSI updates (core state representation)
/// Synheart.onHSIUpdate.listen((hsi) {
/// print('HSI JSON: $hsi');
/// });
///
/// // Enable cloud upload (with consent)
/// Synheart.activate(SynheartFeature.cloud);
/// ```
class Synheart {
  static Synheart? _instance;
  static Synheart get shared => _instance ??= Synheart._();

  /// Typed baseline-snapshot access — see [BaselineSnapshots] for the
  /// per-kind getters.
  ///
  /// Distinct from the legacy [Baselines] class which orchestrates
  /// vendor-sleep ingestion and score caching. [baselineSnapshots] is
  /// the typed read surface for the umbrella baseline envelope shape.
  /// Cross-device transport rides the sync engine — no upload/restore
  /// hooks live on this facade. A local-hydration hook is wired
  /// automatically when the runtime bridge is configured so the typed
  /// getters survive app cold-start.
  static final BaselineSnapshots _baselineSnapshots = BaselineSnapshots();
  static BaselineSnapshots get baselineSnapshots => _baselineSnapshots;

  /// Wire the baseline local-hydration hook against the runtime
  /// bridge. Called immediately after [_coreRuntime] is assigned so
  /// the typed getters on [baselineSnapshots] return real data after
  /// app cold-start (including envelopes pulled from other devices by
  /// the sync engine). Cross-device transport rides the sync engine,
  /// so there are no upload/restore hooks here.
  static void _wireBaselineCloudHooks(CoreRuntimeBridge bridge) {
    _baselineSnapshots.wireLocalHydrator(bridge.baselineHydrateLocal);
    // Fire-and-forget: SMK may not be ready yet (storage callbacks
    // are wired in the same code path right after this call). The
    // FFI returns `{"error": ...}` and the facade no-ops cleanly in
    // that case; first session-end or sync-pull will populate the
    // cache instead. Schedule on the microtask queue so the
    // bridge-config sync path completes first.
    Future.microtask(() async {
      try {
        final restored = await _baselineSnapshots.hydrateFromLocal();
        if (restored.isNotEmpty) {
          SynheartLogger.log(
            '[Synheart] baseline cache hydrated from local: '
            '${restored.length} envelope(s)',
          );
        }
      } catch (e) {
        SynheartLogger.log('[Synheart] baseline hydrate skipped: $e');
      }
    });
  }

  /// Clear the baseline local-hydration hook. Called when the runtime
  /// bridge is torn down so subsequent hydrate calls fail fast instead
  /// of dereferencing a dead bridge.
  static void _clearBaselineCloudHooks() {
    _baselineSnapshots.wireLocalHydrator(null);
  }

  /// core runtime bridge (FFI). Null when native lib unavailable.
  static CoreRuntimeBridge? _coreRuntime;

  /// Cached durable directory passed to the native runtime as `data_dir`.
  /// Without this the runtime falls back to `std::env::temp_dir()`, so the
  /// SRM snapshot (`srm_<subject>.json`) and SQLite (`synheart_<subject>.db`)
  /// don't survive app restarts or updates. Resolved once during
  /// [configure] and reused on subsequent [ensureRuntimeBridge] calls.
  static String? _resolvedDataDir;

  static Future<String> _resolveDataDir() async {
    final cached = _resolvedDataDir;
    if (cached != null) return cached;
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory('${supportDir.path}/synheart-core');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _resolvedDataDir = dir.path;
    return dir.path;
  }

  /// Callback invoked whenever `ingestBatch` returns a completed HSI
  /// window from a per-event push ([pushWearHr] / [pushRr] /
  /// [pushVendorHrv]). This is the primary HSI delivery path on iOS —
  /// the native `setHsiCallback` doesn't fire there, so consumers that
  /// care about HSI on iOS must set this callback.
  ///
  /// On Android the native callback already feeds [_hsvStream] and this
  /// is redundant; consumers typically listen to [onHSIUpdate] instead.
  static void Function(String hsiJson)? onHsi;

  Synheart._();

  // Module manager
  final ModuleManager _moduleManager = ModuleManager();

  // Core modules
  CapabilityModule? _capabilityModule;
  ConsentModule? _consentModule;
  WearModule? _wearModule;
  PhoneModule? _phoneModule;
  BehaviorModule? _behaviorModule;
  DeviceAuthProvider? _deviceAuthProvider;
  Future<void>? _deviceAuthInitInFlight;

  /// True when [sdkRegisterDevice] succeeded for this process (core-runtime auth path).
  static bool _deviceAuthViaCoreRuntime = false;
  static bool _sdkCryptoCallbacksAttached = false;

  // Watch session module
  WatchSessionModule? _watchSessionModule;

  // Main data-collection session (Session SDK) — open/close sessions via Session SDK
  SynheartSession? _mainSession;
  String? _activeMainSessionId;
  StreamSubscription<SessionEvent>? _mainSessionSubscription;

  // (HSI subscription fields removed — HSI is now delivered via setHsiCallback)

  // Session data buffers — accumulate during a session, readable after stop.
  // Bounded ring buffers; oldest entries are evicted at the cap.
  final BoundedBuffer<String> _sessionHsiBuffer = BoundedBuffer<String>(
    maxSessionHsiWindows,
  );
  final BoundedBuffer<WearSample> _sessionWearBuffer =
      BoundedBuffer<WearSample>(maxSessionWearSamples);

  /// Maximum HSI windows retained by [getSessionHsiWindows].
  ///
  /// At the runtime's ~10s window cadence this is a little over 5 hours of
  /// history, well beyond any documented use of the buffer. The durable record
  /// lives in the runtime's storage and is read via [getHSIWindows]; this
  /// buffer only serves recent in-memory history.
  static const int maxSessionHsiWindows = 2000;

  /// Maximum raw wear samples retained by [getSessionWearSamples].
  static const int maxSessionWearSamples = 5000;

  StreamSubscription? _sessionHsiSubscription;
  StreamSubscription? _sessionWearSubscription;

  // Activation manager (four-authority model)
  ActivationManager? _activationManager;

  // Behavior session tracking
  final Map<String, sb.BehaviorSession> _activeBehaviorSessions = {};

  // State
  bool _isConfigured = false;
  bool _isRunning = false;
  Completer<void>? _initCompleter; // guards concurrent init
  String? _userId;
  SynheartConfig? _config;
  bool? _batchIngestOnStop;
  static String? _lastUploadBatchId;
  static DateTime? _lastUploadAt;
  static String? _lastUploadError;
  static DateTime? _lastUploadAttemptAt;

  // Session handle
  SessionHandle? _currentSessionHandle;

  // Pending consent (set before init completes, applied after)
  _PendingConsent? _pendingConsent;

  // Streams
  final BehaviorSubject<String> _hsvStream = BehaviorSubject<String>();

  /// Static stream of HSI updates (core state representation, raw HSI JSON)
  static Stream<String> get onHSIUpdate => shared._hsvStream.stream;

  /// Stream of HSI updates (core state representation, raw HSI JSON)
  ///
  /// HSI (Human State Interface) contains:
  /// - State axes (physiological, engagement, activity, context)
  /// - State indices (arousalIndex, engagementStability, etc.)
  /// - 64D state embedding
  ///
  /// Consumers receive raw HSI JSON strings from the synheart-engine C ABI.
  Stream<String> get hsiUpdates => _hsvStream.stream;

  // --- Typed state subscription ---

  /// Most recently parsed [HSIState], keyed by the raw JSON it came from.
  ///
  /// `.map` on a broadcast stream runs once per subscriber, and
  /// [currentHSIState] is a getter that a widget may read every frame. Parsing
  /// each window once and sharing the immutable result avoids both costs.
  static String? _cachedHsiRaw;
  static HSIState? _cachedHsiState;

  /// Suppresses windows delivered by both producers. See
  /// [HsiDeliveryDeduper] for why two paths exist and how identity is decided.
  static final HsiDeliveryDeduper _hsiDeduper = HsiDeliveryDeduper();

  static HSIState _parseHsiCached(String json) {
    final cached = _cachedHsiState;
    if (cached != null && identical(_cachedHsiRaw, json)) return cached;
    final parsed = HSIState.fromJson(
      json,
      subjectId: shared._config?.subjectId ?? shared._userId ?? '',
    );
    _cachedHsiRaw = json;
    _cachedHsiState = parsed;
    return parsed;
  }

  /// Stream of typed [HSIState] updates.
  ///
  /// Wraps raw JSON from [onHSIUpdate] into typed objects with axis accessors.
  /// [HSIState] is immutable, so all subscribers safely share one parse of
  /// each window.
  static Stream<HSIState> get onStateUpdate =>
      shared._hsvStream.stream.map(_parseHsiCached);

  /// Get the current HSI state as a typed object.
  ///
  /// Cheap to call repeatedly — repeated reads of the same window reuse the
  /// parse performed for the first one.
  static HSIState? get currentHSIState {
    if (!shared._hsvStream.hasValue) return null;
    return _parseHsiCached(shared._hsvStream.value);
  }

  // --- Metrics API ---

  /// Record a single metric event for the current session.
  ///
  /// In Personal mode, the call succeeds silently but data is dropped.
  /// In Insight/Research mode, the metric is persisted to SQLite.
  static Future<void> recordMetric(MetricEvent event) async {
    if (_coreRuntime != null) {
      _coreRuntime!.recordMetric(event.toJson());
      return;
    }
  }

  /// Record multiple metric events for the current session.
  ///
  /// NOTE: despite the plural name there is no batched native path — this
  /// forwards one `record_metric` FFI call per event. It exists as a
  /// convenience over looping [recordMetric] yourself, not as a throughput
  /// optimisation. Prefer keeping [events] to sane sizes until the runtime
  /// exposes a batch entry point.
  static Future<void> recordMetrics(List<MetricEvent> events) async {
    final runtime = _coreRuntime;
    if (runtime == null) return;
    for (final event in events) {
      runtime.recordMetric(event.toJson());
    }
  }

  // --- Local query API ---

  /// List stored sessions with optional filters.
  static Future<List<SessionRecord>> listSessions({SessionRange? range}) async {
    if (_coreRuntime != null) {
      final raw = _coreRuntime!.listSessions();
      if (raw != null) {
        return raw
            .cast<Map<String, dynamic>>()
            .map((m) => SessionRecord.fromMap(m))
            .toList();
      }
    }
    return [];
  }

  /// Mark a stranded `state='active'` session as closed without going
  /// through the normal stop-session lifecycle. Returns `true` on success
  /// (or when the session was already closed).
  ///
  /// Used by [sweepOrphanSessions]; prefer that helper over calling this
  /// directly unless you know exactly which session id to close.
  static Future<bool> closeOrphanSession(String sessionId) async {
    if (_coreRuntime == null) return false;
    return _coreRuntime!.closeOrphanSession(sessionId);
  }

  /// Close every `state='active'` session whose `startUtc` is older than
  /// `olderThan` ago. Returns the number of sessions actually closed.
  ///
  /// Call this once on app start to clean up sessions the host failed to
  /// finalize cleanly (app force-killed mid-session, OS reclaim, sudden
  /// reboot, etc.). Without this they accumulate in [listSessions] as
  /// eternally-active and pollute downstream summaries / histories.
  ///
  /// `olderThan` defaults to 6 hours, which is generous for app sessions
  /// (typical sessions are minutes) and avoids racing a session a user
  /// just started and backgrounded briefly.
  static Future<int> sweepOrphanSessions({
    Duration olderThan = const Duration(hours: 6),
  }) async {
    final sessions = await listSessions();
    if (sessions.isEmpty) return 0;
    final cutoffMs =
        DateTime.now().millisecondsSinceEpoch - olderThan.inMilliseconds;
    final orphans = sessions
        .where((s) => s.isActive && s.startUtc > 0 && s.startUtc < cutoffMs)
        .toList();
    if (orphans.isEmpty) return 0;
    SynheartLogger.log(
      '[synheart] sweepOrphanSessions: closing ${orphans.length} stranded '
      'session(s) older than ${olderThan.inHours}h',
    );
    var closed = 0;
    for (final s in orphans) {
      try {
        if (await closeOrphanSession(s.sessionId)) {
          closed += 1;
        }
      } catch (e) {
        SynheartLogger.log(
          '[synheart] sweepOrphanSessions: closeOrphanSession(${s.sessionId}) '
          'threw: $e',
        );
      }
    }
    return closed;
  }

  /// Get a session summary (decrypted) for the given session.
  static Future<Map<String, dynamic>?> getSessionSummary(
    String sessionId,
  ) async {
    if (_coreRuntime != null) {
      final json = _coreRuntime!.getSessionSummary(sessionId);
      if (json != null) {
        try {
          return Map<String, dynamic>.from(
            const JsonDecoder().convert(json) as Map,
          );
        } catch (_) {}
      }
    }
    return null;
  }

  /// Get decrypted HSI window artifacts for a session.
  ///
  /// Each element is a full HSI 1.3 window payload. The native runtime may
  /// emit each window as either a JSON string or a map; this normalizes to
  /// `Map<String, dynamic>`.
  static Future<List<Map<String, dynamic>>> getHSIWindows(
    String sessionId, {
    WindowRange? range,
  }) async {
    if (_coreRuntime == null) return const [];
    final raw = _coreRuntime!.getHsiWindows(
      sessionId,
      startMs: range?.startMs ?? 0,
      endMs: range?.endMs ?? 0,
      limit: range?.limit ?? 0,
    );
    if (raw == null) return const [];
    return raw.map<Map<String, dynamic>>((e) {
      if (e is Map<String, dynamic>) return e;
      if (e is Map) return Map<String, dynamic>.from(e);
      if (e is String) return jsonDecode(e) as Map<String, dynamic>;
      throw FormatException(
        'unexpected HSI window element type: ${e.runtimeType}',
      );
    }).toList();
  }

  // --- Storage & retention ---

  /// Get storage usage statistics.
  static Future<StorageUsage> getStorageUsage() async {
    if (_coreRuntime != null) {
      final result = _coreRuntime!.getStorageUsage();
      if (result != null) {
        return StorageUsage(
          totalBytes: result['total_bytes'] as int? ?? 0,
          bySessionBytes:
              (result['by_session_bytes'] as Map<String, dynamic>?)?.map(
                (k, v) => MapEntry(k, v as int),
              ) ??
              {},
        );
      }
    }
    return const StorageUsage(totalBytes: 0, bySessionBytes: {});
  }

  /// Set retention policy. Sessions older than [days] will be cleaned up.
  /// Pass null to disable retention.
  static Future<void> setRetentionDays(int? days) async {
    if (days == null) return;
    if (_coreRuntime != null) {
      _coreRuntime!.setRetentionDays(days);
      return;
    }
  }

  // --- Deletion API ---

  /// Delete a session and all its artifacts locally.
  /// Creates tombstones for future sync propagation.
  static Future<void> deleteLocalSession(String sessionId) async {
    if (_coreRuntime != null) {
      _coreRuntime!.deleteSession(sessionId);
      return;
    }
  }

  /// Wipe all local data: SQLite, SMK, and reset state. Also clears
  /// the in-memory `Baselines` cache so the next read returns a
  /// cold-start snapshot instead of stale per-session values.
  static Future<void> wipeLocalData() async {
    if (_coreRuntime != null) {
      _coreRuntime!.wipeLocalData();
      shared._currentSessionHandle = null;
      shared._isRunning = false;
      Baselines.reset();
      _baselineSnapshots.reset();
      return;
    }
    // Stop if running
    if (shared._isRunning) {
      await shared._stopDataCollection();
    }

    shared._currentSessionHandle = null;
    Baselines.reset();
    _baselineSnapshots.reset();
  }

  /// Request account deletion — wipes local data and requests server-side deletion.
  ///
  /// Local data is wiped regardless of whether the server request succeeds: the
  /// user has expressed intent to delete, and a failed server hop shouldn't
  /// leave their data on this device.
  static Future<DeletionRequestResult> requestAccountDeletion() async {
    if (_coreRuntime == null) {
      return const DeletionRequestResult(
        status: 'error',
        message: 'Account deletion unavailable: core runtime not loaded.',
      );
    }
    final serverOk = _coreRuntime!.requestAccountDeletion();
    await wipeLocalData();
    return DeletionRequestResult(
      status: 'accepted',
      message: serverOk
          ? 'Local data wiped. Server deletion pending.'
          : 'Local data wiped. Server deletion request failed — retry when online.',
    );
  }

  /// Cancel a pending account deletion request.
  static Future<DeletionRequestResult> cancelAccountDeletion() async {
    if (_coreRuntime != null) {
      final ok = _coreRuntime!.cancelAccountDeletion();
      return DeletionRequestResult(
        status: ok ? 'cancelled' : 'error',
        message: ok
            ? 'Account deletion cancelled via core runtime.'
            : 'Account deletion cancellation failed.',
      );
    }
    return const DeletionRequestResult(
      status: 'error',
      message:
          'Account deletion cancellation requires core-runtime network bridge.',
    );
  }

  // --- Customer-facing data deletion (GDPR Article 17) ---

  /// Request cloud-side deletion of every byte the platform holds for the
  /// currently-bound user (the subject derived from the `client_id` passed
  /// at SDK setup / device registration). Returns a [DataDeletionRequest]
  /// with `status` typically `pending` — the server runs the chain
  /// asynchronously. Poll [dataDeletionStatus] for completion.
  ///
  /// Pair this with [wipeLocalData] for the standard "Delete my account"
  /// flow: wipe locally first so the user can't keep using the app, then
  /// request the cloud delete.
  ///
  /// `reason` and `contact` are optional audit hints. `dryRun=true` runs the
  /// auth + persistence path but skips the actual purge — useful for testing
  /// integrations end-to-end without losing real data.
  static Future<DataDeletionRequest> requestDataDeletion({
    String? reason,
    String? contact,
    bool dryRun = false,
  }) async {
    if (_coreRuntime == null) {
      throw StateError(
        'requestDataDeletion requires the core-runtime network bridge.',
      );
    }
    final json = await _coreRuntime!.requestDataDeletion(
      reason: reason,
      contact: contact,
      dryRun: dryRun,
    );
    return _parseDataDeletion(json);
  }

  /// Poll the status of a deletion request. The `status` field transitions
  /// `pending` → `inProgress` → `completed` (or `failed`). Once
  /// `status == completed`, the [DataDeletionRequest.result] map carries
  /// per-layer purge stats from the server.
  static Future<DataDeletionRequest> dataDeletionStatus(
    String requestId,
  ) async {
    if (_coreRuntime == null) {
      throw StateError(
        'dataDeletionStatus requires the core-runtime network bridge.',
      );
    }
    final json = await _coreRuntime!.getDataDeletion(requestId);
    return _parseDataDeletion(json);
  }

  /// List recent deletion requests for this caller's org. Mainly useful for
  /// support/admin dashboards.
  static Future<DataDeletionList> listDataDeletions({
    int limit = 20,
    int offset = 0,
  }) async {
    if (_coreRuntime == null) {
      throw StateError(
        'listDataDeletions requires the core-runtime network bridge.',
      );
    }
    final json = await _coreRuntime!.listDataDeletions(
      limit: limit,
      offset: offset,
    );
    if (json == null) {
      throw StateError('Empty response from listDataDeletions.');
    }
    if (json['error'] is String) {
      throw StateError(json['error'] as String);
    }
    final dataList = (json['data'] as List?) ?? const [];
    return DataDeletionList(
      requests: dataList
          .whereType<Map>()
          .map((m) => DataDeletionRequest.fromJson(m.cast<String, dynamic>()))
          .toList(growable: false),
      total: (json['total'] as int?) ?? 0,
    );
  }

  static DataDeletionRequest _parseDataDeletion(Map<String, dynamic>? json) {
    if (json == null) {
      throw StateError('Empty response from data deletion call.');
    }
    if (json['error'] is String) {
      throw StateError(json['error'] as String);
    }
    return DataDeletionRequest.fromJson(json);
  }

  // --- Auth ---

  /// Log out of the installed Core device identity, then clear local SDK data
  /// and revoke consent.
  ///
  /// Hosts must await this before deleting their own account credentials. Core
  /// v0.24 uses the still-authenticated session for a best-effort remote space
  /// leave, then removes the local device record and hardware-backed key.
  static Future<void> logout() async {
    await logoutDeviceAuth();
    _coreRuntime?.wipeLocalData();
    Baselines.reset();
    _baselineSnapshots.reset();
    try {
      await shared._consentModule?.revokeConsent();
    } catch (_) {}
  }

  /// Clear Core's installed device identity and Device Sync membership.
  ///
  /// This is idempotent. Older runtimes that do not export the v0.24 logout
  /// symbol fall back to clearing the Dart request-signing provider; the
  /// surrounding [logout] still performs the legacy local-data wipe.
  static Future<void> logoutDeviceAuth() async {
    final runtime = _coreRuntime;
    if (runtime != null && runtime.sdkDeviceLogoutAvailable) {
      await runtime.sdkLogout();
    }
    shared._deviceAuthProvider = null;
    _deviceAuthViaCoreRuntime = false;
  }

  // --- Sync API ---

  /// Enable or disable sync.
  static Future<void> setSyncEnabled(bool enabled) async {
    if (_coreRuntime != null) {
      _coreRuntime!.setSyncEnabled(enabled);
      return;
    }
  }

  /// Toggle the runtime's ambient-capture HSI emission gate.
  /// Synchronous — defers to the FFI atomic flag, no I/O. No-op when
  /// the runtime hasn't initialised. Default `false` (gate off): the
  /// runtime forwards out-of-session windows only when this is set to
  /// `true`. Sessions always pass through regardless of this flag.
  static void setAmbientCapture(bool enabled) {
    _coreRuntime?.setAmbientCapture(enabled);
  }

  /// Read the runtime's ambient-capture gate. `false` when the
  /// runtime hasn't initialised or the gate is off.
  static bool getAmbientCapture() => _coreRuntime?.getAmbientCapture() ?? false;

  /// Execute a sync cycle (push + pull).
  static Future<SyncResult> syncNow() async {
    final runtime = _coreRuntime;
    if (runtime == null) {
      throw StateError('The native sync runtime is unavailable.');
    }
    final result = await runtime.syncNow();
    return SyncResult.fromRuntimeResponse(result);
  }

  /// Create a sync-space on this device and return
  /// `{sync_space_id, recovery_key}`. The recovery_key is the only
  /// way to rejoin if the device is lost — surface it to the user.
  /// Runs off the UI isolate. Null when the runtime bridge isn't ready.
  static Future<Map<String, dynamic>?> syncCreateSpace({
    String? deviceName,
  }) async {
    final runtime = _coreRuntime;
    if (runtime == null) return null;
    return runtime.syncCreateSpace(deviceName: deviceName);
  }

  /// Mint a short-lived pairing token for another device to join the
  /// current sync-space. Returns `{token, expires_in}`. Runs off the UI
  /// isolate. Null when the runtime bridge or sync engine isn't ready.
  static Future<Map<String, dynamic>?> syncGeneratePairing() async {
    final runtime = _coreRuntime;
    if (runtime == null) return null;
    return runtime.syncGeneratePairing();
  }

  /// Join an existing sync-space using a token from
  /// [syncGeneratePairing]. Returns `{sync_space_id, status}` on
  /// success. Runs off the UI isolate. Null when the runtime bridge isn't
  /// ready.
  static Future<Map<String, dynamic>?> syncJoinSpace({
    required String pairingToken,
    String? deviceName,
  }) async {
    final runtime = _coreRuntime;
    if (runtime == null) return null;
    return runtime.syncJoinSpace(
      pairingToken: pairingToken,
      deviceName: deviceName,
    );
  }

  /// Snapshot of the sync-engine state.
  static Map<String, dynamic>? syncStatusSnapshot() =>
      _coreRuntime?.syncStatus();

  /// Unified native sync-readiness snapshot: prerequisite booleans plus a
  /// primary `state` (e.g. `CONFIGURATION_MISSING`,
  /// `DEVICE_REGISTRATION_REQUIRED`, `NO_ACTIVE_SPACE`, `SRK_UNAVAILABLE`,
  /// `READY`). Prefer `state` over inferring readiness from the separate SDK
  /// gates when diagnosing why sync isn't ready. Null when the bridge isn't
  /// wired. Cloud-upload consent is a host gate and is not included here.
  static Map<String, dynamic>? syncReadinessSnapshot() =>
      _coreRuntime?.syncReadiness();

  /// Check whether a specific Synsync operation can run.
  ///
  /// Unlike [isFeatureOperational], this does not require an active data
  /// collection session. Create, Join, and Recover also do not require an
  /// existing sync space or SRK because those operations establish/recover
  /// that state themselves.
  static Future<SyncReadiness> checkSyncReadiness({
    required SyncOperation operation,
  }) async {
    final s = shared;
    Map<String, dynamic>? nativeSnapshot;
    try {
      nativeSnapshot = _coreRuntime?.syncReadiness();
    } catch (error, stackTrace) {
      // Older native binaries do not export sync-readiness. Treat that as a
      // compatibility/readiness failure instead of crashing the host UI.
      SynheartLogger.log(
        '[Synheart] Native sync-readiness unavailable: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return SyncReadiness.evaluate(
      operation: operation,
      activated:
          s._activationManager?.isActivated(SynheartFeature.synsync) ?? false,
      cloudConsentGranted: s._hasConsentForFeature(SynheartFeature.synsync),
      capabilityAllowed: s._isCapabilityAllowed(SynheartFeature.synsync),
      nativeSnapshot: nativeSnapshot,
    );
  }

  /// Recover access to a sync-space on a fresh device using the
  /// recovery key issued at creation plus the target space id.
  /// Returns `{sync_space_id, owner_user_id, status}` on success.
  /// Runs off the UI isolate. Null when the runtime bridge isn't ready.
  static Future<Map<String, dynamic>?> syncRecoverSpace({
    required String recoveryKey,
    required String spaceId,
  }) async {
    final runtime = _coreRuntime;
    if (runtime == null) return null;
    return runtime.syncRecoverSpace(recoveryKey: recoveryKey, spaceId: spaceId);
  }

  /// Leave the current sync-space for this device only. Returns
  /// `{ok: true}` on success. Runs off the UI isolate. Null when the runtime
  /// bridge isn't ready.
  static Future<Map<String, dynamic>?> syncLeaveSpace() async {
    final runtime = _coreRuntime;
    if (runtime == null) return null;
    return runtime.syncLeaveSpace();
  }

  /// List the devices paired into the current sync-space. Returns
  /// `{devices: [...]}`. Runs off the UI isolate. Null when the runtime bridge
  /// isn't ready.
  static Future<Map<String, dynamic>?> syncListDevices() async {
    final runtime = _coreRuntime;
    if (runtime == null) return null;
    return runtime.syncListDevices();
  }

  /// Revoke a specific device from the current sync-space by its
  /// `device_id`. Returns `{ok: true}` on success. Runs off the UI isolate.
  /// Null when the runtime bridge isn't ready.
  static Future<Map<String, dynamic>?> syncRevokeDevice({
    required String deviceId,
  }) async {
    final runtime = _coreRuntime;
    if (runtime == null) return null;
    return runtime.syncRevokeDevice(deviceId: deviceId);
  }

  /// Delete the current sync-space entirely. Runs off the UI isolate. Returns
  /// `{ok: true}` on success or null when the runtime bridge isn't ready.
  static Future<Map<String, dynamic>?> syncDeleteSpace() async {
    final runtime = _coreRuntime;
    if (runtime == null) return null;
    return runtime.syncDeleteSpace();
  }

  /// Clear only local sync-space state ("start over on this device") without
  /// touching the server. Runs off the UI isolate. Returns `{ok: true}` on
  /// success or null when the runtime bridge isn't ready.
  static Future<Map<String, dynamic>?> syncClearLocalSpace() async {
    final runtime = _coreRuntime;
    if (runtime == null) return null;
    return runtime.syncClearLocalSpace();
  }

  /// Encode every locally-cached baseline envelope into a
  /// passphrase-encrypted `.srm.synheart` blob the user can share
  /// via any OS channel (AirDrop, Quick Share, email, etc.). Used
  /// when cloud sync isn't an option. Returns null when the runtime
  /// bridge isn't ready or no envelopes are cached.
  static Future<Uint8List?> baselineExportOffline({
    required String passphrase,
  }) async {
    final bridge = _coreRuntime;
    if (bridge == null) return null;
    return bridge.baselineExportOffline(passphrase: passphrase);
  }

  /// Decrypt + import a `.srm.synheart` blob. Returns
  /// `{imported, skipped, errors, kinds, exporter_device_id,
  /// created_at_ms}` on success; an `{"error": ...}` map for wrong
  /// passphrase / tampered blob; null when the runtime bridge isn't
  /// ready. Callers should hydrate the typed cache afterwards:
  /// `await Synheart.baselineSnapshots.hydrateFromLocal()`.
  static Future<Map<String, dynamic>?> baselineImportOffline({
    required String passphrase,
    required Uint8List blob,
  }) async {
    final bridge = _coreRuntime;
    if (bridge == null) return null;
    return bridge.baselineImportOffline(passphrase: passphrase, blob: blob);
  }

  /// Get current sync status.
  ///
  /// Reports whether the sync engine is enabled, read from the native
  /// sync-status snapshot and falling back to the configured value. Until
  /// 0.10.2 this returned a hardcoded `SyncStatus(enabled: false)` regardless
  /// of configuration or runtime state.
  ///
  /// [syncStatusSnapshot] and [syncReadinessSnapshot] carry the full picture
  /// (active space, device list, why sync is not ready); prefer them for
  /// anything beyond a boolean.
  @Deprecated(
    'Returns only a single boolean. Use syncReadinessSnapshot() for the '
    'primary readiness state, or syncStatusSnapshot() for engine detail. '
    'Will be removed in 0.12.0.',
  )
  static Future<SyncStatus> getSyncStatus() async {
    final snapshot = _coreRuntime?.syncStatus();
    final nativeEnabled = snapshot?['enabled'];
    if (nativeEnabled is bool) return SyncStatus(enabled: nativeEnabled);
    return SyncStatus(enabled: shared._config?.sync.enabled ?? false);
  }

  // Activation API

  /// Activate a feature. If all four authorities are satisfied
  /// (activation, consent, capability, session), the feature's module starts.
  static void activate(SynheartFeature feature) {
    shared._activationManager?.activate(feature);
    shared._reevaluateFeature(feature);
  }

  /// Deactivate a feature. Stops the feature's module if running.
  static void deactivate(SynheartFeature feature) {
    shared._activationManager?.deactivate(feature);
    shared._reevaluateFeature(feature);
  }

  /// Check whether a feature is currently activated by the developer.
  static bool isActivated(SynheartFeature feature) {
    return shared._activationManager?.isActivated(feature) ?? false;
  }

  /// Return the set of all currently activated features.
  static Set<SynheartFeature> activatedFeatures() {
    return shared._activationManager?.activatedFeatures() ?? {};
  }

  /// True when all four authority gates for [feature] are open —
  /// the developer has activated it, the user granted the required
  /// consent, the platform capability lattice allows it, and a
  /// session is active. Equivalent to the internal
  /// `_reevaluateFeature` gate; exposed so host UI can show
  /// affordances only when calling into the feature will actually
  /// succeed (e.g. the synsync sync card).
  static bool isFeatureOperational(SynheartFeature feature) {
    final s = shared;
    final activated = s._activationManager?.isActivated(feature) ?? false;
    final hasConsent = s._hasConsentForFeature(feature);
    final capabilityAllowed = s._isCapabilityAllowed(feature);
    return activated && hasConsent && capabilityAllowed && s._isRunning;
  }

  /// Initialize Synheart Core SDK
  ///
  /// This must be called before any other operations.
  ///
  /// Example:
  /// ```dart
  /// await Synheart.initialize(
  /// userId: 'anon_user_123',
  /// );
  /// ```
  ///
  /// To initialize and then start a session:
  /// ```dart
  /// await Synheart.initialize(
  /// userId: 'anon_user_123',
  /// );
  /// await Synheart.startSession(); // Start when ready
  /// ```
  /// Whether the SDK has been initialized via [initialize] or [configure].
  static bool get isInitialized => shared._isConfigured;

  /// Canonical subject id reported by the native runtime, captured after init
  /// (when `derive_subject_id_if_needed` may have changed it) and after a
  /// [rebindSubjectId]. Takes precedence over the immutable
  /// `SynheartConfig.subjectId` so the Dart side stays in lockstep with the
  /// native source of truth. Null until the runtime is loaded.
  static String? _nativeSubjectIdOverride;

  /// The subject_id this SDK instance is currently bound to, or null when not
  /// yet configured. Prefers the native runtime subject (see
  /// [_nativeSubjectIdOverride]) so callers agree with what HSI uploads are
  /// attributed under; falls back to the configured value before init.
  static String? get subjectId {
    final native = _nativeSubjectIdOverride;
    if (native != null && native.isNotEmpty) return native;
    final id = shared._config?.subjectId;
    if (id != null && id.isNotEmpty) return id;
    final userId = shared._userId;
    if (userId != null && userId.isNotEmpty) return userId;
    return null;
  }

  /// Ensure the core runtime bridge is loaded.
  ///
  /// Call this after [initialize] if another module may have initialized
  /// the SDK first without the native runtime bridge (e.g. behavior SDK).
  static void ensureRuntimeBridge({
    required String appId,
    required String subjectId,
  }) {
    if (_coreRuntime != null) return;
    try {
      final cfg = shared._config;
      if (cfg?.cloudConfig != null && (cfg?.cloudConfig?.orgId ?? '').isEmpty) {
        SynheartLogger.log(
          '[Synheart] ⚠️ ensureRuntimeBridge: CloudConfig is set but orgId is '
          'empty — cloud ingest stays disabled. Set CloudConfig.orgId.',
        );
      }
      final cachedDataDir = _resolvedDataDir;
      if (cachedDataDir == null) {
        SynheartLogger.log(
          '[Synheart] ⚠️ ensureRuntimeBridge: data_dir not yet resolved — '
          'baselines/SRM will fall back to a temp path and not persist. '
          'Call Synheart.configure() before ensureRuntimeBridge().',
        );
      }
      // Same map as [_configure], with the caller-supplied identifiers layered
      // on top of the stored config.
      _coreRuntime = CoreRuntimeBridge.create({
        ...buildRuntimeConfigMap(
          cfg ?? SynheartConfig.defaults(),
          dataDir: cachedDataDir,
        ),
        'app_id': appId,
        'subject_id': subjectId,
        'client_id': subjectId,
      });
      if (_coreRuntime != null) {
        SynheartLogger.log(
          '[Synheart] core runtime bridge loaded (ensureRuntimeBridge)',
        );
        _wireBaselineCloudHooks(_coreRuntime!);
        // SMK storage callbacks must be registered immediately after handle
        // creation and before any session lifecycle APIs.
        final storageRc = _coreRuntime!.setStorageCallbacks();
        if (storageRc == -2) {
          SynheartLogger.log(
            '[Synheart] Core build lacks synheart_core_set_storage_callbacks; state will not persist.',
          );
        } else if (storageRc == -3) {
          SynheartLogger.log(
            '[Synheart] synheart_native_secure_* symbols not found — consent tokens and device records will not persist across app restarts.',
          );
        } else if (storageRc != 0) {
          SynheartLogger.log(
            '[Synheart] synheart_core_set_storage_callbacks failed: $storageRc',
          );
        }
        // Success path (storageRc == 0) is intentionally silent — bootstrap
        // chatter. Surface only if attachment failed.
      }
    } catch (e) {
      SynheartLogger.log('[Synheart] core runtime bridge unavailable: $e');
    }
  }

  /// The currently active session, if any.
  static SessionHandle? get currentSession => shared._currentSessionHandle;

  /// Initialize the SDK.
  ///
  /// Pass a [SynheartConfig] with `appId` and `subjectId` for full validation.
  /// Alternatively pass [userId] directly for simpler setup.
  ///
  /// Safe to call multiple times — subsequent calls are no-ops if already
  /// initialized, or await the in-progress initialization if one is running.
  static Future<void> initialize({
    SynheartConfig? config,
    String? userId,
    bool autoStart = false,
    String? runtimeLogEnvFilter,
    void Function(String line)? runtimeLogForwarder,
  }) async {
    if (config != null) {
      try {
        config.validate();
      } on SynheartError catch (e) {
        // Log before rethrowing, so the actionable detail reaches the log even
        // when the host renders only a short error message.
        SynheartLogger.log(
          '[Synheart] Configuration rejected (${e.code}):\n${e.message}',
          error: e,
        );
        rethrow;
      }
    }
    return shared._configure(
      appKey: config?.appId ?? 'default',
      userId: userId ?? config?.subjectId ?? '',
      config: config,
      autoStart: autoStart,
      runtimeLogEnvFilter: runtimeLogEnvFilter,
      runtimeLogForwarder: runtimeLogForwarder,
    );
  }

  /// §1b — Initialize Core Runtime `tracing` once per process (optional if you rely on [CoreRuntimeBridge.create]).
  ///
  /// Returns `0` success, `1` already initialized, negative on failure.
  static int initRuntimeLogging({
    String? envFilter,
    void Function(String line)? onLine,
  }) {
    return CoreRuntimeBridge.initRuntimeLogging(
      envFilter: envFilter,
      onLine: onLine,
    );
  }

  /// §3 / §5 — JSON from `synheart_core_sdk_device_auth_status`, or null if unavailable.
  static Map<String, dynamic>? coreDeviceAuthStatus() {
    return _coreRuntime?.sdkDeviceAuthStatus();
  }

  /// §4 — Compact JWS for `X-Synheart-Proof` (non-ingest APIs). Use uppercase [method].
  static String? buildProofHeader(String method, String absoluteUrl) {
    return _coreRuntime?.buildProofHeader(method, absoluteUrl);
  }

  /// Whether the loaded native library exports the full core SDK device-auth ABI.
  static bool get coreSdkDeviceAuthAvailable =>
      _coreRuntime?.sdkDeviceAuthAvailable ?? false;

  /// True after a successful [sdkRegisterDevice] via the core runtime in this session.
  static bool get deviceAuthUsedCoreRuntime => _deviceAuthViaCoreRuntime;

  /// Idempotently ensures the device is registered with the auth server and
  /// that the Dart-side [DeviceAuthProvider] is wired for request signing.
  ///
  /// Safe to call from anywhere after [initialize] has been invoked. Useful
  /// for apps that want to eagerly recover from a lost registration on cold
  /// start (e.g. keychain wipe, fresh install after prior consent) without
  /// waiting for the next [grantConsent] or [startSession] to trigger it.
  ///
  /// Returns `true` if the device is registered after the call completes,
  /// `false` if device auth is not configured or registration failed.
  /// No-ops if already registered in this process.
  static Future<bool> ensureDeviceAuthRegistered() async {
    try {
      return await ensureDeviceAuthRegisteredOrThrow();
    } catch (e) {
      SynheartLogger.log(
        '[Synheart] ensureDeviceAuthRegistered failed: $e',
        error: e,
      );
      return false;
    }
  }

  /// Typed variant of [ensureDeviceAuthRegistered]. Native registration
  /// failures (including `DEVICE_ACCOUNT_MISMATCH`) are allowed to propagate
  /// as [SyncNativeException] so a host can route them correctly.
  static Future<bool> ensureDeviceAuthRegisteredOrThrow() async {
    final cfg = shared._config;
    if (cfg?.deviceAuthConfig == null) return false;
    final status = coreDeviceAuthStatus();
    final expectedSubject = subjectId ?? cfg!.subjectId;
    if (shared._deviceAuthProvider != null &&
        status?['status']?.toString() == 'registered' &&
        _deviceAuthStatusMatchesSubject(status, expectedSubject)) {
      // Provider wired — make sure the consent JWT is also ready so the
      // ingest connector can actually flush. Cheap: ensureCloudConsentReady
      // short-circuits when the runtime reports granted+fresh.
      await _maybeEnsureCloudConsentReady();
      return true;
    }
    await shared._initDeviceAuth(cfg!);
    final registered = shared._deviceAuthProvider != null;
    if (registered) {
      // Registration without a signed consent token leaves the ingest
      // connector stuck with "ERR_AUTH: ingest requires non-empty
      // X-Consent-Token" on every tick. Chain the consent-token flow so
      // callers only need one entry point.
      await _maybeEnsureCloudConsentReady();
    }
    return registered;
  }

  /// Refresh this device's server attestation without rotating its identity.
  ///
  /// Core v0.24 preserves the existing `device_id`, hardware-backed key, and
  /// Device Sync membership. Native failures surface as [SyncNativeException]
  /// so the host can distinguish expired credentials, revoked registration,
  /// and account mismatch instead of treating them as a generic `false`.
  static Future<bool> reattestDeviceAuth() async {
    final cfg = shared._config;
    if (cfg?.deviceAuthConfig == null) return false;
    final runtime = _coreRuntime;
    if (runtime == null || !runtime.sdkDeviceReattestAvailable) return false;

    final result = await runtime.sdkReattestDevice();
    final deviceId =
        result?['device_id'] as String? ?? result?['deviceId'] as String?;
    if (deviceId == null || deviceId.isEmpty) return false;

    shared._deviceAuthProvider ??= DeviceAuthProvider(
      coreRuntime: runtime,
      baseUrl: cfg!.deviceAuthConfig!.authBaseUrl,
    );
    _deviceAuthViaCoreRuntime = true;
    await _maybeEnsureCloudConsentReady();
    return true;
  }

  /// Deprecated compatibility alias. Since Core v0.24, repair means
  /// re-attesting the existing identity rather than registering a new one.
  @Deprecated('Use reattestDeviceAuth; registration is first-run only.')
  static Future<bool> reregisterDeviceAuth() {
    return reattestDeviceAuth();
  }

  /// Best-effort consent-token issuance used to chain off device-auth
  /// registration paths. Swallows errors so device-auth success isn't
  /// reported as failure just because the consent HTTP call flaked —
  /// the ingest connector will retry on its next tick once the token lands.
  static Future<void> _maybeEnsureCloudConsentReady() async {
    try {
      final ready = await ensureCloudConsentReady();
      if (!ready && kDebugMode) {
        // Demoted from production log to debug-only. The previous wording
        // ("ingest will stay blocked until consent token is issued") was
        // misleading because in the most common path — first-time consent
        // grant — this method is called from `_initDeviceAuth`'s post-step
        // before the host's main `consentSubmitFormTyped` has propagated
        // the new cloudUpload=true state through the runtime. So it
        // legitimately returns false at this exact moment but the host's
        // own submit path issues the token within ~300ms, making the log
        // contradicted by the next line in the trace. Keep it in dev
        // builds for visibility; trust the host's flow in production.
        SynheartLogger.log(
          '[Synheart] ensureCloudConsentReady not-yet-ready — host '
          'consentSubmitFormTyped will issue the token shortly.',
        );
      }
    } catch (e) {
      SynheartLogger.log(
        '[Synheart] ensureCloudConsentReady threw: $e — '
        'continuing; connector will retry on next tick.',
        error: e,
      );
    }
  }

  /// Capture the canonical subject id from the native runtime into
  /// [_nativeSubjectIdOverride] so the Dart [subjectId] getter and
  /// [consentTokenSubjectStale] agree with what the runtime is bound to.
  /// Safe to call repeatedly; a null/empty native value leaves the override
  /// unchanged (keeps the configured fallback).
  static void _syncSubjectFromNative() {
    final native = _coreRuntime?.runtimeSubjectId();
    if (native != null && native.isNotEmpty) {
      if (native != _nativeSubjectIdOverride) _invalidateHsiCache();
      _nativeSubjectIdOverride = native;
    }
  }

  /// Drop the memoized [HSIState]. A cached parse carries the subjectId it was
  /// built with, so anything that can change the subject — or tear the
  /// instance down — must clear it.
  static void _invalidateHsiCache() {
    _cachedHsiRaw = null;
    _cachedHsiState = null;
    _hsiDeduper.reset();
  }

  /// Rebind the runtime subject id when the signed-in identity changes, then
  /// re-mint cloud consent for the new subject if needed — without a full
  /// dispose/reinit. Prefer this over re-initializing the SDK on sign-in.
  ///
  /// The native runtime atomically re-points consent (`cached_subject_id` +
  /// token slot) and the cloud connector (`user_id` + subject-scoped queue);
  /// this then syncs the Dart subject and runs the existing self-heal
  /// ([_maybeEnsureCloudConsentReady]) so a stale token is reissued before the
  /// next upload. Returns true when the rebind was applied.
  static Future<bool> rebindSubjectId(String subjectId) async {
    final runtime = _coreRuntime;
    if (runtime == null) return false;
    final trimmed = subjectId.trim();
    if (trimmed.isEmpty) return false;
    final rc = runtime.rebindSubjectId(trimmed);
    if (rc < 0) {
      SynheartLogger.log(
        '[Synheart] rebindSubjectId failed (rc=$rc) for subject change.',
      );
      return false;
    }
    // Keep the Dart-side subject in lockstep with the native runtime.
    _syncSubjectFromNative();
    // rc == 1 => re-mint required, rc == 0 => valid token already loaded.
    // Run the self-heal regardless: it is a cheap no-op when already ready and
    // reissues the token for the new subject otherwise.
    await _maybeEnsureCloudConsentReady();
    return true;
  }

  Future<void> _configure({
    required String appKey,
    required String userId,
    SynheartConfig? config,
    bool autoStart = false,
    String? runtimeLogEnvFilter,
    void Function(String line)? runtimeLogForwarder,
  }) async {
    // Already done — no-op.
    if (_isConfigured) return;

    // Another call is in progress — wait for it instead of racing.
    if (_initCompleter != null) {
      return _initCompleter!.future;
    }

    _initCompleter = Completer<void>();

    _userId = userId;
    _config = config ?? SynheartConfig.defaults();

    final resolvedCfg = _config!;
    final effRuntimeFilter =
        runtimeLogEnvFilter ?? resolvedCfg.runtimeLogEnvFilter;
    if (effRuntimeFilter != null && effRuntimeFilter.isNotEmpty) {
      CoreRuntimeBridge.defaultRuntimeLogEnvFilter = effRuntimeFilter;
    }
    // Initialize core runtime bridge (best-effort; null if native lib absent).
    // NOTE: logging is deferred until AFTER coreNew — the native init emits
    // logs synchronously which crashes the async NativeCallable.listener
    // trampoline if it's already registered.
    try {
      if (resolvedCfg.cloudConfig != null &&
          (resolvedCfg.cloudConfig?.orgId ?? '').isEmpty) {
        SynheartLogger.log(
          '[Synheart] ⚠️ configure: CloudConfig is set but orgId is empty — '
          'cloud ingest stays disabled. Set CloudConfig.orgId.',
        );
      }
      final dataDir = await _resolveDataDir();
      final coreJson = buildRuntimeConfigMap(resolvedCfg, dataDir: dataDir);
      _coreRuntime = CoreRuntimeBridge.create(coreJson);
      // Now safe to register the logging callback — coreNew has returned.
      final logRc = CoreRuntimeBridge.initRuntimeLogging(
        envFilter: effRuntimeFilter,
        onLine: runtimeLogForwarder,
      );
      if (logRc < 0) {
        SynheartLogger.log(
          '[Synheart] synheart_core_init_logging returned $logRc (Core Runtime diagnostics may be limited)',
        );
      }
      if (_coreRuntime != null) {
        SynheartLogger.log('[Synheart] core runtime bridge loaded');
        // Capture the canonical subject the runtime resolved (device-auth
        // derive may have changed it) so Dart-side subject checks match native.
        _syncSubjectFromNative();
        _wireBaselineCloudHooks(_coreRuntime!);
        // SMK storage callbacks must be registered immediately after handle
        // creation and before any session lifecycle APIs.
        final storageRc = _coreRuntime!.setStorageCallbacks();
        if (storageRc == -2) {
          SynheartLogger.log(
            '[Synheart] Core build lacks synheart_core_set_storage_callbacks; state will not persist.',
          );
        } else if (storageRc == -3) {
          SynheartLogger.log(
            '[Synheart] synheart_native_secure_* symbols not found — consent tokens and device records will not persist across app restarts.',
          );
        } else if (storageRc != 0) {
          SynheartLogger.log(
            '[Synheart] synheart_core_set_storage_callbacks failed: $storageRc',
          );
        }
        // Success path (storageRc == 0) is intentionally silent — bootstrap
        // chatter. Surface only if attachment failed.

        if (resolvedCfg.deviceAuthConfig == null) {
          // Device auth is disabled in the runtime config (see the `device_auth`
          // gate above), so attaching crypto callbacks would fail with
          // `ERR_NOT_CONFIGURED: device_auth not enabled` and log a runtime
          // ERROR that reads like a real fault. Local-only hosts are a
          // supported configuration; stay quiet.
        } else if (_coreRuntime!
            .deviceAuthTemporarilyDisabledForSubjectCompat) {
          SynheartLogger.log(
            '[Synheart] Device-auth callbacks skipped: subject_id compatibility guard active.',
          );
        } else if (_coreRuntime!.sdkDeviceAuthAvailable) {
          // Attach crypto callbacks before any core SDK registration/proof
          // API is used (SDK auth sequence §2).
          //
          // Resolves `synheart_native_*` symbols directly into the runtime's
          // callback table — no Dart trampolines. Fails fast at registration
          // time if symbols are missing.
          final table = PlatformNativeSdkCryptoCallbacks.tryCreateRawTable();
          if (table == null) {
            SynheartLogger.log(
              '[Synheart] synheart_native_* crypto symbols not found — '
              'device auth will fail. Ensure synheart_auth plugin is '
              'registered and libsynheart_native_crypto.so is bundled.',
            );
          } else {
            final crc = _coreRuntime!.setSdkCryptoCallbacks(table);
            if (crc != 0) {
              SynheartLogger.log(
                '[Synheart] synheart_core_sdk_set_crypto_callbacks failed: $crc',
              );
            } else {
              _sdkCryptoCallbacksAttached = true;
              // Success path is intentionally silent — bootstrap chatter.
            }
          }
        }
      }
    } catch (e) {
      SynheartLogger.log('[Synheart] core runtime bridge unavailable: $e');
      _coreRuntime = null;
      _clearBaselineCloudHooks();
    }

    try {
      SynheartLogger.log('[Synheart] Initializing capability module..');
      _capabilityModule = CapabilityModule();
      final resolvedConfig = config ?? SynheartConfig.defaults();

      if (resolvedConfig.deviceAuthConfig != null) {
        // ── Device auth deferred ──────────────────────────────────
        // Device attestation and cloud registration are deferred until
        // cloud consent is granted. For now, load default capabilities.
        SynheartLogger.log(
          '[Synheart] Device auth configured — will activate when cloud consent is granted.',
        );
        await _capabilityModule!.loadDefaults();
      } else if (resolvedConfig.capabilityToken != null &&
          resolvedConfig.capabilitySecret != null) {
        // ── Static token path (HMAC-verified) ─────────────────────
        await _capabilityModule!.loadFromToken(
          resolvedConfig.capabilityToken!,
          resolvedConfig.capabilitySecret!,
        );
      } else if (resolvedConfig.allowUnsignedCapabilities) {
        SynheartLogger.log(
          '[Synheart] WARNING: Running with unsigned default capabilities. Do not use in production.',
        );
        await _capabilityModule!.loadDefaults();
      } else {
        throw StateError(
          'Capability token and secret are required. '
          'Provide deviceAuthConfig, capabilityToken+capabilitySecret, '
          'or set allowUnsignedCapabilities: true for debug/testing.',
        );
      }

      SynheartLogger.log('[Synheart] Initializing consent module..');
      _consentModule = ConsentModule(consentConfig: _config?.consentConfig);

      // Wire device signing into consent module so all consent-token requests
      // are signed with device identity (X-Synheart-* headers).
      // Uses lazy binding — resolves _deviceAuthProvider at call time.
      _consentModule!.setDeviceSigner(({
        required String method,
        required String path,
        required List<int> bodyBytes,
      }) async {
        if (_deviceAuthProvider == null) return <String, String>{};
        return _deviceAuthProvider!.signRequest(
          method: method,
          path: path,
          bodyBytes: Uint8List.fromList(bodyBytes),
        );
      });

      _moduleManager.registerModule(_capabilityModule!);
      _moduleManager.registerModule(_consentModule!);

      SynheartLogger.log('[Synheart] Initializing data modules..');
      _wearModule = WearModule(
        consent: _consentModule!,
        focusEnabled:
            true, // 1s interval so runtime gets enough samples per 10s window for HSI
        emotionEnabled: true,
      );
      _phoneModule = PhoneModule(
        capabilities: _capabilityModule!,
        consent: _consentModule!,
      );
      _behaviorModule = BehaviorModule(
        consent: _consentModule!,
        enableMotionLite: _config?.behaviorConfig?.enableMotionLite ?? false,
        emitRawMotionSamples:
            _config?.behaviorConfig?.emitRawMotionSamples ?? false,
      );

      _moduleManager.registerModule(
        _wearModule!,
        dependsOn: ['capabilities', 'consent'],
      );
      _moduleManager.registerModule(
        _phoneModule!,
        dependsOn: ['capabilities', 'consent'],
      );
      _moduleManager.registerModule(
        _behaviorModule!,
        dependsOn: ['capabilities', 'consent'],
      );

      SynheartLogger.log('[Synheart] Initializing Runtime..');
      final rawId = _userId!;
      final runtimeSubjectId = rawId.startsWith('sub_') ? rawId : 'sub_$rawId';
      final runtimeSessionId = 'sess_${DateTime.now().millisecondsSinceEpoch}';

      if (_coreRuntime == null) {
        SynheartLogger.log(
          '[Synheart] WARNING: Native runtime (libsynheart_core_runtime) not loaded — '
          'no HSI will be produced. Ensure native library is bundled '
          'and do a clean build (flutter clean && flutter run).',
        );
      } else {
        SynheartLogger.log(
          '[Synheart] Core runtime bridge loaded. lab=${_coreRuntime!.isLabAvailable ? "ready" : "not built"}',
        );
      }

      // Wire wearable event processor for vendor sync (RAMEN → pipeline)
      _wearModule!.setEventProcessor(
        WearableEventProcessor(
          subjectId: runtimeSubjectId,
          deviceInstallId: runtimeSessionId,
        ),
      );
      _wearModule!.setBridge(_coreRuntime);

      // Push all behavior events (notification, app_switch, touch, etc.) to the runtime
      if (_coreRuntime != null) {
        _behaviorModule!.pushBehaviorToRuntime =
            (int tsMs, int eventType, double value) {
              _coreRuntime?.pushBehavior(tsMs, eventType, value);
            };
        // The rich path, tried first. Returns null when the vendored runtime
        // predates `synheart_core_push_behavior_event`, which is the module's
        // signal to fall back to the int-coded call above. Passing the null
        // through unchanged is load-bearing — swallowing it would drop every
        // event on an older runtime instead of degrading to the legacy path.
        _behaviorModule!.pushBehaviorEventToRuntime = (event) =>
            _coreRuntime?.pushBehaviorEventJson(jsonEncode(event.toJson()));
        // The context-evidence channel, additional to the behaviour channel
        // above rather than an alternative to it. Different runtime buffer,
        // different consumer: this one feeds the person-relative context
        // window, which is the only source of `context.deviation.*` and so the
        // only source of Cognitive Load's friction index. With it unwired,
        // pause / error / scroll deviation are structurally zero on every
        // window no matter how much interaction the person produces.
        _behaviorModule!.pushContextEventToRuntime = (event) =>
            _coreRuntime?.pushContextEventJson(jsonEncode(event.toJson()));
        // Push raw 50 Hz accel batches to the Synheart Runtime so it can
        // derive features and the on-device motion classifier can run.
        //
        // NOTE: the module converts m/s² → g at this boundary. The engine's
        // `push_accel` takes g; `synheart_behavior` reports m/s². See
        // `BehaviorModule`'s call site.
        _behaviorModule!.pushAccelToRuntime =
            (int tsMs, double ax, double ay, double az) {
              _coreRuntime?.pushAccel(tsMs, ax, ay, az);
            };
      }

      _watchSessionModule = WatchSessionModule();
      _watchSessionModule!.initialize();

      _mainSession = SynheartSession();

      SynheartLogger.log('[Synheart] Initializing all modules..');
      await _moduleManager.initializeAll();

      // Bridge the runtime's persisted consent into the Dart
      // ConsentModule at boot. Without this, `_consentModule.current()`
      // sits on `ConsentSnapshot.none()` until the user explicitly
      // re-submits consent, so every module that gates on consent
      // (Behavior, Phone, Wear) short-circuits on first session.
      await _syncConsentModuleFromRuntime();

      _consentModule!.addListener(_onConsentChanged);

      // Self-heal cloud consent after a (re)init. When cloud upload was granted
      // previously but the loaded token was issued for a DIFFERENT subject
      // (e.g. a different signed-in account, or a token minted before the
      // account was known — see [consentTokenSubjectStale]), reissue it for the
      // CURRENT subject so uploads resume immediately instead of waiting for the
      // next consent change. Best-effort + idempotent: [ensureCloudConsentReady]
      // short-circuits when a valid matching token already exists (no network
      // call) and [_maybeEnsureCloudConsentReady] swallows errors when cloud
      // isn't configured/reachable.
      if (consentEffectiveStateTyped()?.cloudUpload == true) {
        await _maybeEnsureCloudConsentReady();
      }

      // Wire HSI callback from core runtime → _hsvStream
      if (_coreRuntime != null) {
        // Consent gate + fan-out live in [_deliverHsiWindow], shared with the
        // per-event push path so both producers behave identically.
        _coreRuntime!.setHsiCallback(_deliverHsiWindow);
      }

      _activationManager = ActivationManager();
      _activationManager!.activateFromConfig(resolvedConfig);

      // Runtime-only policy: no SDK-side auth API configuration/networking here.

      // Wire Syni's hybrid router to the cloud. authHeaders is lazy — it
      // resolves _deviceAuthProvider at call time (device auth registers
      // later, during consent / auto-heal) and builds an X-Synheart-Proof
      // bound to the exact request URL.
      // Resolve through ApiEndpoints rather than repeating a literal origin.
      // A hard-coded host here silently overrides SYNHEART_BASE_URL for this
      // one caller, so a build pointed at another environment would still send
      // Syni traffic to whichever host happened to be written down.
      final syniCloudOrigin =
          (resolvedConfig.cloudConfig?.baseUrl.isNotEmpty == true
                  ? resolvedConfig.cloudConfig!.baseUrl
                  : ApiEndpoints.resolvedCloudBaseUrl)
              .replaceAll(RegExp(r'/+$'), '');
      // SDK-side default for hosts that don't wire their own
      // SyniCloudConfig. Lazily produce X-Synheart-Proof headers via
      // the core runtime — Synheart.buildProofHeader works for both
      // the Dart DeviceAuthProvider path *and* the core-runtime ABI
      // path (sdkDeviceAuthAbi=true), where _deviceAuthProvider is
      // never assigned. Hosts with custom auth can still override by
      // calling configureSyniCloud(...) themselves; hosts with no
      // device auth get null/empty and fall through.
      configureSyniCloud(
        SyniCloudConfig(
          baseUrl: '$syniCloudOrigin/syni',
          authHeaders: (method, url) async {
            final proof = Synheart.buildProofHeader(method.toUpperCase(), url);
            if (proof == null || proof.isEmpty) {
              return const <String, String>{};
            }
            return {'X-Synheart-Proof': proof};
          },
          tenantId: '',
          userId: resolvedConfig.subjectId.isNotEmpty
              ? resolvedConfig.subjectId
              : (_userId ?? ''),
          orgId: resolvedConfig.cloudConfig?.orgId ?? '',
          appId: resolvedConfig.appId,
          deviceId: resolvedConfig.deviceId,
        ),
      );

      if (autoStart) {
        SynheartLogger.log('[Synheart] Starting all modules..');
        await _moduleManager.startAll();
        _wireSessionBuffers();
        _isRunning = true;
      } else {
        SynheartLogger.log(
          '[Synheart] Modules initialized but not started (autoStart=false). Call startSession() when ready.',
        );
        _isRunning = false;
      }

      _isConfigured = true;
      _initCompleter?.complete();
      SynheartLogger.log('[Synheart] Initialization complete');

      // Apply any consent queued before init finished.
      if (_pendingConsent != null) {
        final pc = _pendingConsent!;
        _pendingConsent = null;
        SynheartLogger.log('[Synheart] Applying pending consent..');
        await _grantConsent(
          biosignals: pc.biosignals,
          behavior: pc.behavior,
          phoneContext: pc.phoneContext,
          cloudUpload: pc.cloudUpload,
          vendorSync: pc.vendorSync,
          tier: pc.tier,
          grantedChannels: pc.grantedChannels,
          research: pc.research,
        );
      }

      // Cold-start auto-heal: if the runtime already has persisted cloud
      // consent (e.g. a prior session's grant) and device auth is configured
      // but not yet wired in this process, trigger registration AND refresh
      // the consent JWT so the native ingest connector can flush immediately
      // on its next tick — otherwise it logs "ERR_AUTH: device not registered"
      // (pre-fix) or "ERR_AUTH: ingest requires non-empty X-Consent-Token"
      // (post-fix) every 60s until a session starts. Non-fatal.
      if (resolvedConfig.deviceAuthConfig != null && _coreRuntime != null) {
        final effective = _coreRuntime!.consentEffectiveState();
        final cloudGranted =
            effective?['cloud_upload'] == true ||
            effective?['cloudUpload'] == true;
        if (cloudGranted) {
          if (_deviceAuthProvider == null) {
            try {
              SynheartLogger.log(
                '[Synheart] Persisted cloud consent detected — auto-activating device auth..',
              );
              await _initDeviceAuth(resolvedConfig);
            } catch (e) {
              SynheartLogger.log(
                '[Synheart] Auto device-auth activation failed: $e — '
                'will retry on session start or next consent grant.',
                error: e,
              );
            }
          }
          // Even if registration is cached from a prior session, the consent
          // JWT in the native ingest slot is in-memory state that does not
          // survive a process restart. Re-issue on every cold start when
          // cloud consent is persisted.
          if (_deviceAuthProvider != null) {
            await _maybeEnsureCloudConsentReady();
          }
        }
      }
    } catch (e, stack) {
      final completer = _initCompleter;
      // Only treat this as a failed *initialization* when configuration had
      // not already completed. Everything after `_isConfigured = true` above
      // (pending-consent replay, cold-start device-auth heal) runs inside this
      // same try — a throw there is a post-init hiccup, not a setup failure,
      // and must not reset `_isConfigured` or re-complete a settled completer.
      if (completer != null && !completer.isCompleted) {
        // Clear the completer before completing it, so a later `initialize()`
        // re-runs configuration instead of receiving this same errored future.
        // A transient failure must not be permanent.
        _initCompleter = null;
        _isConfigured = false;
        completer.completeError(e, stack);
        // The caller that started this attempt receives the error via the
        // `rethrow` below, not through this future. When no *concurrent*
        // caller is awaiting it, the completed-with-error future would
        // otherwise surface as an unhandled async error and, in a host that
        // treats those as fatal, take the app down on a recoverable failure.
        completer.future.ignore();
      }
      SynheartLogger.log(
        '[Synheart] Initialization failed: $e',
        error: e,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  /// Start a session — activates permitted modules and begins signal collection.
  ///
  /// Core must activate permitted modules, route normalized
  /// signals to synheart-engine, enable HSV updates, and enable optional HSI export.
  ///
  /// Must be called after initialize(). No data collection occurs until
  /// this method is called.
  ///
  /// At least one feature must be enabled (via [SynheartConfig] or [activate])
  /// or this throws a [StateError].
  ///
  /// [durationSec] if set, the session will end automatically after that many
  /// seconds (Session SDK boundary). If null, session runs until [stopSession].
  ///
  /// Throws a [StateError] when the native runtime is loaded but opens no
  /// session. The Dart-only path below is for hosts with NO native runtime;
  /// falling through to it with a runtime present would mint a session id for a
  /// session that does not exist.
  static Future<SessionHandle?> startSession({int? durationSec}) async {
    if (_coreRuntime != null) {
      // Same precondition the Dart fallback path enforces. Without it the
      // runtime path would happily open a session with no collection consent —
      // the modules then have nothing they are permitted to gather, so the
      // session runs, reports `collecting`, and produces nothing.
      //
      // Note this deliberately checks COLLECTION consent. Granting only
      // cloud-upload, vendor-sync, research, or syni does not make any sensor
      // available, so those must not satisfy it.
      if (!shared._hasAtLeastOneCollectionConsent()) {
        throw StateError(
          'Cannot start a session: no enabled feature has matching consent.\n\n'
          'A session needs BOTH sides of a pair — the feature enabled in '
          'SynheartConfig (wearConfig / behaviorConfig / phoneConfig) AND its '
          'consent granted (biosignals / behavior / phoneContext). Enabling '
          'wear while granting only behavior satisfies neither, so nothing '
          'would collect.\n\n'
          'Cloud upload, vendor sync, research, and syni are not collection '
          'consents — they govern what happens to data once gathered.',
        );
      }
      await shared._prepareRuntimeAuthForSessionStart();
      final result = _coreRuntime!.startSession();
      if (result != null) {
        shared._currentSessionHandle = SessionHandle(
          sessionId: result['session_id'] as String,
          startedAtMs: result['started_at_ms'] as int,
          mode: shared._config?.mode ?? SynheartMode.personal,
        );
        // The native session now exists. Anything that throws past this point
        // must tear it down, or the runtime keeps a session the host does not
        // know about — and the next startSession() is refused as already
        // active, falling through to the Dart-only path below with a handle
        // for a session the runtime never opened.
        try {
          await shared._startRuntimeLinkedCollection();
        } catch (e, st) {
          SynheartLogger.log(
            '[Synheart] startSession: collection failed to start — rolling '
            'back the native session so it is not orphaned: $e',
            error: e,
            stackTrace: st,
          );
          try {
            _coreRuntime!.stopSession();
          } catch (_) {
            // Best effort; the original failure is the one worth reporting.
          }
          shared._currentSessionHandle = null;
          shared._isRunning = false;
          rethrow;
        }
        shared._isRunning = true;

        return shared._currentSessionHandle;
      }

      // The runtime is loaded but refused to open a session. Falling through to
      // the Dart-only path below would mint a `core_<millis>` handle and report
      // `collecting` for a session the runtime never opened — no native
      // windowing, no HSI, no stored artifacts, and no error to explain it.
      throw StateError(
        'The native session failed to start.\n\n'
        'The runtime is loaded but returned no session, so nothing would be '
        'collected. This is not the local-only path — that applies only when no '
        'native runtime is present.\n\n'
        'Most often the runtime already holds an open session: call stopSession() '
        'before starting another. Check runtimeDiagnostics() for symbol or '
        'configuration problems.',
      );
    }
    await shared._startDataCollection(durationSec: durationSec);
    return shared._currentSessionHandle;
  }

  Future<void> _prepareRuntimeAuthForSessionStart() async {
    final cfg = _config;
    if (cfg == null || cfg.deviceAuthConfig == null) return;
    if (_deviceAuthProvider != null) return;
    // Device-auth registration only matters for cloud-bound uploads (HSI ingest,
    // lab payloads). If cloud is off, attestation is wasted work and the
    // backend rightly returns 403 (DEV_003). Skip silently — local-only
    // sessions don't need a registered device.
    final cloudGranted = await hasConsent('cloudUpload');
    if (!cloudGranted) {
      SynheartLogger.log(
        '[Synheart] Session start preflight: cloud upload consent off — skipping device auth.',
      );
      return;
    }
    try {
      SynheartLogger.log(
        '[Synheart] Session start preflight: initializing device auth..',
      );
      await _initDeviceAuth(cfg);
      SynheartLogger.log(
        '[Synheart] Session start preflight: device auth ready.',
      );
    } catch (e) {
      SynheartLogger.log(
        '[Synheart] Session start preflight: device auth init failed ($e). Continuing in local mode.',
      );
    }
  }

  /// Whether the main data-collection session is currently running.
  ///
  /// Reads the native runtime, which is authoritative — the Dart module flag
  /// tracks whether collection was started, a related but different thing, and
  /// would keep reporting a running session after a runtime-side teardown.
  /// Falls back to the Dart flag when the native bridge is absent.
  static bool get isSessionRunning {
    final runtime = _coreRuntime;
    if (runtime == null) return shared._isRunning;
    try {
      return runtime.isRunning;
    } catch (_) {
      // Older runtimes may not export `is_running`; the Dart flag still holds.
      return shared._isRunning;
    }
  }

  /// Stop the current session — halts module streaming and clears ephemeral buffers.
  ///
  /// Core must halt module streaming, stop synheart-engine updates,
  /// clear ephemeral buffers, and prevent further HSI export.
  static Future<void> stopSession() async {
    if (_coreRuntime != null) {
      // Snapshot the engine summary BEFORE tearing down the runtime.
      // `_coreRuntime.stopSession()` calls the native `stop_session`,
      // which drops the pipeline (engine_module sets `pipeline =
      // None`). Reading `frameCount()` after that point always
      // returns 0, which printed a misleading
      // "no HSI produced — no window completed" line at session end
      // even when several windows had landed in the session buffer.
      shared._logRuntimeSummary();
      _coreRuntime!.stopSession();
      await shared._stopRuntimeLinkedCollection();
      shared._currentSessionHandle = null;
      shared._isRunning = false;
      return;
    }
    return shared._stopDataCollection();
  }

  /// Returns a snapshot of all HSI JSON windows accumulated during the current
  /// (or most recent) session. The list is cleared when [startSession] is called.
  static List<String> getSessionHsiWindows() =>
      shared._sessionHsiBuffer.snapshot();

  /// Returns a snapshot of all raw wear samples accumulated during the current
  /// (or most recent) session. The list is cleared when [startSession] is called.
  static List<WearSample> getSessionWearSamples() =>
      shared._sessionWearBuffer.snapshot();

  /// Start wear data collection
  ///
  /// Starts collecting biosignals from wearables.
  ///
  /// Example:
  /// ```dart
  /// await Synheart.startWearCollection();
  /// ```
  static Future<void> startWearCollection({Duration? interval}) async {
    return shared._startWearCollection(interval: interval);
  }

  /// Stop wear data collection
  ///
  /// Stops collecting biosignals but keeps wear module initialized.
  ///
  /// Example:
  /// ```dart
  /// await Synheart.stopWearCollection();
  /// ```
  static Future<void> stopWearCollection() async {
    return shared._stopWearCollection();
  }

  /// Start behavior data collection
  ///
  /// Starts collecting behavioral interaction patterns.
  ///
  /// Example:
  /// ```dart
  /// await Synheart.startBehaviorCollection();
  /// ```
  static Future<void> startBehaviorCollection() async {
    return shared._startBehaviorCollection();
  }

  /// Stop behavior data collection
  ///
  /// Stops collecting behavioral data but keeps behavior module initialized.
  ///
  /// Example:
  /// ```dart
  /// await Synheart.stopBehaviorCollection();
  /// ```
  static Future<void> stopBehaviorCollection() async {
    return shared._stopBehaviorCollection();
  }

  /// Check if notification listener access is enabled (Android) or notification
  /// permission is granted (iOS). Required for behavior notification metrics.
  ///
  /// Falls back to a direct platform-channel call when the behavior SDK has
  /// not been initialized yet, so callers do not have to wait for
  /// [startBehaviorCollection] to complete.
  static Future<bool> checkNotificationListenerEnabled() async {
    final sb = shared._behaviorModule?.synheartBehavior;
    if (sb != null) {
      try {
        return await sb.checkNotificationPermission();
      } catch (e) {
        SynheartLogger.log(
          '[Synheart] checkNotificationPermission via SDK failed, '
          'falling back to direct channel: $e',
          error: e,
        );
      }
    }
    final result = await _invokeBehaviorChannel<bool>(
      'checkNotificationPermission',
    );
    return result ?? false;
  }

  /// Open system settings where the user can enable notification access.
  /// On Android: Notification listener access (Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).
  /// On iOS: Opens app settings.
  ///
  /// Falls back to a direct platform-channel call when the behavior SDK has
  /// not been initialized yet, so the system settings page still opens even
  /// if behavior collection has not started yet.
  static Future<void> openNotificationListenerSettings() async {
    final sb = shared._behaviorModule?.synheartBehavior;
    if (sb != null) {
      try {
        await sb.requestNotificationPermission();
        return;
      } catch (e) {
        SynheartLogger.log(
          '[Synheart] requestNotificationPermission via SDK failed, '
          'falling back to direct channel: $e',
          error: e,
        );
      }
    }
    await _invokeBehaviorChannel<void>('requestNotificationPermission');
  }

  static const MethodChannel _behaviorFallbackChannel = MethodChannel(
    'ai.synheart.behavior',
  );

  static Future<T?> _invokeBehaviorChannel<T>(String method) async {
    try {
      return await _behaviorFallbackChannel.invokeMethod<T>(method);
    } catch (e) {
      SynheartLogger.log(
        '[Synheart] Direct behavior channel call "$method" failed: $e',
        error: e,
      );
      return null;
    }
  }

  /// Start phone context data collection
  ///
  /// Starts collecting phone motion and context data.
  ///
  /// Example:
  /// ```dart
  /// await Synheart.startPhoneCollection();
  /// ```
  static Future<void> startPhoneCollection() async {
    return shared._startPhoneCollection();
  }

  /// Stop phone context data collection
  ///
  /// Stops collecting phone data but keeps phone module initialized.
  ///
  /// Example:
  /// ```dart
  /// await Synheart.stopPhoneCollection();
  /// ```
  static Future<void> stopPhoneCollection() async {
    return shared._stopPhoneCollection();
  }

  /// Check if wear module is collecting data
  static bool get isWearCollecting => shared._isWearCollecting;

  /// Check if behavior module is collecting data
  static bool get isBehaviorCollecting => shared._isBehaviorCollecting;

  /// Check if phone module is collecting data
  static bool get isPhoneCollecting => shared._isPhoneCollecting;

  // ── Watch Session API ─────────────────────────────────────────────────

  /// Whether a watch session is currently active.
  static bool get isWatchSessionActive =>
      shared._watchSessionModule?.isActive ?? false;

  /// The active watch session ID, if any.
  static String? get activeWatchSessionId =>
      shared._watchSessionModule?.activeSessionId;

  /// Stream of [SessionEvent]s from the active watch session.
  ///
  /// Events flow: `SessionStarted` -> `SessionFrame*` -> `SessionSummary`.
  /// Each [SessionFrame] carries HR metrics (hr_mean_bpm, rmssd_ms, sdnn_ms).
  static Stream<SessionEvent> get watchSessionEvents {
    final mod = shared._watchSessionModule;
    if (mod == null) {
      throw StateError(
        'WatchSessionModule not initialized. Call initialize() first.',
      );
    }
    return mod.events;
  }

  /// Query watch connectivity status.
  ///
  /// Returns [WatchStatus] with `reachable`, `paired`, `installed`, `supported`.
  /// Returns null if the module is not initialized or the platform doesn't
  /// support watch connectivity.
  ///
  /// Example:
  /// ```dart
  /// final status = await Synheart.getWatchStatus();
  /// if (status?.reachable == true) {
  /// print('Watch is reachable');
  /// }
  /// ```
  static Future<WatchStatus?> getWatchStatus() async {
    return shared._watchSessionModule?.getWatchStatus();
  }

  /// Start a session on the companion watch.
  ///
  /// Sends a start command to the paired watch via the Wearable Data Layer
  /// (Wear OS MessageClient / Apple Watch WCSession). The watch begins
  /// reading HR data and streams [SessionFrame] events back.
  ///
  /// Returns a broadcast stream of [SessionEvent]s.
  ///
  /// Example:
  /// ```dart
  /// final stream = Synheart.startWatchSession(
  /// SessionConfig(
  /// mode: SessionMode.focus,
  /// durationSec: 300,
  /// profile: ComputeProfile(windowSec: 60, emitIntervalSec: 5),
  /// ),
  /// );
  /// stream.listen((event) {
  /// if (event is SessionFrame) {
  /// print('HR: ${event.metrics['hr_mean_bpm']}');
  /// }
  /// });
  /// ```
  static Stream<SessionEvent> startWatchSession(SessionConfig config) {
    final mod = shared._watchSessionModule;
    if (mod == null) {
      throw StateError(
        'WatchSessionModule not initialized. Call initialize() first.',
      );
    }
    return mod.startSession(config);
  }

  /// Stop the active watch session.
  ///
  /// Sends a stop command to the watch. A [SessionSummary] event will be
  /// emitted on the session stream before it closes.
  static Future<void> stopWatchSession() async {
    await shared._watchSessionModule?.stopSession();
  }

  // ── End Watch Session API ─────────────────────────────────────────────

  /// Stream of raw wear samples
  ///
  /// Subscribe to this stream to receive real-time biosignal data.
  /// The stream respects consent - no data is emitted if consent is denied.
  ///
  /// Example:
  /// ```dart
  /// Synheart.wearSampleStream.listen((sample) {
  /// print('HR: ${sample.hr} BPM');
  /// print('RR Intervals: ${sample.rrIntervals}');
  /// });
  /// ```
  static Stream<WearSample> get wearSampleStream {
    if (shared._wearModule == null) {
      throw StateError('Wear module not initialized. Call initialize() first.');
    }
    return shared._wearModule!.rawSampleStream;
  }

  /// Stream of raw behavior events
  ///
  /// Subscribe to this stream to receive real-time behavioral interaction events.
  /// The stream respects consent - no data is emitted if consent is denied.
  ///
  /// Example:
  /// ```dart
  /// Synheart.behaviorEventStream.listen((event) {
  /// print('Event: ${event.type} at ${event.timestamp}');
  /// });
  /// ```
  static Stream<BehaviorEvent> get behaviorEventStream {
    if (shared._behaviorModule == null) {
      throw StateError(
        'Behavior module not initialized. Call initialize() first.',
      );
    }
    return shared._behaviorModule!.eventStream.events;
  }

  /// Start a behavior session
  ///
  /// Starts tracking behavioral interactions and returns a session ID.
  /// Use this session ID when stopping the session to get results.
  ///
  /// Example:
  /// ```dart
  /// final sessionId = await Synheart.startBehaviorSession();
  /// // .. user interacts with app ..
  /// final results = await Synheart.stopBehaviorSession(sessionId);
  /// print('Focus Hint: ${results.focusHint}');
  /// ```
  static Future<String> startBehaviorSession() async {
    return shared._startBehaviorSession();
  }

  /// Stop a behavior session and get results
  ///
  /// Ends the session and returns aggregated results including tap rate,
  /// keystroke rate, focus hint, and other behavioral metrics.
  ///
  /// Example:
  /// ```dart
  /// final results = await Synheart.stopBehaviorSession(sessionId);
  /// print('Tap Rate: ${results.tapRate}');
  /// print('Keystroke Rate: ${results.keystrokeRate}');
  /// print('Focus Hint: ${results.focusHint}');
  /// ```
  static Future<BehaviorSessionResults> stopBehaviorSession(
    String sessionId,
  ) async {
    return shared._stopBehaviorSession(sessionId);
  }

  /// Number of HSI snapshots pending upload (0 if cloud connector not enabled).
  static int get uploadQueueLength => _coreRuntime?.uploadQueueLength ?? 0;

  /// Wall-clock timestamp (Unix ms) of the most recent successful
  /// ingest upload. Null when nothing has uploaded yet in this
  /// process. Drive a "Synced N min ago" badge from this; do not
  /// expose [uploadQueueLength] to end users — the queue length
  /// fluctuates per flush tick and reads as scary noise.
  static int? get lastIngestSuccessAtMs => _coreRuntime?.lastIngestSuccessAtMs;

  /// Aggregate cloud-sync state for host UI. Reads
  /// [uploadQueueLength], [lastIngestSuccessAtMs], and the
  /// [consentEffectiveStateTyped] cloud flag and collapses them
  /// into one of four user-facing buckets — see
  /// [CloudSyncStatus]. The host renders a single pill from this,
  /// no need to combine signals manually.
  static CloudSyncStatus get cloudSyncStatus {
    final cloudOn = consentEffectiveStateTyped()?.cloudUpload ?? false;
    if (!cloudOn) return CloudSyncStatus.localOnly;
    final queue = uploadQueueLength;
    final lastMs = lastIngestSuccessAtMs;
    if (queue > 0) return CloudSyncStatus.syncing;
    if (lastMs != null) return CloudSyncStatus.synced;
    return CloudSyncStatus.pending;
  }

  // ── HSI history (on-device mirror of uploaded payloads) ──────────────
  //
  // The native ingest connector deletes rows from the outbound upload queue
  // on HTTP 200 — that table is pure "pending uploads". `hsi_history` is a
  // separate on-device table that keeps a copy of each successfully
  // uploaded HSI payload so apps can render offline timelines and users
  // keep access to their data after cloud storage.
  //
  // Retention is age-based (default 30 days, enforced by the native side on
  // each archive pass). Returns empty / 0 when no cloud connector is
  // configured. These are pure on-device operations — no network I/O.

  /// List archived HSI payloads (oldest first).
  ///
  /// - [since] filters rows by upload timestamp; `null` returns all.
  /// - [limit] caps the result count; `null` or `0` means unbounded.
  ///
  /// Each map is a parsed HSI JSON object (schema depends on the producer's
  /// `hsi_version`). Returns empty when the cloud connector is not wired.
  static List<Map<String, dynamic>> listHsiHistory({
    DateTime? since,
    int? limit,
  }) {
    return _coreRuntime?.hsiHistoryList(since: since, limit: limit) ?? const [];
  }

  /// Fetch normalized HSI windows from the **cloud archive** for `[from, to]`.
  ///
  /// Unlike [listHsiHistory] (the on-device 30-day mirror), this pulls the
  /// user's archived windows from the cloud — the source of truth for
  /// historical (>30-day) and cross-device HSI. Each returned map is a full HSI
  /// window payload exactly as archived (any HSI version); the host parses it
  /// with the same path it uses for local windows, so cloud and local history
  /// render identically with full axis fidelity.
  ///
  /// Consent- and device-auth-gated runtime-side; returns empty when cloud is
  /// not configured/consented, the range is empty, or the vendored runtime
  /// predates this capability (missing native symbol).
  ///
  /// NOTE: like the upload flush, the underlying FFI call performs the network
  /// round-trip synchronously (native `block_on`). It is exposed as a [Future]
  /// so hosts can `await` it, but callers should drive it from a loading state
  /// (and ideally off the UI isolate) until a fully async FFI lands.
  static Future<List<Map<String, dynamic>>> fetchCloudHsiWindows({
    required DateTime from,
    required DateTime to,
  }) async {
    final rt = _coreRuntime;
    if (rt == null) return const [];
    return rt.fetchCloudHsiWindows(
      fromMs: from.toUtc().millisecondsSinceEpoch,
      toMs: to.toUtc().millisecondsSinceEpoch,
    );
  }

  /// Number of archived HSI payloads currently on-device.
  static int hsiHistoryCount() => _coreRuntime?.hsiHistoryCount() ?? 0;

  /// Wipe the on-device HSI history. Intended for user-initiated
  /// "delete my data" flows. Does NOT clear the outbound upload queue —
  /// pending uploads will still be sent to the cloud unless stopped.
  /// Returns true on success, false if the runtime is unavailable.
  static bool clearHsiHistory() => _coreRuntime?.hsiHistoryClear() ?? false;

  /// Batch id from the last successful cloud ingest (null if none yet).
  static String? get lastUploadBatchId => _lastUploadBatchId;

  /// Time of the last successful cloud ingest (null if none yet).
  static DateTime? get lastUploadAt => _lastUploadAt;

  /// Last upload error message (null when last attempt succeeded or no attempt yet).
  static String? get lastUploadError => _lastUploadError;

  /// Time of the last upload attempt (success or failure); null if no attempt yet.
  static DateTime? get lastUploadAttemptAt => _lastUploadAttemptAt;

  /// Bridge-first ingestion facade for queue + upload orchestration.
  static SynheartIngestion get ingestion => SynheartIngestion.instance;

  /// Whether a consent type is currently ENFORCEABLE — which is not the same
  /// question as whether the user granted it.
  ///
  /// Once a cloud consent client is configured, the runtime returns false for
  /// every consent type until the consent service has issued a token, whatever
  /// the user chose:
  ///
  /// ```rust
  /// if cloud_configured && self.consent_status() != ConsentStatus::Granted {
  ///     return false;
  /// }
  /// ```
  ///
  /// So a local-only app sees the user's choice here, while a cloud-configured
  /// app sees the user's choice AND cloud confirmation. A false result does not
  /// mean the user declined.
  ///
  /// To read what the user actually chose, use [consentEffectiveStateTyped].
  /// Use this when the answer gates an action that must not proceed without
  /// cloud-side confirmation, such as an upload.
  ///
  /// Accepts either spelling of a consent type (`cloudUpload` or
  /// `cloud_upload`); the Dart fallback path only understands camelCase, so the
  /// name is normalised before dispatch.
  ///
  /// Example:
  /// ```dart
  /// bool hasConsent = await Synheart.hasConsent('biosignals');
  /// ```
  static Future<bool> hasConsent(String consentType) async {
    if (_coreRuntime != null) {
      return _coreRuntime!.hasConsent(_runtimeConsentKey(consentType));
    }
    return shared._hasConsent(_dartConsentKey(consentType));
  }

  /// The two consent vocabularies, and the translation between them.
  ///
  /// The native runtime keys consent in snake_case (`cloud_upload`); the Dart
  /// API and `ConsentSnapshot` use camelCase (`cloudUpload`). Every other call
  /// site converts before crossing the boundary — `grantConsent` sends
  /// `cloud_upload`, `consentEffectiveState` reads `cloud_upload` back.
  ///
  /// [hasConsent] did not, and passed the caller's spelling through unchanged.
  /// Neither spelling then worked in both places: `hasConsent('cloudUpload')`
  /// asked the runtime about a key it does not define, and
  /// `hasConsent('cloud_upload')` missed every case in the Dart fallback's
  /// switch. Both returned false regardless of what the user had granted — so a
  /// caller gating on cloud upload saw consent as absent while the effective
  /// state reported it granted.
  ///
  /// Translating here rather than at the call sites keeps both spellings
  /// working for hosts that already pass one or the other.
  static const Map<String, String> _consentKeyCamelToSnake = {
    'biosignals': 'biosignals',
    'behavior': 'behavior',
    'phoneContext': 'phone_context',
    'cloudUpload': 'cloud_upload',
    'vendorSync': 'vendor_sync',
    'research': 'research',
    'syni': 'syni',
  };

  /// Accept either spelling, return the snake_case key the runtime defines.
  /// Unknown values pass through so a newer consent type still reaches the
  /// runtime rather than being silently rewritten.
  static String _runtimeConsentKey(String consentType) =>
      _consentKeyCamelToSnake[consentType] ?? consentType;

  /// Accept either spelling, return the camelCase key the Dart fallback's
  /// switch matches on.
  static String _dartConsentKey(String consentType) {
    for (final entry in _consentKeyCamelToSnake.entries) {
      if (entry.value == consentType) return entry.key;
    }
    return consentType;
  }

  /// Override consent cloud endpoint routing for the active runtime.
  static bool consentConfigureCloud({required String baseUrl, String? appId}) {
    final rt = _coreRuntime;
    if (rt == null) return false;
    final resolvedAppId = appId ?? shared._config?.appId;
    if (resolvedAppId == null || resolvedAppId.isEmpty) return false;
    return rt.consentConfigureCloud(baseUrl, resolvedAppId);
  }

  /// Read editable consent form JSON contract from runtime.
  ///
  /// Prefer [consentGetEditableFormTyped] for typed access.
  static Map<String, dynamic>? consentGetEditableForm() {
    return _coreRuntime?.consentGetEditableForm();
  }

  /// Read editable consent form as a typed [ConsentForm].
  ///
  /// Returns `null` when the runtime bridge is unavailable.
  static ConsentForm? consentGetEditableFormTyped() {
    final raw = _coreRuntime?.consentGetEditableForm();
    if (raw == null) return null;
    return ConsentForm.fromJson(raw);
  }

  /// Submit consent form JSON to runtime using offline-first semantics.
  ///
  /// Prefer [consentSubmitFormTyped] for typed submission.
  /// Enrol this device in a research study by redeeming an access code and its
  /// study (cohort) code. Uses the device's existing cloud credentials; no
  /// tokens are exposed to the caller. Returns the runtime's JSON response — the
  /// enrolment on success, or a map with an `error` key — or null when the
  /// native runtime is unavailable.
  ///
  /// Cloud consent must be granted first (the enrolment rides the device's
  /// consent credential).
  static Future<Map<String, dynamic>?> enrolResearchStudy({
    required String accessCode,
    required String studyCode,
  }) {
    return _researchStudyCall(accessCode, studyCode, validateOnly: false);
  }

  /// Preview a research-study access + study code pair without redeeming the
  /// code. Same return contract as [enrolResearchStudy].
  static Future<Map<String, dynamic>?> validateResearchStudyCodes({
    required String accessCode,
    required String studyCode,
  }) {
    return _researchStudyCall(accessCode, studyCode, validateOnly: true);
  }

  /// Withdraw from the participant's active research study for this app. No
  /// codes are needed — the participant and app are taken from the device's
  /// signed cloud credential. Idempotent: withdrawing with no active enrolment
  /// succeeds. After withdrawal the device's next token mint drops the study_id
  /// claim, so uploads stop being attributed to the study.
  static Future<Map<String, dynamic>?> withdrawResearchStudy() {
    final rt = _coreRuntime;
    if (rt == null) return Future.value(null);
    return rt.withdrawResearchStudy();
  }

  /// Read the device's CURRENT active research-study enrolment for this app —
  /// the AUTHORITATIVE attribution state. This is the same (participant_id,
  /// app_id) lookup the consent-service mint uses to stamp the study_id claim on
  /// upload tokens, so `enrolled: true` means this app's uploads are attributed
  /// to the study. Use it to correct a stale local "enrolled" flag. No codes
  /// needed — identity comes from the device's signed cloud credential. Returns
  /// `{enrolled: bool, study: {...}, enrolment: {...}}`, or null when the native
  /// runtime is unavailable.
  static Future<Map<String, dynamic>?> researchStudyStatus() {
    final rt = _coreRuntime;
    if (rt == null) return Future.value(null);
    return rt.researchStudyStatus();
  }

  /// Persist a durable study-consent record to the consent service.
  ///
  /// Records the user's consent to a specific study-consent document version so
  /// there is a durable, server-side record of what was agreed to and when.
  /// [consentDocumentVersion] and [signedAt] identify the document and the
  /// moment of consent; [affirmations] is an arbitrary map of per-item consent
  /// states, and [signature] / [consentDocumentHash] are optional integrity
  /// fields. [userId] defaults to the configured subject when omitted. Returns
  /// the created record's `{id, created_at}` on success, or null when the native
  /// runtime is unavailable.
  static Future<Map<String, dynamic>?> recordStudyConsent({
    required String appId,
    String? deviceId,
    required String userId,
    String? studyId,
    required String consentDocumentVersion,
    String? consentDocumentHash,
    Map<String, dynamic>? affirmations,
    String? signature,
    required String signedAt,
  }) {
    final rt = _coreRuntime;
    if (rt == null) return Future.value(null);
    return rt.recordStudyConsent({
      'app_id': appId,
      if (deviceId != null) 'device_id': deviceId,
      'user_id': userId,
      if (studyId != null) 'study_id': studyId,
      'consent_document_version': consentDocumentVersion,
      if (consentDocumentHash != null)
        'consent_document_hash': consentDocumentHash,
      if (affirmations != null) 'affirmations': affirmations,
      if (signature != null) 'signature': signature,
      'signed_at': signedAt,
    });
  }

  /// Request erasure of the data the participant contributed to their study for
  /// this app — the deletion the consent copy promises alongside withdrawal. No
  /// identifiers are needed; the participant and app are taken from the device's
  /// signed cloud credential. Returns the runtime's JSON response or null when
  /// the native runtime is unavailable.
  ///
  /// When [dryRun] is true the response is an inventory preview
  /// (`{dry_run: true, bronze_objects: N, ...}`) and nothing is deleted — show
  /// it for confirmation. A real request is accepted asynchronously and carries
  /// a `request_id` (`{request_id, status: 'pending', ...}`). Idempotent: with
  /// no enrolment the response is a no-op (`{deleted: false}`).
  static Future<Map<String, dynamic>?> requestStudyDataDeletion({
    bool dryRun = false,
  }) {
    final rt = _coreRuntime;
    if (rt == null) return Future.value(null);
    return rt.requestStudyDataDeletion(dryRun: dryRun);
  }

  static Future<Map<String, dynamic>?> _researchStudyCall(
    String accessCode,
    String studyCode, {
    required bool validateOnly,
  }) async {
    final rt = _coreRuntime;
    if (rt == null) return null;
    final access = accessCode.trim();
    final study = studyCode.trim();
    if (access.isEmpty || study.isEmpty) {
      return {'error': 'access_code and study_code are required'};
    }
    return rt.enrolResearchStudy(
      accessCode: access,
      studyCode: study,
      validateOnly: validateOnly,
    );
  }

  static Future<Map<String, dynamic>?> consentSubmitForm({
    required Map<String, dynamic> formJson,
    String? deviceId,
    String? platform,
    String? userId,
  }) async {
    final rt = _coreRuntime;
    final consentCfg = shared._config?.consentConfig;
    if (rt == null || consentCfg == null) return null;
    final resolvedDeviceId = deviceId ?? consentCfg.deviceId;
    final resolvedPlatform = platform ?? consentCfg.platform;
    final resolvedUserId = userId ?? consentCfg.userId ?? shared._userId;
    if (resolvedDeviceId == null ||
        resolvedDeviceId.isEmpty ||
        resolvedPlatform.isEmpty) {
      return {
        'error':
            'consent_submit_form requires non-empty device_id and platform',
      };
    }

    // Direct-submit path is used by runtime UI toggles that bypass
    // [grantConsent]. If the form grants cloud upload and device auth is
    // configured but not yet wired, kick the device registration off in
    // the background so the ingest connector picks it up on its next
    // flush tick. Non-fatal on failure.
    //
    // We deliberately do NOT `await` this. ensureDeviceAuthRegistered →
    // _initDeviceAuth runs the 7-step Play Integrity bind + token mint +
    // HTTPS POST flow as an FFI call on the main isolate; on a cold
    // IntegrityService bind that parks the main thread for multiple
    // seconds, which trips Android's ANR watchdog (SIGQUIT, "Wrote
    // stack traces to tombstoned") on first-time signup — exactly when
    // this consent submit handler is mid-call. The sibling
    // [grantConsent] path (line ~4040) was already fixed in v17; this
    // direct-submit path needed the same treatment.
    //
    // Host UIs that need to know when registration finishes observe
    // `runtime.sdkDeviceAuthStatus()` (the "Setting up your workspace"
    // card pattern); they don't need this call site to block for them.
    final allowCloud =
        formJson['allow_cloud'] == true ||
        formJson['allowCloud'] == true ||
        formJson['cloud_upload'] == true ||
        formJson['cloudUpload'] == true;
    if (allowCloud &&
        shared._config?.deviceAuthConfig != null &&
        shared._deviceAuthProvider == null) {
      unawaited(
        ensureDeviceAuthRegistered().then(
          (registered) {
            if (!registered) {
              SynheartLogger.log(
                '[Synheart] consentSubmitFormTyped: background device-auth '
                'registration did not complete (cloud-upload consent on '
                'but registration returned false). Will retry on the next '
                'session start.',
              );
            }
          },
          onError: (Object e, StackTrace st) {
            SynheartLogger.log(
              '[Synheart] consentSubmitFormTyped: background device-auth '
              'registration threw: $e',
              error: e,
              stackTrace: st,
            );
            // Continue — local mode still works; cloud upload will retry
            // once registration eventually succeeds.
          },
        ),
      );
    }

    final result = await rt.consentSubmitForm(
      deviceId: resolvedDeviceId,
      platform: resolvedPlatform,
      userId: resolvedUserId,
      formJson: formJson,
    );

    // The runtime's ConsentForm parser covers biosignals / phone_context
    // / behavior / cloud / research / vendor_sync. Propagate `syni`
    // through the per-type grant/revoke FFI when the host included it
    // on the form so the runtime state stays in sync — and the
    // post-submit `_syncConsentModuleFromRuntime` below picks the new
    // value up. Skipped when the submit itself errored or the key
    // wasn't sent.
    if ((result == null || result['error'] == null) &&
        formJson.containsKey('syni')) {
      await (formJson['syni'] == true
          ? rt.grantConsent('syni')
          : rt.revokeConsent('syni'));
    }

    // Bridge the runtime's effective state into the Dart ConsentModule.
    //
    // Without this, `ConsentModule._currentConsent` stays at its
    // `ConsentSnapshot.none()` boot default — and everything that gates
    // on `_consent.current().allowsChannel(..)` (BehaviorModule,
    // PhoneModule, WearModule) sees no consent forever, even though
    // runtime correctly reports it granted. Downstream symptoms:
    // `BehaviorModule._startTrackingIfNeeded: SKIP (consent channel not
    // granted)`, `synheart_behavior` never initializes,
    // `Synheart.behaviorEventStream` stays empty for the app session.
    //
    // Fire-and-forget so a sync failure here never blocks the form
    // submit result.
    if (result == null || result['error'] == null) {
      // ignore: discarded_futures — sync is observational, not on the critical path
      shared._syncConsentModuleFromRuntime();
    }

    return result;
  }

  /// Pull the runtime's effective consent state and push it into the
  /// Dart [ConsentModule] so all consumers that read `_consent.current()`
  /// (modules, observers) see the truth instead of the stale
  /// `ConsentSnapshot.none()` default set at boot.
  ///
  /// No-ops if either the runtime bridge or the Dart consent module
  /// isn't available yet.
  Future<void> _syncConsentModuleFromRuntime() async {
    final effective = consentEffectiveStateTyped();
    if (effective == null) return;
    final module = _consentModule;
    if (module == null) return;
    try {
      final snapshot = ConsentSnapshot(
        biosignals: effective.biosignals,
        behavior: effective.behavior,
        phoneContext: effective.phoneContext,
        cloudUpload: effective.cloudUpload,
        syni: effective.syni,
        vendorSync: effective.vendorSync,
        research: effective.research,
        timestamp: DateTime.now(),
      );
      await module.updateConsent(snapshot);
      SynheartLogger.log(
        '[Synheart] Dart ConsentModule synced from runtime: '
        'biosignals=${effective.biosignals}, '
        'behavior=${effective.behavior}, '
        'phoneContext=${effective.phoneContext}, '
        'cloudUpload=${effective.cloudUpload}, '
        'vendorSync=${effective.vendorSync}, '
        'research=${effective.research}, '
        'syni=${effective.syni}',
      );
    } catch (e, st) {
      SynheartLogger.log(
        '[Synheart] Failed to sync ConsentModule from runtime: $e',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Submit a typed [ConsentForm] to runtime using offline-first semantics.
  ///
  /// Returns the raw runtime response map (`{ synced, accepted, token }` on
  /// success, `{ error }` on failure, `null` if the bridge is unavailable).
  static Future<Map<String, dynamic>?> consentSubmitFormTyped({
    required ConsentForm form,
    String? deviceId,
    String? platform,
    String? userId,
  }) {
    return consentSubmitForm(
      formJson: form.toJson(),
      deviceId: deviceId,
      platform: platform,
      userId: userId,
    );
  }

  /// Read high-level consent status machine from runtime.
  static Map<String, dynamic>? consentStatus() {
    return _coreRuntime?.consentStatus();
  }

  /// Read runtime effective accepted state summary.
  ///
  /// Prefer [consentEffectiveStateTyped] for typed access.
  static Map<String, dynamic>? consentEffectiveState() {
    return _coreRuntime?.consentEffectiveState();
  }

  /// Read runtime effective accepted state as a typed [ConsentEffectiveState].
  ///
  /// Returns `null` when the runtime bridge is unavailable.
  static ConsentEffectiveState? consentEffectiveStateTyped() {
    final raw = _coreRuntime?.consentEffectiveState();
    if (raw == null) return null;
    return ConsentEffectiveState.fromJson(raw);
  }

  /// Broadcast stream of consent snapshots. Emits whenever any channel
  /// is granted or revoked. Useful for hosts that render consent state
  /// in multiple places and want them to stay in sync without polling
  /// [consentEffectiveStateTyped] or re-dispatching reads manually
  /// after every change.
  ///
  /// Empty stream when the SDK isn't initialised yet.
  static Stream<ConsentSnapshot> get consentChanges {
    return shared._consentModule?.observe() ??
        const Stream<ConsentSnapshot>.empty();
  }

  /// Whether consent token should be refreshed soon.
  static bool consentNeedsTokenRefresh() {
    return _coreRuntime?.consentNeedsTokenRefresh() ?? false;
  }

  /// Clear stored consent artifacts in runtime.
  static bool consentClearStored() {
    return _coreRuntime?.consentClearStored() ?? false;
  }

  Future<bool> _hasConsent(String consentType) async {
    if (_consentModule == null) {
      return false;
    }

    final consent = _consentModule!.current();
    switch (consentType) {
      case 'biosignals':
        return consent.biosignals;
      case 'behavior':
        return consent.behavior;
      case 'phoneContext':
        return consent.phoneContext;
      case 'cloudUpload':
        return consent.cloudUpload;
      case 'syni':
        return consent.syni;
      case 'vendorSync':
        return consent.vendorSync;
      case 'research':
        return consent.research;
      default:
        return false;
    }
  }

  /// Revoke consent for a specific data type
  ///
  /// Example:
  /// ```dart
  /// await Synheart.revokeConsentType('biosignals');
  /// ```
  static Future<void> revokeConsentType(String consentType) async {
    if (_coreRuntime != null) {
      await _coreRuntime!.revokeConsent(consentType);
      // Fall through to Dart consent module so UI stays in sync
    }
    return shared._revokeConsentType(consentType);
  }

  Future<void> _revokeConsentType(String consentType) async {
    if (_consentModule == null) {
      throw StateError('Consent module not initialized');
    }

    final current = _consentModule!.current();
    final updated = ConsentSnapshot(
      biosignals: consentType == 'biosignals' ? false : current.biosignals,
      behavior: consentType == 'behavior' ? false : current.behavior,
      phoneContext: consentType == 'phoneContext'
          ? false
          : current.phoneContext,
      cloudUpload: consentType == 'cloudUpload' ? false : current.cloudUpload,
      syni: consentType == 'syni' ? false : current.syni,
      vendorSync: consentType == 'vendorSync' ? false : current.vendorSync,
      research: consentType == 'research' ? false : current.research,
      timestamp: DateTime.now(),
    );

    await _consentModule!.updateConsent(updated);
  }

  /// Get latest HSI JSON (latest runtime output), or null if none produced yet.
  String? get currentState {
    return _hsvStream.hasValue ? _hsvStream.value : null;
  }

  /// Get the currently configured user id (if initialized)
  String? get userId => _userId;

  /// Get behavior module for recording events
  BehaviorModule? get behaviorModule => _behaviorModule;

  /// Breathing compliance detector.
  /// Returns null until the core runtime bridge is initialized.
  /// Use [Synheart.breathing] (static) from app code; this instance getter
  /// exists for symmetry with the other module getters.
  BreathingModule? get breathingModule =>
      _coreRuntime == null ? null : BreathingModule(_coreRuntime!);

  /// Static breathing accessor — matches `Synheart.setTaskType` usage in apps.
  /// Returns null until the core runtime bridge is initialized.
  static BreathingModule? get breathing =>
      _coreRuntime == null ? null : BreathingModule(_coreRuntime!);

  // -------------------------------------------------------------------------
  // Syni — adaptive AI agent (gated feature)
  // -------------------------------------------------------------------------
  //
  // Lazily constructed once `consent.syni == true`. The module performs its
  // own install lifecycle (model download, persona materialization, engine
  // load on a worker isolate). See `lib/src/modules/syni/syni_module.dart`.

  static SyniModule? _syni;
  static SyniCloudConfig? _syniCloudConfig;
  static SyniServiceClient? _syniServiceClient;
  static CoreRuntimeBridge? _syniServiceRuntime;

  static SyniServiceClient? _resolveSyniService() {
    final runtime = _coreRuntime;
    if (runtime == null) return null;
    if (!identical(_syniServiceRuntime, runtime)) {
      _syniServiceRuntime = runtime;
      _syniServiceClient = SyniServiceClient(
        CoreRuntimeSyniServiceTransport(runtime),
      );
    }
    return _syniServiceClient;
  }

  /// Inject (or clear) the cloud config used by Syni's hybrid router.
  ///
  /// With a config set, `Synheart.syni!.hasCloud` is true and chat calls can
  /// route to the Syni cloud (per `SyniExecutionMode`). Without it, Syni
  /// runs local-only.
  ///
  /// Resets the cached `SyniModule` so the next `Synheart.syni` access picks
  /// up the new config. Safe to call before or after `initialize()`.
  static void configureSyniCloud(SyniCloudConfig? config) {
    _syniCloudConfig = config;
    _syni = null;
  }

  /// Adaptive AI client. Returns null until the Synheart facade is running.
  /// Once non-null the caller drives `install`, `chat`, and `uninstall`
  /// directly on it.
  ///
  /// Operational status follows the four-authority model — `chat()` only
  /// succeeds after `install()` reaches [SyniInstalled], and the capability
  /// gate (`isFeatureOperational(SynheartFeature.syni)`) returns true only
  /// when installed.
  ///
  /// **V1 note**: this getter does NOT yet check `consent.syni` because
  /// `ConsentForm` does not expose a `syni` channel — there is no way for a
  /// user to grant syni consent through the public form. For V1 the explicit
  /// `install()` call (which downloads a multi-GB model) functions as the
  /// opt-in moment. Re-enable the consent check once `ConsentForm` grows a
  /// `syni` field and host apps surface it in their consent UI.
  ///
  /// The device-signed [SyniModule.service] client is independent of the local
  /// model install lifecycle. It becomes available whenever the Core runtime
  /// bridge exposes the Syni service ABI and authentication is configured.
  static SyniModule? get syni {
    // Gate on SDK *initialization*, not session-running state — Syni is
    // usable any time after `initialize()`, independent of whether a
    // session is active.
    if (!shared._isConfigured) return null;
    return _syni ??= SyniModule(
      cloudConfig: _syniCloudConfig,
      serviceProvider: _resolveSyniService,
      hsiSnapshot: () => Synheart.currentHSIState,
    );
  }

  /// Get the core runtime bridge (for diagnostics and direct FFI access).
  CoreRuntimeBridge? get coreRuntime => _coreRuntime;

  /// Whether the runtime uses batch ingest on stop (true) or streaming/realtime (false).
  /// Batch ingest is now managed by the core runtime; this returns the config value.
  static bool get batchIngestOnStop =>
      shared._batchIngestOnStop ?? shared._config?.batchIngestOnStop ?? false;

  /// Set runtime mode: true = batch ingest when session stops, false = realtime HSI every ~10s.
  /// Applies to the next session start; safe to call when initialized.
  static void setBatchIngestOnStop(bool value) {
    shared._batchIngestOnStop = value;
  }

  /// Push a touch behavior event into the runtime for the given timestamp (ms since epoch).
  /// Use from game screens so taps are reflected in behavioral_metrics in exports/lab.
  /// No-op if runtime or bridge is unavailable.
  static void pushBehaviorTouch(int tsMs) {
    _coreRuntime?.pushBehavior(tsMs, RuntimeBehaviorEvent.input.code, 1.0);
  }

  /// Push a notification-received behavior event into the runtime for the given timestamp (ms since epoch).
  /// Call when the app displays or receives a notification so behavioral_metrics include notification counts.
  /// No-op if runtime or bridge is unavailable.
  ///
  /// This is the **payload-less** path: it reaches the engine as
  /// `NotificationReceived { action: None, source_app_id: None }`, so the
  /// interruption is counted but its cost is not measurable. Prefer
  /// [pushBehaviorEvent] with a `BehaviorEventInput.notification(...)` carrying
  /// the action and source app wherever the platform can supply them.
  static void pushBehaviorNotificationReceived(int tsMs) {
    _coreRuntime?.pushBehavior(
      tsMs,
      RuntimeBehaviorEvent.notification.code,
      1.0,
    );
  }

  // ── Rich behavior / context events ──────────────────────────────────
  //
  // The typed path. Unlike `pushBehavior(ts, code, value)` these carry the
  // variant payload the engine's behavioural feature group actually reads.

  /// Which mobile-host ABI calls the loaded native runtime exports.
  ///
  /// A binding existing in this SDK is not the same as the call working on the
  /// device: the vendored runtime is a pinned artifact and lags the source
  /// tree. Every `false` entry is a call that silently no-ops (or returns
  /// `null`) — drive a capability table off this rather than assuming, and
  /// re-vendor with `synheart install runtime` to close a gap.
  ///
  /// Empty when the native runtime is not loaded at all.
  static Map<String, bool> get mobileHostAbiSupport =>
      _coreRuntime?.mobileHostAbiSupport ?? const <String, bool>{};

  /// Whether the loaded runtime can take rich behavior events.
  ///
  /// Check this before choosing between the windowed-summary path and the
  /// per-keystroke legacy path — the two must never both run for the same
  /// keystrokes, and deciding after a failed push means a window is already
  /// buffered with nowhere to go.
  static bool get supportsRichBehaviorEvents =>
      _coreRuntime?.supportsRichBehaviorEvents ?? false;

  /// Push a typed behavior event carrying its full payload.
  ///
  /// Returns the runtime's status (`0` = accepted), or `null` when the loaded
  /// runtime does not export `synheart_core_push_behavior_event` — a `null`
  /// means "this build cannot take rich events", not "the event was bad".
  ///
  /// **Do not double-count.** If you send a windowed `Typing` summary, do not
  /// also push the raw keystrokes that produced it: the engine counts both and
  /// every rate feature roughly doubles.
  static int? pushBehaviorEvent(BehaviorEventInput event) =>
      _coreRuntime?.pushBehaviorEventJson(jsonEncode(event.toJson()));

  /// Push one privacy-preserving context event — keyboard, pointer or
  /// shortcut.
  ///
  /// This is the **only** source of `context.deviation.*`, and therefore the
  /// only source of Cognitive Load's friction index (CFI). A host that pushes
  /// rich behaviour events but no context events leaves `pause_elevation`,
  /// `err_elevation` and `scroll_deviation` structurally zero on every window.
  ///
  /// It is a *second* channel, not an alternative to [pushBehaviorEvent]: the
  /// two write to different runtime buffers with different consumers, so one
  /// event on each per user action is correct and is not a double count.
  /// Pushing the same event twice on this channel is — feed each event once.
  ///
  /// **Keyboard events must come from the host's text layer.** Native taps are
  /// keystroke-ambiguous on Android, so the SDK's translator drops them; a
  /// `TextField` listener, IME or keyboard extension is what can actually tell
  /// an insertion from a deletion. Send [ContextEventInput.textChange] for
  /// both directions: `err_rate` is `N_corr / N_key`, so corrections without
  /// the keystrokes they corrected spike the error rate to its ceiling.
  ///
  /// Returns `0` on acceptance, or `null` when the symbol is absent. A
  /// non-zero status most often means the runtime was built without the
  /// `app-context` cargo feature, which compiles the call as an inert stub
  /// that always returns `1` — not that the payload was wrong.
  static int? pushContextEvent(ContextEventInput event) =>
      _coreRuntime?.pushContextEventJson(jsonEncode(event.toJson()));

  /// Push a raw context-event payload.
  ///
  /// Escape hatch for a host that needs a shape this SDK's version of
  /// [ContextEventInput] does not model yet. Prefer the typed call: the wire
  /// form is an externally-tagged Rust enum, a payload that does not parse
  /// buffers nothing, and the failure is indistinguishable from a runtime
  /// built without the context feature.
  static int? pushContextEventJson(Map<String, dynamic> event) =>
      _coreRuntime?.pushContextEventJson(jsonEncode(event));

  /// Declare which application is in the foreground.
  ///
  /// The call that gives the engine an app identity at all. Without it the
  /// runtime's `current_app` stays `None`, `None` resolves to the `Unknown`
  /// app category, and `Unknown`'s interpretation-mask row is **all zeros** —
  /// so CFI / Cognitive Load, Stress `B`, Mental Fatigue `B` and Focus's
  /// deviation sub-terms all read `0` for a person who was working the whole
  /// time.
  ///
  /// [app] is an Android package name or iOS bundle id. Send it at session
  /// start, on every foreground resume, and periodically — repeats are cheap
  /// and are treated as steady-state observations rather than app switches, so
  /// a heartbeat does not fabricate fragmentation. The SDK runs that heartbeat
  /// for you; call this directly only for a source the SDK does not have.
  ///
  /// Returns the runtime status (`0` = accepted), or `null` when the runtime
  /// does not export `push_behavior_event` — the legacy int-coded call carries
  /// no payload and so cannot name an app.
  static int? pushAppForeground(String app, {int? tsMs}) => pushBehaviorEvent(
    BehaviorEventInput.appForeground(
      tsMs ?? DateTime.now().millisecondsSinceEpoch,
      app,
    ),
  );

  /// Score today's accumulated Strain and attach it to the next HSI frame.
  ///
  /// Returns the score JSON, or `null` when the symbol is absent **or** when
  /// the day has nothing scorable accumulated yet. The second case is normal.
  ///
  /// **Call this before [rollDay].** Rolling finalises the day and clears the
  /// values Strain is computed from, so a host that rolls first gets `null`
  /// every day and never emits a Strain score. `rollDay` does not score for
  /// you — it validates the index and folds the day into the longitudinal
  /// baselines, nothing more.
  ///
  /// Takes no input: the engine accumulated the inputs itself over the day.
  static String? attachStrainScore() => _coreRuntime?.attachStrainScoreJson();

  /// Push a GPS-derived ground speed sample in **m/s**.
  ///
  /// The high-confidence input for `locomotion_state`, which otherwise runs
  /// permanently on its low-confidence accel-only fallback. Ordering does not
  /// matter — speed is drained by window range and reduced to a median.
  static void pushSpeed(int tsMs, double speedMps) =>
      _coreRuntime?.pushSpeed(tsMs, speedMps);

  /// Declare where the accelerometer physically sits.
  ///
  /// The four kinematic heads withhold entirely under
  /// [AccelPlacement.unknown], and only [AccelPlacement.pocket] and
  /// [AccelPlacement.waist] are inside the validated envelope. Placement on a
  /// phone is dynamic — re-declare it as it changes rather than setting it
  /// once at startup.
  static void setAccelPlacement(AccelPlacement placement) =>
      _coreRuntime?.setAccelPlacement(placement.code);

  /// Declare the window containing [tsMs] to be a rest window.
  ///
  /// Composite definition: screen off for ≥ 2 min **and** no interaction
  /// **and** low motion, with a wall-clock sleep window as an override.
  /// Screen-off alone is not rest — someone watching a video is screen-on and
  /// resting; someone in a meeting is screen-off and working.
  ///
  /// One-shot: call it once per rest *window*, not once when a break begins.
  /// Without it Focus is never zeroed on a break and Capacity never takes the
  /// recovery path, so break windows score as engaged.
  static void declareRestWindow(int tsMs) =>
      _coreRuntime?.declareRestWindow(tsMs);

  /// Drain every completed window as a JSON array, oldest first.
  ///
  /// Prefer this to [tick] after any gap — `tick` polls a single window, so a
  /// backgrounded stretch silently skips the windows it spanned. Returns
  /// `null` when the runtime predates `synheart_core_tick_all`; fall back to
  /// [tick] in that case rather than assuming there were no windows.
  ///
  /// Every window it drains is also delivered through [onHSIUpdate] /
  /// [onStateUpdate], so a host running its own tick loop does not have to
  /// parse the return value to keep the documented streams alive.
  static String? tickAll(int nowMs) {
    final json = _coreRuntime?.tickAll(nowMs);
    _deliverHsiArray(json);
    return json;
  }

  /// Emit every window still held by the lateness budget.
  ///
  /// Call on backgrounding and at session end, or up to one budget's worth of
  /// windows is stranded forever. Returns the same JSON array shape [tickAll]
  /// does, or `null` when the symbol is absent.
  ///
  /// Like [tickAll], the drained windows also reach [onHSIUpdate] /
  /// [onStateUpdate].
  static String? flushPending(int nowMs) {
    final json = _coreRuntime?.flushPending(nowMs);
    _deliverHsiArray(json);
    return json;
  }

  /// Fan a `tick_all` / `flush_pending` JSON array out to the HSI streams.
  ///
  /// Both symbols return an array of HSI documents rather than the single
  /// document `tick` returns, and neither goes through the native HSI
  /// callback. Without this a host that ticks explicitly — which §6.1 of the
  /// mobile host guide requires for the whole session, since `push_behavior`
  /// does not advance the clock — would see `onStateUpdate` stay silent for
  /// every window its own loop drained, and the session buffer behind
  /// `getSessionHsiWindows()` stay empty with it.
  ///
  /// Delivery is deduplicated by `meta.ids.hsi_id`, so a window that also
  /// arrives via the native callback is not published twice.
  static void _deliverHsiArray(String? arrayJson) {
    if (arrayJson == null || arrayJson.isEmpty) return;
    final List<dynamic> windows;
    try {
      final decoded = jsonDecode(arrayJson);
      if (decoded is! List) return;
      windows = decoded;
    } catch (e) {
      SynheartLogger.log(
        '[Synheart] tick_all/flush_pending returned unparseable JSON: $e',
        error: e,
      );
      return;
    }
    for (final window in windows) {
      // Re-encode rather than passing the decoded map: the delivery path is
      // string-based end to end (the deduper reads `meta.ids.hsi_id` off the
      // raw text and `HSIState` keeps it as `rawJson`).
      final hsiJson = jsonEncode(window);
      shared._deliverHsiWindow(hsiJson);
      onHsi?.call(hsiJson);
    }
  }

  /// Advance the daily accumulator. [dayIndex] is days since epoch in the
  /// host's **local** zone and must strictly advance.
  ///
  /// Skip it and the engine adopts a provisional UTC day, which is wrong for
  /// most of the world. Returns `null` when the symbol is absent.
  static int? rollDay(int dayIndex) => _coreRuntime?.rollDay(dayIndex);

  /// Export per-head session state — Capacity, Mental Fatigue, Stress, Valence
  /// and the context engine. Persist once per emitted window and on
  /// background/terminate.
  static String? exportSessionState() => _coreRuntime?.exportSessionState();

  /// Restore session state. **Must run before the first tick** — window 1
  /// writes each head's state slot, so a later restore is overwritten by a
  /// cold window.
  static int? loadSessionState(String json) =>
      _coreRuntime?.loadSessionState(json);

  /// The comparability key. Persist it beside any cached score: a score
  /// computed under a different `config_id` is not comparable to a new one.
  static String? configId() => _coreRuntime?.configId();

  /// Most recent human-state vector as JSON, or `null` before the first window
  /// has closed.
  static String? lastHsv() => _coreRuntime?.lastHsv();

  /// Push a heart-rate sample into the runtime with provider attribution.
  ///
  /// Routes directly through `ingestBatch` as a single-event batch so the
  /// runtime sees the sample immediately (no Dart-side 5s delay) while
  /// preserving the `provider` tag that `pushHr(ts, bpm)` would otherwise
  /// drop. HSI windows produced by the batch are delivered through
  /// [onHsi] — the primary HSI path on iOS, where the native
  /// `setHsiCallback` doesn't fire.
  ///
  /// The default [provider] is `sdk_wear`, not `default_sensor`. Both are
  /// Tier 3 in core-runtime's `provider_tier`, but only `sdk_wear` has a row in
  /// `signals_for` — the table that registers the source behind
  /// `meta.provenance.sources[*].signals`. Tagged `default_sensor`, the sample
  /// moves the axes and registers nothing, so every modality chip reads absent
  /// while the rate is visibly grounded. Pass `ble_hrm` only for a real strap:
  /// it is Tier 1 and routes into the breathing detector's Tier-1 series.
  static void pushWearHr(int tsMs, double bpm, {String provider = 'sdk_wear'}) {
    _ingestSingleEvent({
      'type': 'hr',
      'ts_ms': tsMs,
      'bpm': bpm,
      'provider': provider,
    });
  }

  /// Push an RR interval with provider attribution.
  ///
  /// Unlike [pushWearHr], RR samples must reach BOTH the runtime
  /// (HRV/HSI pipeline) and the breathing-compliance detector. The
  /// JSON `ingestBatch` route only covers the former — the runtime's
  /// `synheart::ingest_batch_json` calls `runtime.push_rr` but does
  /// NOT call `breathing.push_rr`. The dedicated FFI
  /// (`synheart_core_push_rr` → `synheart::push_rr`) hits both and
  /// now also carries the provider tag end-to-end so the engine can
  /// route Tier-1 sources (`'ble_hrm'`) into the breathing detector's
  /// Tier-1 series and stratify research exports by source.
  ///
  /// Pass the source label that produced this sample:
  /// - `'ble_hrm'` — BLE chest strap (Tier-1)
  /// - `'watch_sample'` — Apple Watch / Wear OS HK frame (Tier-2)
  /// - `'garmin_companion'`— Garmin Connect IQ companion (Tier-2)
  /// Default `'default_sensor'` is treated as Tier-3.
  static void pushRr(
    int tsMs,
    double rrMs, {
    String provider = 'default_sensor',
  }) {
    _coreRuntime?.pushRr(tsMs, rrMs, provider: provider);
  }

  /// Push a batch of RR intervals delivered together in one sensor
  /// notification (e.g. a BLE Heart Rate Measurement packet carrying several
  /// RR values under one arrival timestamp).
  ///
  /// The runtime reconstructs a distinct per-beat timestamp for each interval
  /// from [anchorTsMs] instead of collapsing them onto that shared arrival
  /// time — so no beat is lost to HRV or the research export. [order] is `0`
  /// for oldest-first (BLE HRM, the default) or `1` for newest-first. Prefer
  /// this over looping [pushRr] whenever a packet carries more than one RR
  /// value. See [pushRr] for the `provider` routing labels.
  static void pushRrBatch(
    int anchorTsMs,
    List<double> rrMs, {
    int order = 0,
    String provider = 'default_sensor',
  }) {
    _coreRuntime?.pushRrBatch(
      anchorTsMs,
      rrMs,
      order: order,
      provider: provider,
    );
  }

  /// Push vendor-reported HRV metrics (Tier 2). See [pushWearHr] for
  /// routing semantics. Negative/-1 fields are interpreted as "not
  /// available" and omitted from the batch payload.
  static void pushVendorHrv(
    int tsMs, {
    double rmssd = -1.0,
    double sdnn = -1.0,
    double stress = -1.0,
    double recovery = -1.0,
    String provider = 'default_sensor',
  }) {
    _ingestSingleEvent({
      'type': 'vendor_hrv',
      'ts_ms': tsMs,
      if (rmssd > 0) 'rmssd_ms': rmssd,
      if (sdnn > 0) 'sdnn_ms': sdnn,
      if (stress >= 0) 'stress': stress,
      if (recovery >= 0) 'recovery': recovery,
      'provider': provider,
    });
  }

  /// Push vendor vital signs (SpO2, respiration) to lab windows.
  /// Pass -1.0 for unavailable fields.
  static void pushVendorVitals(
    int tsMs, {
    double spo2 = -1.0,
    double respiration = -1.0,
  }) {
    _coreRuntime?.pushVendorVitals(tsMs, spo2: spo2, respiration: respiration);
  }

  /// Push a single accelerometer sample to the engine. Feeds the
  /// Synheart Runtime motion features (`motion.accel_rms`,
  /// `motion.steps_est`, `motion.posture_proxy`) which in turn drive
  /// the corresponding SRM baselines.
  ///
  /// Hosts that don't have raw IMU should leave this unused — the
  /// engine synthesises a coarse motion signal from `WearSample.steps`
  /// in `ingest_wear_sample`. Hosts with phone IMU (via `sensors_plus`
  /// or platform-specific bridges) should call this at ≥ 25 Hz during
  /// sessions for the engine to reach a Ready motion baseline.
  ///
  /// `x` / `y` / `z` are in m/s² (gravity-included). The engine
  /// internally subtracts gravity and computes magnitude.
  static void pushAccel(int tsMs, double x, double y, double z) {
    _coreRuntime?.pushAccel(tsMs, x, y, z);
  }

  // ── Personalization task / workout APIs ─────────────────────────────
  // the personalization spec. Forwarded directly to the engine pipeline
  // (no batch ingest) because they set pipeline state rather than
  // produce FeatureSet rows.

  /// Set the active task type for personalization-aware confidence
  /// modulation. Persists until set again or — for workouts pushed via
  /// [pushWorkoutEvent] — until the workout end is reached.
  ///
  /// Use [TaskType.unknown] to clear an active task.
  static void setTaskType(TaskType task) {
    _coreRuntime?.setTaskType(task.discriminant);
  }

  /// Push a workout / exercise event from a wearable adapter.
  ///
  /// Activates the `Movement` task for `[startTime, endTime]` with the
  /// supplied [WorkoutKind]. Optional `vendorStrain` / `vendorRecovery`
  /// scalars (in `[0, 1]`) are forwarded to the FeatureSet as
  /// `vendor_hrv.strain` / `vendor_hrv.recovery`.
  ///
  /// After `endTime` passes, the engine's next window automatically
  /// decays the task back to `Unknown`.
  static void pushWorkoutEvent(WorkoutEvent event) {
    _coreRuntime?.pushWorkoutEvent(
      event.startTime.millisecondsSinceEpoch,
      event.endTime.millisecondsSinceEpoch,
      workoutKind: event.kind.discriminant,
      vendorStrain: event.vendorStrainForFfi,
      vendorRecovery: event.vendorRecoveryForFfi,
    );
  }

  /// Currently active task type. Returns [TaskType.unknown] before any
  /// host call, after a workout window has expired, or when the engine
  /// is not running.
  static TaskType currentTaskType() {
    final raw = _coreRuntime?.currentTaskType() ?? 0;
    return TaskType.fromDiscriminant(raw);
  }

  /// Currently active workout kind. Returns [WorkoutKind.unknown]
  /// outside an active `Movement` task.
  static WorkoutKind currentWorkoutKind() {
    final raw = _coreRuntime?.currentWorkoutKind() ?? 0;
    return WorkoutKind.fromDiscriminant(raw);
  }

  /// Set the focus-kind sub-classification of the active `Focus` task.
  /// Pair with [setTaskType] (set TaskType.focus first, then this).
  ///
  /// Has no effect outside an active `Focus` task. The engine records
  /// the kind on the explanation trace for observability; multiplier
  /// effect is reserved for a future rule-pack update — see
  /// [FocusKind] doc.
  ///
  /// Use [FocusKind.unknown] to clear the sub-classification.
  static void setFocusKind(FocusKind kind) {
    _coreRuntime?.setFocusKind(kind.discriminant);
  }

  /// Currently active focus kind. Returns [FocusKind.unknown] outside
  /// an active `Focus` task or when never set.
  static FocusKind currentFocusKind() {
    final raw = _coreRuntime?.currentFocusKind() ?? 0;
    return FocusKind.fromDiscriminant(raw);
  }

  /// Last `PersonalizationContext` as JSON.
  ///
  /// Returns `null` before the first HSI window completes. Schema:
  ///
  /// ```json
  /// {
  /// "normalized": { "z": {..}, "z_confidence": {..} },
  /// "recovery_index": { "value": 0.34, "confidence": 0.81,
  /// "components": {..} },
  /// "thresholds": { "overload_threshold": 0.62, .. },
  /// "priors": { "by_type": { "recovery": 0.85, "strain": 1.15 } },
  /// "confidence_modifier": 1.0,
  /// "confidence_modifier_by_type": { "focus": 0.80, "capacity": 0.80 },
  /// "maturity": "ready",
  /// "explanation": { "entries": [
  /// { "factor": "low_sleep_recent", "effect": -0.20,
  /// "note": "recent sleep median below 40 — cognitive heads dampened 20%" }
  /// ]}
  /// }
  /// ```
  ///
  /// Render `explanation.entries` in "why was this score modulated?"
  /// SDK panels .
  static String? personalizationContextJson() {
    return _coreRuntime?.personalizationContextJson();
  }

  /// Push a daily wearable summary into the longitudinal SRM. After a
  /// batch, call [srmTriggerWearableRecompute] so the resulting
  /// `WearableReference` propagates to the next inference window.
  ///
  /// Allowed [dimension] values:
  /// - `sleep_need` — total sleep in seconds (3h–14h filter)
  /// - `sleep_regularity` — bedtime-midpoint hours-of-day (0–24)
  /// - `hrv_rmssd` — daily RMSSD in ms
  /// - `hrv_sdnn` — daily SDNN in ms (e.g. Apple Health Watch HRV)
  /// - `resting_hr` — resting HR in bpm
  /// - `recovery_score` — vendor recovery in `[0, 1]`
  /// - `deep_sleep_min` / `rem_sleep_min` — minutes per night
  /// - `daily_strain` — vendor strain normalised to `[0, 1]`
  ///
  /// [dayIndex] is the unix-epoch day (compute via
  /// [epochDayFor] or `timestamp.millisecondsSinceEpoch ~/ 86400000`).
  /// [fidelity]: `0 = raw observation`, `1 = vendor summary`. Most
  /// vendor backfill pushes are `1` with a confidence of 0.80–0.90.
  static void srmPushWearableDaily({
    required String dimension,
    required int dayIndex,
    required double value,
    double confidence = 0.85,
    int fidelity = 1,
  }) {
    _coreRuntime?.srmPushWearableDaily(
      dimension: dimension,
      dayIndex: dayIndex,
      value: value,
      confidence: confidence,
      fidelity: fidelity,
    );
  }

  /// Trigger an SRM recompute and propagate the resulting
  /// `WearableReference` to the state runtime.
  ///
  /// Call after a batch of [srmPushWearableDaily] (e.g. at the end of
  /// vendor backfill) so the next `tick()` window picks up fresh
  /// personal baselines.
  ///
  /// [triggerType]: `0 = Window` (incremental, recommended), `1 =
  /// AffectedWindow`, `2 = Full` (rebuild everything).
  /// [asOfDay] defaults to today's epoch-day if `null`.
  static void srmTriggerWearableRecompute({int triggerType = 0, int? asOfDay}) {
    final day = asOfDay ?? epochDayFor(DateTime.now());
    _coreRuntime?.srmTriggerWearableRecompute(
      triggerType: triggerType,
      asOfDay: day,
    );
  }

  /// Convert a `DateTime` to the unix-epoch day index used by
  /// [srmPushWearableDaily]. Always operates in UTC so the day boundary
  /// is stable across the user's timezone.
  static int epochDayFor(DateTime t) =>
      t.toUtc().millisecondsSinceEpoch ~/ 86_400_000;

  /// Consent-gate a completed HSI window and fan it out to [_hsvStream] and
  /// the behavior module.
  ///
  /// Shared by both HSI producers: the native `setHsiCallback` (Android) and
  /// [_ingestSingleEvent] (the per-event push path, and the only producer that
  /// fires on iOS, where the native callback doesn't). Before this was
  /// factored out, only the native callback fed the stream — so on iOS the
  /// documented `onHSIUpdate` / `onStateUpdate` surface stayed silent for
  /// hosts driving the SDK through `pushWearHr` / `pushVendorHrv`, and the
  /// session buffer behind `getSessionHsiWindows()` stayed empty with it.
  ///
  /// Consent gating is already enforced by the native runtime before HSI
  /// reaches `state_tx`. The Dart `_consentModule.current()` snapshot has been
  /// observed returning stale defaults (biosignals reading `false` even after
  /// `consentSubmitFormTyped` wrote the consent store natively) — which once
  /// dropped 100% of HSI windows during a validation run. Cross-check the
  /// effective-state snapshot so a stale Dart-side cache can't block delivery.
  void _deliverHsiWindow(String hsiJson) {
    // A window completed by a per-event push reaches Dart twice — once via the
    // native callback, once as the ingest return value. See
    // [HsiDeliveryDeduper].
    if (!_hsiDeduper.shouldDeliver(hsiJson)) return;

    final local = _consentModule?.current();
    final effective = _coreRuntime?.consentEffectiveState();
    final biosignalsEffective =
        effective?['biosignals'] == true || effective?['research'] == true;
    final biosignalsLocal = local?.biosignals == true;
    if (!biosignalsEffective && !biosignalsLocal) return;

    if (!_hsvStream.isClosed) _hsvStream.add(hsiJson);
    // Surface motion-state on BehaviorModule for consumers that want a
    // posture/motion read alongside HSI delivery. Cheap parse — bails out fast
    // when no motion_state axis is present in the snapshot.
    _behaviorModule?.ingestHsi(hsiJson);
  }

  /// Serialize a single sensor event and hand it to `ingestBatch`. Used
  /// by the provider-tagged `push*` APIs so each sample keeps its source
  /// attribution (which the raw `pushHr`/`pushRr` FFI signatures can't
  /// carry).
  ///
  /// When the batch completes a window, the result is delivered through
  /// [_deliverHsiWindow] (so `onHSIUpdate` / `onStateUpdate` / the session
  /// buffer all see it) and then to the legacy [onHsi] callback.
  static void _ingestSingleEvent(Map<String, dynamic> event) {
    final runtime = _coreRuntime;
    if (runtime == null) return;
    final batchJson = jsonEncode([event]);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final hsi = runtime.ingestBatch(batchJson, nowMs);
    if (hsi != null) {
      shared._deliverHsiWindow(hsi);
      onHsi?.call(hsi);
    }
  }

  /// Advance the engine pipeline clock directly. Prefer the ingest buffer
  /// pattern for mobile — this is exposed for watch engine / advanced use.
  static String? tick(int nowMs) {
    final hsi = _coreRuntime?.tick(nowMs);
    // Same reason [tickAll] delivers: a host-driven tick is the only clock a
    // behavior-only session has, and its window would otherwise never reach
    // the documented streams. Deduplicated by `hsi_id`, so this is safe
    // alongside the native callback.
    if (hsi != null && hsi.isNotEmpty) {
      shared._deliverHsiWindow(hsi);
      onHsi?.call(hsi);
    }
    return hsi;
  }

  /// Ingest a pre-built event batch. Prefer [pushWearHr]/[pushRr] +
  /// automatic buffer flush for mobile — this is for watch engine / advanced use.
  static String? ingestBatch(String batchJson, int nowMs) {
    return _coreRuntime?.ingestBatch(batchJson, nowMs);
  }

  /// Last preprocessed features from the engine (HRV, motion, quality, SRM context).
  static String? get lastFeatures => _coreRuntime?.lastFeatures();

  // ── synheart-engine SRM API (baselines live in the native engine) ──

  /// Baseline summary from the native synheart-engine.
  ///
  /// Identical to [runtimeBaselinesJson] — both read the same native
  /// `baselines_json`.
  @Deprecated(
    'Duplicate of runtimeBaselinesJson — both return the same native payload. '
    'Use runtimeBaselinesJson. Will be removed in 0.12.0.',
  )
  static String? get runtimeBaselineSummary => runtimeBaselinesJson;

  /// All native runtime baselines as JSON, or `null` when the native runtime
  /// is not linked.
  static String? get runtimeBaselinesJson => _coreRuntime?.baselinesJson();

  /// Export the native runtime SRM snapshot as JSON for cross-session persistence.
  static String? exportRuntimeSRMSnapshot() {
    // Symmetric with the load and with [longitudinalSnapshotJson]: a host that
    // exports before the first session would otherwise get null and persist
    // nothing, silently.
    _coreRuntime?.ensurePipeline();
    return _coreRuntime?.exportSrmSnapshot();
  }

  /// Load a native runtime SRM snapshot from JSON.
  /// Returns true on success, false on failure.
  static bool loadRuntimeSRMSnapshot(String json) {
    // Same cold-boot problem [loadLongitudinalSnapshot] documents, and it was
    // missing here: a host restoring baselines at startup does so before any
    // session has materialized the Pipeline, so the load failed and the
    // person re-warmed 30 observations across 3 days that were already on
    // disk. Symptom is a snapshot that saves cleanly every session end and is
    // rejected on every launch. `ensurePipeline` is a no-op when one exists.
    _coreRuntime?.ensurePipeline();
    return _coreRuntime?.loadSrmSnapshot(json) ?? false;
  }

  /// Ensure the native engine pipeline exists, creating a default one if
  /// none is live yet.
  ///
  /// The runtime lazily creates its `Pipeline` — before the first session
  /// (or sleep-score attach) there is no pipeline, so
  /// [exportRuntimeSRMSnapshot] returns `null` and [loadRuntimeSRMSnapshot]
  /// fails with "runtime not available". Persistence round-trips on app
  /// boot run before any of those triggers, so they must materialise the
  /// pipeline first. No-op when a pipeline already exists.
  static void ensureRuntimePipeline() {
    _coreRuntime?.ensurePipeline();
  }

  /// The native synheart-engine version, or `null` if unavailable.
  static String? get runtimeVersion => CoreRuntimeBridge.version();

  // ── synheart-lab session API ──

  /// Whether the lab C ABI symbols are available in the loaded native library.
  static bool get isLabAvailable => _coreRuntime?.isLabAvailable ?? false;

  /// Start a lab session. Returns `null` on success, or an error string.
  static String? labStart(String protocolJson, int startedAtMs) {
    return _coreRuntime?.labStart(protocolJson, startedAtMs);
  }

  /// Open a window in the active lab session. Returns the window ID.
  static String? labOpenWindow({
    String? parentId,
    required String windowType,
    String? label,
    required int startedAtMs,
  }) {
    return _coreRuntime?.labOpenWindow(
      parentId,
      windowType,
      label,
      startedAtMs,
    );
  }

  /// Close a window in the active lab session.
  static void labCloseWindow(String windowId, int endedAtMs) {
    _coreRuntime?.labCloseWindow(windowId, endedAtMs);
  }

  /// Set protocol-specific values on a lab window.
  static void labSetWindowValues(String windowId, String valuesJson) {
    _coreRuntime?.labSetWindowValues(windowId, valuesJson);
  }

  /// Merge session-level metadata into `session_metadata.extra_data`.
  ///
  /// Returns `null` on success, or an error string.
  static String? labMergeSessionExtraData(String patchJson) {
    return _coreRuntime?.labMergeExtraData(patchJson);
  }

  /// Set per-window state-data overrides before closing a lab window.
  ///
  /// Supported override keys include `device_context`, `system_state`,
  /// and `session_spacing` in the JSON object.
  static void labSetWindowStateOverrides(
    String windowId,
    String overridesJson,
  ) {
    _coreRuntime?.labSetStateOverrides(windowId, overridesJson);
  }

  /// Finalize the lab session and return the complete payload JSON.
  static String? labFinalize(int endedAtMs) {
    return _coreRuntime?.labFinalize(endedAtMs);
  }

  /// Get the last lab export JSON (available after session end in research mode).
  static String? get labExportJson => _coreRuntime?.labExportJson();

  /// Whether the linked runtime exports the lab re-enqueue symbol
  /// (engine v0.8.1+). Older binaries return false and
  /// [labReenqueueSession] will yield [LabReenqueueResult.unsupported].
  static bool get isLabReenqueueAvailable =>
      _coreRuntime?.isLabReenqueueAvailable ?? false;

  /// Re-enqueue a previously-finalized lab session payload for cloud
  /// upload. Use this to retry sessions whose initial upload was
  /// dropped on a 4xx (typically a cloud schema mismatch — the runtime
  /// removes those rows from the upload queue so they don't clog the
  /// connector).
  ///
  /// Host reads the persisted JSON from app-side storage (pulse-focus:
  /// `LabPayloadService` / the `lab_payloads` SQLite table) and passes
  /// it back in here. Same consent + connector gates apply as the
  /// auto-enqueue path; see [LabReenqueueResult] for outcomes.
  ///
  /// Returns [LabReenqueueResult.cloudNotConfigured] when the SDK is
  /// not initialized — callers should treat that as a no-op rather
  /// than a bug.
  static LabReenqueueResult labReenqueueSession(String sessionJson) {
    final rt = _coreRuntime;
    if (rt == null) return LabReenqueueResult.cloudNotConfigured;
    return rt.labReenqueueSession(sessionJson);
  }

  // ── Lab metadata ─────────────────────────────────────────────────────

  /// Whether the runtime exposes the lab metadata symbols.
  static bool get isLabMetadataAvailable =>
      _coreRuntime?.isLabMetadataAvailable ?? false;

  /// Build the metadata payload from current config + caller-supplied device
  /// and user info, then upload it if the canonical hash differs from the
  /// cached copy or the dirty flag is set. Returns the active `meta_id`.
  ///
  /// Call once at app start (after registration + research consent) and again
  /// only when [labMarkMetadataDirty] has been signaled. Subsequent calls are
  /// cheap — they short-circuit when the payload is unchanged.
  static String? labEnsureMetadata({
    required String deviceId,
    required String platform,
    required String osVersion,
    String? userInfoJson,
    String? deviceExtraJson,
  }) {
    return _coreRuntime?.labEnsureMetadata(
      deviceId: deviceId,
      platform: platform,
      osVersion: osVersion,
      userInfoJson: userInfoJson,
      deviceExtraJson: deviceExtraJson,
    );
  }

  /// Mark cached lab metadata as needing re-upload. Hosts call this on
  /// profile edits, device swaps, app version bumps, and consent changes.
  static void labMarkMetadataDirty(String reason) {
    _coreRuntime?.labMarkMetadataDirty(reason);
  }

  /// Cached `meta_id` to stamp on lab sessions, or null if nothing is cached.
  static String? labCurrentMetadataId() => _coreRuntime?.labCurrentMetadataId();

  // Collection status getters
  bool get _isWearCollecting {
    return _wearModule?.status == ModuleStatus.running;
  }

  bool get _isBehaviorCollecting {
    return _behaviorModule?.status == ModuleStatus.running;
  }

  bool get _isPhoneCollecting {
    return _phoneModule?.status == ModuleStatus.running;
  }

  /// Clear session buffers and subscribe to consent-gated HSI + raw wear streams.
  void _wireSessionBuffers() {
    _sessionHsiSubscription?.cancel();
    _sessionWearSubscription?.cancel();
    _sessionHsiBuffer.clear();
    _sessionWearBuffer.clear();
    // A new session starts a fresh dedup window; a leftover id from the
    // previous session must not suppress this session's first window.
    _hsiDeduper.reset();
    // HSI session buffer is filled via the setHsiCallback wired in configure().
    // The _hsvStream already receives consent-gated HSI; listen to it for session buffering.
    _sessionHsiSubscription = _hsvStream.stream.listen((hsiJson) {
      _sessionHsiBuffer.add(hsiJson);
    });
    if (_wearModule != null) {
      _sessionWearSubscription = _wearModule!.rawSampleStream.listen(
        (sample) => _sessionWearBuffer.add(sample),
      );
    }
  }

  /// Resolves the foreground app for the life of the session. See
  /// [BehaviorConfig.reportForegroundApp] for why an app identity is
  /// load-bearing rather than decorative.
  ForegroundAppReporter? _foregroundAppReporter;

  /// Gates the reporter on app lifecycle.
  ///
  /// The default [SelfForegroundAppSource] reports *this* app's id, which is
  /// the truth while the person is here and a lie the moment they leave. A
  /// heartbeat that keeps asserting it from the background is worse than
  /// silence: the engine would attribute another app's window to this one. So
  /// the heartbeat runs only while the app is visible, and resumes with an
  /// immediate resolve so the window the person came back into is typed.
  ///
  /// A host that supplies a real [ForegroundAppSource] (Android
  /// `UsageStatsManager`) does not need this gate — but it costs nothing there,
  /// because a backgrounded host has no windows of its own to type either.
  AppLifecycleListener? _foregroundLifecycleListener;

  /// The foreground-app reporter, for host diagnostics (how many resolves
  /// landed, and which id). `null` when reporting is off or no usable id was
  /// found.
  ForegroundAppReporter? get foregroundAppReporter => _foregroundAppReporter;

  /// Pick a foreground-app identity.
  ///
  /// Resolution order, most explicit first. `appId` comes last and is filtered:
  /// it is documented as "developer-provided app identifier" and hosts legitimately
  /// set it to a Synheart-issued `app_…` id, which is not a package name and
  /// would never match the taxonomy. A dot and no `app_` prefix is the
  /// cheap test for "this looks like a package name / bundle id".
  String? _resolveForegroundAppId() {
    final config = _config;
    if (config == null) return null;

    final explicit = config.behaviorConfig?.foregroundAppId;
    if (explicit != null && explicit.isNotEmpty) return explicit;

    final packageName = config.deviceAuthConfig?.packageName;
    if (packageName != null && packageName.isNotEmpty) return packageName;

    final appId = config.appId;
    if (appId.contains('.') && !appId.startsWith('app_')) return appId;

    return null;
  }

  Future<void> _startForegroundAppReporter() async {
    final config = _config;
    if (config == null) return;
    // A host that passes no `BehaviorConfig` at all still gets the reporter:
    // the field defaults to `true`, and an absent config is "I did not think
    // about this", not "do not report". Opting out means passing
    // `BehaviorConfig(reportForegroundApp: false)` deliberately.
    final behavior = config.behaviorConfig ?? const BehaviorConfig();
    if (!behavior.reportForegroundApp) return;
    if (_foregroundAppReporter != null) return;

    final source = behavior.foregroundAppSource ?? _selfForegroundAppSource();
    if (source == null) {
      SynheartLogger.log(
        '[Synheart] reportForegroundApp is on but no usable application id was '
        'found — set BehaviorConfig.foregroundAppId (an Android package name / '
        'iOS bundle id). Until then the engine types every window against the '
        'Unknown app category, whose interpretation-mask row is all zeros, so '
        'CFI / Cognitive Load, Stress B, Mental Fatigue B and Focus deviation '
        'terms will read 0.',
      );
      return;
    }

    _foregroundAppReporter = ForegroundAppReporter(
      source: source,
      push: Synheart.pushBehaviorEvent,
    );
    await _foregroundAppReporter!.start();
    _attachForegroundLifecycleGate();
  }

  void _attachForegroundLifecycleGate() {
    if (_foregroundLifecycleListener != null) return;
    try {
      _foregroundLifecycleListener = AppLifecycleListener(
        onStateChange: (state) {
          final reporter = _foregroundAppReporter;
          if (reporter == null) return;
          switch (state) {
            case AppLifecycleState.resumed:
              // `start()` is idempotent and resolves once immediately.
              reporter.start();
            case AppLifecycleState.inactive:
              // A transient overlay (a call banner, the app switcher) is not
              // leaving. Stopping here would drop resolves on every
              // notification shade pull.
              break;
            case AppLifecycleState.hidden:
            case AppLifecycleState.paused:
            case AppLifecycleState.detached:
              reporter.stop();
          }
        },
      );
    } on Object catch (e) {
      // Needs a bound WidgetsBinding. A headless host (a background isolate,
      // a plain Dart test) has none — the reporter still runs, it just is not
      // lifecycle-gated, which for a headless host is the correct behaviour
      // anyway since there is no foreground to leave.
      SynheartLogger.log(
        '[Synheart] foreground-app lifecycle gate unavailable ($e); the '
        'resolve heartbeat will run unconditionally for this session.',
      );
    }
  }

  SelfForegroundAppSource? _selfForegroundAppSource() {
    final id = _resolveForegroundAppId();
    return id == null ? null : SelfForegroundAppSource(id);
  }

  Future<void> _startRuntimeLinkedCollection() async {
    if (_isRunning) return;
    await _moduleManager.startAll();
    _wireSessionBuffers();
    _isRunning = true;
    _reevaluateAllFeatures();
    await _startForegroundAppReporter();
  }

  Future<void> _stopRuntimeLinkedCollection() async {
    _foregroundLifecycleListener?.dispose();
    _foregroundLifecycleListener = null;
    _foregroundAppReporter?.dispose();
    _foregroundAppReporter = null;
    await _sessionHsiSubscription?.cancel();
    _sessionHsiSubscription = null;
    await _sessionWearSubscription?.cancel();
    _sessionWearSubscription = null;
    // `_logRuntimeSummary` is called by [stopSession] before
    // `_coreRuntime.stopSession()` so the pipeline is still alive
    // when frame_count is read. Calling it here again would log a
    // second line with frame_count=0 (pipeline torn down by then).
    await _moduleManager.stopAll();
  }

  void _logRuntimeSummary() {
    if (_coreRuntime == null) return;
    final fc = _coreRuntime!.frameCount();
    SynheartLogger.log(
      '[Runtime] Session end: frameCount=$fc'
      '${fc == 0 ? " (no HSI produced — no window completed)" : ""}',
    );
  }

  /// Start all data collection modules
  Future<void> _startDataCollection({int? durationSec}) async {
    if (!_isConfigured) {
      throw StateError(
        'Synheart must be initialized before starting data collection',
      );
    }

    if (_isRunning) {
      SynheartLogger.log('[Synheart] Data collection already running');
      return;
    }

    final activated = _activationManager?.activatedFeatures() ?? {};
    if (activated.isEmpty) {
      throw StateError(
        'At least one feature must be enabled to start a session. '
        'Configure SynheartConfig with at least one of: wearConfig, phoneConfig, '
        'behaviorConfig, cloudConfig; or call Synheart.activate() for a feature.',
      );
    }

    if (!_hasAtLeastOneFeatureWithConsent()) {
      throw StateError(
        'At least one feature must have consent to start a session. '
        'Grant consent for at least one of: biosignals, behavior, phoneContext (e.g. via Synheart.grantConsent or the app consent UI).',
      );
    }

    SynheartLogger.log('[Synheart] Starting all data collection modules..');

    // Open main collection session via Session SDK (session boundary)
    final sessionId = 'core_${DateTime.now().millisecondsSinceEpoch}';
    final sec =
        durationSec ?? 86400; // default 24h — long-lived; stop explicitly
    final config = SessionConfig(
      mode: SessionMode.focus,
      durationSec: sec,
      sessionId: sessionId,
    );
    _activeMainSessionId = sessionId;
    _mainSessionSubscription = _mainSession!
        .startSession(config)
        .listen(
          (_) {},
          onDone: () {
            _activeMainSessionId = null;
            if (_isRunning) {
              _isRunning = false;
              _reevaluateAllFeatures();
              _logRuntimeSummary();
              _moduleManager.stopAll();
              SynheartLogger.log(
                '[Synheart] Main session ended (duration or stream closed)',
              );
            }
          },
          onError: (e, st) {
            SynheartLogger.log(
              '[Synheart] Main session stream error: $e',
              error: e,
              stackTrace: st,
            );
            _activeMainSessionId = null;
          },
        );

    await _moduleManager.startAll();

    _wireSessionBuffers();

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final mode = _config?.mode ?? SynheartMode.personal;
    _currentSessionHandle = SessionHandle(
      sessionId: sessionId,
      startedAtMs: nowMs,
      mode: mode,
    );

    _isRunning = true;
    _reevaluateAllFeatures();
    SynheartLogger.log('[Synheart] Data collection started');
  }

  /// Stop all data collection modules
  Future<void> _stopDataCollection() async {
    if (!_isConfigured) {
      throw StateError(
        'Synheart must be initialized before stopping data collection',
      );
    }

    if (!_isRunning) {
      SynheartLogger.log('[Synheart] Data collection already stopped');
      return;
    }

    SynheartLogger.log('[Synheart] Stopping all data collection modules..');

    // Close main collection session via Session SDK
    if (_activeMainSessionId != null) {
      await _mainSession?.stopSession(_activeMainSessionId!);
      await _mainSessionSubscription?.cancel();
      _mainSessionSubscription = null;
      _activeMainSessionId = null;
    }
    // Cancel buffer subscriptions but keep buffers for post-session queries
    await _sessionHsiSubscription?.cancel();
    _sessionHsiSubscription = null;
    await _sessionWearSubscription?.cancel();
    _sessionWearSubscription = null;

    _currentSessionHandle = null;

    _isRunning = false;
    _reevaluateAllFeatures();
    _logRuntimeSummary();
    await _moduleManager.stopAll();
    SynheartLogger.log('[Synheart] Data collection stopped');
  }

  /// Start wear data collection
  Future<void> _startWearCollection({Duration? interval}) async {
    if (!_isConfigured) {
      throw StateError(
        'Synheart must be initialized before starting wear collection',
      );
    }

    if (_wearModule == null) {
      throw StateError('Wear module not initialized');
    }

    if (_isWearCollecting) {
      // SynheartLogger.log('[Synheart] Wear collection already running');
      // If interval changed, update it
      if (interval != null) {
        await _wearModule!.updateCollectionInterval(interval);
      }
      return;
    }

    // SynheartLogger.log('[Synheart] Starting wear data collection..');
    if (interval != null) {
      await _wearModule!.updateCollectionInterval(interval);
    }
    await _wearModule!.start();
    // SynheartLogger.log('[Synheart] Wear data collection started');
  }

  /// Stop wear data collection
  Future<void> _stopWearCollection() async {
    if (!_isConfigured) {
      throw StateError(
        'Synheart must be initialized before stopping wear collection',
      );
    }

    if (_wearModule == null) {
      throw StateError('Wear module not initialized');
    }

    if (!_isWearCollecting) {
      // SynheartLogger.log('[Synheart] Wear collection already stopped');
      return;
    }

    // SynheartLogger.log('[Synheart] Stopping wear data collection..');
    await _wearModule!.stop();
    // SynheartLogger.log('[Synheart] Wear data collection stopped');
  }

  /// Start behavior data collection
  Future<void> _startBehaviorCollection() async {
    if (!_isConfigured) {
      throw StateError(
        'Synheart must be initialized before starting behavior collection',
      );
    }

    if (_behaviorModule == null) {
      throw StateError('Behavior module not initialized');
    }

    if (_isBehaviorCollecting) {
      // SynheartLogger.log('[Synheart] Behavior collection already running');
      return;
    }

    // SynheartLogger.log('[Synheart] Starting behavior data collection..');
    await _behaviorModule!.start();
    // SynheartLogger.log('[Synheart] Behavior data collection started');
  }

  /// Stop behavior data collection
  Future<void> _stopBehaviorCollection() async {
    if (!_isConfigured) {
      throw StateError(
        'Synheart must be initialized before stopping behavior collection',
      );
    }

    if (_behaviorModule == null) {
      throw StateError('Behavior module not initialized');
    }

    if (!_isBehaviorCollecting) {
      // SynheartLogger.log('[Synheart] Behavior collection already stopped');
      return;
    }

    // SynheartLogger.log('[Synheart] Stopping behavior data collection..');
    await _behaviorModule!.stop();
    // SynheartLogger.log('[Synheart] Behavior data collection stopped');
  }

  /// Start phone context data collection
  Future<void> _startPhoneCollection() async {
    if (!_isConfigured) {
      throw StateError(
        'Synheart must be initialized before starting phone collection',
      );
    }

    if (_phoneModule == null) {
      throw StateError('Phone module not initialized');
    }

    if (_isPhoneCollecting) {
      SynheartLogger.log('[Synheart] Phone collection already running');
      return;
    }

    SynheartLogger.log('[Synheart] Starting phone data collection..');
    await _phoneModule!.start();
    SynheartLogger.log('[Synheart] Phone data collection started');
  }

  /// Stop phone context data collection
  Future<void> _stopPhoneCollection() async {
    if (!_isConfigured) {
      throw StateError(
        'Synheart must be initialized before stopping phone collection',
      );
    }

    if (_phoneModule == null) {
      throw StateError('Phone module not initialized');
    }

    if (!_isPhoneCollecting) {
      SynheartLogger.log('[Synheart] Phone collection already stopped');
      return;
    }

    SynheartLogger.log('[Synheart] Stopping phone data collection..');
    await _phoneModule!.stop();
    SynheartLogger.log('[Synheart] Phone data collection stopped');
  }

  /// Start a behavior session
  Future<String> _startBehaviorSession() async {
    if (!_isConfigured) {
      throw StateError(
        'Synheart must be initialized before starting behavior session',
      );
    }

    if (_behaviorModule == null) {
      throw StateError('Behavior module not initialized');
    }

    final synheartBehavior = _behaviorModule!.synheartBehavior;
    if (synheartBehavior == null) {
      throw StateError(
        'synheart_behavior not initialized. Behavior module must be started first.',
      );
    }

    // SynheartLogger.log('[Synheart] Starting behavior session..');
    final session = await synheartBehavior.startSession();

    // Track the session so we can end it later
    _activeBehaviorSessions[session.sessionId] = session;

    // SynheartLogger.log(
    // '[Synheart] Behavior session started: ${session.sessionId}',
    // );
    return session.sessionId;
  }

  /// Stop a behavior session and get results
  Future<BehaviorSessionResults> _stopBehaviorSession(String sessionId) async {
    if (!_isConfigured) {
      throw StateError(
        'Synheart must be initialized before stopping behavior session',
      );
    }

    if (_behaviorModule == null) {
      throw StateError('Behavior module not initialized');
    }

    final synheartBehavior = _behaviorModule!.synheartBehavior;
    if (synheartBehavior == null) {
      throw StateError(
        'synheart_behavior not initialized. Behavior module must be started first.',
      );
    }

    // Get the tracked session
    final session = _activeBehaviorSessions[sessionId];
    if (session == null) {
      throw StateError(
        'Session not found: $sessionId. Make sure you started the session using startBehaviorSession().',
      );
    }

    // SynheartLogger.log('[Synheart] Stopping behavior session: $sessionId..');

    // End the session and get summary
    final summary = await session.end();

    // Remove from tracking
    _activeBehaviorSessions.remove(sessionId);

    // SynheartLogger.log('[Synheart] Behavior session stopped: $sessionId');
    return BehaviorSessionResults.fromSummary(summary);
  }

  /// Get wear features for a specific time window
  /// Wrap a widget with behavior gesture detector if behavior consent is granted
  ///
  /// This method automatically checks if:
  /// - The SDK is initialized
  /// - Behavior module is available
  /// - Behavior consent is granted
  ///
  /// If all conditions are met, the widget is wrapped with the gesture detector.
  /// Otherwise, the original widget is returned unwrapped.
  ///
  /// Example:
  /// ```dart
  /// MaterialApp(
  /// home: Synheart.wrapWithBehaviorDetector(
  /// MaterialApp(..),
  /// ),
  /// )
  /// ```
  static Widget wrapWithBehaviorDetector(Widget child) {
    return shared._wrapWithBehaviorDetector(child);
  }

  Widget _wrapWithBehaviorDetector(Widget child) {
    // Check if SDK is configured and behavior module is available
    if (!_isConfigured || _behaviorModule == null) {
      return child;
    }

    // Check if behavior consent is granted
    if (_consentModule == null || !_consentModule!.current().behavior) {
      return child;
    }

    // Get synheart_behavior instance
    final synheartBehavior = _behaviorModule!.synheartBehavior;
    if (synheartBehavior == null) {
      return child;
    }

    // Wrap with gesture detector
    return synheartBehavior.wrapWithGestureDetector(child);
  }

  /// Get current consent snapshot
  ConsentSnapshot? get currentConsent {
    return _consentModule?.current();
  }

  /// Update consent
  static Future<void> updateConsent(ConsentSnapshot consent) async {
    return shared._updateConsent(consent);
  }

  Future<void> _updateConsent(ConsentSnapshot consent) async {
    if (_consentModule == null) {
      throw StateError('Consent module not initialized');
    }
    await _consentModule!.updateConsent(consent);
  }

  // Consent service integration methods

  /// Consent UI manager (for app-provided UI)
  final ConsentUIManager _consentUI = ConsentUIManager();

  /// Set custom consent UI provider
  ///
  /// Example:
  /// ```dart
  /// Synheart.setConsentUIProvider((profiles) async {
  /// // Show your custom UI
  /// return await showConsentDialog(profiles);
  /// });
  /// ```
  static void setConsentUIProvider(ConsentUIProvider provider) {
    shared._consentUI.customUIProvider = provider;
  }

  /// Get available consent profiles from cloud service
  ///
  /// Requires ConsentConfig to be provided during initialization.
  static Future<List<ConsentProfile>> getAvailableConsentProfiles() async {
    return shared._getAvailableConsentProfiles();
  }

  Future<List<ConsentProfile>> _getAvailableConsentProfiles() async {
    if (_consentModule == null) {
      throw StateError('Consent module not initialized');
    }
    return _consentModule!.getAvailableProfiles();
  }

  /// Request consent by presenting UI and issuing token
  ///
  /// This method:
  /// 1. Fetches available consent profiles
  /// 2. Presents UI (via customUIProvider if set)
  /// 3. Issues token for selected profile
  /// 4. Updates local consent snapshot
  ///
  /// Returns the issued token, or null if user declined.
  static Future<ConsentToken?> requestConsent() async {
    return shared._requestConsent();
  }

  Future<ConsentToken?> _requestConsent() async {
    if (_consentModule == null) {
      throw StateError('Consent module not initialized');
    }

    try {
      final profiles = await _consentModule!.getAvailableProfiles();
      if (profiles.isEmpty) {
        SynheartLogger.log('[Synheart] No consent profiles available');
        return null;
      }

      final selected = await _consentUI.presentConsentFlow(profiles);
      if (selected == null) {
        return null; // User declined
      }

      final token = await _consentModule!.requestConsent(selected);
      return token;
    } catch (e, stack) {
      SynheartLogger.log(
        '[Synheart] Error requesting consent: $e',
        error: e,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  /// Check current consent status
  static ConsentStatus getConsentStatus() {
    return shared._getConsentStatus();
  }

  ConsentStatus _getConsentStatus() {
    if (_consentModule == null) {
      return ConsentStatus.pending;
    }
    return _consentModule!.checkConsentStatus();
  }

  /// Get current consent token (if available and valid)
  static ConsentToken? getCurrentConsentToken() {
    return shared._getCurrentConsentToken();
  }

  ConsentToken? _getCurrentConsentToken() {
    return _consentModule?.getCurrentToken();
  }

  /// True when a consent token is loaded but its subject (`user_id` claim)
  /// differs from the runtime's current [subjectId]. Consent tokens are
  /// subject-scoped: one issued for a previous subject (e.g. a different
  /// signed-in account, or a token minted before the account was known) must be
  /// reissued for the current subject before use, so uploads are attributed to
  /// the right subject. Conservative: returns false (no reissue) when there's no
  /// token, no known subject, or the token carries no `user_id` claim — a
  /// stable, matching subject is a no-op.
  static bool consentTokenSubjectStale() {
    // Compare against the NATIVE runtime subject (the value HSI uploads are
    // actually attributed under, after any `derive_subject_id_if_needed`),
    // falling back to the Dart-side subject only before the runtime is loaded.
    // Using the Dart config alone can disagree with a runtime-derived subject
    // and yield a false stale verdict (or miss a real one).
    final native = _coreRuntime?.runtimeSubjectId();
    final current = (native != null && native.isNotEmpty) ? native : subjectId;
    if (current == null || current.isEmpty) return false;
    final tok = getCurrentConsentToken();
    if (tok == null) return false;
    final tokenSubject = tok.claims['user_id']?.toString();
    if (tokenSubject == null || tokenSubject.isEmpty) return false;
    return tokenSubject != current;
  }

  /// Ensure runtime cloud consent is ready for ingest uploads.
  ///
  /// This follows the granular runtime flow:
  /// - read editable form,
  /// - submit current consent choices,
  /// - verify runtime status / token refresh state.
  ///
  /// IMPORTANT: this is the consent-grant chain — the runtime gate
  /// (`has_consent`) deliberately fails-closed when cloud is configured
  /// but no valid consent token is loaded. We must NOT pre-check that
  /// gate here, because the whole point of this function is to obtain
  /// the token that flips the gate open. Instead we read the local
  /// snapshot (effective state) directly: that tells us whether the
  /// user has chosen to allow cloud upload, independent of token
  /// validity. When the snapshot says cloud is allowed but no valid
  /// token exists, this is exactly the cold-start "user granted in a
  /// prior session, token expired or never persisted" case — and we
  /// need to re-submit the form to issue a fresh token.
  static Future<bool> ensureCloudConsentReady() async {
    final runtime = _coreRuntime;
    if (runtime == null) return false;
    final effective = consentEffectiveStateTyped();
    if (effective?.cloudUpload != true) return false;

    final status = consentStatus()?['status']?.toString().toLowerCase();
    final needsRefresh = consentNeedsTokenRefresh();
    // A 'granted' token is only usable if it was issued for the SAME subject the
    // runtime is currently configured with. After a subject change the persisted
    // token still names the previous subject; reporting it as ready would
    // attribute uploads to the wrong subject. Treat a stale-subject token as
    // not-ready so the submit path below reissues it for the current subject.
    if (status == 'granted' && !needsRefresh && !consentTokenSubjectStale()) {
      return true;
    }

    final currentForm = consentGetEditableFormTyped();
    if (currentForm == null) return false;
    final local = shared._consentModule?.current();
    final mergedForm = currentForm.copyWith(
      biosignals:
          local?.biosignals ?? effective?.biosignals ?? currentForm.biosignals,
      phoneContext:
          local?.phoneContext ??
          effective?.phoneContext ??
          currentForm.phoneContext,
      behavior: local?.behavior ?? effective?.behavior ?? currentForm.behavior,
      allowCloud: true,
      allowResearch:
          local?.research ?? effective?.research ?? currentForm.allowResearch,
      allowVendorSync:
          local?.vendorSync ??
          effective?.vendorSync ??
          currentForm.allowVendorSync,
    );

    final submit = await consentSubmitFormTyped(form: mergedForm);
    if (submit == null || submit['error'] != null) {
      return false;
    }
    // Verify a token was actually issued. submit_form returns
    // `synced=false, token=null` (without `error`) when the cloud
    // profile fetch or token-issue HTTP call failed — the local
    // snapshot is still saved but the runtime stays in Pending and
    // the biosignal/research gates remain closed. Treating that as
    // success would silently drop pushes for the rest of the session.
    final tokenIssued = submit['token'] != null;
    final synced = submit['synced'] == true;
    if (!tokenIssued || !synced) {
      SynheartLogger.log(
        '[Synheart] ensureCloudConsentReady: submit accepted but no '
        'cloud token issued (synced=$synced, token=$tokenIssued). '
        'Likely network/cloud unavailable — gates stay closed.',
      );
      return false;
    }
    final refreshedStatus = consentStatus()?['status']
        ?.toString()
        .toLowerCase();
    return refreshedStatus == 'granted' && !consentNeedsTokenRefresh();
  }

  /// Get all consent statuses as a map
  ///
  /// Example:
  /// ```dart
  /// Map<String, bool> statuses = await Synheart.getConsentStatusMap();
  /// print(statuses['biosignals']); // true/false
  /// ```
  static Map<String, bool> getConsentStatusMap() {
    return shared._getConsentStatusMap();
  }

  /// Check if consent is needed
  ///
  /// Returns true if:
  /// - CloudConfig is provided
  /// - At least one module config is provided (Wear, Phone, or Behavior)
  /// - No stored consent exists
  ///
  /// Example:
  /// ```dart
  /// if (await Synheart.needsConsent()) {
  /// // Show consent UI
  /// }
  /// ```
  static Future<bool> needsConsent() async {
    return shared._needsConsent();
  }

  Future<bool> _needsConsent() async {
    if (!_isConfigured) {
      throw StateError(
        'Synheart must be initialized before checking consent needs',
      );
    }

    // Only need consent if CloudConfig is provided
    if (_config?.cloudConfig == null) {
      return false;
    }

    // Check if at least one module config is provided
    final hasModuleConfig =
        _config?.wearConfig != null ||
        _config?.phoneConfig != null ||
        _config?.behaviorConfig != null;

    if (!hasModuleConfig) {
      return false;
    }

    // Check if consent was previously granted
    if (_consentModule == null) {
      return true; // No consent module means no stored consent
    }

    final consent = _consentModule!.current();
    return !consent.biosignals && !consent.behavior && !consent.phoneContext;
  }

  /// Get consent information for enabled modules
  ///
  /// Returns a map of module names to their consent descriptions.
  /// Only includes modules that have configs provided during initialization.
  ///
  /// Example:
  /// ```dart
  /// final consentInfo = await Synheart.getConsentInfo();
  /// print(consentInfo['biosignals']); // "Collect heart rate and HRV data.."
  /// ```
  static Future<Map<String, String>> getConsentInfo() async {
    return shared._getConsentInfo();
  }

  Future<Map<String, String>> _getConsentInfo() async {
    if (!_isConfigured) {
      throw StateError(
        'Synheart must be initialized before getting consent info',
      );
    }

    final info = <String, String>{};

    if (_config?.wearConfig != null) {
      info['biosignals'] =
          'Collect heart rate, heart rate variability, and other biosignals from your wearable device to understand your physiological state.';
    }

    if (_config?.phoneConfig != null) {
      info['phoneContext'] =
          'Collect motion and phone context data (screen state, app usage) to understand your activity patterns and device interactions.';
    }

    if (_config?.behaviorConfig != null) {
      info['behavior'] =
          'Collect behavioral data (typing patterns, gestures) to understand your interaction patterns and cognitive state.';
    }

    if (_config?.cloudConfig != null) {
      info['cloudUpload'] =
          'Upload anonymized state data to the cloud for enhanced insights and personalization. Your data is encrypted and pseudonymized.';
    }

    return info;
  }

  /// Grant consent for specific modules
  ///
  /// This should be called after the user has made their consent choices in the UI.
  /// If CloudConfig is provided, this will also issue
  /// a consent token from the consent service.
  ///
  /// Example:
  /// ```dart
  /// await Synheart.grantConsent(
  /// biosignals: true,
  /// behavior: true,
  /// phoneContext: true,
  /// cloudUpload: true,
  /// );
  /// ```

  /// Process a vendor wearable event from RAMEN into the SRM pipeline.
  ///
  /// Call this from the wear SDK when a [RamenEvent] arrives.
  /// The internal WearModule instance (for vendor sync state observation).
  static WearModule? get wearModule => shared._wearModule;

  /// The event is normalized to a CanonicalWearableEvent, stored in SQLite,
  /// and pushed to the runtime for longitudinal baseline computation.
  ///
  /// Returns the canonical event the vendor payload was mapped to, or
  /// `null` if dropped (consent denied, no processor, mapping miss).
  static Future<CanonicalWearableEvent?> processVendorEvent({
    required String provider,
    required String eventType,
    required Map<String, dynamic> payload,
    required String eventId,
    required int seq,
  }) async {
    return shared._wearModule?.processVendorEvent(
      provider: provider,
      eventType: eventType,
      payload: payload,
      eventId: eventId,
      seq: seq,
    );
  }

  // ── Sleep Score ──────────────────────────────────────────────────

  /// Compute a batch [SleepScoreResult] from a [SleepScoreInput].
  ///
  /// Stateless: runs purely through the engine pipeline and does not
  /// persist. Use [attachSleepScore] to ride the next HSI with the
  /// returned result. Returns `null` if the runtime is not initialized
  /// or the engine rejected the input.
  static SleepScoreResult? computeSleepScore(SleepScoreInput input) {
    return _coreRuntime?.computeSleepScore(input);
  }

  /// Attach a batch [SleepScoreResult] so it rides the next emitted
  /// HSI window as the `sleep_score` axis and feeds the Path-B
  /// 7-night median. Returns 0 on success, non-zero on failure.
  static int attachSleepScore(SleepScoreResult result) {
    return _coreRuntime?.attachSleepScore(result) ?? -1;
  }

  // ── Recovery Score ────────────────────────────────────────────────

  /// Compute a daily Recovery Score from a JSON-encoded
  /// `RecoveryScoreInput`.
  ///
  /// Three-stage scoring:
  /// - Stage 1 (FirstDay): 1 night of sleep + (HR or HRV)
  /// - Stage 2 (ShortHistory): ≥ 3 nights with HR/HRV trends
  /// - Stage 3 (Personalized): ≥ 7 nights + stable wearable baselines
  ///
  /// Returns the JSON-encoded `RecoveryScoreResult` on success, the
  /// literal `"null"` when the input has no overnight HR/HRV (sleep-only
  /// recovery is forbidden by design), or `null` on parse error / when
  /// the runtime isn't initialized.
  ///
  /// Decode the result with `RecoveryScoreResult.fromJsonString` (Dart
  /// model in the consuming app) or `jsonDecode(raw)` for ad-hoc
  /// rendering. The shape mirrors the Synheart Runtime's
  /// `RecoveryScoreResult` JSON-serialized form and is locked.
  static String? computeRecoveryScoreJson(String inputJson) {
    return _coreRuntime?.recoveryScoreComputeJson(inputJson);
  }

  /// Same as [computeRecoveryScoreJson] with a host-supplied
  /// correlation id attached to tracing events.
  static String? computeRecoveryScoreJsonTraced(
    String inputJson,
    String correlationId,
  ) {
    return _coreRuntime?.recoveryScoreComputeJsonTraced(
      inputJson,
      correlationId,
    );
  }

  /// Typed version of [computeRecoveryScoreJson]: builds the JSON,
  /// invokes the engine, and parses the result. Returns `null` when
  /// the input has no overnight HR/HRV (sleep-only recovery is
  /// forbidden by design) or when the runtime isn't ready / the
  /// engine returned an error.
  static RecoveryScoreResult? computeRecoveryScore(RecoveryScoreInput input) {
    final raw = _coreRuntime?.recoveryScoreComputeJson(input.toJsonString());
    if (raw == null || raw.isEmpty || raw == 'null') return null;
    try {
      return RecoveryScoreResult.fromJsonString(raw);
    } catch (_) {
      return null;
    }
  }

  // ── Readiness Score ───────────────────────────────────────────────

  /// Compute a daily Readiness Score from a JSON-encoded
  /// `ReadinessScoreInput`. Combines today's Recovery Score with
  /// optional acute / chronic load, fatigue, and history context to
  /// answer "how much strain should the user take today?".
  ///
  /// Returns the JSON-encoded `ReadinessScoreResult` on success, or
  /// `null` on parse error / runtime not ready.
  static String? computeReadinessScoreJson(String inputJson) {
    return _coreRuntime?.readinessScoreComputeJson(inputJson);
  }

  /// Same as [computeReadinessScoreJson] with a host-supplied
  /// correlation id attached to tracing events.
  static String? computeReadinessScoreJsonTraced(
    String inputJson,
    String correlationId,
  ) {
    return _coreRuntime?.readinessScoreComputeJsonTraced(
      inputJson,
      correlationId,
    );
  }

  /// Typed version of [computeReadinessScoreJson]: builds the JSON,
  /// invokes the engine, and parses the result. Returns `null` only
  /// when the runtime isn't ready or the engine returned an error —
  /// readiness is computed whenever a recovery anchor is provided.
  static ReadinessScoreResult? computeReadinessScore(
    ReadinessScoreInput input,
  ) {
    final raw = _coreRuntime?.readinessScoreComputeJson(input.toJsonString());
    if (raw == null || raw.isEmpty || raw == 'null') return null;
    try {
      return ReadinessScoreResult.fromJsonString(raw);
    } catch (_) {
      return null;
    }
  }

  /// Attach today's daily Recovery Score (`0.=100`) so personalization
  /// Stage 2 blends it alongside the per-window HRV / RHR / provider /
  /// recent-sleep components. Sticky across HSI windows until cleared
  /// or replaced — call again on day rollover with a fresh score.
  /// Returns `0` on success.
  static int attachRecoveryScoreToday(int score) {
    return _coreRuntime?.attachRecoveryScoreToday(score) ?? -1;
  }

  /// Drop today's Recovery Score. Use on day rollover when no fresh
  /// score is yet available. Returns `0` on success.
  static int clearRecoveryScoreToday() {
    return _coreRuntime?.clearRecoveryScoreToday() ?? -1;
  }

  /// Snapshot of the current [WearableReferenceView] — including
  /// Path-B `recent_sleep_score_median`. Null when no reference has
  /// been produced yet or the runtime is not initialized.
  static WearableReferenceView? get wearableReference {
    return _coreRuntime?.wearableReference();
  }

  /// Last live-head SleepScore JSON (live-head shape:
  /// path/mode/components/tier/baseline). Null before the first
  /// window closes. For the batch-score shape use [computeSleepScore].
  static String? get lastSleepScoreJson {
    return _coreRuntime?.lastSleepScoreJson();
  }

  /// Raw JSON of the longitudinal SRM snapshot (Path-B
  /// `recent_sleep_score_ring`, dimension buffers, last reference,
  /// schema version). Useful to surface the ring before any HSI
  /// window has closed — the ring updates on every
  /// [attachSleepScore], whereas [wearableReference] only refreshes
  /// when the live HSI tick produces a window.
  static String? get longitudinalSnapshotJson {
    // Symmetric with [loadLongitudinalSnapshot]: callers shouldn't
    // need to know about Pipeline lifecycle to read an empty-but-valid
    // snapshot at cold boot. Returns null only when the native runtime
    // itself is missing.
    _coreRuntime?.ensurePipeline();
    return _coreRuntime?.exportLongitudinalSnapshot();
  }

  /// Restore the longitudinal SRM snapshot exported by
  /// [longitudinalSnapshotJson] back into the native runtime.
  ///
  /// The native runtime does NOT auto-persist this snapshot — its FFI
  /// contract is "host persists; restores via
  /// `synheart_core_load_longitudinal_snapshot` on startup". Without
  /// this call after [initialize], a fresh app launch starts with an
  /// empty SRM pipeline: the Path-B sleep-score ring, dimension
  /// buffers and last reference are all gone, so baselines blank back
  /// to the cold-start "Empty" state on every restart.
  ///
  /// Returns `0` on success, a non-zero error code from the runtime,
  /// or `-1` when the native runtime is not linked.
  static int loadLongitudinalSnapshot(String json) {
    // Cold-boot restore happens before any session/sleep-score has
    // materialized the runtime's Pipeline; without this, the load
    // would fail with "runtime not available" through no fault of
    // the caller. ensurePipeline() is documented as no-op when one
    // already exists, so the warm-path cost is zero.
    _coreRuntime?.ensurePipeline();
    return _coreRuntime?.loadLongitudinalSnapshot(json) ?? -1;
  }

  // ── Realtime event stream (RAMEN via native stream-runtime) ──────

  /// `true` when the RAMEN stream callback should auto-route vendor.*
  /// events through [processVendorEvent]. Set by [startVendorSync] (and
  /// cleared by [stopVendorSync]). Other consumers — e.g.
  /// [onDataDeletionUpdate] — don't depend on it; they ride the same
  /// connection regardless.
  static bool _vendorAutoRouteEnabled = false;

  /// Start the RAMEN streaming connection — the primitive shared by every
  /// real-time event surface (data deletion updates, vendor sync, future
  /// account events, etc.).
  ///
  /// Use this directly when you only want non-vendor events
  /// (e.g. [onDataDeletionUpdate]). Use [startVendorSync] when you also
  /// want vendor data auto-routed through [processVendorEvent].
  ///
  /// [config] must include `host`, `port`, `app_id`, `device_id`, `user_id`.
  /// Optional: `api_key`, `use_tls`, `providers`, `event_types`.
  ///
  /// Connection-level consent: requires `CloudUpload` only — the umbrella
  /// "we connect to your cloud" consent. Per-event-type consent is
  /// enforced at the dispatch layer (see [_vendorAutoRouteEnabled] for
  /// vendor events).
  static void startEventStream(Map<String, dynamic> config) {
    final bridge = _coreRuntime;
    if (bridge == null) {
      SynheartLogger.stream('Cannot start: runtime not initialized');
      return;
    }

    SynheartLogger.stream(
      'Starting RAMEN '
      'host=${config['host']}:${config['port']} '
      'app_id=${config['app_id']} '
      'user_id=${config['user_id']} '
      'use_tls=${config['use_tls']}',
    );

    // Capture connection-level identifiers so [_emitRawRamenEvent]
    // can stamp them onto each surfaced [RamenEvent] (the runtime
    // only carries event-level fields on the broadcast).
    _vendorAppId = config['app_id']?.toString() ?? '';
    _vendorUserId = config['user_id']?.toString() ?? '';

    // Register callback — each event from the native runtime is parsed and processed.
    bridge.setStreamCallback((String eventJson) {
      try {
        final event = jsonDecode(eventJson) as Map<String, dynamic>;
        final provider = event['provider']?.toString() ?? '';
        final eventType = event['event_type']?.toString() ?? '';
        final payloadJson = event['payload_json']?.toString() ?? '{}';
        final eventId = event['event_id']?.toString() ?? '';
        final seq = (event['seq'] as num?)?.toInt() ?? 0;

        // Surface the raw event on the typed stream first so apps
        // that want client-side ping handling see it before the
        // auto-route below kicks in.
        _emitRawRamenEvent(event);

        // Customer-facing GDPR data deletion events have a separate
        // typed stream — they're not vendor data, so skip the
        // vendor-routing fall-through after emitting.
        if (eventType.startsWith('user.data_deletion.')) {
          _emitDataDeletionUpdate(event);
          return;
        }

        // Skip the auto-route for ping-flavored events: their inline
        // payload is empty by design (Garmin / Oura / Fitbit only send
        // a notification). The app must subscribe to [rawRamenEvents]
        // and use `RamenEventDispatcher` to fetch the full record via
        // REST before re-entering [processVendorEvent]. Auto-routing
        // here would just store an empty payload keyed by the event_id,
        // which then blocks the real one.
        final hint = event['delivery_hint']?.toString() ?? '';
        if (hint == 'ping') {
          SynheartLogger.stream(
            '[RAMEN] ping event provider=$provider type=$eventType '
            'event_id=$eventId seq=$seq — deferring to rawRamenEvents subscriber',
          );
          return;
        }

        Map<String, dynamic> payload;
        try {
          payload = jsonDecode(payloadJson) as Map<String, dynamic>;
        } catch (_) {
          payload = {};
        }

        // Surface the full raw payload so we can diff what RAMEN delivers
        // vs what backfill stores. Truncate at 1k chars to avoid log spam
        // on large workout/strain bodies.
        final preview = payloadJson.length > 1000
            ? '${payloadJson.substring(0, 1000)}…(${payloadJson.length}B)'
            : payloadJson;
        SynheartLogger.stream(
          '[RAMEN] event provider=$provider type=$eventType '
          'event_id=$eventId seq=$seq payload=$preview',
        );

        // Vendor data routing is gated on the customer having opted into
        // vendor sync. Apps using the stream only for non-vendor events
        // (e.g. data deletion updates) get the raw event on
        // [rawRamenEvents] without auto-routing into the vendor pipeline.
        if (_vendorAutoRouteEnabled) {
          processVendorEvent(
            provider: provider,
            eventType: eventType,
            payload: payload,
            eventId: eventId,
            seq: seq,
          );

          // Mirror sleep events into Baselines.ingestVendorSleep — same fan-out
          // the backfill path performs. Baselines looks for the raw vendor
          // record under `<provider>_data`, so wrap it accordingly.
          if (eventType.contains('sleep')) {
            final wrapped = <String, dynamic>{
              '${provider}_data': payload,
              'timestamp': DateTime.now().toUtc().toIso8601String(),
            };
            // ignore: discarded_futures — fire-and-forget, matches backfill
            Baselines.ingestVendorSleep(provider: provider, payload: wrapped);
          }
        }
      } catch (e) {
        SynheartLogger.stream('event parse failed: $e', error: e);
      }
    });

    bridge.startStream(config);
  }

  /// Stop the RAMEN streaming connection. Clears the vendor auto-route
  /// flag as a side effect — call [startVendorSync] again to re-enable.
  static void stopEventStream() {
    SynheartLogger.stream('Stopping RAMEN');
    _coreRuntime?.stopStream();
    _coreRuntime?.clearStreamCallback();
    _vendorAutoRouteEnabled = false;
    _vendorAppId = '';
    _vendorUserId = '';
  }

  /// Start the RAMEN connection AND enable vendor-event auto-routing
  /// through [processVendorEvent]. Equivalent to [startEventStream] for
  /// the connection, plus a one-line flag flip on the dispatch layer.
  ///
  /// Use this when your app pulls vendor data (Whoop / Garmin / Oura /
  /// Fitbit) and wants the runtime to normalize + store events as they
  /// arrive. Use [startEventStream] when you only want non-vendor
  /// events (data deletion, future account events).
  static void startVendorSync(Map<String, dynamic> config) {
    _vendorAutoRouteEnabled = true;
    startEventStream(config);
  }

  /// Stop the RAMEN streaming connection. Alias of [stopEventStream] —
  /// kept for back-compat with callers that paired it with
  /// [startVendorSync].
  static void stopVendorSync() => stopEventStream();

  /// Get the current vendor sync connection state.
  ///
  /// Returns "connecting", "connected", "disconnected", or "reconnecting".
  static String? get vendorSyncState => _coreRuntime?.streamState();

  /// Stream of canonical vendor events as they are processed and stored.
  static Stream<CanonicalWearableEvent>? get vendorEvents =>
      shared._wearModule?.canonicalEvents;

  // ── Raw RAMEN event stream (for capability-flavored handling) ─────
  //
  // Apps that want client-side control over stream vs ping delivery
  // (capability-flavored delivery, 2026-05-02) subscribe here and route through
  // `RamenEventDispatcher` from synheart_wear before calling
  // `Synheart.processVendorEvent`. Apps that don't care can keep
  // using `vendorEvents` — the runtime auto-routes inline payloads
  // there, but ping-flavored events arrive payload-less and need
  // a follow-up REST pull.

  static final StreamController<RamenEvent> _ramenEventController =
      StreamController<RamenEvent>.broadcast();

  // Captured from the most recent [startVendorSync] config. The
  // native RamenEvent carries only event-level fields; app_id /
  // user_id are connection-level so we stamp them here before surfacing.
  static String _vendorAppId = '';
  static String _vendorUserId = '';

  /// Raw RAMEN events as they arrive from the runtime, with the
  /// capability-flavored `deliveryHint` parsed from the cloud.
  ///
  /// Apps wanting ping vs stream control should subscribe here
  /// rather than `vendorEvents` (which only sees the post-processed
  /// canonical events that the runtime auto-routed). Pair with
  /// `RamenEventDispatcher` from synheart_wear to materialize ping
  /// payloads via REST.
  static Stream<RamenEvent> get rawRamenEvents => _ramenEventController.stream;

  /// Internal: invoked from the stream callback below for every
  /// incoming event.
  static void _emitRawRamenEvent(Map<String, dynamic> json) {
    if (_ramenEventController.isClosed) return;
    _ramenEventController.add(
      RamenEvent.fromRuntimeJson(
        json,
        appId: _vendorAppId,
        userId: _vendorUserId,
      ),
    );
  }

  // ── Customer data deletion: real-time updates from RAMEN ──────────

  static final StreamController<DataDeletionEvent> _dataDeletionUpdates =
      StreamController<DataDeletionEvent>.broadcast();

  /// Real-time status transitions for [requestDataDeletion]. The cloud
  /// publishes one event per lifecycle change (`scheduled`, `completed`,
  /// `failed`, `cancelled`) over the same RAMEN stream that vendor
  /// events use.
  ///
  /// Prerequisites: a live RAMEN connection ([startVendorSync] called).
  /// If the SDK isn't connected when the event lands, RAMEN replays
  /// missed events on reconnect via its persistent cursor — your handler
  /// still runs, just later.
  ///
  /// Typical use:
  /// ```dart
  /// final sub = Synheart.onDataDeletionUpdate.listen((event) {
  ///   if (event.status == DataDeletionStatus.completed) {
  ///     // Tell the user their data is gone.
  ///   }
  /// });
  /// await Synheart.requestDataDeletion(reason: 'user-initiated');
  /// ```
  static Stream<DataDeletionEvent> get onDataDeletionUpdate =>
      _dataDeletionUpdates.stream;

  /// Internal: parse a `user.data_deletion.*` envelope and emit on the
  /// typed stream. Best-effort — a parse failure logs and continues.
  static void _emitDataDeletionUpdate(Map<String, dynamic> envelope) {
    if (_dataDeletionUpdates.isClosed) return;
    try {
      final raw = envelope['payload_json']?.toString() ?? '{}';
      final payload = jsonDecode(raw) as Map<String, dynamic>;
      _dataDeletionUpdates.add(
        DataDeletionEvent.fromRuntimeJson(
          envelope: envelope,
          payload: payload,
          appId: _vendorAppId,
          userId: _vendorUserId,
        ),
      );
    } catch (e) {
      SynheartLogger.stream('data deletion event parse failed: $e', error: e);
    }
  }

  /// Query stored vendor events from the Core runtime.
  ///
  /// Returns a list of decoded event maps with `event_id`, `type`, `provider`,
  /// `payload`, `observed_at_ms`, `confidence`, etc.
  static List<dynamic>? queryVendorEvents({
    String? provider,
    String? type,
    DateTime? start,
    DateTime? end,
    int limit = 100,
  }) {
    return _coreRuntime?.queryVendorEvents(
      provider: provider,
      type: type,
      startMs: start?.millisecondsSinceEpoch,
      endMs: end?.millisecondsSinceEpoch,
      limit: limit,
    );
  }

  /// Get the most recent vendor event of a given type.
  static Map<String, dynamic>? getLatestVendorEvent(
    String provider,
    String type,
  ) {
    return _coreRuntime?.getLatestVendorEvent(provider, type);
  }

  /// Delete all stored vendor events for a provider (e.g. on unlink).
  static int deleteVendorEventsForProvider(String provider) {
    return _coreRuntime?.deleteVendorEventsForProvider(provider) ?? -1;
  }

  static Future<void> grantConsent({
    required bool biosignals,
    required bool behavior,
    required bool phoneContext,
    required bool cloudUpload,
    bool vendorSync = false,
    String? profileId,
    ConsentTier? tier,
    ConsentChannels? grantedChannels,
    bool research = false,
    bool syni = false,
  }) async {
    if (_coreRuntime != null) {
      // Mirror every channel's new value into the native core — grant when
      // true, revoke when false. Without the revoke path the core's state
      // drifts out of sync with the UI the moment the user flips a toggle
      // OFF (the subsequent hasConsent read returns the stale TRUE).
      //
      // grant/revoke now run off the UI isolate (they do blocking network I/O
      // — see CoreRuntime._consentMutate). Await them SEQUENTIALLY so two
      // consent mutations never race on the shared native handle.
      final rt = _coreRuntime!;
      await (biosignals
          ? rt.grantConsent('biosignals')
          : rt.revokeConsent('biosignals'));
      await (behavior
          ? rt.grantConsent('behavior')
          : rt.revokeConsent('behavior'));
      await (phoneContext
          ? rt.grantConsent('phone_context')
          : rt.revokeConsent('phone_context'));
      await (cloudUpload
          ? rt.grantConsent('cloud_upload')
          : rt.revokeConsent('cloud_upload'));
      await (vendorSync
          ? rt.grantConsent('vendor_sync')
          : rt.revokeConsent('vendor_sync'));
      await (research
          ? rt.grantConsent('research')
          : rt.revokeConsent('research'));
      await (syni ? rt.grantConsent('syni') : rt.revokeConsent('syni'));
      // Fall through to Dart consent module so UI and module wiring stays in sync
    }
    return shared._grantConsent(
      biosignals: biosignals,
      behavior: behavior,
      phoneContext: phoneContext,
      cloudUpload: cloudUpload,
      vendorSync: vendorSync,
      profileId: profileId,
      tier: tier,
      grantedChannels: grantedChannels,
      research: research,
      syni: syni,
    );
  }

  Future<void> _grantConsent({
    required bool biosignals,
    required bool behavior,
    required bool phoneContext,
    required bool cloudUpload,
    bool vendorSync = false,
    String? profileId,
    ConsentTier? tier,
    ConsentChannels? grantedChannels,
    bool research = false,
    bool syni = false,
  }) async {
    if (!_isConfigured) {
      // If init is in progress, wait for it then proceed.
      if (_initCompleter != null) {
        await _initCompleter!.future;
      } else {
        // Not even started — queue for later.
        _pendingConsent = _PendingConsent(
          biosignals: biosignals,
          behavior: behavior,
          phoneContext: phoneContext,
          cloudUpload: cloudUpload,
          vendorSync: vendorSync,
          tier: tier,
          grantedChannels: grantedChannels,
          research: research,
        );
        SynheartLogger.log(
          '[Synheart] SDK not yet initialized — consent queued and will be applied after init.',
        );
        return;
      }
    }

    if (_consentModule == null) {
      throw StateError('Consent module not initialized');
    }

    // If cloud consent is granted and device auth is configured but not yet
    // initialized, kick device attestation off in the background.
    //
    // _initDeviceAuth runs the 7-step registration (Play Integrity bind +
    // token mint + keypair + HTTPS POST to /v1/device/register). The FFI
    // hop into the native runtime is synchronous from the main isolate's
    // POV; on cold Play Integrity bind it can park the main thread for
    // multiple seconds, which trips Android's ANR watchdog (SIGQUIT,
    // "Wrote stack traces to tombstoned") on first-time signup — exactly
    // when the consent screen is mid-submit.
    //
    // The host UI is already designed for asynchronous registration —
    // the "Setting up your workspace" card observes the runtime's auth
    // status stream and dismisses when registration completes — so the
    // consent handler doesn't need to block on it. Fire-and-forget,
    // log on completion / failure. Failures here don't break local mode;
    // they just mean cloud uploads will keep retrying until the next
    // successful registration attempt.
    if (cloudUpload &&
        _config?.deviceAuthConfig != null &&
        _deviceAuthProvider == null) {
      SynheartLogger.log(
        '[Synheart] Cloud consent granted — activating device auth (background)..',
      );
      unawaited(
        _initDeviceAuth(_config!).then(
          (_) => SynheartLogger.log(
            '[Synheart] Device auth activated successfully.',
          ),
          onError: (Object e, StackTrace st) {
            SynheartLogger.log(
              '[Synheart] Device auth activation failed: $e',
              error: e,
              stackTrace: st,
            );
            // Continue — cloud uploads will fail but local mode still works
          },
        ),
      );
    }

    // If cloud or platform-ingest is configured and cloudUpload is true, issue token.
    if (_config?.cloudConfig != null && cloudUpload && profileId != null) {
      try {
        // Request token directly with known profile id.
        await _consentModule!.requestConsentByProfileId(
          profileId,
          grantedChannels: grantedChannels,
          tier: tier,
          cloud: cloudUpload,
          research: research,
        );
        SynheartLogger.log(
          '[Synheart] Consent token issued for profile: $profileId (tier: ${(tier ?? ConsentTier.local).name})',
        );
      } catch (e) {
        SynheartLogger.log(
          '[Synheart] Error issuing consent token: $e',
          error: e,
        );
        // Continue with local consent even if token issuance fails
      }
    } else if (_config?.cloudConfig != null &&
        cloudUpload &&
        profileId == null) {
      // Caller granted cloud but didn't supply a profile id. Without a token
      // the native ingest connector fails every flush tick with
      // "ERR_AUTH: ingest requires non-empty X-Consent-Token". Route through
      // the runtime's editable-form submission path, which derives the
      // profile id from the runtime's current form (offline default when no
      // profile has been selected) and issues the JWT end-to-end.
      await _maybeEnsureCloudConsentReady();
    }

    // Update local consent snapshot
    final snapshot = ConsentSnapshot(
      biosignals: biosignals,
      behavior: behavior,
      phoneContext: phoneContext,
      cloudUpload: cloudUpload,
      syni: syni,
      vendorSync: vendorSync,
      research: research,
      timestamp: DateTime.now(),
      explicitlyDenied: false,
      tier: tier ?? ConsentTier.local,
      channels: grantedChannels,
    );

    await _consentModule!.updateConsent(snapshot);

    // If any consent was denied, stop data collection for those modules immediately
    if (!biosignals && _wearModule != null) {
      SynheartLogger.log(
        '[Synheart] Biosignals consent denied - stopping wear data collection',
      );
      // The WearModule will handle this via consent stream listener
    }

    if (!behavior && _behaviorModule != null) {
      SynheartLogger.log(
        '[Synheart] Behavior consent denied - stopping behavior data collection',
      );
      // The BehaviorModule will handle this via consent checks
    }

    if (!phoneContext && _phoneModule != null) {
      SynheartLogger.log(
        '[Synheart] Phone context consent denied - stopping phone data collection',
      );
      // The PhoneModule will handle this via consent checks
    }

    SynheartLogger.log(
      '[Synheart] Consent granted: biosignals=$biosignals, behavior=$behavior, phoneContext=$phoneContext, cloudUpload=$cloudUpload',
    );
  }

  Map<String, bool> _getConsentStatusMap() {
    if (_coreRuntime != null) {
      final runtime = _coreRuntime!;
      final syni = _consentModule?.current().syni ?? false;
      return {
        'biosignals': runtime.hasConsent('biosignals'),
        'behavior': runtime.hasConsent('behavior'),
        'phoneContext': runtime.hasConsent('phone_context'),
        'cloudUpload': runtime.hasConsent('cloud_upload'),
        'syni': syni,
        'vendorSync': runtime.hasConsent('vendor_sync'),
        'research': runtime.hasConsent('research'),
      };
    }

    if (_consentModule == null) {
      return {
        'biosignals': false,
        'behavior': false,
        'phoneContext': false,
        'cloudUpload': false,
        'syni': false,
        'vendorSync': false,
        'research': false,
      };
    }

    final consent = _consentModule!.current();
    return {
      'biosignals': consent.biosignals,
      'behavior': consent.behavior,
      'phoneContext': consent.phoneContext,
      'cloudUpload': consent.cloudUpload,
      'syni': consent.syni,
      'vendorSync': consent.vendorSync,
      'research': consent.research,
    };
  }

  /// Delete all local data
  ///
  /// Clears:
  /// - Module caches (wear, phone, behavior)
  /// - Consent data (but keeps consent preferences)
  /// - Upload queue
  /// - HSI state
  ///
  /// Example:
  /// ```dart
  /// await Synheart.deleteLocalData();
  /// ```
  static Future<void> deleteLocalData() async {
    return shared._deleteLocalData();
  }

  Future<void> _deleteLocalData() async {
    if (!_isConfigured) {
      throw StateError(
        'Synheart must be initialized before deleting local data',
      );
    }

    SynheartLogger.log('[Synheart] Deleting all local data..');

    // Clear module caches
    if (_wearModule != null) {
      await _wearModule!.clearCache();
    }
    if (_phoneModule != null) {
      await _phoneModule!.clearCache();
    }
    if (_behaviorModule != null) {
      await _behaviorModule!.clearCache();
    }

    // Wipe the core-runtime side: SQLite, SMK, longitudinal SRM
    // snapshot (where the persisted Path-B `recent_sleep_score_ring`
    // lives). Consumer apps that call this public entry expect _all_
    // local state to be gone — module caches alone weren't enough.
    if (_coreRuntime != null) {
      _coreRuntime!.wipeLocalData();
    }

    // Drop in-memory Baselines caches (latest score, last source,
    // dedupe map) so the next snapshot read returns cold-start.
    Baselines.reset();
    _baselineSnapshots.reset();

    SynheartLogger.log('[Synheart] Local data deleted');
  }

  /// Delete data for a specific module
  ///
  /// Example:
  /// ```dart
  /// await Synheart.deleteModuleData('biosignals');
  /// ```
  static Future<void> deleteModuleData(String moduleName) async {
    return shared._deleteModuleData(moduleName);
  }

  Future<void> _deleteModuleData(String moduleName) async {
    if (!_isConfigured) {
      throw StateError(
        'Synheart must be initialized before deleting module data',
      );
    }

    SynheartLogger.log('[Synheart] Deleting data for module: $moduleName');

    switch (moduleName.toLowerCase()) {
      case 'biosignals':
      case 'wear':
        await _wearModule?.clearCache();
        break;
      case 'phonecontext':
      case 'phone':
        await _phoneModule?.clearCache();
        break;
      case 'behavior':
        await _behaviorModule?.clearCache();
        break;
      default:
        throw ArgumentError('Unknown module: $moduleName');
    }

    SynheartLogger.log('[Synheart] Module data deleted: $moduleName');
  }

  /// Delete cloud data.
  ///
  /// **This never deleted anything.** The implementation logged
  /// "Deleting cloud data.." followed by "Cloud data deletion requested" and
  /// returned — no queue was cleared and no request was sent. Because it was
  /// public, documented, and resolved successfully, a host could reasonably
  /// have wired it to a "Delete my cloud data" control and shipped a privacy
  /// promise the SDK did not keep.
  ///
  /// Use [requestDataDeletion] instead: it drives the real GDPR Article 17
  /// chain through the runtime, returns a [DataDeletionRequest] with a
  /// pollable `requestId`, and publishes progress on [onDataDeletionUpdate].
  /// Pair it with [wipeLocalData] for the full "delete my account" flow.
  ///
  /// Throws [UnsupportedError] rather than silently succeeding, so any
  /// existing caller fails loudly at the point of the false promise.
  @Deprecated(
    'Never deleted anything — it only logged. Use requestDataDeletion() for '
    'cloud-side erasure and wipeLocalData() for on-device data. Will be '
    'removed in 0.12.0.',
  )
  static Future<void> deleteCloudData() async {
    throw UnsupportedError(
      'Synheart.deleteCloudData() was a no-op and has been disabled. Use '
      'Synheart.requestDataDeletion() to request cloud-side erasure (poll it '
      'with dataDeletionStatus() or subscribe to onDataDeletionUpdate), and '
      'Synheart.wipeLocalData() to clear on-device data.',
    );
  }

  /// Revoke consent (clears token and notifies cloud)
  static Future<void> revokeConsent() async {
    return shared._revokeConsent();
  }

  Future<void> _revokeConsent() async {
    if (_consentModule == null) {
      throw StateError('Consent module not initialized');
    }
    await _consentModule!.revokeConsent();
  }

  /// Deny consent (marks as explicitly denied by user)
  ///
  /// This should be called when user declines consent in the UI,
  /// to distinguish from "never asked" (pending) state.
  static Future<void> denyConsent() async {
    return shared._denyConsent();
  }

  Future<void> _denyConsent() async {
    if (_consentModule == null) {
      throw StateError('Consent module not initialized');
    }
    await _consentModule!.denyConsent();
  }

  /// Runtime diagnostics — availability, native version, frame count, and any
  /// optional native symbols the loaded runtime failed to export.
  ///
  /// Useful for debugging and runtime verification screens. Keys:
  ///
  /// - `isAvailable` (`bool`) — the native bridge loaded.
  /// - `version` (`String?`) — native runtime version.
  /// - `frameCount` (`int`) — HSI frames produced in the current session.
  /// - `missingSymbols` (`List<String>`) — optional symbols the loaded library
  ///   does not export. Non-empty means the vendored runtime predates this SDK
  ///   release and the features behind those symbols are silently disabled;
  ///   run `synheart install runtime` to update it.
  /// - `probedSymbols` (`int`) — how many optional symbols have been checked.
  ///   Optional bindings resolve lazily, so this is `0` until something uses
  ///   them and an empty `missingSymbols` alongside `probedSymbols: 0` means
  ///   "nothing checked", not "all good". Pass `probeAll: true` to force a full
  ///   audit first.
  ///
  /// The `lastQuality` key was removed in 0.10.2 — it read a native symbol
  /// (`synheart_core_last_quality`) that the runtime has never exported
  /// outside the edge/watch variant, so it always reported `0.0`.
  static Map<String, dynamic> runtimeDiagnostics({bool probeAll = false}) {
    if (probeAll) {
      // Resolve every optional symbol so `missingSymbols` is a real audit.
      // Off by default: it costs ~18 lookups and logs a line per miss, which
      // belongs on a diagnostics screen rather than on every status poll.
      SynheartCoreFFI.load()?.probeOptionalSymbols();
    }
    return {
      'isAvailable': _coreRuntime != null,
      'version': CoreRuntimeBridge.version(),
      'frameCount': _coreRuntime?.frameCount() ?? 0,
      'missingSymbols': SynheartCoreFFI.missingSymbols.toList(growable: false)
        ..sort(),
      'probedSymbols': SynheartCoreFFI.probedSymbolCount,
    };
  }

  /// All synheart crate versions, target, profile, and enabled features.
  /// No active session needed — compile-time info baked into the .so/.a.
  static Map<String, dynamic>? get buildInfo => CoreRuntimeBridge.buildInfo();

  /// Get module statuses (for debugging)
  Map<String, String> getModuleStatuses() {
    final statuses = _moduleManager.getModuleStatuses();
    return statuses.map((key, value) => MapEntry(key, value.name));
  }

  /// Handle consent changes — reevaluate all features via the four-authority model.
  void _onConsentChanged(ConsentSnapshot newConsent) {
    // Background HRV / live HRV is not part of the consent snapshot
    // (it's a separate runtime gate, not a granted-channel) but it's
    // the user-facing toggle next to consents on the privacy screen,
    // so include it alongside for parity.
    SynheartLogger.log(
      '[Synheart] Consent changed: '
      'biosignals=${newConsent.biosignals} '
      'behavior=${newConsent.behavior} '
      'phoneContext=${newConsent.phoneContext} '
      'cloudUpload=${newConsent.cloudUpload} '
      'syni=${newConsent.syni} '
      'vendorSync=${newConsent.vendorSync} '
      'research=${newConsent.research} '
      'backgroundHrv=${getAmbientCapture()}',
    );

    _reevaluateAllFeatures();
  }

  // Feature Reevaluation (Four-Authority Model)

  /// Reevaluate whether a single feature should be operational.
  ///
  /// ```
  /// isOperational = activated AND hasConsent AND capabilityAllowed AND isRunning
  /// ```
  void _reevaluateFeature(SynheartFeature feature) {
    final activated = _activationManager?.isActivated(feature) ?? false;
    final hasConsent = _hasConsentForFeature(feature);
    final capabilityAllowed = _isCapabilityAllowed(feature);
    final isOperational =
        activated && hasConsent && capabilityAllowed && _isRunning;

    switch (feature) {
      case SynheartFeature.wear:
        if (isOperational && _wearModule?.status != ModuleStatus.running) {
          _wearModule?.start().catchError(
            (e) => SynheartLogger.log(
              '[Synheart] Error starting wear: $e',
              error: e,
            ),
          );
        } else if (!isOperational &&
            _wearModule?.status == ModuleStatus.running) {
          _wearModule?.stop().catchError(
            (e) => SynheartLogger.log(
              '[Synheart] Error stopping wear: $e',
              error: e,
            ),
          );
        }
      case SynheartFeature.behavior:
        if (isOperational && _behaviorModule?.status != ModuleStatus.running) {
          _behaviorModule?.start().catchError(
            (e) => SynheartLogger.log(
              '[Synheart] Error starting behavior: $e',
              error: e,
            ),
          );
        } else if (!isOperational &&
            _behaviorModule?.status == ModuleStatus.running) {
          _behaviorModule?.stop().catchError(
            (e) => SynheartLogger.log(
              '[Synheart] Error stopping behavior: $e',
              error: e,
            ),
          );
        }

      case SynheartFeature.phoneContext:
        if (isOperational && _phoneModule?.status != ModuleStatus.running) {
          _phoneModule?.start().catchError(
            (e) => SynheartLogger.log(
              '[Synheart] Error starting phone: $e',
              error: e,
            ),
          );
        } else if (!isOperational &&
            _phoneModule?.status == ModuleStatus.running) {
          _phoneModule?.stop().catchError(
            (e) => SynheartLogger.log(
              '[Synheart] Error stopping phone: $e',
              error: e,
            ),
          );
        }
      case SynheartFeature.cloud:
        // Cloud connector removed — managed by core runtime bridge.
        break;
      case SynheartFeature.synsync:
        // No module to start/stop — baselines ride the existing sync
        // engine. The operational gate controls whether the sync
        // engine pushes/pulls baseline artifacts.
        break;
      case SynheartFeature.syni:
        break;
    }
  }

  /// Reevaluate all features (e.g. after consent change or session start/stop).
  void _reevaluateAllFeatures() {
    for (final feature in SynheartFeature.values) {
      _reevaluateFeature(feature);
    }
  }

  /// Check consent for a feature's required consent type.
  bool _hasConsentForFeature(SynheartFeature feature) {
    final consent = _consentModule?.current();
    if (consent == null) return false;
    switch (feature.requiredConsent) {
      case 'biosignals':
        return consent.biosignals;
      case 'behavior':
        return consent.behavior;
      case 'phoneContext':
        return consent.phoneContext;
      case 'cloudUpload':
        return consent.cloudUpload;
      case 'syni':
        return consent.syni;
      default:
        return false;
    }
  }

  /// True if at least one activated feature has consent (required to start a session).
  /// True when at least one channel that actually yields sensor data is
  /// granted, read from the runtime's effective state where available.
  ///
  /// Distinct from [ConsentEffectiveState.hasAnyGrant], which also counts
  /// cloudUpload / vendorSync / research / syni. Those permit what happens to
  /// data once collected; none of them makes a sensor readable, so a session
  /// gated on `hasAnyGrant` can start with nothing to collect.
  bool _hasAtLeastOneCollectionConsent() {
    final activated = _activationManager?.activatedFeatures() ?? const {};
    for (final feature in _collectionFeatures) {
      if (activated.contains(feature) && _hasCollectionConsentFor(feature)) {
        return true;
      }
    }
    return false;
  }

  /// The features that actually acquire sensor data.
  ///
  /// `cloud`, `synsync` and `syni` are deliberately absent: they govern what
  /// happens to data once collected, so none of them makes a session capable of
  /// gathering anything.
  static const List<SynheartFeature> _collectionFeatures = [
    SynheartFeature.wear,
    SynheartFeature.behavior,
    SynheartFeature.phoneContext,
  ];

  /// Consent for [feature], preferring the runtime's effective state.
  ///
  /// Distinct from [_hasConsentForFeature], which reads `_consentModule` only.
  /// That Dart-side snapshot has been observed returning stale defaults after
  /// the runtime's consent store was already written — the same problem
  /// [_deliverHsiWindow] guards against — so a session start gated on it alone
  /// could reject a user who had in fact granted consent.
  bool _hasCollectionConsentFor(SynheartFeature feature) {
    final effective = consentEffectiveStateTyped();
    if (effective != null) {
      switch (feature) {
        case SynheartFeature.wear:
          return effective.biosignals;
        case SynheartFeature.behavior:
          return effective.behavior;
        case SynheartFeature.phoneContext:
          return effective.phoneContext;
        default:
          return false;
      }
    }
    return _hasConsentForFeature(feature);
  }

  bool _hasAtLeastOneFeatureWithConsent() {
    final activated = _activationManager?.activatedFeatures() ?? {};
    for (final feature in activated) {
      if (_hasConsentForFeature(feature)) return true;
    }
    return false;
  }

  /// Configure device authentication, register device, and fetch capabilities.
  Future<void> _initDeviceAuth(SynheartConfig resolvedConfig) async {
    final current = _deviceAuthInitInFlight;
    if (current != null) {
      return current;
    }

    final attempt = _initDeviceAuthOnce(resolvedConfig);
    _deviceAuthInitInFlight = attempt;
    try {
      await attempt;
    } finally {
      if (identical(_deviceAuthInitInFlight, attempt)) {
        _deviceAuthInitInFlight = null;
      }
    }
  }

  Future<void> _initDeviceAuthOnce(SynheartConfig resolvedConfig) async {
    final dac = resolvedConfig.deviceAuthConfig!;
    SynheartLogger.log('[Synheart] Configuring device authentication..');

    final runtime = _coreRuntime;
    if (runtime == null) {
      throw StateError(
        'Device registration requires core-runtime. Native runtime bridge is unavailable.',
      );
    }
    if (!runtime.sdkDeviceAuthAvailable) {
      throw StateError(
        'Device registration requires synheart_core_sdk_* symbols in the native runtime.',
      );
    }
    if (!_sdkCryptoCallbacksAttached) {
      throw StateError(
        'Device registration requires SDK crypto callbacks to be attached. '
        'Ensure the synheart_auth plugin is registered and '
        'libsynheart_native_crypto.so (Android) / the @_cdecl symbols (iOS) '
        'are bundled so synheart_native_* resolves.',
      );
    }

    SynheartLogger.log(
      '[Synheart] DeviceAuthConfig: authBaseUrl=${dac.authBaseUrl} '
      'capabilityBaseUrl=${dac.capabilityBaseUrl ?? "(default=authBaseUrl)"} '
      'allowUnsignedCapabilities=${resolvedConfig.allowUnsignedCapabilities} '
      'appId=${resolvedConfig.appId}',
    );

    try {
      // After keychain restore the runtime can already be in `registered`
      // state. Calling sdkRegisterDevice again kicks off the full 7-step
      // re-registration (Play Integrity → new keypair → HTTP POST), which
      // blocks the main isolate's microtask queue while it runs and ANRs
      // the app on cold boot once a few stale device records pile up
      // server-side. Short-circuit when the runtime already considers us
      // registered — the keychain/state is the source of truth.
      final preSnap = runtime.sdkDeviceAuthStatus();
      final preStatus = preSnap?['status']?.toString();
      final expectedSubject = Synheart.subjectId ?? resolvedConfig.subjectId;
      if (preStatus == 'registered' &&
          _deviceAuthStatusMatchesSubject(preSnap, expectedSubject)) {
        final restoredId = preSnap?['device_id']?.toString();
        _deviceAuthViaCoreRuntime = true;
        final idPreview = (restoredId == null || restoredId.length <= 8)
            ? (restoredId ?? '?')
            : '${restoredId.substring(0, 8)}..';
        SynheartLogger.log(
          '[Synheart] Device already registered (restored from keychain) — '
          'skipping re-registration (device_id preview: $idPreview)',
        );
      } else {
        final reg = await runtime.sdkRegisterDevice(resolvedConfig.subjectId);
        final deviceId =
            reg?['device_id'] as String? ?? reg?['deviceId'] as String?;
        final err = reg?['error']?.toString();
        if (reg == null ||
            deviceId == null ||
            (err != null && err.isNotEmpty)) {
          throw StateError(
            'Core SDK register_device failed: ${reg ?? "null result"}',
          );
        }
        _deviceAuthViaCoreRuntime = true;
        final idPreview = deviceId.length <= 8
            ? deviceId
            : '${deviceId.substring(0, 8)}..';
        SynheartLogger.log(
          '[Synheart] Core SDK device registration complete (device_id preview: $idPreview)',
        );
      }
    } catch (e) {
      SynheartLogger.log('[Synheart] Device registration failed: $e', error: e);
      // Native identity decisions are part of the public contract. Never hide
      // account mismatch/revocation/etc. behind a dev capability fallback;
      // the host must be able to route the typed code safely.
      if (e is! SyncNativeException &&
          resolvedConfig.allowUnsignedCapabilities) {
        SynheartLogger.log(
          '[Synheart] WARNING: Device registration failed, falling back to unsigned capabilities.',
        );
        await _capabilityModule!.loadDefaults();
        return;
      }
      rethrow;
    }

    try {
      // No bundle-shipped capability token is loaded here: the runtime gates
      // capabilities fail-closed from a verified consent JWT instead.
      await _capabilityModule?.loadDefaults();
    } catch (e) {
      SynheartLogger.log(
        '[Synheart] Capability defaults load failed: $e',
        error: e,
      );
      if (resolvedConfig.allowUnsignedCapabilities) {
        SynheartLogger.log(
          '[Synheart] WARNING: Falling back to unsigned default capabilities.',
        );
        await _capabilityModule!.loadDefaults();
      } else {
        rethrow;
      }
    }

    // 4. Create DeviceAuthProvider for cloud/platform signing
    _deviceAuthProvider = DeviceAuthProvider(
      coreRuntime: runtime,
      baseUrl: dac.authBaseUrl,
    );
  }

  /// v0.24 status includes the restored identity's canonical subject. Compare
  /// it with the canonical subject read back from Core after configuration,
  /// not the raw client id in [SynheartConfig.subjectId]. Comparing canonical
  /// `sub_<hash>` with that raw value made every restored identity look like a
  /// different account and incorrectly invoked first-run registration.
  ///
  /// A missing subject keeps compatibility with older runtime snapshots.
  static bool _deviceAuthStatusMatchesSubject(
    Map<String, dynamic>? status,
    String expectedSubject,
  ) {
    final actual = status?['subject_id']?.toString().trim();
    return actual == null || actual.isEmpty || actual == expectedSubject;
  }

  /// Check whether the CapabilityModule allows a given feature.
  bool _isCapabilityAllowed(SynheartFeature feature) {
    final cap = _capabilityModule;
    if (cap == null) return false;
    switch (feature) {
      case SynheartFeature.wear:
        return cap.capability(Module.wear) != CapabilityLevel.none;
      case SynheartFeature.behavior:
        return cap.capability(Module.behavior) != CapabilityLevel.none;
      case SynheartFeature.phoneContext:
        return cap.capability(Module.phone) != CapabilityLevel.none;
      case SynheartFeature.cloud:
        return cap.capability(Module.cloud) != CapabilityLevel.none;
      case SynheartFeature.synsync:
        // Synsync rides the same capability tier as cloud — it's a
        // cloud-bound operation (baseline upload + restore), gated
        // on the same "has the customer activated cloud features?"
        // signal. No separate capability lattice entry needed.
        return cap.capability(Module.cloud) != CapabilityLevel.none;
      case SynheartFeature.syni:
        // Syni runs independent of the wearable capability lattice. Real
        // operational gating (model installed, engine loaded) lives in
        // SyniModule and is composed at the four-authority layer.
        return _syni?.isInstalled ?? false;
    }
  }

  /// Stop Synheart Core SDK
  static Future<void> stop() async {
    return shared._stop();
  }

  Future<void> _stop() async {
    if (!_isRunning) {
      return;
    }

    try {
      SynheartLogger.log('[Synheart] Stopping..');

      // Remove consent listener (best-effort)
      _consentModule?.removeListener(_onConsentChanged);

      // Stop the modules FIRST, then unhook the HSI callback. The reverse
      // order unregistered the dispatch path while the engine was still
      // producing windows, widening the race documented on
      // CoreRuntimeBridge._retiredCallables. Stopping first means nothing is
      // emitting by the time we clear.
      await _moduleManager.stopAll();

      // Clear HSI callback (core runtime handles cleanup in dispose)
      _coreRuntime?.clearHsiCallback();

      _isRunning = false;
      SynheartLogger.log('[Synheart] Stopped');
    } catch (e, stack) {
      SynheartLogger.log(
        '[Synheart] Stop failed: $e',
        error: e,
        stackTrace: stack,
      );
    }
  }

  /// Dispose all resources
  static Future<void> dispose() async {
    return shared._dispose();
  }

  Future<void> _dispose() async {
    try {
      await _stop();

      _coreRuntime?.dispose();
      _coreRuntime = null;
      _syni = null;
      _syniServiceClient = null;
      _syniServiceRuntime = null;
      _clearBaselineCloudHooks();

      await _moduleManager.disposeAll();

      await _hsvStream.close();

      await _mainSessionSubscription?.cancel();
      _mainSessionSubscription = null;
      _mainSession?.dispose();
      _mainSession = null;
      _activeMainSessionId = null;

      _watchSessionModule?.dispose();
      _watchSessionModule = null;

      await _sessionHsiSubscription?.cancel();
      _sessionHsiSubscription = null;
      await _sessionWearSubscription?.cancel();
      _sessionWearSubscription = null;
      _sessionHsiBuffer.clear();
      _sessionWearBuffer.clear();

      _consentModule = null;
      _capabilityModule = null;
      _wearModule = null;
      _phoneModule = null;
      _behaviorModule = null;
      _coreRuntime?.dispose();
      _coreRuntime = null;
      _clearBaselineCloudHooks();
      _activationManager = null;
      _pendingConsent = null;

      _currentSessionHandle = null;

      _isConfigured = false;
      _isRunning = false;
      _initCompleter = null;
      _invalidateHsiCache();
      _deviceAuthViaCoreRuntime = false;
      _sdkCryptoCallbacksAttached = false;

      SynheartLogger.log('[Synheart] Disposed');
      // Allow re-initialization by creating a fresh instance next time.
      _instance = null;
    } catch (e, stack) {
      SynheartLogger.log(
        '[Synheart] Dispose failed: $e',
        error: e,
        stackTrace: stack,
      );
    }
  }
}

/// Sync result from a push/pull cycle.
class SyncResult {
  final int pushed;
  final int pulled;

  const SyncResult({this.pushed = 0, this.pulled = 0});

  factory SyncResult.fromRuntimeResponse(Map<String, dynamic>? response) {
    if (response == null) {
      throw StateError('The native sync operation returned no result.');
    }
    final pushed = response['pushed'];
    final pulled = response['pulled'];
    if (pushed is! num || pulled is! num) {
      throw const FormatException(
        'The native sync operation returned an invalid result.',
      );
    }
    return SyncResult(pushed: pushed.toInt(), pulled: pulled.toInt());
  }
}

/// Current sync status.
class SyncStatus {
  final bool enabled;

  const SyncStatus({required this.enabled});
}

/// Session record returned from session queries.
class SessionRecord {
  final String sessionId;
  final String subjectId;
  final String mode;
  final int createdAtUtc;
  final int startUtc;

  /// `null` while the session is still active; set to the runtime's
  /// `ended_at_ms` once the session is closed.
  final int? endedAtUtc;

  /// `'active'` while a session is in flight; `'closed'` once
  /// `stopSession` (or an orphan sweep) has finalized it.
  final String state;
  final String appId;
  final String appVersion;
  final String deviceId;
  final String platform;

  const SessionRecord({
    required this.sessionId,
    required this.subjectId,
    required this.mode,
    required this.createdAtUtc,
    required this.startUtc,
    this.endedAtUtc,
    this.state = 'active',
    this.appId = '',
    this.appVersion = '',
    this.deviceId = '',
    this.platform = 'flutter',
  });

  /// True iff the session is still marked `'active'` in storage.
  /// Used by [Synheart.sweepOrphanSessions] to find candidates.
  bool get isActive => state == 'active';

  factory SessionRecord.fromMap(Map<String, dynamic> map) {
    int readInt(List<String> keys) {
      for (final k in keys) {
        final v = map[k];
        if (v is int) return v;
        if (v is num) return v.toInt();
      }
      return 0;
    }

    int? readIntOpt(List<String> keys) {
      for (final k in keys) {
        final v = map[k];
        if (v is int) return v;
        if (v is num) return v.toInt();
      }
      return null;
    }

    return SessionRecord(
      sessionId: map['session_id'] as String? ?? '',
      subjectId: map['subject_id'] as String? ?? '',
      mode: map['mode'] as String? ?? 'personal',
      createdAtUtc: readInt(['created_at_utc', 'created_at_ms']),
      startUtc: readInt(['started_at_ms', 'start_utc']),
      endedAtUtc: readIntOpt(['ended_at_ms', 'end_utc']),
      state: map['state'] as String? ?? 'active',
      appId: map['app_id'] as String? ?? '',
      appVersion: map['app_version'] as String? ?? '',
      deviceId: map['device_id'] as String? ?? '',
      platform: map['platform'] as String? ?? 'flutter',
    );
  }
}

class IngestionSubmissionResponse {
  final bool success;
  final int statusCode;
  final String? errorMessage;
  final Map<String, dynamic>? details;

  const IngestionSubmissionResponse({
    required this.success,
    required this.statusCode,
    this.errorMessage,
    this.details,
  });
}

/// User-facing cloud-sync state. Combines queue depth, last-success
/// timestamp, and cloud-upload consent into a single bucket the host
/// can render as a pill.
///
/// - [synced] — queue empty, at least one successful upload this
/// process. "Everything is in the cloud."
/// - [syncing] — queue has rows. "Uploading…"
/// - [pending] — queue empty but no successful upload yet (cold
/// start, or first session before token + first window). "Will
/// sync as soon as something is ready."
/// - [localOnly] — cloud-upload consent is off. "By your choice,
/// nothing leaves the device."
enum CloudSyncStatus { synced, syncing, pending, localOnly }

class QueueFlushResult {
  final bool success;
  final int uploaded;
  final int failed;
  final int requeued;
  final String? errorMessage;

  const QueueFlushResult({
    required this.success,
    required this.uploaded,
    required this.failed,
    required this.requeued,
    this.errorMessage,
  });
}

class QueueStatusSnapshot {
  final int queueLength;
  final String? lastUploadBatchId;
  final DateTime? lastUploadAt;
  final DateTime? lastUploadAttemptAt;
  final String? lastUploadError;

  const QueueStatusSnapshot({
    required this.queueLength,
    this.lastUploadBatchId,
    this.lastUploadAt,
    this.lastUploadAttemptAt,
    this.lastUploadError,
  });
}

class SynheartIngestion {
  SynheartIngestion._();

  static final SynheartIngestion instance = SynheartIngestion._();

  QueueStatusSnapshot get queueStatus => QueueStatusSnapshot(
    queueLength: Synheart.uploadQueueLength,
    lastUploadBatchId: Synheart.lastUploadBatchId,
    lastUploadAt: Synheart.lastUploadAt,
    lastUploadAttemptAt: Synheart.lastUploadAttemptAt,
    lastUploadError: Synheart.lastUploadError,
  );

  void enqueueHsiWindows(List<String> hsiJsons, {int? timestampMs}) {
    final bridge = Synheart._coreRuntime;
    if (bridge == null || hsiJsons.isEmpty) return;
    final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    for (final hsiJson in hsiJsons) {
      if (hsiJson.trim().isEmpty) continue;
      bridge.enqueueHsi(hsiJson, ts);
    }
  }

  /// Explain a closed cloud gate in terms of what the caller can act on.
  ///
  /// `hasConsent` is not a simple read of the user's choice. Once a cloud
  /// consent client is configured, the runtime returns false for EVERY consent
  /// type until the consent service has issued a token, whatever the user
  /// granted:
  ///
  /// ```rust
  /// if cloud_configured && self.consent_status() != ConsentStatus::Granted {
  ///     return false;
  /// }
  /// ```
  ///
  /// Reporting that as "consent not granted" sends developers to re-check a
  /// consent screen that is already correct. The usual cause is a consent
  /// service that never issued a token — commonly a `PROFILE_NOT_FOUND` on the
  /// app id — so this separates "the user said no" from "the user said yes and
  /// the cloud has not confirmed it".
  static String _describeClosedCloudGate() {
    final effective = Synheart._coreRuntime?.consentEffectiveState();
    final grantedLocally =
        effective?['cloud_upload'] == true || effective?['cloudUpload'] == true;

    if (!grantedLocally) {
      return 'cloudUpload consent not granted';
    }
    return 'cloudUpload is granted locally, but the runtime is holding the '
        'cloud gate closed: no consent token has been issued. Every consent '
        'type reads as denied in this state, regardless of what the user chose. '
        'Check the consent service for this app id — a missing default consent '
        'profile (PROFILE_NOT_FOUND) is the usual cause.';
  }

  Future<QueueFlushResult> flushIfEligible({bool requireConsent = true}) async {
    final bridge = Synheart._coreRuntime;
    if (bridge == null) {
      Synheart._lastUploadAttemptAt = DateTime.now().toUtc();
      Synheart._lastUploadError = 'core runtime bridge unavailable';
      return const QueueFlushResult(
        success: false,
        uploaded: 0,
        failed: 0,
        requeued: 0,
        errorMessage: 'core runtime bridge unavailable',
      );
    }
    if (requireConsent && !await Synheart.hasConsent('cloudUpload')) {
      Synheart._lastUploadAttemptAt = DateTime.now().toUtc();
      final why = _describeClosedCloudGate();
      Synheart._lastUploadError = why;
      return QueueFlushResult(
        success: false,
        uploaded: 0,
        failed: 0,
        requeued: 0,
        errorMessage: why,
      );
    }

    Synheart._lastUploadAttemptAt = DateTime.now().toUtc();
    final result = await bridge.flushUploads();
    if (result == null) {
      Synheart._lastUploadError = 'flush_uploads returned null';
      return const QueueFlushResult(
        success: false,
        uploaded: 0,
        failed: 0,
        requeued: 0,
        errorMessage: 'flush_uploads returned null',
      );
    }

    final uploaded = result['uploaded'] as int? ?? 0;
    final failed = result['failed'] as int? ?? 0;
    final requeued = result['requeued'] as int? ?? 0;
    Synheart._lastUploadAt = DateTime.now().toUtc();
    Synheart._lastUploadError = null;
    if (uploaded > 0) {
      Synheart._lastUploadBatchId =
          result['batch_id']?.toString() ??
          'flush_${Synheart._lastUploadAt!.millisecondsSinceEpoch}';
    }
    return QueueFlushResult(
      success: true,
      uploaded: uploaded,
      failed: failed,
      requeued: requeued,
    );
  }

  Future<IngestionSubmissionResponse> submitSessionArtifacts(
    Map<String, dynamic> payload, {
    List<String> hsiWindows = const <String>[],
  }) async {
    final bridge = Synheart._coreRuntime;
    if (bridge == null) {
      return const IngestionSubmissionResponse(
        success: false,
        statusCode: 503,
        errorMessage: 'core runtime bridge unavailable',
      );
    }
    enqueueHsiWindows(hsiWindows);
    final flush = await flushIfEligible();
    if (!flush.success) {
      return IngestionSubmissionResponse(
        success: false,
        statusCode: 403,
        errorMessage: flush.errorMessage,
        details: {'payloadAccepted': false},
      );
    }
    return IngestionSubmissionResponse(
      success: true,
      statusCode: 200,
      details: {
        'payloadAccepted': true,
        'payloadKeys': payload.keys.length,
        'uploaded': flush.uploaded,
        'failed': flush.failed,
        'requeued': flush.requeued,
        'queuedWindows': hsiWindows.length,
      },
    );
  }

  Future<IngestionSubmissionResponse> submitMetadata(
    Map<String, dynamic> payload,
  ) async {
    final bridge = Synheart._coreRuntime;
    if (bridge == null) {
      return const IngestionSubmissionResponse(
        success: false,
        statusCode: 503,
        errorMessage: 'core runtime bridge unavailable',
      );
    }
    return IngestionSubmissionResponse(
      success: true,
      statusCode: 202,
      details: {
        'accepted': true,
        'payloadKeys': payload.keys.length,
        'message':
            'Metadata payload accepted by bridge-first SDK; no separate metadata upload path.',
      },
    );
  }
}

class LabIngestResponse {
  final bool success;
  final int statusCode;
  final String? errorMessage;

  const LabIngestResponse({
    required this.success,
    required this.statusCode,
    this.errorMessage,
  });
}

/// Consent values queued before SDK initialization.
class _PendingConsent {
  final bool biosignals;
  final bool behavior;
  final bool phoneContext;
  final bool cloudUpload;
  final bool vendorSync;
  final ConsentTier? tier;
  final ConsentChannels? grantedChannels;
  final bool research;

  _PendingConsent({
    required this.biosignals,
    required this.behavior,
    required this.phoneContext,
    required this.cloudUpload,
    this.vendorSync = false,
    this.tier,
    this.grantedChannels,
    this.research = false,
  });
}
