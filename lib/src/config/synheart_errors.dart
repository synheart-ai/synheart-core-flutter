/// Deterministic error codes for Synheart Core.
class SynheartError implements Exception {
  final String code;
  final String message;

  const SynheartError(this.code, this.message);

  @override
  String toString() => 'SynheartError($code): $message';

  static const notConfigured = SynheartError(
    'ERR_NOT_CONFIGURED',
    'Synheart.configure() must be called before this operation.',
  );

  static const invalidMode = SynheartError(
    'ERR_INVALID_MODE',
    'The specified mode is not valid for this operation.',
  );

  static const researchNotAllowed = SynheartError(
    'ERR_RESEARCH_NOT_ALLOWED',
    'Research mode requires privacy.allowResearch to be true.',
  );

  static const sessionNotFound = SynheartError(
    'ERR_SESSION_NOT_FOUND',
    'No session found with the given session_id.',
  );

  static const sessionActive = SynheartError(
    'ERR_SESSION_ACTIVE',
    'Cannot start a new session while one is already active.',
  );

  static const noActiveSession = SynheartError(
    'ERR_NO_ACTIVE_SESSION',
    'No active session. Call startSession() first.',
  );

  static const storageDisabled = SynheartError(
    'ERR_STORAGE_DISABLED',
    'Storage is disabled in the current configuration.',
  );

  static const syncDisabled = SynheartError(
    'ERR_SYNC_DISABLED',
    'Sync is not enabled in the current configuration.',
  );

  static const cryptoKeyUnavailable = SynheartError(
    'ERR_CRYPTO_KEY_UNAVAILABLE',
    'Encryption key is not available.',
  );

  static const modeForbidsStream = SynheartError(
    'ERR_MODE_FORBIDS_STREAM',
    'The current mode does not allow this stream type.',
  );
}

/// Who can resolve a [SynheartNativeError].
///
/// If the integrating code can fix it without asking the person, the owner is
/// [app] even when the person sees the effect.
enum NativeErrorOwner {
  /// The integrating code: call order, arguments, configuration, build.
  app,

  /// Only the person can act: sign in, grant consent, re-enter a code.
  user,

  /// Connectivity, the OS credential store, device capability. Usually wait.
  environment,

  /// The Synheart cloud refused or failed.
  service,

  /// A defect in the native runtime. Report it with [SynheartNativeError.errorId].
  runtime,

  /// The runtime sent no owner (older runtime) or one this SDK does not know.
  unknown;

  static NativeErrorOwner parse(Object? raw) => switch (raw) {
    'app' => app,
    'user' => user,
    'environment' => environment,
    'service' => service,
    'runtime' => runtime,
    _ => unknown,
  };
}

/// What to do about a [SynheartNativeError]. One closed-set action per failure;
/// [SynheartNativeError.recoveryCall] names the native call that performs it
/// when there is one.
enum NativeErrorRecovery {
  /// Repeat the same call, after [SynheartNativeError.retryAfterMs] if set.
  retry,

  /// Retry once the device is unlocked. Never wipe data for this.
  waitForDeviceUnlock,

  /// Change the call: arguments, order, or which function.
  fixCall,

  /// Change the configuration passed to `Synheart.initialize`.
  fixConfiguration,

  /// Ask the person to re-enter what they typed.
  reenterInput,

  /// Re-authenticate the account.
  signIn,

  /// Run device registration.
  registerDevice,

  /// Refresh the device attestation.
  reattestDevice,

  /// Sign out, then register again.
  signOutThenRegister,

  /// Ask for the consent named in [SynheartNativeError.reason], then retry.
  grantConsent,

  /// Start pairing again on the other device.
  generateNewPairingCode,

  /// Re-read sync readiness, then join or create a space.
  rejoinSpace,

  /// Start a session, then retry.
  startSessionFirst,

  /// Stop the active session, then retry.
  endSessionFirst,

  /// The feature is compiled out of this runtime build.
  useSupportedBuild,

  /// Report it, with [SynheartNativeError.errorId] and the diagnostic log.
  reportBug,

  /// Nothing changes the outcome; show [SynheartNativeError.message].
  none,

  /// The runtime sent no recovery (older runtime) or one this SDK does not know.
  unknown;

