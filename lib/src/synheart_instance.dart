import 'dart:convert';

import 'core_runtime/core_runtime_bridge.dart';
import 'core_runtime/platform_native_sdk_crypto_callbacks.dart';
import 'config/runtime_config_map.dart';
import 'config/synheart_config.dart';
import 'models/behavior_event_input.dart';
import 'modules/behavior/behavior_code.dart';
import 'modules/cloud/device_auth_provider.dart';
import 'core/logger.dart';

/// A single, self-contained Synheart runtime instance (one native handle).
///
/// `Synheart.shared` is the **personal** runtime and remains the default surface
/// for the app. Use [SynheartInstance] to run a **second** runtime alongside it —
/// the canonical case being a **research** instance with its own pseudonymous
/// `subject_id`, its own `data_dir`, and its own attested device identity,
/// created on Life Lab enrol and disposed + wiped on withdraw.
///
/// The underlying [CoreRuntimeBridge] is already fully per-handle (every op is
/// routed through its own native handle), so two instances are independent:
/// distinct engines, Tokio runtimes, storage, and device-auth identities. The
/// only hard requirement is a **distinct [dataDir] and `subject_id` per
/// instance** — otherwise the two handles contend on the same SQLite / SRM files
/// (see `research-ingest-mobile.md` §2.1–2.3).
class SynheartInstance {
  final CoreRuntimeBridge _bridge;
  final SynheartConfig config;

  /// The durable directory this instance's native runtime writes to
  /// (`synheart_<subject>.db`, SRM snapshot, ingest queue). Must be unique per
  /// instance — e.g. `<appSupport>/synheart-core/research`.
  final String dataDir;

  DeviceAuthProvider? _deviceAuth;
  bool _disposed = false;

  SynheartInstance._(this._bridge, this.config, this.dataDir);

  /// Create and wire a new runtime instance, or `null` if the native library is
  /// unavailable / the handle could not be created.
  ///
  /// Wiring mirrors `Synheart.ensureRuntimeBridge`: create the handle, attach
  /// storage callbacks (so consent tokens + device records persist), then attach
  /// the per-handle crypto callbacks so this instance can attest its **own**
  /// device identity. Baseline/SRM cloud hooks are intentionally NOT wired here —
  /// they target a process-global hydrator on the personal facade and are not
  /// needed for a research/lab instance.
  static SynheartInstance? create({
    required SynheartConfig config,
    required String dataDir,
  }) {
    config.validate();
    final bridge = CoreRuntimeBridge.create(_buildConfigMap(config, dataDir));
    if (bridge == null) {
      SynheartLogger.log(
        '[SynheartInstance] core runtime bridge unavailable for '
        'subject=${config.subjectId} dataDir=$dataDir',
      );
      return null;
    }

    // Persist consent tokens / device records under THIS instance's store.
    final storageRc = bridge.setStorageCallbacks();
    if (storageRc != 0) {
      SynheartLogger.log(
        '[SynheartInstance] setStorageCallbacks rc=$storageRc — state may not '
        'persist for subject=${config.subjectId}',
      );
    }

    final instance = SynheartInstance._(bridge, config, dataDir);

    // Per-instance attested identity: attach crypto callbacks before any
    // registration / proof call (SDK auth sequence §2). Distinct subject_id +
    // device_id keep this identity separate from the personal instance.
    if (!bridge.deviceAuthTemporarilyDisabledForSubjectCompat &&
        bridge.sdkDeviceAuthAvailable) {
      final table = PlatformNativeSdkCryptoCallbacks.tryCreateRawTable();
      if (table == null) {
        SynheartLogger.log(
          '[SynheartInstance] synheart_native_* crypto symbols not found — '
          'device auth will fail for subject=${config.subjectId}.',
        );
      } else {
        final crc = bridge.setSdkCryptoCallbacks(table);
        if (crc != 0) {
          SynheartLogger.log(
            '[SynheartInstance] setSdkCryptoCallbacks failed: $crc',
          );
        }
      }
      final dac = config.deviceAuthConfig;
      if (dac != null) {
        instance._deviceAuth = DeviceAuthProvider(
          coreRuntime: bridge,
          baseUrl: dac.authBaseUrl,
        );
      }
    }

    SynheartLogger.log(
      '[SynheartInstance] created (subject=${config.subjectId} '
      'org=${config.cloudConfig?.orgId ?? ''} dataDir=$dataDir)',
    );
    return instance;
  }