  static NativeErrorRecovery parse(Object? raw) => switch (raw) {
    'retry' => retry,
    'wait_for_device_unlock' => waitForDeviceUnlock,
    'fix_call' => fixCall,
    'fix_configuration' => fixConfiguration,
    'reenter_input' => reenterInput,
    'sign_in' => signIn,
    'register_device' => registerDevice,
    'reattest_device' => reattestDevice,
    'sign_out_then_register' => signOutThenRegister,
    'grant_consent' => grantConsent,
    'generate_new_pairing_code' => generateNewPairingCode,
    'rejoin_space' => rejoinSpace,
    'start_session_first' => startSessionFirst,
    'end_session_first' => endSessionFirst,
    'use_supported_build' => useSupportedBuild,
    'report_bug' => reportBug,
    'none' => none,
    _ => unknown,
  };
}

/// A structured failure reported by the native runtime.
///
/// Every runtime failure has this shape, whether it arrived inside a sync
/// envelope (`{"ok": false, "error": {...}}`) or was read back after a call that
/// returned null, `false` or a non-zero code. Branch on [code] and [recovery];
/// show [message]; log [hint] and [errorId]. Internal detail (server bodies,
/// paths, tokens) never reaches here: it stays in the native diagnostic log,
/// on the line tagged with the same [errorId].
///
/// Every field beyond [code], [message] and [retryable] is optional in both
/// directions: an older runtime never sends it, and a newer SDK must not
/// assume it.
class SynheartNativeError {
  /// Stable machine-readable code, e.g. `CONSENT_REQUIRED`, `NETWORK`.
  /// Treat an unrecognised value as `UNKNOWN`.
  final String code;

  /// End-user-safe message. Show it; never parse it.
  final String message;

  /// Whether retrying the same call unchanged may succeed.
  ///
  /// Runtimes before 0.20.0 inverted this in both directions, so honour it only
  /// on 0.20.0 and later (the SDK's minimum).
  final bool retryable;

  /// Closed-set token narrowing the cause, or null when there is none.
  ///
  /// On attestation and registration failures: `transient`, `timeout`,
  /// `quota`, `unsupported`, `misconfigured`, `server_transient`, `policy`,
  /// `unknown`. On `INVALID_ARGUMENT`: `null`, `not_utf8`, `blank`,
  /// `malformed`, `out_of_range`, `unrecognized`. On `CONSENT_REQUIRED`: the
  /// consent type to grant, e.g. `biosignals`.
  final String? reason;

  /// Suggested backoff before retrying. Null unless [retryable].
  final int? retryAfterMs;

  /// Diagnostics — `phase`, `http_status`, `server_code`, `argument`. Log it;
  /// branch on [argument] if you need the parameter, never on the map shape.
  final Map<String, dynamic>? detail;

  /// Raw `owner` token; see [ownerKind].
  final String? owner;

  /// Raw `recovery` token; see [recoveryKind].
  final String? recovery;

  /// The exact native function that performs [recovery], when one does, e.g.
  /// `synheart_core_grant_consent`. Agents should read this, not [hint].
  final String? recoveryCall;

  /// One developer-facing sentence on the cause. Log it; it may be reworded in
  /// any runtime release, so never branch on it.
  final String? hint;

  /// The native entry point that failed, e.g. `synheart_core_start_session`.
  final String? op;

  /// Eight hex digits matching the native diagnostic log line for this
  /// failure. Put it in bug reports and "report a problem" UI.
  final String? errorId;

  /// `runtime_version` and `abi`, present only when the runtime itself is at
  /// fault ([ownerKind] is [NativeErrorOwner.runtime]).
  final Map<String, dynamic>? report;

  const SynheartNativeError({
    required this.code,
    required this.message,
    this.retryable = false,
    this.reason,
    this.retryAfterMs,
    this.detail,
    this.owner,
    this.recovery,
    this.recoveryCall,
    this.hint,
    this.op,
    this.errorId,
    this.report,
  });

  /// Parse a native error object. Missing or mistyped fields fall back to a
  /// safe shape, so a malformed payload never throws here.
  factory SynheartNativeError.fromMap(Map<String, dynamic> error) {
    String? str(String key) {
      final v = error[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    Map<String, dynamic>? map(String key) {
      final v = error[key];
      if (v is Map<String, dynamic>) return v;
      return v is Map ? Map<String, dynamic>.from(v) : null;
    }

    final retryable = error['retryable'];
    final retryAfterMs = error['retry_after_ms'];
    return SynheartNativeError(
      code: str('code') ?? 'UNKNOWN',
      message: str('message') ?? 'An unexpected error occurred.',
      retryable: retryable is bool ? retryable : false,
      reason: str('reason'),
      // A JSON number may decode as double across the FFI boundary.
      retryAfterMs: retryAfterMs is num ? retryAfterMs.toInt() : null,
      detail: map('detail'),
      owner: str('owner'),
      recovery: str('recovery'),
      recoveryCall: str('recovery_call'),
      hint: str('hint'),
      op: str('op'),
      errorId: str('error_id'),
      report: map('report'),
    );
  }

  /// Fallback used when a failure is known but its payload is missing or
  /// malformed.
  factory SynheartNativeError.unknown() => const SynheartNativeError(
    code: 'UNKNOWN',
    message: 'An unexpected error occurred.',
  );

  /// Who can resolve this failure.
  NativeErrorOwner get ownerKind => NativeErrorOwner.parse(owner);

  /// What to do about it.
  NativeErrorRecovery get recoveryKind => NativeErrorRecovery.parse(recovery);

  /// On `INVALID_ARGUMENT`: the rejected parameter's name, e.g. `batch_json`.
  String? get argument {
    final a = detail?['argument'];
    return a is String ? a : null;
  }

  /// A defect in the runtime, not in the integrating code. Report it.
  bool get isRuntimeBug => ownerKind == NativeErrorOwner.runtime;

  /// The device can never attest (no Play Services, emulator, Simulator).
  /// Degrade to local-only and stop asking, including across relaunches.
  bool get isUnsupported => reason == 'unsupported';

  /// The attestation setup is wrong; a developer has to fix it.
  bool get isMisconfigured => reason == 'misconfigured';

  /// The server refused this device permanently.
  bool get isPolicyRefusal => reason == 'policy';

  @override
  String toString() {
    // What lands in crash logs: enough to act on without the native log.
    final buf = StringBuffer('SynheartNativeError($code): $message');
    if (reason != null) buf.write(' [reason: $reason]');
    if (argument != null) buf.write(' [argument: $argument]');
    if (recovery != null) buf.write(' [recovery: $recovery]');
    if (recoveryCall != null) buf.write(' [call: $recoveryCall]');
    if (op != null) buf.write(' [op: $op]');
    if (errorId != null) buf.write(' [error_id: $errorId]');
    buf.write(' (retryable: $retryable');
    if (retryAfterMs != null) buf.write(', retryAfterMs: $retryAfterMs');
    buf.write(')');
    return buf.toString();
  }
}

/// The name this type had when only sync calls reported structured errors.
typedef SyncNativeError = SynheartNativeError;

/// Thrown when the native runtime reports a failure. Carries the structured
/// [error] so the host can render cause-specific copy and decide whether to
/// retry, instead of a generic failure message.
class SynheartNativeException implements Exception {
  final SynheartNativeError error;

  const SynheartNativeException(this.error);

  String get code => error.code;
  String get message => error.message;
  bool get retryable => error.retryable;
  String? get reason => error.reason;
  int? get retryAfterMs => error.retryAfterMs;
  Map<String, dynamic>? get detail => error.detail;
  NativeErrorOwner get owner => error.ownerKind;
  NativeErrorRecovery get recovery => error.recoveryKind;
  String? get recoveryCall => error.recoveryCall;
  String? get errorId => error.errorId;

  bool get isUnsupported => error.isUnsupported;
  bool get isMisconfigured => error.isMisconfigured;
  bool get isPolicyRefusal => error.isPolicyRefusal;

  @override
  String toString() => 'SynheartNativeException: $error';
}

/// Thrown by the sync bridge methods when the native layer reports a failure
/// envelope. A [SynheartNativeException], so one `catch` handles every runtime
/// failure.
class SyncNativeException extends SynheartNativeException {
  const SyncNativeException(super.error);

  @override
  String toString() => 'SyncNativeException: $error';
}