  /// Assemble the JSON config the native `synheart_core_new` expects. Mirrors
  /// the map built in `Synheart.ensureRuntimeBridge`, but with an explicit,
  /// per-instance [dataDir] (the facade uses a single cached `_resolvedDataDir`).
  /// Assemble the JSON config `synheart_core_new` expects, with this
  /// instance's own [dataDir] (the facade uses one cached process-wide path).
  static Map<String, dynamic> _buildConfigMap(
    SynheartConfig config,
    String dataDir,
  ) => buildRuntimeConfigMap(config, dataDir: dataDir);

  // ── State ──────────────────────────────────────────────────────────────────

  bool get isDisposed => _disposed;

  /// Whether the lab C ABI is available in the loaded native build.
  bool get isLabAvailable => !_disposed && _bridge.isLabAvailable;

  /// The canonical subject id the runtime resolved (device-auth derives it from
  /// the `client_id` passed to [registerDevice]).
  String? get subjectId => _disposed ? null : _bridge.runtimeSubjectId();

  /// The per-instance device-auth provider (request signing), or `null` if
  /// device auth is unavailable for this instance.
  DeviceAuthProvider? get deviceAuth => _deviceAuth;

  // ── Device auth (per-instance attested identity) ─────────────────────────────

  /// Register (attest) this instance's device identity under [clientId]. For a
  /// research instance, pass the pseudonymous research client id so the derived
  /// subject is research-scoped and unlinkable to the personal identity.
  Future<Map<String, dynamic>?> registerDevice(String clientId) async {
    final result = await _bridge.sdkRegisterDevice(clientId);
    _restoreDeviceAuthProviderAfterSuccess(result);
    return result;
  }

  /// Refresh this identity's attestation while preserving its device ID.
  Future<Map<String, dynamic>?> reattestDevice() async {
    final result = await _bridge.sdkReattestDevice();
    _restoreDeviceAuthProviderAfterSuccess(result);
    return result;
  }

  /// Clear this instance's installed device identity and sync membership.
  Future<void> logoutDevice() async {
    await _bridge.sdkLogout();
    _deviceAuth = null;
  }

  void _restoreDeviceAuthProviderAfterSuccess(Map<String, dynamic>? result) {
    if ((result?['device_id'] == null && result?['deviceId'] == null) ||
        _deviceAuth != null) {
      return;
    }
    final auth = config.deviceAuthConfig;
    if (auth == null) return;
    _deviceAuth = DeviceAuthProvider(
      coreRuntime: _bridge,
      baseUrl: auth.authBaseUrl,
    );
  }

  Map<String, dynamic>? deviceAuthStatus() => _bridge.sdkDeviceAuthStatus();

  /// Native device/Synsync readiness snapshot for THIS instance — the
  /// **pollable** signal used to detect a revoked or unregistered attested
  /// identity (`device_revoked` / `device_registered`).
  ///
  /// Ingest HTTP (and therefore any `401` / `KEY_INVALIDATED` response) lives
  /// entirely inside the native runtime and never surfaces to Dart, so an app
  /// that wants to recover an invalidated research identity polls this snapshot
  /// instead of observing the 401 directly. Null when disposed or the native
  /// symbol is unavailable.
  Map<String, dynamic>? syncReadiness() =>
      _disposed ? null : _bridge.syncReadiness();

  /// Build an `X-Synheart-Proof` header for an outbound request on this
  /// instance's identity.
  String? buildProofHeader(String method, String absoluteUrl) =>
      _bridge.buildProofHeader(method, absoluteUrl);

  // ── Consent ──────────────────────────────────────────────────────────────────

  Map<String, dynamic>? consentGetEditableForm() =>
      _bridge.consentGetEditableForm();

  Future<Map<String, dynamic>?> consentSubmitForm({
    required String deviceId,
    required String platform,
    String? userId,
    required Map<String, dynamic> formJson,
  }) => _bridge.consentSubmitForm(
    deviceId: deviceId,
    platform: platform,
    userId: userId,
    formJson: formJson,
  );

  Map<String, dynamic>? consentStatus() => _bridge.consentStatus();

  // ── Research study (per-instance, attested credential) ───────────────────────
  //
  // These run on THIS instance's own handle: enrol/withdraw/status resolve the
  // participant + app from the instance's device-attested cloud credential (no
  // user JWT). Use these — not the static `Synheart.*ResearchStudy*` helpers,
  // which are bound to the personal singleton runtime — to drive a research
  // instance's enrolment lifecycle.

  /// Preview an (access, study) code pair for THIS instance without redeeming it.
  Future<Map<String, dynamic>?> validateResearchStudyCodes({
    required String accessCode,
    required String studyCode,
  }) => _disposed
      ? Future.value(null)
      : _bridge.enrolResearchStudy(
          accessCode: accessCode,
          studyCode: studyCode,
          validateOnly: true,
        );

  /// Redeem an (access, study) code pair and create the enrolment on THIS
  /// instance's attested credential.
  Future<Map<String, dynamic>?> enrolResearchStudy({
    required String accessCode,
    required String studyCode,
  }) => _disposed
      ? Future.value(null)
      : _bridge.enrolResearchStudy(
          accessCode: accessCode,
          studyCode: studyCode,
          validateOnly: false,
        );

  /// Read THIS instance's current active research-study enrolment.
  Future<Map<String, dynamic>?> researchStudyStatus() =>
      _disposed ? Future.value(null) : _bridge.researchStudyStatus();

  /// Withdraw THIS instance from its active research study.
  Future<Map<String, dynamic>?> withdrawResearchStudy() =>
      _disposed ? Future.value(null) : _bridge.withdrawResearchStudy();

  // ── Signal push (RR fan-in during a lab window) ──────────────────────────────

  /// Push an RR (inter-beat) interval into this instance. During an open lab
  /// window this feeds the research lab session's `wear_data`.
  void pushRr(int tsMs, double rrMs, {String provider = 'default_sensor'}) =>
      _bridge.pushRr(tsMs, rrMs, provider: provider);

  /// Push a batch of RR intervals delivered together in one sensor
  /// notification. See [CoreRuntimeBridge.pushRrBatch]. Prefer this over
  /// looping [pushRr] when a packet carries multiple RR values sharing one
  /// arrival timestamp (e.g. BLE HRM) — it keeps every beat.
  void pushRrBatch(
    int anchorTsMs,
    List<double> rrMs, {
    int order = 0,
    String provider = 'default_sensor',
  }) => _bridge.pushRrBatch(anchorTsMs, rrMs, order: order, provider: provider);

  void pushHr(int tsMs, double bpm) => _bridge.pushHr(tsMs, bpm);

  String? ingestBatch(String batchJson, int nowMs) =>
      _bridge.ingestBatch(batchJson, nowMs);

  // ── Behavior fan-in (typing dynamics during a lab window) ────────────────────

  /// Push a raw behavior event into this instance's engine. Fed into an open
  /// lab session's behavioral metrics. [eventType] is a [RuntimeBehaviorEvent]
  /// code; most callers want [pushBehaviorTouch].
  void pushBehavior(int tsMs, int eventType, double value) =>
      _bridge.pushBehavior(tsMs, eventType, value);

  /// Push a touch/keystroke behavior event. During an open lab window this
  /// feeds the research lab session's typing dynamics so the finalized payload
  /// carries the same behavioral metrics the personal runtime produces.
  void pushBehaviorTouch(int tsMs) =>
      _bridge.pushBehavior(tsMs, RuntimeBehaviorEvent.input.code, 1.0);

  /// Push a typed behavior event carrying its full payload — most importantly
  /// a windowed [TypingSessionData], which the legacy int-coded path cannot
  /// express at all.
  ///
  /// Returns the runtime status (`0` = accepted), or `null` when this instance
  /// is disposed or the runtime does not export the symbol.
  ///
  /// Do not also push the raw keystrokes behind a `Typing` summary — the
  /// engine counts both and every rate feature roughly doubles.
  int? pushBehaviorEvent(BehaviorEventInput event) => _disposed
      ? null
      : _bridge.pushBehaviorEventJson(jsonEncode(event.toJson()));

  /// Declare the window containing [tsMs] to be a rest window. One-shot: call
  /// once per rest window, not once when a break begins.
  void declareRestWindow(int tsMs) {
    if (!_disposed) _bridge.declareRestWindow(tsMs);
  }

  /// Drain every completed window as a JSON array, oldest first. Prefer this
  /// to [tick] after a gap. `null` when disposed or unsupported.
  String? tickAll(int nowMs) => _disposed ? null : _bridge.tickAll(nowMs);

  /// Emit every window still held by the lateness budget. Call on
  /// backgrounding and at session end.
  String? flushPending(int nowMs) =>
      _disposed ? null : _bridge.flushPending(nowMs);

  /// Export this instance's per-head session state for persistence.
  String? exportSessionState() =>
      _disposed ? null : _bridge.exportSessionState();

  /// Restore session state. Must run before this instance's first [tick].
  int? loadSessionState(String json) =>
      _disposed ? null : _bridge.loadSessionState(json);

  /// This instance's comparability key. Persist it beside any cached score.
  String? configId() => _disposed ? null : _bridge.configId();

  // ── Session lifecycle (drives the pipeline the lab window records over) ───────

  /// Start this instance's behavior/HSI session. Called before [labStart] so
  /// the engine has an active pipeline the lab window can record over (mirrors
  /// the personal runtime's `startSession` → `labStart` order).
  Map<String, dynamic>? startSession() =>
      _disposed ? null : _bridge.startSession();

  /// Stop this instance's session. Called after [labFinalize].
  bool stopSession() => _disposed ? false : _bridge.stopSession();

  bool get isSessionRunning => !_disposed && _bridge.isRunning;

  /// Advance the pipeline clock so windows that should close by [nowMs] are
  /// flushed (drives the same window-closing the personal runtime's ticker does).
  String? tick(int nowMs) => _disposed ? null : _bridge.tick(nowMs);

  // ── Lab session ──────────────────────────────────────────────────────────────

  /// Whether the lab-metadata C ABI is available in the loaded native build.
  bool get isLabMetadataAvailable =>
      !_disposed && _bridge.isLabMetadataAvailable;

  /// Ensure the lab-session metadata (device / platform / user info) is cached
  /// on this instance before the first [labStart]. Mirrors the personal
  /// runtime's `labEnsureMetadata`.
  String? labEnsureMetadata({
    required String deviceId,
    required String platform,
    required String osVersion,
    String? userInfoJson,
    String? deviceExtraJson,
  }) => _bridge.labEnsureMetadata(
    deviceId: deviceId,
    platform: platform,
    osVersion: osVersion,
    userInfoJson: userInfoJson,
    deviceExtraJson: deviceExtraJson,
  );

  String? labStart(String protocolJson, int startedAtMs) =>
      _bridge.labStart(protocolJson, startedAtMs);

  String? labOpenWindow({
    String? parentId,
    required String windowType,
    String? label,
    required int startedAtMs,
  }) => _bridge.labOpenWindow(parentId, windowType, label, startedAtMs);

  bool labCloseWindow(String windowId, int endedAtMs) =>
      _bridge.labCloseWindow(windowId, endedAtMs);

  bool labSetWindowValues(String windowId, String valuesJson) =>
      _bridge.labSetWindowValues(windowId, valuesJson);

  String? labMergeSessionExtraData(String patchJson) =>
      _bridge.labMergeExtraData(patchJson);

  /// Finalize the lab session; the runtime auto-enqueues the payload to
  /// cloud lab-ingest under this instance's (research) identity.
  String? labFinalize(int endedAtMs) => _bridge.labFinalize(endedAtMs);

  bool get isLabReenqueueAvailable => _bridge.isLabReenqueueAvailable;

  LabReenqueueResult labReenqueueSession(String sessionJson) =>
      _bridge.labReenqueueSession(sessionJson);

  // ── Teardown (withdraw) ──────────────────────────────────────────────────────

  /// Wipe this instance's local runtime data (SQLite, SRM, ingest queue,
  /// consent + device records). Call before [dispose] on study withdrawal.
  bool wipeLocalData() => _disposed ? false : _bridge.wipeLocalData();

  /// Free the native handle. After this the instance is unusable. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bridge.dispose();
    _deviceAuth = null;
  }
}
