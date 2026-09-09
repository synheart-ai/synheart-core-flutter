/// Safe Dart wrapper over `synheart_core_runtime` C ABI.
///
/// Replaces the internal storage, crypto, sync, consent, artifact pipeline,
/// and cloud connector logic.
/// Platform-specific code (Keychain, HealthKit, sensors) stays in Flutter plugins.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'package:flutter/foundation.dart';

import '../config/synheart_errors.dart';
import '../core/logger.dart';
import '../core/serial_operation_queue.dart';

import '../models/sleep_score.dart';
import 'ffi_bindings.dart';
import 'platform_native_sdk_storage_callbacks.dart';
import 'sdk_ffi.dart';

/// Forwarder installed before `synheart_core_init_logging` (top-level for FFI).
void Function(String line)? synheartRuntimeLogForwarder;

/// Set by [CoreRuntimeBridge.initRuntimeLogging] so the top-level trampoline
/// can release CStrings that the native layer leaks across the async hop.
void Function(Pointer<Utf8> ptr)? _synheartRuntimeLogFree;

/// Decode an FFI-owned C string and free it via [freeFn]. Tolerates malformed
/// UTF-8 so a bad byte never kills the listener isolate. Returns null only if
/// `ptr` is null.
String? _readFfiStringAndFree(
  Pointer<Utf8> ptr,
  void Function(Pointer<Utf8>) freeFn,
) {
  if (ptr == nullptr) return null;
  try {
    return ptr.toDartString();
  } on FormatException {
    final raw = ptr.cast<Uint8>();
    var len = 0;
    while (raw[len] != 0) {
      len++;
    }
    return utf8.decode(raw.asTypedList(len), allowMalformed: true);
  } finally {
    freeFn(ptr);
  }
}

enum _SyncFfiOperation {
  registerDevice,
  reattestDevice,
  logoutDevice,
  syncNow,
  createSpace,
  generatePairing,
  joinSpace,
  recoverSpace,
  leaveSpace,
  listDevices,
  revokeDevice,
  deleteSpace,
  clearLocalSpace,
}

const _syncFfiWorkerFailureKey = '_synheart_sync_ffi_worker_failure';

/// Sendable entrypoint for one sync operation.
///
/// Passing a closure created inside [CoreRuntimeBridge] to [Isolate.run]
/// over-captures `this` on the Dart VM. That pulls the bridge's
/// [DynamicLibrary] into the isolate message and fails before the worker can
/// start. A bound tear-off of this value object carries only primitives and
/// the enum, so the native library is resolved inside the worker instead.
final class _SyncFfiInvocation {
  const _SyncFfiInvocation({
    required this.handleAddr,
    required this.operation,
    required this.firstArg,
    required this.secondArg,
  });

  final int handleAddr;
  final _SyncFfiOperation operation;
  final String firstArg;
  final String secondArg;

  Map<String, dynamic>? call() => _executeSyncFfiOperation(
    handleAddr: handleAddr,
    operation: operation,
    firstArg: firstArg,
    secondArg: secondArg,
  );
}

/// Execute one sync ABI call entirely inside the worker isolate.
///
/// Only sendable values cross the isolate boundary: a handle address, an enum,
/// and strings. Keeping the bridge and its FFI wrapper out of the callback
/// avoids accidental closure over-capture of native-backed Dart objects.
Map<String, dynamic>? _executeSyncFfiOperation({
  required int handleAddr,
  required _SyncFfiOperation operation,
  String firstArg = '',
  String secondArg = '',
}) {
  final ffi = SynheartCoreFFI.load();
  if (ffi == null) {
    SynheartLogger.log(
      '[Synheart Sync FFI] Worker could not load the native runtime for '
      '${operation.name}.',
      name: 'synheart.sync.ffi',
    );
    return <String, dynamic>{_syncFfiWorkerFailureKey: 'runtime_load_failed'};
  }
  final handle = Pointer<Void>.fromAddress(handleAddr);
  try {
    final output = switch (operation) {
      _SyncFfiOperation.registerDevice => _withWorkerCString(
        firstArg,
        (clientId) => ffi.sdkFfi.registerDevice == null
            ? nullptr.cast<Utf8>()
            : ffi.sdkFfi.registerDevice!(handle, clientId.cast()),
      ),
      _SyncFfiOperation.reattestDevice =>
        ffi.sdkFfi.reattestDevice?.call(handle) ?? nullptr.cast<Utf8>(),
      _SyncFfiOperation.logoutDevice =>
        ffi.sdkFfi.logout?.call(handle) ?? nullptr.cast<Utf8>(),
      _SyncFfiOperation.syncNow => ffi.syncNow(handle),
      _SyncFfiOperation.createSpace => _withWorkerCString(
        firstArg,
        (name) => ffi.syncCreateSpace(handle, name.cast()),
      ),
      _SyncFfiOperation.generatePairing => ffi.syncGeneratePairing(handle),
      _SyncFfiOperation.joinSpace => _withWorkerCString(
        firstArg,
        (token) => _withWorkerCString(
          secondArg,
          (name) => ffi.syncJoinSpace(handle, token.cast(), name.cast()),
        ),
      ),
      _SyncFfiOperation.recoverSpace => _withWorkerCString(
        firstArg,
        (key) => _withWorkerCString(
          secondArg,
          (spaceId) => ffi.syncRecoverSpace(handle, key.cast(), spaceId.cast()),
        ),
      ),
      _SyncFfiOperation.leaveSpace => ffi.syncLeaveSpace(handle),
      _SyncFfiOperation.listDevices => ffi.syncListDevices(handle),
      _SyncFfiOperation.revokeDevice => _withWorkerCString(
        firstArg,
        (deviceId) => ffi.syncRevokeDevice(handle, deviceId.cast()),
      ),
      _SyncFfiOperation.deleteSpace => ffi.syncDeleteSpace(handle),
      _SyncFfiOperation.clearLocalSpace => ffi.syncClearLocalSpace(handle),
    };
    if (output == nullptr) {
      SynheartLogger.log(
        '[Synheart Sync FFI] Native call returned a null pointer for '
        '${operation.name}.',
        name: 'synheart.sync.ffi',
      );
      return <String, dynamic>{_syncFfiWorkerFailureKey: 'native_null_pointer'};
    }
    final json = _readFfiStringAndFree(output, ffi.coreFreeString);
    if (json == null) return null;
    return jsonDecode(json) as Map<String, dynamic>;
  } catch (error, stackTrace) {
    SynheartLogger.log(
      '[Synheart Sync FFI] Worker call failed for ${operation.name}.',
      name: 'synheart.sync.ffi',
      error: error,
      stackTrace: stackTrace,
    );
    return <String, dynamic>{
      _syncFfiWorkerFailureKey: 'exception',
      'error_type': error.runtimeType.toString(),
      'error_message': error.toString(),
    };
  }
}

Pointer<Utf8> _withWorkerCString(
  String value,
  Pointer<Utf8> Function(Pointer<Utf8> value) call,
) {
  final pointer = value.toNativeUtf8();
  try {
    return call(pointer);
  } finally {
    malloc.free(pointer);
  }
}

/// Unwrap the native sync response envelope.
///
/// The native sync FFI returns a consistent shape so a failure reason is never
/// lost to a bare null:
///   * success  → `{"ok": true, "data": {...}}`  → returns the `data` map
///   * failure  → `{"ok": false, "error": {...}}` → throws [SyncNativeException]
///
/// Tolerant of two legacy inputs so a lagging vendored native lib still works:
///   * `null` (old failure sentinel) → returns `null`
///   * a map with no `ok` key (old bare payload) → returned unchanged
///
/// Kept top-level (not a method) so it can be unit-tested without a live handle.
Map<String, dynamic>? unwrapSyncEnvelope(Map<String, dynamic>? raw) {
  if (raw == null) return null;
  if (!raw.containsKey('ok')) {
    // Legacy bare payload from an older native build — pass through.
    return raw;
  }
  if (raw['ok'] == true) {
    final data = raw['data'];
    // Success payloads are always objects; tolerate a missing/!map `data`.
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }
  final error = raw['error'];
  throw SyncNativeException(
    error is Map<String, dynamic>
        ? SyncNativeError.fromMap(error)
        : SyncNativeError.unknown(),
  );
}

void _synheartRuntimeLogTrampoline(Pointer<Utf8> line, Pointer<Void> userData) {
  final free = _synheartRuntimeLogFree;
  if (free == null) return;
  final text = _readFfiStringAndFree(line, free);
  if (text == null) return;
  final custom = synheartRuntimeLogForwarder;
  if (custom != null) {
    custom(text);
    return;
  }
  if (kDebugMode) {
    debugPrint('[synheart] $text');
  }
}

/// Bridge to the core runtime via FFI.
///
/// Usage:
/// ```dart
/// final bridge = CoreRuntimeBridge.create({
/// 'app_id': 'com.example',
/// 'subject_id': 'sub_abc123',
/// 'mode': 'personal',
/// });
/// final session = bridge?.startSession();
/// bridge?.pushHr(DateTime.now().millisecondsSinceEpoch, 72.0);
/// bridge?.stopSession();
/// bridge?.dispose();
/// ```
class CoreRuntimeBridge {
  CoreRuntimeBridge._(
    this._ffi,
    this._handle, {
    required this.deviceAuthTemporarilyDisabledForSubjectCompat,
  });

  final SynheartCoreFFI _ffi;
  final Pointer<Void> _handle;
  final bool deviceAuthTemporarilyDisabledForSubjectCompat;
  bool _disposed = false;
  Pointer<SynheartSdkCryptoCallbacks>? _sdkCryptoTable;

  /// In-flight `Isolate.run` FFI calls. Each captures a raw native handle
  /// ADDRESS and runs on a background isolate, so [dispose] must wait for them
  /// before `coreFree` frees the handle — otherwise the background isolate
  /// dereferences a freed pointer (use-after-free). Reachable now that the
  /// subject re-key tears Core down on auth changes.
  final Set<Future<Object?>> _inflightFfi = <Future<Object?>>{};

  /// The native runtime owns mutable device identity and sync-space state.
  /// Keep both families ordered so registration/reattest/logout cannot overlap
  /// a roster, transfer, or lifecycle mutation on the same handle.
  final SerialOperationQueue _syncOperationQueue = SerialOperationQueue();

  /// Trampolines retired by [clearHsiCallback] / [clearStreamCallback] but not
  /// yet closed.
  ///
  /// Closing a `NativeCallable` at clear time is a use-after-free. The runtime's
  /// `synheart_core_clear_hsi_callback` only calls `JoinHandle::abort()` on the
  /// tokio listener task; `abort()` requests cancellation and returns without
  /// joining, so a worker can still be inside the dispatch path when the FFI
  /// call returns. Closing the trampoline at that point produces
  ///
  ///     runtime_entry.cc: error: Callback invoked after it has been deleted.
  ///     Fatal signal 6 (SIGABRT) in tid NNN (tokio-rt-worker)
  ///
  /// with `synheart_core_set_hsi_callback::{closure}` as the innermost frame
  /// (observed on Android arm64, runtime v0.19.2, after a session ends and the
  /// subject re-key re-configures Core).
  ///
  /// So we hand the registration back to the runtime immediately but keep the
  /// trampoline alive, and only close it in [dispose] once `coreFree` has
  /// dropped the handle — and with it the embedded tokio runtime and its
  /// workers. After that nothing can reach the pointer.
  ///
  /// The cost is a handful of live trampolines per handle (one per
  /// re-configure, which is rare), all released on dispose. That is a trivial
  /// amount of memory next to a hard crash.
  final List<NativeCallable<Void Function(Pointer<Utf8>, Pointer<Void>)>>
  _retiredCallables =
      <NativeCallable<Void Function(Pointer<Utf8>, Pointer<Void>)>>[];

  /// Runs [body] on a background isolate — a native FFI call that
  /// dereferences the handle by address — and registers the in-flight future
  /// so [dispose] can await it before `coreFree` frees the handle. EVERY
  /// handle-dereferencing `Isolate.run` in this bridge MUST go through here,
  /// or a teardown that races an in-flight call frees the handle out from
  /// under the isolate (use-after-free across the FFI boundary).
  Future<T> _runFfi<T>(FutureOr<T> Function() body) {
    final f = Isolate.run(body);
    _inflightFfi.add(f);
    f.whenComplete(() => _inflightFfi.remove(f));
    return f;
  }

  /// Default `env_filter` when [initRuntimeLogging] is called with a null/empty filter.
  // static String defaultRuntimeLogEnvFilter = 'info,synheart_core_runtime=debug';
  static String defaultRuntimeLogEnvFilter = 'info';

  static bool _loggingInstalled = false;
  static NativeCallable<Void Function(Pointer<Utf8>, Pointer<Void>)>?
  _logCallable;
  static SynheartCoreFFI? _logFfi;

  /// True once logging installed via the crash-safe **buffered (pull-based)**
  /// path. When true, [_drainTimer] is pumping lines and no `NativeCallable`
  /// is registered — nothing can dangle across a Dart hot restart.
  static bool _bufferedMode = false;

  /// Periodic drain pump for buffered mode. Cancelled by
  /// [shutdownRuntimeLogging].
  static Timer? _drainTimer;

  /// How often buffered mode polls the runtime's ring buffer. ~4 Hz adds at
  /// most ~250 ms latency to diagnostic lines — an acceptable trade for
  /// removing the hot-restart crash class.
  static Duration bufferedDrainInterval = const Duration(milliseconds: 250);

  /// Initialize Runtime `tracing` once per process (call before [create] if you
  /// need a custom filter or sink). See the book: `book/src/abi/logging.md`.
  ///
  /// Prefers **buffered (pull-based) mode**: the runtime formats lines into an
  /// internal ring buffer and this bridge polls them on a [Timer.periodic], so
  /// no function pointer crosses FFI. This is the fix for the Flutter
  /// hot-restart crash (`Callback invoked after it has been deleted`) — the
  /// dying isolate can't invalidate a pointer the runtime never held.
  ///
  /// Falls back to the legacy push-callback path automatically when the
  /// running runtime is too old to export the buffered symbols, so a lagging
  /// vendored native lib still logs (it just keeps the old crash exposure on
  /// hot restart until the lib is updated).
  ///
  /// [onLine] receives each decoded line in either mode. Returns `0` on
  /// success, `1` if already initialized, negative on failure.
  static int initRuntimeLogging({
    SynheartCoreFFI? ffi,
    String? envFilter,
    void Function(String line)? onLine,
    bool preferBuffered = true,
  }) {
    if (_loggingInstalled) return 1;

    final lib = ffi ?? SynheartCoreFFI.load();
    if (lib == null) return -2;

    if (preferBuffered) {
      final rc = _initRuntimeLoggingBuffered(lib, envFilter, onLine);
      // null => buffered symbols unavailable on this runtime; fall through.
      if (rc != null) return rc;
      if (kDebugMode) {
        debugPrint(
          '[synheart] buffered logging unavailable on this runtime; '
          'falling back to callback mode (hot-restart crash exposure remains)',
        );
      }
    }
    return _initRuntimeLoggingCallback(lib, envFilter, onLine);
  }

  /// Buffered-mode init. Returns the runtime status code, or `null` when the
  /// runtime doesn't export the buffered symbols (caller should fall back).
  static int? _initRuntimeLoggingBuffered(
    SynheartCoreFFI lib,
    String? envFilter,
    void Function(String line)? onLine,
  ) {
    // Accessing these `late final` lookups throws if the symbol is absent
    // (older vendored .so). Probe them before committing to buffered mode.
    final int Function(Pointer<Utf8>) initBuffered;
    final Pointer<Utf8> Function() drain;
    try {
      initBuffered = lib.initLoggingBuffered;
      drain = lib.drainLogs;
    } catch (_) {
      return null; // symbols missing → signal fallback
    }

    final chosen = envFilter ?? defaultRuntimeLogEnvFilter;
    final filterArg = chosen.isEmpty ? nullptr : chosen.toNativeUtf8();
    try {
      final rc = initBuffered(filterArg);
      if (rc == 0 || rc == 1) {
        synheartRuntimeLogForwarder = onLine;
        _logFfi = lib;
        _bufferedMode = true;
        _loggingInstalled = true;
        _startDrainPump(lib, drain);
      }
      return rc;
    } catch (_) {
      return -3;
    } finally {
      if (filterArg != nullptr) {
        malloc.free(filterArg);
      }
    }
  }

  /// Legacy push-callback init (pre-buffered runtimes, or `preferBuffered:
  /// false`). Registers a [NativeCallable.listener] — the host MUST call
  /// [shutdownRuntimeLogging] before the isolate is destroyed.
  static int _initRuntimeLoggingCallback(
    SynheartCoreFFI lib,
    String? envFilter,
    void Function(String line)? onLine,
  ) {
    final chosen = envFilter ?? defaultRuntimeLogEnvFilter;
    final filterArg = chosen.isEmpty ? nullptr : chosen.toNativeUtf8();
    try {
      synheartRuntimeLogForwarder = onLine;
      _synheartRuntimeLogFree = lib.coreFreeString;
      _logCallable ??=
          NativeCallable<Void Function(Pointer<Utf8>, Pointer<Void>)>.listener(
            _synheartRuntimeLogTrampoline,
          );
      _logFfi = lib;
      final rc = lib.initLogging(
        filterArg,
        _logCallable!.nativeFunction,
        nullptr,
      );
      if (rc == 0 || rc == 1) {
        _loggingInstalled = true;
      }
      return rc;
    } catch (_) {
      return -3;
    } finally {
      if (filterArg != nullptr) {
        malloc.free(filterArg);
      }
    }
  }

  /// Start (or restart) the buffered-mode drain pump: poll the runtime ring,
  /// split the `\n`-joined blob, and forward each line.
  static void _startDrainPump(
    SynheartCoreFFI lib,
    Pointer<Utf8> Function() drain,
  ) {
    _drainTimer?.cancel();
    _drainTimer = Timer.periodic(bufferedDrainInterval, (_) {
      _drainOnce(lib, drain);
    });
  }

  /// Drain and forward all lines currently pending in the runtime ring.
  static void _drainOnce(SynheartCoreFFI lib, Pointer<Utf8> Function() drain) {
    Pointer<Utf8> ptr;
    try {
      ptr = drain();
    } catch (_) {
      return;
    }
    if (ptr == nullptr) return; // empty buffer — the normal idle case
    final blob = _readFfiStringAndFree(ptr, lib.coreFreeString);
    if (blob == null || blob.isEmpty) return;
    final custom = synheartRuntimeLogForwarder;
    for (final line in blob.split('\n')) {
      if (custom != null) {
        custom(line);
      } else if (kDebugMode) {
        debugPrint('[synheart] $line');
      }
    }
  }

  /// Tear down runtime log forwarding installed by [initRuntimeLogging].
  ///
  /// **Buffered mode (default):** cancels the drain pump after one final
  /// flush. Not required for correctness on hot restart — buffered mode is
  /// crash-safe because no `NativeCallable` is registered — but calling it on
  /// [AppLifecycleState.detached] stops the timer promptly on a clean exit.
  ///
  /// **Callback (legacy) mode:** REQUIRED before the Dart isolate that
  /// registered the [NativeCallable] is destroyed, so the runtime joins its
  /// worker before the trampoline is freed.
  ///
  /// Wire-up for Flutter apps:
  /// ```dart
  /// class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  /// @override
  /// void didChangeAppLifecycleState(AppLifecycleState state) {
  /// if (state == AppLifecycleState.detached) {
  /// CoreRuntimeBridge.shutdownRuntimeLogging();
  /// }
  /// }
  /// }
  /// ```
  ///
  /// Idempotent: safe to call when logging was never initialised, or
  /// twice in a row. Returns `0` = OK, `1` = was-not-initialised,
  /// `<0` = failure.
  static int shutdownRuntimeLogging() {
    final ffi = _logFfi;

    // Buffered mode: flush once more, then stop polling. There is no worker
    // thread or trampoline to join — cancelling the timer fully detaches us.
    if (_bufferedMode) {
      if (ffi != null) {
        try {
          _drainOnce(ffi, ffi.drainLogs);
        } catch (_) {
          /* best-effort final flush */
        }
      }
      _drainTimer?.cancel();
      _drainTimer = null;
      _bufferedMode = false;
      synheartRuntimeLogForwarder = null;
      _loggingInstalled = false;
      _logFfi = null;
      return 0;
    }

    var rc = 1;
    if (ffi != null) {
      try {
        rc = ffi.shutdownLogging();
      } catch (_) {
        rc = -3;
      }
    }

    // Close the Dart-side callable AFTER the runtime has stopped
    // forwarding events. The runtime's shutdown_logging joins the
    // worker thread, so by this point no thread can be in the middle
    // of calling _logCallable.nativeFunction.
    final callable = _logCallable;
    if (callable != null) {
      try {
        callable.close();
      } catch (_) {
        /* ignore */
      }
      _logCallable = null;
    }
    synheartRuntimeLogForwarder = null;
    _synheartRuntimeLogFree = null;
    _loggingInstalled = false;
    _logFfi = null;
    return rc;
  }

  /// Lines the runtime dropped due to ring overflow (buffered mode) or
  /// channel backpressure — a growing value means the drain pump or callback
  /// is falling behind. Returns `0` when logging isn't initialised or the
  /// runtime is too old to report it.
  static int runtimeDroppedLogLines() {
    final ffi = _logFfi;
    if (ffi == null) return 0;
    try {
      return ffi.droppedLogLines();
    } catch (_) {
      return 0;
    }
  }

  /// Create a bridge from a config map. Returns null if the native
  /// library is unavailable or config is invalid.
  static CoreRuntimeBridge? create(Map<String, dynamic> config) {
    final ffi = SynheartCoreFFI.load();
    if (ffi == null) return null;

    final runtimeConfig = Map<String, dynamic>.from(config);

    // Optional compatibility guard (off by default) for runtimes where
    // device-auth subject derivation is not yet aligned with engine validation.
    final forceDisableDeviceAuth =
        runtimeConfig['_compat_force_disable_device_auth'] == true;
    runtimeConfig.remove('_compat_force_disable_device_auth');

    final deviceAuth = runtimeConfig['device_auth'];
    var deviceAuthForcedOff = false;
    if (forceDisableDeviceAuth && deviceAuth is Map) {
      runtimeConfig['device_auth'] = <String, dynamic>{
        ...deviceAuth.map((k, v) => MapEntry(k.toString(), v)),
        'enabled': false,
      };
      runtimeConfig.remove('client_id');
      deviceAuthForcedOff = true;
    }

    // Compatibility shim for non-canonical subject IDs — applied ONLY when
    // device-auth is off. With device-auth ON the Rust runtime derives the
    // canonical subject from `client_id` at init (RFC-0008); prepending `sub_`
    // here would fight that derivation and pass a subject the runtime then
    // overrides, so we leave `subject_id` untouched and let the host read the
    // canonical value back via [runtimeSubjectId] after create().
    final effectiveDeviceAuth = runtimeConfig['device_auth'];
    final deviceAuthEnabled =
        effectiveDeviceAuth is Map && effectiveDeviceAuth['enabled'] == true;
    final rawSubjectId = runtimeConfig['subject_id'];
    if (!deviceAuthEnabled &&
        rawSubjectId is String &&
        rawSubjectId.isNotEmpty &&
        !rawSubjectId.startsWith('sub_')) {
      runtimeConfig['subject_id'] = 'sub_$rawSubjectId';
    }

    final cJson = jsonEncode(runtimeConfig).toNativeUtf8();
    try {
      final handle = ffi.coreNew(cJson.cast());
      if (handle == nullptr) {
        // Pull Rust's last-error message (set by synheart_core_new on every
        // nullptr return). Falls back to a keys/empty dump for older
        // runtime builds that don't export the symbol.
        String? reason;
        final lastErr = ffi.coreLastError;
        if (lastErr != null) {
          final p = lastErr();
          if (p != nullptr) {
            reason = p.toDartString();
            ffi.coreFreeString(p);
          }
        }
        if (reason != null) {
          SynheartLogger.log(
            '[Synheart FFI] coreNew failed: $reason',
            name: 'synheart.ffi',
          );
        } else {
          // Older runtime build without the last-error symbol — fall back
          // to listing which Dart-side fields look empty so the operator
          // still has something to grep on. Avoids logging values
          // (some are sensitive).
          final emptyFields = <String>[];
          runtimeConfig.forEach((k, v) {
            if (v == null) {
              emptyFields.add('$k=null');
            } else if (v is String && v.isEmpty) {
              emptyFields.add('$k=""');
            }
          });
          SynheartLogger.log(
            '[Synheart FFI] coreNew returned nullptr (no last-error symbol). '
            'keys=${runtimeConfig.keys.toList()} empty=$emptyFields',
            name: 'synheart.ffi',
          );
        }
        return null;
      }
      // §1b: logging after core creation — avoids crash from async
      // NativeCallable.listener trampoline during synchronous coreNew.
      initRuntimeLogging(ffi: ffi);
      return CoreRuntimeBridge._(
        ffi,
        handle,
        deviceAuthTemporarilyDisabledForSubjectCompat: deviceAuthForcedOff,
      );
    } finally {
      malloc.free(cJson);
    }
  }

  /// Whether the native library was loaded and the handle is valid.
  bool get isAvailable => !_disposed;

  /// True when this native build exports the full `synheart_core_sdk_*` device-auth ABI.
  bool get sdkDeviceAuthAvailable => !_disposed && _ffi.sdkFfi.isAvailable;

  /// Whether this runtime supports the v0.24 identity-preserving refresh verb.
  bool get sdkDeviceReattestAvailable =>
      !_disposed && _ffi.sdkFfi.reattestDevice != null;

  /// Whether this runtime supports the v0.24 destructive identity logout verb.
  bool get sdkDeviceLogoutAvailable => !_disposed && _ffi.sdkFfi.logout != null;

  /// Register host crypto callbacks (§2). Must be called before [sdkRegisterDevice] / proof APIs.
  ///
  /// [table] must point at a caller-owned [SynheartSdkCryptoCallbacks] populated with
  /// process-resolved native function pointers — the bridge takes ownership and frees
  /// it on [dispose] or on the next successful call.
  ///
  /// Returns `0` on success. On failure, frees the provided table.
  int setSdkCryptoCallbacks(Pointer<SynheartSdkCryptoCallbacks> table) {
    if (_disposed) return -1;
    if (!_ffi.sdkFfi.isAvailable) return -2;
    if (_sdkCryptoTable != null) {
      calloc.free(_sdkCryptoTable!);
      _sdkCryptoTable = null;
    }
    final rc = _ffi.sdkFfi.setCryptoCallbacksInvoke(_handle, table);
    if (rc != 0) {
      calloc.free(table);
      return rc;
    }
    _sdkCryptoTable = table;
    return 0;
  }

  /// Attach host-provided secure-storage callbacks so the native core can
  /// persist state (consent tokens, device records, …) across app restarts.
  ///
  /// Resolves `synheart_native_secure_store` / `…_load` / `…_delete` from the
  /// process (iOS) or from `libsynheart_native_crypto.so` (Android) and hands
  /// the function pointers to `synheart_core_set_storage_callbacks`.
  ///
  /// Returns:
  /// - `0` on success,
  /// - `-1` if the runtime is disposed,
  /// - `-2` if `synheart_core_set_storage_callbacks` isn't exported by this
  /// core build,
  /// - `-3` if the native symbols are missing (no storage backend available),
  /// - any other non-zero value the core's FFI returned.
  int setStorageCallbacks() {
    if (_disposed) return -1;
    final setter = _ffi.sdkFfi.setStorageCallbacks;
    if (setter == null) return -2;
    final triple = PlatformNativeSdkStorageCallbacks.tryResolveTriple();
    if (triple == null) return -3;
    return setter(_handle, triple.store, triple.load, triple.delete);
  }

  /// §3 — device registration (attestation). [clientId] is the app user id for this session.
  /// Runs on a background isolate so the blocking FFI call doesn't ANR the UI thread.
  Future<Map<String, dynamic>?> sdkRegisterDevice(String clientId) {
    if (_ffi.sdkFfi.registerDevice == null) return Future.value(null);
    return _runBackgroundSyncEnvelope(
      _SyncFfiOperation.registerDevice,
      firstArg: clientId,
      throwOnWorkerFailure: true,
    );
  }

  /// Refresh the current device's attestation without changing its device ID.
  /// Runs off the UI isolate because the native v0.24 call is blocking.
  Future<Map<String, dynamic>?> sdkReattestDevice() {
    if (_ffi.sdkFfi.reattestDevice == null) return Future.value(null);
    return _runBackgroundSyncEnvelope(
      _SyncFfiOperation.reattestDevice,
      throwOnWorkerFailure: true,
    );
  }

  /// End the installed device identity and clear its native sync membership.
  /// The runtime defines logout as idempotent, but still returns an envelope so
  /// the allocation can be released consistently. The call is blocking in C.
  Future<Map<String, dynamic>?> sdkLogout() {
    if (_ffi.sdkFfi.logout == null) return Future.value(null);
    return _runBackgroundSyncEnvelope(
      _SyncFfiOperation.logoutDevice,
      throwOnWorkerFailure: true,
    );
  }

  /// §3 / §5 — JSON snapshot from `synheart_core_sdk_device_auth_status`.
  Map<String, dynamic>? sdkDeviceAuthStatus() {
    if (_disposed || _ffi.sdkFfi.deviceAuthStatus == null) return null;
    final out = _readAndFree(_ffi.sdkFfi.deviceAuthStatus!(_handle));
    if (out == null) return null;
    try {
      return jsonDecode(out) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// §4 — compact JWS value for `X-Synheart-Proof` (non-ingest APIs). Use uppercase [method].
  String? buildProofHeader(String method, String absoluteUrl) {
    if (_disposed || _ffi.sdkFfi.buildProofHeader == null) return null;
    final m = method.toNativeUtf8();
    final u = absoluteUrl.toNativeUtf8();
    try {
      return _readAndFree(
        _ffi.sdkFfi.buildProofHeader!(_handle, m.cast(), u.cast()),
      );
    } finally {
      malloc.free(m);
      malloc.free(u);
    }
  }

  /// Release the native handle. Must be called when done.
  ///
  /// Marks disposed FIRST (every Isolate.run FFI method early-returns on
  /// `_disposed`, and the check + `_runFfi` spawn happen with no `await`
  /// between them, so no new background call can start once this runs), then
  /// defers the
  /// actual `coreFree` until any IN-FLIGHT background-isolate calls finish —
  /// otherwise `coreFree` would free the handle while a background isolate is
  /// still dereferencing it (use-after-free).
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    clearStreamCallback();
    clearHsiCallback();
    final pending = _inflightFfi.toList();
    Future<void> freeWhenIdle() async {
      if (pending.isNotEmpty) {
        try {
          await Future.wait<Object?>(pending);
        } catch (_) {
          // A failed in-flight call still completed (no longer touching the
          // handle) — proceed to free.
        }
      }
      _ffi.coreFree(_handle);

      // Only now is it safe to free the trampolines. `coreFree` drops the
      // handle, which drops the embedded tokio runtime and joins its workers,
      // so no task can be part-way through a callback dispatch any more. Doing
      // this before `coreFree` is what crashed — see [_retiredCallables].
      for (final callable in _retiredCallables) {
        callable.close();
      }
      _retiredCallables.clear();

      if (_sdkCryptoTable != null) {
        calloc.free(_sdkCryptoTable!);
        _sdkCryptoTable = null;
      }
    }

    unawaited(freeWhenIdle());
  }

  // ── Session lifecycle ────────────────────────────────────────────────

  /// Start a session. Returns session JSON or null on error.
  Map<String, dynamic>? startSession() {
    return _callJson(() => _ffi.startSession(_handle));
  }

  /// Stop the current session.
  bool stopSession() => _ffi.stopSession(_handle) == 0;

  /// Get the current session as a map, or null.
  Map<String, dynamic>? currentSession() {
    return _callJson(() => _ffi.currentSession(_handle));
  }

  /// Whether a session is running.
  ///
  /// Guarded on [_disposed]: `Synheart.isSessionRunning` reads this from UI
  /// code, so a read racing teardown would otherwise dereference a freed
  /// handle across the FFI boundary.
  bool get isRunning => _disposed ? false : _ffi.isRunning(_handle) != 0;

  // ── Subject identity ─────────────────────────────────────────────────

  /// The runtime's canonical subject id (RFC-0008), or null when unavailable.
  /// Read this back after init to pick up a subject the runtime derived itself
  /// (e.g. from `client_id` when device-auth is on), so Dart-side state can be
  /// reconciled with the native source of truth.
  String? runtimeSubjectId() {
    if (_disposed) return null;
    try {
      return _readAndFree(_ffi.getSubjectId(_handle));
    } catch (_) {
      // Runtime build predates the symbol — degrade softly so subject sync
      // never breaks init; callers fall back to the configured subject.
      return null;
    }
  }

  /// Atomically rebind the runtime subject id, re-pointing consent
  /// (`cached_subject_id` + token slot) and the cloud connector (`user_id` +
  /// subject-scoped queue) without a full dispose/reinit. Returns `1` when a
  /// consent re-mint is required for the new subject, `0` when a valid token is
  /// already loaded, and `-1` on error (disposed handle or empty subject).
  int rebindSubjectId(String subjectId, {bool invalidateToken = true}) {
    if (_disposed) return -1;
    final s = subjectId.toNativeUtf8();
    try {
      return _ffi.rebindSubjectId(_handle, s.cast(), invalidateToken ? 1 : 0);
    } catch (_) {
      // Runtime build predates the symbol — degrade softly.
      return -1;
    } finally {
      malloc.free(s);
    }
  }

  /// Create the engine pipeline without starting a background tick task.
  /// Used by the ingest buffer which handles ticking via ingestBatch.
  void ensurePipeline() => _ffi.ensurePipeline(_handle);

  // ── Sensor push ──────────────────────────────────────────────────────

  /// Push an RR interval with provider attribution.
  ///
  /// `provider` is forwarded to the engine for Tier-1 routing (only
  /// `'ble_hrm'` qualifies for the breathing detector's Tier-1 series
  /// today). The C-string is allocated and freed inside this call —
  /// the FFI layer copies it on the runtime side, no need to retain.
  void pushRr(int tsMs, double rrMs, {String provider = 'default_sensor'}) {
    final cstr = provider.toNativeUtf8();
    try {
      _ffi.pushRr(_handle, tsMs, rrMs, cstr);
    } finally {
      malloc.free(cstr);
    }
  }

  /// Push a batch of RR intervals that arrived together in one sensor
  /// notification (e.g. a BLE Heart Rate Measurement packet carrying several
  /// RR values under one arrival timestamp).
  ///
  /// [anchorTsMs] is that shared arrival timestamp; the runtime reconstructs a
  /// distinct per-beat timestamp for each interval (newest beat at the anchor,
  /// earlier beats back-dated) so no beat is lost. [order] states how [rrMs] is
  /// ordered: `0` = oldest-first (BLE HRM default), `1` = newest-first. Empty
  /// [rrMs] is a no-op. The array and provider C-string are allocated and freed
  /// inside this call; the runtime copies what it needs.
  void pushRrBatch(
    int anchorTsMs,
    List<double> rrMs, {
    int order = 0,
    String provider = 'default_sensor',
  }) {
    if (rrMs.isEmpty) return;
    final rrPtr = malloc<Double>(rrMs.length);
    final cstr = provider.toNativeUtf8();
    try {
      for (var i = 0; i < rrMs.length; i++) {
        rrPtr[i] = rrMs[i];
      }
      _ffi.pushRrBatch(_handle, anchorTsMs, rrPtr, rrMs.length, order, cstr);
    } finally {
      malloc.free(rrPtr);
      malloc.free(cstr);
    }
  }

  void pushHr(int tsMs, double bpm) => _ffi.pushHr(_handle, tsMs, bpm);

  // ── Breathing compliance ────────────────────────────────────────────
  // Tier-1 RR pushed via [pushRr] is auto-forwarded to the breathing
  // detector. These setters configure target/window/profile; [breathing
  // EvaluateJson] reads back the current verdict as JSON.

  void breathingSetTargetBpm(double bpm) =>
      _ffi.breathingSetTargetBpm(_handle, bpm);
  void breathingSetWindowSecs(int secs) =>
      _ffi.breathingSetWindowSecs(_handle, secs);
  void breathingSetPopulation(int profile) =>
      _ffi.breathingSetPopulation(_handle, profile);
  Map<String, dynamic>? breathingEvaluateJson() =>
      _callJson(() => _ffi.breathingEvaluate(_handle));
  void breathingReset() => _ffi.breathingReset(_handle);

  /// Advance the pipeline clock. Returns HSI JSON if a window completed.
  String? tick(int nowMs) => _readAndFree(_ffi.tick(_handle, nowMs));

  /// Push vendor-reported HRV metrics (Tier 2).
  /// Pass -1.0 for unavailable fields.
  void pushVendorHrv(
    int tsMs, {
    double rmssd = -1.0,
    double sdnn = -1.0,
    double stress = -1.0,
    double recovery = -1.0,
  }) => _ffi.pushVendorHrv(_handle, tsMs, rmssd, sdnn, stress, recovery);

  /// Push vendor vitals (SpO2, respiration) to lab windows.
  void pushVendorVitals(
    int tsMs, {
    double spo2 = -1.0,
    double respiration = -1.0,
  }) => _ffi.pushVendorVitals(_handle, tsMs, spo2, respiration);

  void pushAccel(int tsMs, double x, double y, double z) =>
      _ffi.pushAccel(_handle, tsMs, x, y, z);
  void pushBehavior(int tsMs, int eventType, double value) =>
      _ffi.pushBehavior(_handle, tsMs, eventType, value);

  // ── Mobile host surface ─────────────────────────────────────────────
  //
  // Each of these degrades to a no-op when the vendored runtime predates the
  // symbol (see the optional lookups in `ffi_bindings.dart`). The return
  // values distinguish the two cases where it matters: `pushBehaviorEventJson`
  // and `rollDay` return `null` for "not available in this runtime" and an int
  // status otherwise, so a caller can tell an unavailable ABI from a rejected
  // event.

  /// Whether the loaded runtime can take rich behavior events at all.
  ///
  /// Probe this once and pick a path, rather than inferring it from a `null`
  /// return after the fact. A host that aggregates keystrokes into windowed
  /// `Typing` summaries needs to know *before* it starts buffering whether the
  /// summary will land: discovering it ten seconds later leaves a window's
  /// worth of keystrokes with no path to the engine, and re-sending them
  /// through the legacy call would double-count everything already summarized.
  bool get supportsRichBehaviorEvents => _ffi.pushBehaviorEvent != null;

  /// Which of the mobile-host ABI calls the *loaded* runtime actually exports.
  ///
  /// The vendored `.so` / xcframework a host ships is a pinned artifact, not
  /// this source tree, so a binding being present here says nothing about
  /// whether the call does anything on the device in front of you. Every entry
  /// below degrades to a no-op (or a `null` return) when false.
  ///
  /// Keys are the Dart-facing names, not the C symbols, so a host can drive a
  /// capability table off this map without hard-coding `synheart_core_…`
  /// strings. Reading it resolves each optional lookup, so it doubles as the
  /// audit `runtimeDiagnostics(probeAll: true)` performs.
  Map<String, bool> get mobileHostAbiSupport => <String, bool>{
    'pushBehaviorEvent': _ffi.pushBehaviorEvent != null,
    'pushContextEvent': _ffi.pushContextEvent != null,
    'pushSpeed': _ffi.pushSpeed != null,
    'setAccelPlacement': _ffi.setAccelPlacement != null,
    'declareRestWindow': _ffi.declareRestWindow != null,
    'tickAll': _ffi.tickAll != null,
    'flushPending': _ffi.flushPending != null,
    'rollDay': _ffi.rollDay != null,
    'exportSessionState': _ffi.exportSessionState != null,
    'loadSessionState': _ffi.loadSessionState != null,
    'configId': _ffi.configId != null,
    'lastHsv': _ffi.lastHsv != null,
    'attachStrainScoreJson': _ffi.attachStrainScoreJson != null,
  };

  /// Push one rich behavior event as JSON. Returns the runtime's status
  /// (`0` = accepted), or `null` when the runtime does not export the symbol.
  ///
  /// Prefer the typed `BehaviorEventInput` wrapper on the facade — the `kind`
  /// string is a closed set and an unrecognised one is dropped silently.
  int? pushBehaviorEventJson(String eventJson) {
    final fn = _ffi.pushBehaviorEvent;
    if (fn == null) return null;
    return _withCString(eventJson, (p) => fn(_handle, p));
  }

  /// Push a foreground-app context event as JSON. Returns `0` on acceptance,
  /// or `null` when the symbol is absent.
  ///
  /// Two separate things must be true for this to do anything: the runtime
  /// must be recent enough to export the symbol **and** must have been built
  /// with the `app-context` cargo feature. Without the feature the symbol is
  /// compiled as an inert stub that always returns `1`, so a non-zero result
  /// here is far more likely to mean "this build has no context layer" than
  /// "your JSON was wrong".
  ///
  /// Send the app *category*, never a context label: the engine derives the
  /// 12-class `ContextLabel` itself, and two-letter app codes collide with
  /// live label codes (`BR` is `BreakRecovery`, not "browsing/reading").
  int? pushContextEventJson(String eventJson) {
    final fn = _ffi.pushContextEvent;
    if (fn == null) return null;
    return _withCString(eventJson, (p) => fn(_handle, p));
  }

  /// Push a GPS-derived ground speed sample in **m/s**.
  ///
  /// The high-confidence input for `locomotion_state`; without it that axis
  /// runs permanently on its low-confidence accel-only fallback. Speed is the
  /// one wholly ungated channel — drained by window range and reduced to a
  /// median — so out-of-order GPS is never dropped.
  void pushSpeed(int tsMs, double speedMps) =>
      _ffi.pushSpeed?.call(_handle, tsMs, speedMps);

  /// Declare where the accelerometer sits. See `AccelPlacement`.
  void setAccelPlacement(int placementCode) =>
      _ffi.setAccelPlacement?.call(_handle, placementCode);

  /// Declare that the window containing [tsMs] is a rest window.
  ///
  /// Without this Focus is never zeroed on a break and Capacity never takes
  /// the recovery path, so break windows score as engaged.
  ///
  /// Three semantics bite in this order:
  ///
  /// * [tsMs] is epoch ms on the same clock as every `push_*`, and the
  ///   declaration lands on the window whose bounds **contain** it — not on
  ///   whichever window emerges next. Those differ whenever a lateness budget
  ///   is deferring emission.
  /// * It is **one-shot** by design. A sticky flag a host forgot to clear
  ///   would pin Focus at exactly `0.0`, stop Capacity depleting and freeze
  ///   Mental Fatigue's engaged clock for the rest of the session, silently.
  ///   Call it once per rest *window*, not once when a break begins.
  /// * A declaration whose window has already been emitted is discarded, not
  ///   carried forward.
  void declareRestWindow(int tsMs) =>
      _ffi.declareRestWindow?.call(_handle, tsMs);

  /// Drain **every** completed window, oldest first, as a JSON array.
  ///
  /// Prefer this to [tick] after any gap: `tick` polls one window and
  /// `tick_all` drains them all, so a 40 s background gap does not silently
  /// skip the windows it spanned.
  ///
  /// Returns `null` when the runtime does not export the symbol — callers
  /// should fall back to [tick] in that case rather than assuming no windows.
  String? tickAll(int nowMs) {
    final fn = _ffi.tickAll;
    if (fn == null) return null;
    return _readAndFree(fn(_handle, nowMs));
  }

  /// Emit every window still held by the lateness budget, as a JSON array in
  /// the same shape [tickAll] returns.
  ///
  /// Call on backgrounding and at session end, or up to one budget's worth of
  /// windows is stranded forever. Safe to call routinely — with nothing
  /// pending it returns `[]`.
  String? flushPending(int nowMs) {
    final fn = _ffi.flushPending;
    if (fn == null) return null;
    return _readAndFree(fn(_handle, nowMs));
  }

  /// Advance the daily accumulator to [dayIndex] (days since epoch in the
  /// host's **local** zone).
  ///
  /// Skip it and the engine adopts a provisional UTC day, which is wrong for
  /// most of the world. The index must strictly advance — a repeat or a
  /// negative returns `ERR_DAILY_DAY_NOT_ADVANCING`. Returns `null` when the
  /// symbol is absent.
  int? rollDay(int dayIndex) => _ffi.rollDay?.call(_handle, dayIndex);

  /// Export the per-head session state: Capacity, Mental Fatigue, Stress,
  /// Valence and the context engine.
  ///
  /// Persist once per emitted window and on background/terminate.
  /// Score today's accumulated Strain and queue it onto the next HSI frame.
  ///
  /// Returns the score JSON, `null` when the symbol is absent, and also `null`
  /// when the day has no scorable component yet — nothing was accumulated, so
  /// there is nothing to attach. That second case is normal, not an error.
  ///
  /// **Call this BEFORE `rollDay`.** Rolling finalises the day and clears the
  /// very values the Strain computation reads, so a host that rolls first gets
  /// `null` here every single day and never emits a Strain score at all.
  /// `rollDay` does not do this for you.
  ///
  /// Takes no input: the engine accumulated Strain's inputs itself over the
  /// day (heart-rate load, workout events), and asking the host to supply them
  /// would invite a second, disagreeing copy of numbers the engine already
  /// holds.
  String? attachStrainScoreJson() {
    final fn = _ffi.attachStrainScoreJson;
    if (fn == null) return null;
    return _readAndFree(fn(_handle));
  }

  String? exportSessionState() {
    final fn = _ffi.exportSessionState;
    if (fn == null) return null;
    return _readAndFree(fn(_handle));
  }

  /// Restore a previously exported session state.
  ///
  /// **Must run before the first tick.** Window 1 writes each head's state
  /// slot, so a later restore is overwritten by a cold window — and by then
  /// the context baseline has already counted one window against the wrong
  /// history. Returns `0` on success, `null` when the symbol is absent.
  int? loadSessionState(String json) {
    final fn = _ffi.loadSessionState;
    if (fn == null) return null;
    return _withCString(json, (p) => fn(_handle, p));
  }

  /// The comparability key for anything you cache.
  ///
  /// Changes whenever anything value-affecting changes, including the
  /// `sensing` and `mask_profile` declarations. Persist it beside any cached
  /// score: a score computed under a different `config_id` is not comparable
  /// to a new one. Opaque — compare for equality, never parse.
  String? configId() {
    final fn = _ffi.configId;
    if (fn == null) return null;
    return _readAndFree(fn(_handle));
  }

  /// The most recent human-state vector as JSON, or `null` before the first
  /// window has closed (a normal early-session state, not an error).
  ///
  /// Episodic suppression is applied at the source, so on an episodic host
  /// neither this nor the HSI frame shows `capacity` or `mental_fatigue`.
  String? lastHsv() {
    final fn = _ffi.lastHsv;
    if (fn == null) return null;
    return _readAndFree(fn(_handle));
  }

  // ── Personalization task / workout APIs ─────────────────────────────
  // Discriminants match the engine FFI contract — see
  // synheart-engine personalization API.

  /// Set the active task type. `0=Unknown, 1=Focus, 2=Recovery,
  /// 3=Movement, 4=Conversation`. Prefer the typed [TaskType] enum on
  /// `SynheartCore` over calling this with raw integers.
  void setTaskType(int taskKind) => _ffi.setTaskType(_handle, taskKind);

  /// Push a workout/exercise event with optional vendor scalars.
  /// Workout-kind discriminants: `0=Unknown, 1=Cardio, 2=Strength,
  /// 3=Hiit, 4=LowIntensity, 5=Sport`. Pass `-1.0` for missing vendor
  /// scalars.
  void pushWorkoutEvent(
    int startMs,
    int endMs, {
    int workoutKind = 0,
    double vendorStrain = -1.0,
    double vendorRecovery = -1.0,
  }) => _ffi.pushWorkoutEvent(
    _handle,
    startMs,
    endMs,
    workoutKind,
    vendorStrain,
    vendorRecovery,
  );

  /// Currently active task type discriminant.
  int currentTaskType() => _ffi.currentTaskType(_handle);

  /// Currently active workout kind discriminant.
  int currentWorkoutKind() => _ffi.currentWorkoutKind(_handle);

  /// Set the active focus-kind sub-classification. No effect outside
  /// an active `Focus` task. See [FocusKind] for discriminants.
  void setFocusKind(int focusKind) => _ffi.setFocusKind(_handle, focusKind);

  /// Currently active focus kind discriminant.
  int currentFocusKind() => _ffi.currentFocusKind(_handle);

  /// Last `PersonalizationContext` as JSON. Returns `null` before the
  /// first window has completed. Schema mirrors the Synheart Runtime's
  /// `PersonalizationContext` JSON-serialized form.
  String? personalizationContextJson() =>
      _readAndFree(_ffi.personalizationContextJson(_handle));

  /// Push a longitudinal SRM daily value. Allowed dimensions:
  /// `sleep_need`, `sleep_regularity`, `hrv_rmssd`, `resting_hr`,
  /// `recovery_score`, `deep_sleep_min`, `rem_sleep_min`. Day-index =
  /// epoch-day (`epoch_ms / 86_400_000`). Fidelity: `0`=raw, `1`=summary.
  void srmPushWearableDaily({
    required String dimension,
    required int dayIndex,
    required double value,
    double confidence = 0.85,
    int fidelity = 1,
  }) {
    _withCString(
      dimension,
      (p) => _ffi.srmPushWearableDaily(
        _handle,
        p,
        dayIndex,
        value,
        confidence,
        fidelity,
      ),
    );
  }

  /// Trigger a longitudinal SRM recompute. Call after a batch of
  /// [srmPushWearableDaily] so the next inference window picks up
  /// fresh personal baselines. `triggerType`: `0=Window, 1=AffectedWindow,
  /// 2=Full`.
  void srmTriggerWearableRecompute({
    int triggerType = 0,
    required int asOfDay,
  }) => _ffi.srmTriggerWearableRecompute(_handle, triggerType, asOfDay);

  void pushSleepStages(String json) {
    _withCString(json, (p) => _ffi.pushSleepStages(_handle, p));
  }

  /// Batch ingest. Returns HSI JSON if a window completed.
  String? ingestBatch(String batchJson, int nowMs) {
    return _withCString(batchJson, (p) {
      return _readAndFree(_ffi.ingestBatch(_handle, p, nowMs));
    });
  }

  // ── Batch nightly sleep score ──────────────────────────────────────
  //
  // All methods here marshal UTF-8 and free the returned native strings.
  // See the Synheart Runtime sleep-score integration spec for
  // input/output JSON shapes.

  /// Compute a nightly sleep score (stateless).
  ///
  /// [inputJson] must match `synheart_sleep_score::SleepScoreInput`.
  /// Returns the serialized `SleepScoreResult` or `null` on parse error.
  String? sleepScoreComputeJson(String inputJson) {
    return _withCString(inputJson, (p) {
      return _readAndFree(_ffi.sleepScoreComputeJson(_handle, p));
    });
  }

  /// Same as [sleepScoreComputeJson] but with a caller-supplied
  /// correlation ID attached to tracing events.
  String? sleepScoreComputeJsonTraced(String inputJson, String correlationId) {
    return _withCString(inputJson, (p) {
      return _withCString(correlationId, (cid) {
        return _readAndFree(_ffi.sleepScoreComputeJsonTraced(_handle, p, cid));
      });
    });
  }

  /// Compute a daily Recovery Score (stateless).
  ///
  /// [inputJson] must match `synheart_recovery_score::RecoveryScoreInput`.
  /// Returns the serialized `RecoveryScoreResult` JSON, the literal
  /// string `"null"` when the input had no overnight HR/HRV (sleep-only
  /// recovery is forbidden by design), or `null` on parse failure.
  String? recoveryScoreComputeJson(String inputJson) {
    return _withCString(inputJson, (p) {
      return _readAndFree(_ffi.recoveryScoreComputeJson(_handle, p));
    });
  }

  /// Same as [recoveryScoreComputeJson] but with a caller-supplied
  /// correlation ID attached to tracing events.
  String? recoveryScoreComputeJsonTraced(
    String inputJson,
    String correlationId,
  ) {
    return _withCString(inputJson, (p) {
      return _withCString(correlationId, (cid) {
        return _readAndFree(
          _ffi.recoveryScoreComputeJsonTraced(_handle, p, cid),
        );
      });
    });
  }

  /// Compute a daily Readiness Score.
  ///
  /// [inputJson] must match `synheart_readiness_score::ReadinessScoreInput`.
  /// Returns the serialized `ReadinessScoreResult` JSON, or `null` on
  /// parse failure / runtime not ready.
  String? readinessScoreComputeJson(String inputJson) {
    return _withCString(inputJson, (p) {
      return _readAndFree(_ffi.readinessScoreComputeJson(_handle, p));
    });
  }

  /// Same as [readinessScoreComputeJson] but with a caller-supplied
  /// correlation ID attached to tracing events.
  String? readinessScoreComputeJsonTraced(
    String inputJson,
    String correlationId,
  ) {
    return _withCString(inputJson, (p) {
      return _withCString(correlationId, (cid) {
        return _readAndFree(
          _ffi.readinessScoreComputeJsonTraced(_handle, p, cid),
        );
      });
    });
  }

  /// Queue a batch `SleepScoreResult` JSON to ride the next HSI and
  /// feed the Path-B rolling median. Returns `0` on success.
  int attachSleepScoreJson(String resultJson) {
    return _withCString(
          resultJson,
          (p) => _ffi.attachSleepScoreJson(_handle, p),
        ) ??
        -1;
  }

  /// Attach today's daily Recovery Score (`0.=100`).
  /// Sticky across windows until cleared or
  /// replaced. Returns `0` on success.
  int attachRecoveryScoreToday(int score) {
    final clamped = score < 0 ? 0 : (score > 255 ? 255 : score);
    return _ffi.attachRecoveryScoreToday(_handle, clamped);
  }

  /// Drop today's Recovery Score so personalization Stage 2 reverts to
  /// the per-component composite. Returns `0` on success.
  int clearRecoveryScoreToday() {
    return _ffi.clearRecoveryScoreToday(_handle);
  }

  /// Get the last **live-head** `SleepScore` JSON
  /// (`rulepack://sleep_autonomic_v1`). Null if no window has completed.
  String? lastSleepScoreJson() =>
      _readAndFree(_ffi.lastSleepScoreJson(_handle));

  /// Export the longitudinal SRM snapshot for cross-launch persistence.
  String? exportLongitudinalSnapshot() =>
      _readAndFree(_ffi.exportLongitudinalSnapshot(_handle));

  /// Restore the longitudinal SRM from a prior snapshot.
  /// Returns the engine error code (0 on success).
  int loadLongitudinalSnapshot(String json) {
    return _withCString(
          json,
          (p) => _ffi.loadLongitudinalSnapshot(_handle, p),
        ) ??
        -1;
  }

  /// Get the current wearable reference, including Path-B
  /// `recent_sleep_score_median`. Null if no reference is set.
  String? wearableReferenceJson() =>
      _readAndFree(_ffi.wearableReferenceJson(_handle));

  // ── Typed sleep-score bridge API ───────────────────────────────────

  /// Typed form of [sleepScoreComputeJson]. Returns `null` if the engine
  /// rejected the input or the JSON couldn't be parsed.
  SleepScoreResult? computeSleepScore(SleepScoreInput input) {
    final json = sleepScoreComputeJson(input.toJsonString());
    if (json == null) return null;
    try {
      return SleepScoreResult.fromJsonString(json);
    } catch (_) {
      return null;
    }
  }

  /// Typed form of [sleepScoreComputeJsonTraced].
  SleepScoreResult? computeSleepScoreTraced(
    SleepScoreInput input,
    String correlationId,
  ) {
    final json = sleepScoreComputeJsonTraced(
      input.toJsonString(),
      correlationId,
    );
    if (json == null) return null;
    try {
      return SleepScoreResult.fromJsonString(json);
    } catch (_) {
      return null;
    }
  }

  /// Typed form of [attachSleepScoreJson] — serializes the result
  /// internally. Returns 0 on success.
  int attachSleepScore(SleepScoreResult result) {
    // Round-trip via JSON so we use the same wire format the runtime side
    // expects. SleepScoreResult fields are symmetric with serde.
    final json = jsonEncode({
      'score': result.score,
      'score_normalized': result.scoreNormalized,
      'confidence': result.confidence,
      'path': result.path.wire,
      'mode': result.mode.wire,
      'components': {
        'duration': result.components.duration,
        'quality': result.components.quality,
        'continuity': result.components.continuity,
        'consistency': result.components.consistency,
        'personalization': result.components.personalization,
        'vendor_score': result.components.vendorScore,
        'proxy_hr': result.components.proxyHr,
      },
      'adjustments': {
        'debt_penalty': result.adjustments.debtPenalty,
        'hr_adjustment': result.adjustments.hrAdjustment,
      },
      'effective_weights': {
        'duration': result.effectiveWeights.duration,
        'quality': result.effectiveWeights.quality,
        'continuity': result.effectiveWeights.continuity,
        'consistency': result.effectiveWeights.consistency,
        'personalization': result.effectiveWeights.personalization,
      },
      'reason': result.reason?.wire,
      'prior_night_count': result.priorNightCount,
      'pipeline_version': result.pipelineVersion,
      'model_id': result.modelId,
      'constants_hash': result.constantsHash,
    });
    return attachSleepScoreJson(json);
  }

  /// Typed form of [lastSleepScoreJson] — returns the live-head
  /// SleepScore as raw JSON (path/mode/components/tier/baseline).
  /// The live-head and batch shapes differ; use [computeSleepScore]
  /// for the batch form.
  String? lastSleepScoreRawJson() => lastSleepScoreJson();

  /// Typed form of [wearableReferenceJson] — returns just the Path-B
  /// fields callers usually need (`status`, `recent_sleep_score_median`).
  /// For the full reference, parse the raw JSON yourself.
  WearableReferenceView? wearableReference() {
    final json = wearableReferenceJson();
    if (json == null) return null;
    try {
      return WearableReferenceView.fromJsonString(json);
    } catch (_) {
      return null;
    }
  }

  // ── Consent ──────────────────────────────────────────────────────────

  Future<bool> grantConsent(String type) => _consentMutate(type, grant: true);

  Future<bool> revokeConsent(String type) => _consentMutate(type, grant: false);

  /// Grant or revoke a single consent type. The FFI persists the change and
  /// re-issues/syncs the consent token, which blocks on network I/O — calling
  /// it on the UI isolate froze the main thread and ANR'd (observed stack:
  /// main tid=1 Native … synheart_core_revoke_consent). Run it on a background
  /// isolate, mirroring [sdkRegisterDevice] / [consentSubmitForm]. Callers that
  /// mutate several channels must await these SEQUENTIALLY (not concurrently)
  /// so two mutations never race on the shared native handle.
  Future<bool> _consentMutate(String type, {required bool grant}) async {
    if (_disposed) return false;
    final handleAddr = _handle.address;
    return _runFfi(() {
      final ffi = SynheartCoreFFI.load();
      if (ffi == null) return false;
      final handle = Pointer<Void>.fromAddress(handleAddr);
      final p = type.toNativeUtf8();
      try {
        final rc = grant
            ? ffi.grantConsent(handle, p.cast())
            : ffi.revokeConsent(handle, p.cast());
        return rc == 0;
      } catch (_) {
        return false;
      } finally {
        malloc.free(p);
      }
    });
  }

  bool hasConsent(String type) {
    return _withCString(type, (p) => _ffi.hasConsent(_handle, p) != 0);
  }

  Map<String, dynamic>? currentConsent() {
    return _callJson(() => _ffi.currentConsent(_handle));
  }

  bool consentConfigureCloud(String baseUrl, String appId) {
    final pBase = baseUrl.toNativeUtf8();
    final pApp = appId.toNativeUtf8();
    try {
      return _ffi.consentConfigureCloud(_handle, pBase.cast(), pApp.cast()) ==
          0;
    } finally {
      malloc.free(pBase);
      malloc.free(pApp);
    }
  }

  Map<String, dynamic>? consentGetEditableForm() {
    return _callJson(() => _ffi.consentGetEditableForm(_handle));
  }

  Future<Map<String, dynamic>?> consentSubmitForm({
    required String deviceId,
    required String platform,
    String? userId,
    required Map<String, dynamic> formJson,
  }) async {
    if (_disposed) return null;
    final handleAddr = _handle.address;
    final payload = jsonEncode(formJson);
    return _runFfi(() {
      final ffi = SynheartCoreFFI.load();
      if (ffi == null) return null;
      final handle = Pointer<Void>.fromAddress(handleAddr);
      final pDevice = deviceId.toNativeUtf8();
      final pPlatform = platform.toNativeUtf8();
      final pUser = userId != null ? userId.toNativeUtf8() : nullptr;
      final pForm = payload.toNativeUtf8();
      try {
        final ptr = ffi.consentSubmitForm(
          handle,
          pDevice.cast(),
          pPlatform.cast(),
          pUser.cast(),
          pForm.cast(),
        );
        if (ptr == nullptr) return null;
        final raw = ptr.toDartString();
        ffi.coreFreeString(ptr);
        return jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        return null;
      } finally {
        malloc.free(pDevice);
        malloc.free(pPlatform);
        if (pUser != nullptr) malloc.free(pUser);
        malloc.free(pForm);
      }
    });
  }

  /// Persist a durable study-consent record via the consent service. [payload]
  /// carries the record body (`consent_document_version`, optional `study_id` /
  /// `consent_document_hash` / `affirmations` / `signature`, `signed_at`, …).
  /// Returns the created record's `{id, created_at}` on success, or null when
  /// the native runtime (or this symbol) is unavailable.
  Future<Map<String, dynamic>?> recordStudyConsent(
    Map<String, dynamic> payload,
  ) async {
    if (_disposed) return null;
    final handleAddr = _handle.address;
    final encoded = jsonEncode(payload);
    return _runFfi(() {
      final ffi = SynheartCoreFFI.load();
      if (ffi == null) return null;
      final recordFn = ffi.recordStudyConsent;
      // Older native libs lack this symbol; degrade gracefully.
      if (recordFn == null) return null;
      final handle = Pointer<Void>.fromAddress(handleAddr);
      final pPayload = encoded.toNativeUtf8();
      try {
        final ptr = recordFn(handle, pPayload.cast());
        if (ptr == nullptr) return null;
        final raw = ptr.toDartString();
        ffi.coreFreeString(ptr);
        return jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        return null;
      } finally {
        malloc.free(pPayload);
      }
    });
  }

  /// Redeem a research-study access + study code, or (when [validateOnly])
  /// preview the pair without redeeming. Returns the runtime's JSON response.
  Future<Map<String, dynamic>?> enrolResearchStudy({
    required String accessCode,
    required String studyCode,
    bool validateOnly = false,
  }) async {
    if (_disposed) return null;
    final handleAddr = _handle.address;
    return _runFfi(() {
      final ffi = SynheartCoreFFI.load();
      if (ffi == null) return null;
      final handle = Pointer<Void>.fromAddress(handleAddr);
      final pAccess = accessCode.toNativeUtf8();
      final pStudy = studyCode.toNativeUtf8();
      try {
        final ptr = validateOnly
            ? ffi.validateStudyCodes(handle, pAccess.cast(), pStudy.cast())
            : ffi.enrolStudy(handle, pAccess.cast(), pStudy.cast());
        if (ptr == nullptr) return null;
        final raw = ptr.toDartString();
        ffi.coreFreeString(ptr);
        return jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        return null;
      } finally {
        malloc.free(pAccess);
        malloc.free(pStudy);
      }
    });
  }

  /// Withdraw from the device's active research study for this app. No codes
  /// needed — participant + app come from the device's signed cloud credential.
  /// Returns the service response (`{"withdrawn": bool, ...}`) or null.
  Future<Map<String, dynamic>?> withdrawResearchStudy() async {
    if (_disposed) return null;
    final handleAddr = _handle.address;
    return _runFfi(() {
      final ffi = SynheartCoreFFI.load();
      if (ffi == null) return null;
      final handle = Pointer<Void>.fromAddress(handleAddr);
      final ptr = ffi.withdrawStudy(handle);
      if (ptr == nullptr) return null;
      try {
        final raw = ptr.toDartString();
        ffi.coreFreeString(ptr);
        return jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    });
  }

  /// Read the device's CURRENT active research-study enrolment for this app —
  /// the authoritative attribution state (same lookup the consent mint uses).
  /// Returns `{enrolled: bool, study: {...}, enrolment: {...}}`. Hosts should
  /// use this to correct a stale local "enrolled" flag.
  Future<Map<String, dynamic>?> researchStudyStatus() async {
    if (_disposed) return null;
    final handleAddr = _handle.address;
    return _runFfi(() {
      final ffi = SynheartCoreFFI.load();
      if (ffi == null) return null;
      final handle = Pointer<Void>.fromAddress(handleAddr);
      final ptr = ffi.researchStudyStatus(handle);
      if (ptr == nullptr) return null;
      try {
        final raw = ptr.toDartString();
        ffi.coreFreeString(ptr);
        return jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    });
  }

  /// Request erasure of the data the participant contributed to their study.
  /// [dryRun] returns an inventory preview without deleting; a real request is
  /// accepted asynchronously and carries a `request_id`.
  Future<Map<String, dynamic>?> requestStudyDataDeletion({
    bool dryRun = false,
  }) async {
    if (_disposed) return null;
    final handleAddr = _handle.address;
    return _runFfi(() {
      final ffi = SynheartCoreFFI.load();
      if (ffi == null) return null;
      final handle = Pointer<Void>.fromAddress(handleAddr);
      final ptr = ffi.requestStudyDataDeletion(handle, dryRun);
      if (ptr == nullptr) return null;
      try {
        final raw = ptr.toDartString();
        ffi.coreFreeString(ptr);
        return jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    });
  }

  bool consentClearStored() => _ffi.consentClearStored(_handle) == 0;

  Map<String, dynamic>? consentStatus() {
    return _callJson(() => _ffi.consentStatus(_handle));
  }

  Map<String, dynamic>? consentEffectiveState() {
    return _callJson(() => _ffi.consentEffectiveState(_handle));
  }

  bool consentNeedsTokenRefresh() =>
      _ffi.consentNeedsTokenRefresh(_handle) != 0;

  // ── Capabilities ─────────────────────────────────────────────────────

  bool loadCapabilityToken(String tokenJson, String secret) {
    final tj = tokenJson.toNativeUtf8();
    final s = secret.toNativeUtf8();
    try {
      return _ffi.loadCapabilityToken(_handle, tj.cast(), s.cast()) == 0;
    } finally {
      malloc.free(tj);
      malloc.free(s);
    }
  }

  // ── Queries ──────────────────────────────────────────────────────────

  List<dynamic>? listSessions() {
    final json = _readAndFree(_ffi.listSessions(_handle));
    if (json == null) return null;
    return jsonDecode(json) as List<dynamic>;
  }

  String? getSessionSummary(String sessionId) {
    return _withCString(sessionId, (p) {
      return _readAndFree(_ffi.getSessionSummary(_handle, p));
    });
  }

  List<dynamic>? getHsiWindows(
    String sessionId, {
    int startMs = 0,
    int endMs = 0,
    int limit = 0,
  }) {
    return _withCString(sessionId, (p) {
      final json = _readAndFree(
        _ffi.getHsiWindows(_handle, p, startMs, endMs, limit),
      );
      if (json == null) return null;
      return jsonDecode(json) as List<dynamic>;
    });
  }

  Map<String, dynamic>? getStorageUsage() {
    return _callJson(() => _ffi.getStorageUsage(_handle));
  }

  // ── Syni service (device-signed cloud chat + sessions) ────────────────

  /// Whether the linked runtime exports the complete Syni service ABI.
  /// Runtime 0.21.0 introduced this surface; older runtimes remain usable for
  /// every other Core feature and report Syni service as unsupported.
  bool get isSyniServiceAvailable =>
      !_disposed &&
      _ffi.syniChat != null &&
      _ffi.syniListSessions != null &&
      _ffi.syniGetSession != null &&
      _ffi.syniGetSessionMessages != null &&
      _ffi.syniCloseSession != null;

  Future<Map<String, dynamic>> syniChatJson(String requestJson) =>
      _runSyniJson(_SyniFfiOperation.chat, value: requestJson);

  Future<Map<String, dynamic>> syniListSessionsJson({int limit = 0}) =>
      _runSyniJson(_SyniFfiOperation.listSessions, limit: limit);

  Future<Map<String, dynamic>> syniGetSessionJson(String sessionId) =>
      _runSyniJson(_SyniFfiOperation.getSession, value: sessionId);

  Future<Map<String, dynamic>> syniGetSessionMessagesJson(
    String sessionId, {
    int limit = 0,
  }) => _runSyniJson(
    _SyniFfiOperation.getSessionMessages,
    value: sessionId,
    limit: limit,
  );

  Future<Map<String, dynamic>> syniCloseSessionJson(String sessionId) =>
      _runSyniJson(_SyniFfiOperation.closeSession, value: sessionId);

  /// Runs one blocking Syni HTTP call off the UI isolate. The raw handle is
  /// tracked through [_runFfi], so [dispose] cannot free it while a request is
  /// in flight. Native request and response strings are released on every
  /// path, including malformed JSON and server errors.
  Future<Map<String, dynamic>> _runSyniJson(
    _SyniFfiOperation operation, {
    String? value,
    int limit = 0,
  }) {
    if (_disposed) {
      return Future.value(const {
        'error': 'ERR_UNAVAILABLE: Synheart Core runtime is disposed',
      });
    }
    if (!isSyniServiceAvailable) {
      return Future.value(const {
        'error':
            'ERR_UNSUPPORTED: linked Synheart Core runtime does not expose '
            'the Syni service API (requires runtime 0.21.0+)',
      });
    }

    final handleAddress = _handle.address;
    return _runFfi(() {
      final ffi = SynheartCoreFFI.load();
      if (ffi == null) {
        return const <String, dynamic>{
          'error': 'ERR_UNAVAILABLE: Synheart Core runtime is unavailable',
        };
      }
      final handle = Pointer<Void>.fromAddress(handleAddress);
      Pointer<Utf8> output = nullptr;
      Pointer<Utf8>? input;
      try {
        switch (operation) {
          case _SyniFfiOperation.chat:
            final call = ffi.syniChat;
            if (call == null) return _syniUnsupportedEnvelope;
            input = (value ?? '').toNativeUtf8();
            output = call(handle, input);
            break;
          case _SyniFfiOperation.listSessions:
            final call = ffi.syniListSessions;
            if (call == null) return _syniUnsupportedEnvelope;
            output = call(handle, limit);
            break;
          case _SyniFfiOperation.getSession:
            final call = ffi.syniGetSession;
            if (call == null) return _syniUnsupportedEnvelope;
            input = (value ?? '').toNativeUtf8();
            output = call(handle, input);
            break;
          case _SyniFfiOperation.getSessionMessages:
            final call = ffi.syniGetSessionMessages;
            if (call == null) return _syniUnsupportedEnvelope;
            input = (value ?? '').toNativeUtf8();
            output = call(handle, input, limit);
            break;
          case _SyniFfiOperation.closeSession:
            final call = ffi.syniCloseSession;
            if (call == null) return _syniUnsupportedEnvelope;
            input = (value ?? '').toNativeUtf8();
            output = call(handle, input);
            break;
        }

        if (output == nullptr) {
          return const <String, dynamic>{
            'error': 'ERR_NETWORK: Syni service returned an empty response',
          };
        }
        final raw = output.toDartString();
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
        return <String, dynamic>{
          'error': 'ERR_NETWORK: Syni service returned non-object JSON',
        };
      } catch (error) {
        return <String, dynamic>{
          'error': 'ERR_NETWORK: Syni service call failed: $error',
        };
      } finally {
        if (input != null) malloc.free(input);
        if (output != nullptr) ffi.coreFreeString(output);
      }
    });
  }

  // ── Metrics ──────────────────────────────────────────────────────────

  bool recordMetric(Map<String, dynamic> event) {
    final json = jsonEncode(event);
    return _withCString(json, (p) => _ffi.recordMetric(_handle, p) == 0);
  }

  // ── Deletion ─────────────────────────────────────────────────────────

  bool deleteSession(String sessionId) {
    return _withCString(sessionId, (p) => _ffi.deleteSession(_handle, p) == 0);
  }

  /// Mark a stranded `state='active'` session as closed. Returns true on
  /// success (or when the session was already closed). Used by startup
  /// orphan-session sweeps.
  bool closeOrphanSession(String sessionId) {
    return _withCString(
      sessionId,
      (p) => _ffi.closeOrphanSession(_handle, p) == 0,
    );
  }

  bool wipeLocalData() => _ffi.wipeLocalData(_handle) == 0;

  int setRetentionDays(int days) => _ffi.setRetentionDays(_handle, days);

  // ── Sync ─────────────────────────────────────────────────────────────

  void setSyncEnabled(bool enabled) =>
      _ffi.setSyncEnabled(_handle, enabled ? 1 : 0);

  /// Run one envelope-returning sync FFI call away from the UI isolate.
  ///
  /// The raw envelope is decoded in the worker isolate, then unwrapped here so
  /// [SyncNativeException] retains its concrete type. All calls share
  /// [_syncOperationQueue] because the native sync engine is stateful and a
  /// roster read must not race a sync or space mutation on the same handle.
  Future<Map<String, dynamic>?> _runBackgroundSyncEnvelope(
    _SyncFfiOperation operation, {
    String firstArg = '',
    String secondArg = '',
    bool throwOnWorkerFailure = false,
  }) {
    return _syncOperationQueue.run(() async {
      if (_disposed) return null;
      final handleAddr = _handle.address;
      final invocation = _SyncFfiInvocation(
        handleAddr: handleAddr,
        operation: operation,
        firstArg: firstArg,
        secondArg: secondArg,
      );
      final Map<String, dynamic>? raw;
      try {
        raw = await _runFfi(invocation.call);
      } catch (error, stackTrace) {
        SynheartLogger.log(
          '[Synheart Sync FFI] Could not start/receive worker for '
          '${operation.name}.',
          name: 'synheart.sync.ffi',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
      final workerFailure = raw?[_syncFfiWorkerFailureKey];
      if (workerFailure != null) {
        SynheartLogger.log(
          '[Synheart Sync FFI] ${operation.name} failed in worker: '
          '$workerFailure; type=${raw?['error_type']}; '
          'message=${raw?['error_message']}',
          name: 'synheart.sync.ffi',
        );
        if (throwOnWorkerFailure) {
          throw SyncNativeException(
            SyncNativeError(
              code: 'SDK_FFI_WORKER_FAILURE',
              message: 'The native Device Sync worker could not run.',
              reason: 'misconfigured',
              detail: <String, dynamic>{
                'operation': operation.name,
                'worker_failure': workerFailure,
                if (raw?['error_type'] != null)
                  'error_type': raw?['error_type'],
                if (raw?['error_message'] != null)
                  'error_message': raw?['error_message'],
              },
            ),
          );
        }
        return null;
      }
      return unwrapSyncEnvelope(raw);
    });
  }

  // ── Ambient capture ─────────────────────────────────────────────────

  /// Toggle the runtime's out-of-session HSI emission gate. When off
  /// (the default), the runtime forwards HSI windows only while a
  /// session is active; when on, it forwards every window. Hosts use
  /// this to drop the FFI fan-out cost on the background-capture
  /// path when the participant has revoked or paused ambient consent.
  void setAmbientCapture(bool enabled) =>
      _ffi.setAmbientCapture(_handle, enabled ? 1 : 0);

  /// Read the runtime's ambient-capture gate. `true` when the gate
  /// is on. Useful for diagnostics — Mirror's own
  /// `AmbientCaptureService` is the source of truth for the
  /// app-side flag.
  bool getAmbientCapture() => _ffi.getAmbientCapture(_handle) != 0;

  /// Run a sync cycle (push + pull). This performs a blocking network
  /// round-trip in the native runtime, so it runs on a background isolate
  /// (`_runFfi`) rather than `_callJson` — calling it inline on the UI isolate
  /// froze the main thread until the request completed/timed out (a
  /// user-triggered ANR on the manual-sync path, and a stall on the periodic
  /// path). Returns null when the bridge is disposed or the engine isn't wired.
  Future<Map<String, dynamic>?> syncNow() =>
      _runBackgroundSyncEnvelope(_SyncFfiOperation.syncNow);

  /// Create a new sync-space on the cloud and become its first
  /// device. Returns `{sync_space_id, recovery_key}` — the recovery
  /// key is the SRK fragment the user must store; without it a lost
  /// device cannot rejoin. Returns null when the engine isn't wired.
  Future<Map<String, dynamic>?> syncCreateSpace({String? deviceName}) {
    return _runBackgroundSyncEnvelope(
      _SyncFfiOperation.createSpace,
      firstArg: deviceName ?? '',
    );
  }

  /// Generate a short-lived pairing token on the current sync-space.
  /// Returns `{token, expires_in}` — show the token to the user so a
  /// second device can call [syncJoinSpace] with it.
  Future<Map<String, dynamic>?> syncGeneratePairing() =>
      _runBackgroundSyncEnvelope(_SyncFfiOperation.generatePairing);

  /// Join an existing sync-space using a pairing token from
  /// [syncGeneratePairing]. Returns `{sync_space_id, status}` on
  /// success. The new device becomes the second member of the space
  /// and the next [syncNow] will pull every artifact the originator
  /// has pushed.
  Future<Map<String, dynamic>?> syncJoinSpace({
    required String pairingToken,
    String? deviceName,
  }) {
    return _runBackgroundSyncEnvelope(
      _SyncFfiOperation.joinSpace,
      firstArg: pairingToken,
      secondArg: deviceName ?? '',
    );
  }

  /// Snapshot of the sync-engine state: `{enabled, sync_space_id,
  /// device_count}`. Use for the "paired with N devices" UI line.
  Map<String, dynamic>? syncStatus() {
    return _callSyncEnvelope(() => _ffi.syncStatus(_handle));
  }

  /// Unified native sync-readiness snapshot: individual prerequisite booleans
  /// (`configured`, `storage_present`, `device_registered`, `engine_ready`,
  /// `active_space`, `srk_ready`, …) plus one primary `state` — the first
  /// unmet gate in priority order (`CONFIGURATION_MISSING`,
  /// `STORAGE_UNAVAILABLE`, `DEVICE_REVOKED`, `DEVICE_REGISTRATION_REQUIRED`,
  /// `ENGINE_NOT_INITIALIZED`, `NO_ACTIVE_SPACE`, `SRK_UNAVAILABLE`, `READY`).
  /// Use `state` for UI/logs instead of inferring readiness from separate
  /// checks. Cloud-upload consent is intentionally excluded — the host owns
  /// that gate. Null when the runtime bridge isn't wired.
  Map<String, dynamic>? syncReadiness() {
    return _callSyncEnvelope(() => _ffi.syncReadiness(_handle));
  }

  /// Recover access to a sync-space on a fresh device using the
  /// recovery key (SRK fragment) issued at creation plus the target
  /// space id. Returns `{sync_space_id, owner_user_id, status}` on
  /// success. Returns null when the engine isn't wired.
  Future<Map<String, dynamic>?> syncRecoverSpace({
    required String recoveryKey,
    required String spaceId,
  }) {
    return _runBackgroundSyncEnvelope(
      _SyncFfiOperation.recoverSpace,
      firstArg: recoveryKey,
      secondArg: spaceId,
    );
  }

  /// Leave the current sync-space for this device only. Returns
  /// `{ok: true}` on success. Returns null when the engine isn't wired.
  Future<Map<String, dynamic>?> syncLeaveSpace() =>
      _runBackgroundSyncEnvelope(_SyncFfiOperation.leaveSpace);

  /// List the devices paired into the current sync-space. Returns
  /// `{devices: [{device_id, device_name, is_primary, trusted_at,
  /// last_seen_at, revoked}, …]}`. Returns null when the engine
  /// isn't wired.
  Future<Map<String, dynamic>?> syncListDevices() =>
      _runBackgroundSyncEnvelope(_SyncFfiOperation.listDevices);

  /// Revoke a specific device from the current sync-space by its
  /// `device_id`. Returns `{ok: true}` on success. Returns null when
  /// the engine isn't wired.
  Future<Map<String, dynamic>?> syncRevokeDevice({required String deviceId}) {
    return _runBackgroundSyncEnvelope(
      _SyncFfiOperation.revokeDevice,
      firstArg: deviceId,
    );
  }

  /// Delete the current sync-space entirely (all devices, cloud
  /// state). Returns `{ok: true}` on success. Returns null when the
  /// engine isn't wired.
  Future<Map<String, dynamic>?> syncDeleteSpace() =>
      _runBackgroundSyncEnvelope(_SyncFfiOperation.deleteSpace);

  /// Clear only LOCAL sync-space state — the "start over on this device"
  /// path. Does NOT touch the server (this device stays a member remotely);
  /// use [syncLeaveSpace] to also remove it server-side. Returns `{ok: true}`
  /// on success, null when the engine isn't wired.
  Future<Map<String, dynamic>?> syncClearLocalSpace() =>
      _runBackgroundSyncEnvelope(_SyncFfiOperation.clearLocalSpace);

  // ── Vendor Events ────────────────────────────────────────────────────

  /// Ingest a canonical vendor event (JSON map from CanonicalWearableEvent.toMap()).
  bool ingestVendorEvent(String eventJson) {
    return _withCString(
      eventJson,
      (p) => _ffi.ingestVendorEvent(_handle, p) == 0,
    );
  }

  /// Query stored vendor events. Returns parsed JSON list, or null on error.
  List<dynamic>? queryVendorEvents({
    String? provider,
    String? type,
    int? startMs,
    int? endMs,
    int limit = 100,
  }) {
    final query = jsonEncode({
      if (provider != null) 'provider': provider,
      if (type != null) 'type': type,
      if (startMs != null) 'start_ms': startMs,
      if (endMs != null) 'end_ms': endMs,
      'limit': limit,
    });
    return _withCString(query, (p) {
      final json = _readAndFree(_ffi.queryVendorEvents(_handle, p));
      if (json == null) return null;
      final list = jsonDecode(json) as List<dynamic>;
      // The runtime persists `payload` as a JSON string (see
      // CanonicalWearableEvent.toMap). Decode it back into a Map so callers
      // receive a fully-decoded event — matches the documented contract on
      // [Synheart.queryVendorEvents].
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          final raw = item['payload'];
          if (raw is String && raw.isNotEmpty) {
            try {
              item['payload'] = jsonDecode(raw);
            } catch (_) {
              // Leave as-is; consumers can still inspect the string.
            }
          }
        }
      }
      return list;
    });
  }

  /// Get the latest vendor event for a provider + type. Returns JSON map or null.
  Map<String, dynamic>? getLatestVendorEvent(String provider, String type) {
    final pProv = provider.toNativeUtf8();
    final pType = type.toNativeUtf8();
    try {
      final json = _readAndFree(
        _ffi.getLatestVendorEvent(_handle, pProv.cast(), pType.cast()),
      );
      if (json == null) return null;
      final map = jsonDecode(json) as Map<String, dynamic>;
      // Decode the nested `payload` JSON string for the documented contract.
      final raw = map['payload'];
      if (raw is String && raw.isNotEmpty) {
        try {
          map['payload'] = jsonDecode(raw);
        } catch (_) {
          // Leave as-is.
        }
      }
      return map;
    } finally {
      malloc.free(pProv);
      malloc.free(pType);
    }
  }

  /// Delete all vendor events for a provider. Returns deleted count, or -1 on error.
  int deleteVendorEventsForProvider(String provider) {
    return _withCString(
      provider,
      (p) => _ffi.deleteVendorEventsForProvider(_handle, p),
    );
  }

  // ── SRM / Baselines ──────────────────────────────────────────────────

  String? baselinesJson() => _readAndFree(_ffi.baselinesJson(_handle));
  String? exportSrmSnapshot() => _readAndFree(_ffi.exportSrmSnapshot(_handle));

  bool loadSrmSnapshot(String json) {
    return _withCString(json, (p) => _ffi.loadSrmSnapshot(_handle, p) == 0);
  }

  Map<String, dynamic>? srmOverallStatus() {
    return _callJson(() => _ffi.srmOverallStatus(_handle));
  }

  // ── Cloud ────────────────────────────────────────────────────────────

  void enqueueHsi(String hsiJson, int timestampMs) {
    _withCString(hsiJson, (p) => _ffi.enqueueHsi(_handle, p, timestampMs));
  }

  int get uploadQueueLength => _ffi.uploadQueueLength(_handle);

  /// Wall-clock timestamp (Unix ms) of the most recent successful
  /// ingest upload. Returns null when nothing has uploaded yet in
  /// this process. Hosts use this to render a "Synced / Syncing /
  /// Pending" pill instead of exposing raw queue counts.
  int? get lastIngestSuccessAtMs {
    final ms = _ffi.lastIngestSuccessAtMs(_handle);
    return ms == 0 ? null : ms;
  }

  /// Flush the outbound ingest queue to the cloud.
  ///
  /// Runs on a background isolate: the native `flush_uploads` performs its HTTP
  /// round-trip synchronously, so calling it on the UI isolate blocks the main
  /// thread for the length of the request — unbounded on a slow or dead
  /// network.
  ///
  /// Returns null when the bridge is disposed, the symbol is unavailable, or
  /// the native call failed.
  Future<Map<String, dynamic>?> flushUploads() async {
    if (_disposed) return null;
    final handleAddr = _handle.address;
    return _runFfi(() {
      final ffi = SynheartCoreFFI.load();
      if (ffi == null) return null;
      final handle = Pointer<Void>.fromAddress(handleAddr);
      try {
        final ptr = ffi.flushUploads(handle);
        if (ptr == nullptr) return null;
        final raw = ptr.toDartString();
        ffi.coreFreeString(ptr);
        final decoded = jsonDecode(raw);
        return decoded is Map<String, dynamic> ? decoded : null;
      } catch (_) {
        return null;
      }
    });
  }

  Map<String, dynamic>? uploadMetadata() {
    return _callJson(() => _ffi.uploadMetadata(_handle));
  }

  // ── HSI history (on-device mirror of uploaded payloads) ─────────────
  //
  // Populated by the ingest connector on HTTP 200, archiving each
  // HSI chunk to the local history mirror. Retention is age-based
  // (default 30 days). Returns empty / 0 when the runtime has no cloud
  // connector configured.

  /// List archived HSI payloads in upload order (oldest first).
  ///
  /// - [since]: filter rows uploaded at or after this instant.
  /// - [limit]: cap the returned count; `null` or `0` means unbounded.
  List<Map<String, dynamic>> hsiHistoryList({DateTime? since, int? limit}) {
    if (_disposed) return const [];
    final sinceMs = since?.millisecondsSinceEpoch ?? 0;
    final lim = (limit ?? 0).clamp(0, 1 << 31);
    final ptr = _ffi.hsiHistoryList(_handle, sinceMs, lim);
    final raw = _readAndFree(ptr);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<Map<String, dynamic>>().toList(
          growable: false,
        );
      }
    } catch (_) {}
    return const [];
  }

  /// Fetch archived HSI windows from the cloud archive for `[fromMs, toMs]`
  /// (epoch ms). Each map is a full HSI window payload exactly as archived (any
  /// HSI version) — the host parses it with the same path it uses for local
  /// windows. Returns empty on error, when no cloud connector is configured, or
  /// when the native symbol is absent (older vendored lib).
  ///
  /// The FFI call performs blocking network I/O, so it runs on a background
  /// isolate (mirroring [sdkRegisterDevice]); on the UI isolate it would block
  /// the main thread for the length of the request.
  Future<List<Map<String, dynamic>>> fetchCloudHsiWindows({
    required int fromMs,
    required int toMs,
  }) async {
    if (_disposed) return const [];
    final handleAddr = _handle.address;
    // Guard the symbol lookup + call: a vendored lib that predates this FFI
    // export throws ArgumentError on first `fetchCloudHsi` access. Treat a
    // missing symbol (or any FFI/parse failure) as "no cloud data".
    return _runFfi(() {
      final ffi = SynheartCoreFFI.load();
      if (ffi == null) return const <Map<String, dynamic>>[];
      final handle = Pointer<Void>.fromAddress(handleAddr);
      try {
        final ptr = ffi.fetchCloudHsi(handle, fromMs, toMs);
        if (ptr == nullptr) return const <Map<String, dynamic>>[];
        final raw = ptr.toDartString();
        ffi.coreFreeString(ptr);
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded.whereType<Map<String, dynamic>>().toList(
            growable: false,
          );
        }
      } catch (_) {}
      return const <Map<String, dynamic>>[];
    });
  }

  /// Number of archived HSI payloads on-device. Returns `0` on error.
  int hsiHistoryCount() {
    if (_disposed) return 0;
    final n = _ffi.hsiHistoryCount(_handle);
    return n < 0 ? 0 : n;
  }

  /// Wipe on-device HSI history. Intended for user-initiated
  /// "delete my data" flows. Returns true on success.
  bool hsiHistoryClear() {
    if (_disposed) return false;
    return _ffi.hsiHistoryClear(_handle) == 0;
  }

  // ── Wellness Score ───────────────────────────────────────────────────

  /// Get the last Wellness Score as JSON, or null if baselines are not ready.
  String? wellnessJson() => _readAndFree(_ffi.wellnessJson(_handle));

  String? lastFeatures() => _readAndFree(_ffi.lastFeatures(_handle));

  // ── Diagnostics ──────────────────────────────────────────────────────

  String? diagnostics() => _readAndFree(_ffi.diagnostics(_handle));
  int get lastErrorCode => _ffi.lastErrorCode(_handle);
  bool get isRuntimeAvailable => _ffi.isRuntimeAvailable(_handle) != 0;
  bool get isNetworkReachable => _ffi.isNetworkReachable(_handle) != 0;

  // ── Account ──────────────────────────────────────────────────────────

  bool requestAccountDeletion() => _ffi.requestAccountDeletion(_handle) == 0;
  bool cancelAccountDeletion() => _ffi.cancelAccountDeletion(_handle) == 0;

  // ── Customer-facing data deletion (GDPR Article 17) ─────────────────

  /// Request cloud-side deletion of every byte the platform holds for the
  /// currently-bound subject (the value derived from your `client_id` at
  /// register time). Returns the persisted request row as parsed JSON, or
  /// `{"error": "..."}` if the call failed.
  ///
  /// `reason` and `contact` are optional — both land in the audit row
  /// metadata so operators can correlate later. `dryRun=true` exercises the
  /// auth + persistence path without running the actual purge.
  ///
  /// Runs on a background isolate; the underlying HTTPS call can block.
  Future<Map<String, dynamic>?> requestDataDeletion({
    String? reason,
    String? contact,
    bool dryRun = false,
  }) async {
    if (_disposed) return null;
    final handleAddr = _handle.address;
    return _runFfi(() {
      final ffi = SynheartCoreFFI.load();
      if (ffi == null) return null;
      final handle = Pointer<Void>.fromAddress(handleAddr);
      final reasonPtr = (reason == null || reason.isEmpty)
          ? nullptr
          : reason.toNativeUtf8();
      final contactPtr = (contact == null || contact.isEmpty)
          ? nullptr
          : contact.toNativeUtf8();
      try {
        final resPtr = ffi.requestDataDeletion(
          handle,
          reasonPtr.cast(),
          contactPtr.cast(),
          dryRun,
        );
        if (resPtr == nullptr) return null;
        final str = resPtr.toDartString();
        ffi.coreFreeString(resPtr);
        return jsonDecode(str) as Map<String, dynamic>;
      } catch (_) {
        return null;
      } finally {
        if (reasonPtr != nullptr) malloc.free(reasonPtr);
        if (contactPtr != nullptr) malloc.free(contactPtr);
      }
    });
  }

  /// Poll the status of a deletion request. `status` transitions through
  /// pending → in_progress → completed (or failed). On success the `result`
  /// field carries per-layer purge stats from the server.
  Future<Map<String, dynamic>?> getDataDeletion(String requestId) async {
    if (_disposed) return null;
    final handleAddr = _handle.address;
    return _runFfi(() {
      final ffi = SynheartCoreFFI.load();
      if (ffi == null) return null;
      final handle = Pointer<Void>.fromAddress(handleAddr);
      final idPtr = requestId.toNativeUtf8();
      try {
        final resPtr = ffi.getDataDeletion(handle, idPtr.cast());
        if (resPtr == nullptr) return null;
        final str = resPtr.toDartString();
        ffi.coreFreeString(resPtr);
        return jsonDecode(str) as Map<String, dynamic>;
      } catch (_) {
        return null;
      } finally {
        malloc.free(idPtr);
      }
    });
  }

  // ── Baseline local bridge ──────────────────────────────────────────
  //
  // Cross-device baseline transport rides the existing sync engine
  // (`/v1/sync/`); there's no separate baseline cloud bridge here.

  /// Read the latest locally-persisted baseline envelope per kind
  /// (synchronous on-device SQLite read + decryption — no network).
  /// Returns `{snapshots: [...]}` so the Dart-side facade can parse
  /// envelopes uniformly. Null when the runtime binary doesn't ship
  /// the symbol.
  Future<Map<String, dynamic>?> baselineHydrateLocal() async {
    if (_disposed) return null;
    final handleAddr = _handle.address;
    return _runFfi(() {
      final ffi = SynheartCoreFFI.load();
      if (ffi == null) return null;
      final fn = ffi.baselineHydrateLocal;
      if (fn == null) return null;
      final handle = Pointer<Void>.fromAddress(handleAddr);
      try {
        final resPtr = fn(handle);
        if (resPtr == nullptr) return null;
        final str = resPtr.toDartString();
        ffi.coreFreeString(resPtr);
        return jsonDecode(str) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    });
  }

  /// Encrypt every cached baseline envelope into a passphrase-keyed
  /// offline blob (`.srm.synheart`). Returns the raw bytes ready for
  /// the OS share sheet, or null when the runtime binary doesn't
  /// ship the FFI / no envelopes are cached / the passphrase is
  /// empty.
  Future<Uint8List?> baselineExportOffline({required String passphrase}) async {
    if (_disposed) return null;
    final handleAddr = _handle.address;
    return _runFfi(() {
      final ffi = SynheartCoreFFI.load();
      if (ffi == null) return null;
      final fn = ffi.baselineExportOffline;
      if (fn == null) return null;
      final handle = Pointer<Void>.fromAddress(handleAddr);
      final passPtr = passphrase.toNativeUtf8();
      try {
        final resPtr = fn(handle, passPtr.cast());
        if (resPtr == nullptr) return null;
        final str = resPtr.toDartString();
        ffi.coreFreeString(resPtr);
        final decoded = jsonDecode(str) as Map<String, dynamic>;
        if (decoded['error'] is String) return null;
        final b64 = decoded['blob_b64'] as String?;
        if (b64 == null) return null;
        return base64Decode(b64);
      } catch (_) {
        return null;
      } finally {
        malloc.free(passPtr);
      }
    });
  }

  /// Decrypt + import a `.srm.synheart` blob into local storage.
  /// Returns `{imported, skipped, errors, kinds, exporter_device_id,
  /// created_at_ms}`. Null when the runtime binary doesn't ship the
  /// FFI; an `{"error": ...}` map for wrong passphrase / tampered blob.
  Future<Map<String, dynamic>?> baselineImportOffline({
    required String passphrase,
    required Uint8List blob,
  }) async {
    if (_disposed) return null;
    final handleAddr = _handle.address;
    final blobB64 = base64Encode(blob);
    return _runFfi(() {
      final ffi = SynheartCoreFFI.load();
      if (ffi == null) return null;
      final fn = ffi.baselineImportOffline;
      if (fn == null) return null;
      final handle = Pointer<Void>.fromAddress(handleAddr);
      final passPtr = passphrase.toNativeUtf8();
      final blobPtr = blobB64.toNativeUtf8();
      try {
        final resPtr = fn(handle, passPtr.cast(), blobPtr.cast());
        if (resPtr == nullptr) return null;
        final str = resPtr.toDartString();
        ffi.coreFreeString(resPtr);
        return jsonDecode(str) as Map<String, dynamic>;
      } catch (_) {
        return null;
      } finally {
        malloc.free(passPtr);
        malloc.free(blobPtr);
      }
    });
  }

  /// List recent deletion requests for this caller's org. Mostly useful for
  /// dashboards / audit views; most apps will only call
  /// [requestDataDeletion] + [getDataDeletion].
  Future<Map<String, dynamic>?> listDataDeletions({
    int limit = 20,
    int offset = 0,
  }) async {
    if (_disposed) return null;
    final handleAddr = _handle.address;
    return _runFfi(() {
      final ffi = SynheartCoreFFI.load();
      if (ffi == null) return null;
      final handle = Pointer<Void>.fromAddress(handleAddr);
      try {
        final resPtr = ffi.listDataDeletions(handle, limit, offset);
        if (resPtr == nullptr) return null;
        final str = resPtr.toDartString();
        ffi.coreFreeString(resPtr);
        return jsonDecode(str) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    });
  }

  // ── Stream (RAMEN vendor sync) ─────────────────────────────────────

  NativeCallable<Void Function(Pointer<Utf8>, Pointer<Void>)>? _streamCallable;

  /// Start the RAMEN streaming connection.
  ///
  /// [config] must include: `host`, `port`, `app_id`, `device_id`, `user_id`.
  /// Optional: `api_key`, `use_tls`, `providers`, `event_types`.
  int startStream(Map<String, dynamic> config) {
    final json = jsonEncode(config);
    return _withCString(json, (p) => _ffi.streamStart(_handle, p));
  }

  /// Stop the RAMEN streaming connection.
  int stopStream() => _ffi.streamStop(_handle);

  /// Register a callback for RAMEN stream events.
  ///
  /// The [onEvent] function receives raw event JSON for each vendor event.
  /// Uses the same NativeCallable.listener pattern as HSI callback.
  void setStreamCallback(void Function(String eventJson) onEvent) {
    clearStreamCallback();

    void nativeCallback(Pointer<Utf8> jsonPtr, Pointer<Void> _) {
      if (jsonPtr == nullptr) return;
      final text = _readFfiStringAndFree(jsonPtr, _ffi.coreFreeString);
      if (text != null) onEvent(text);
    }

    _streamCallable =
        NativeCallable<Void Function(Pointer<Utf8>, Pointer<Void>)>.listener(
          nativeCallback,
        );
    _ffi.setStreamCallback(_handle, _streamCallable!.nativeFunction, nullptr);
  }

  /// Unregister the stream callback.
  ///
  /// Retires the trampoline rather than closing it — see [_retiredCallables].
  void clearStreamCallback() {
    if (_streamCallable != null) {
      _retiredCallables.add(_streamCallable!);
      _streamCallable = null;
    }
  }

  /// Get the current stream connection state.
  String? streamState() => _readAndFree(_ffi.streamState(_handle));

  // ── HSI state callback ──────────────────────────────────────────────

  NativeCallable<Void Function(Pointer<Utf8>, Pointer<Void>)>? _hsiCallable;

  /// Register a callback for real-time HSI state updates.
  ///
  /// The [onHsi] function is called on each HSI frame (typically 1Hz during
  /// an active session) with the raw JSON string.
  ///
  /// Only one callback can be active. Call [clearHsiCallback] to unregister.
  void setHsiCallback(void Function(String hsiJson) onHsi) {
    clearHsiCallback();

    void nativeCallback(Pointer<Utf8> jsonPtr, Pointer<Void> _) {
      if (jsonPtr == nullptr) return;
      final text = _readFfiStringAndFree(jsonPtr, _ffi.coreFreeString);
      if (text != null) onHsi(text);
    }

    _hsiCallable =
        NativeCallable<Void Function(Pointer<Utf8>, Pointer<Void>)>.listener(
          nativeCallback,
        );
    _ffi.setHsiCallback(_handle, _hsiCallable!.nativeFunction, nullptr);
  }

  /// Unregister the HSI callback.
  ///
  /// Tells the runtime to stop dispatching, then retires the trampoline rather
  /// than closing it — see [_retiredCallables].
  void clearHsiCallback() {
    if (_hsiCallable != null) {
      _ffi.clearHsiCallback(_handle);
      _retiredCallables.add(_hsiCallable!);
      _hsiCallable = null;
    }
  }

  // ── Lab ──────────────────────────────────────────────────────────────

  /// Whether the lab C ABI symbols are available.
  bool get isLabAvailable => _ffi.labAvailable(_handle) != 0;

  /// Start a lab session. Returns `null` on success, or a short error
  /// string identifying the failure code from the runtime.
  ///
  /// The runtime FFI returns `c_int`: `0` on success, `1` on
  /// `"Lab session already active"`, and other small integers for other
  /// validation failures. We surface non-zero codes as
  /// `"lab_start: error code N"` so callers (e.g. Mirror's
  /// `MirrorLabSessionManager`) can distinguish success from failure
  /// without having to interpret the raw integer.
  String? labStart(String protocolJson, int startedAtMs) {
    return _withCString(protocolJson, (p) {
      final rc = _ffi.labStart(_handle, p, startedAtMs);
      if (rc == 0) return null;
      return 'lab_start: error code $rc';
    });
  }

  /// Open a window in the active lab session. Returns the window ID.
  String? labOpenWindow(
    String? parentId,
    String windowType,
    String? label,
    int startedAtMs,
  ) {
    final pParent = (parentId ?? '').toNativeUtf8();
    final pType = windowType.toNativeUtf8();
    final pLabel = (label ?? '').toNativeUtf8();
    try {
      return _readAndFree(
        _ffi.labOpenWindow(
          _handle,
          pParent.cast(),
          pType.cast(),
          pLabel.cast(),
          startedAtMs,
        ),
      );
    } finally {
      malloc.free(pParent);
      malloc.free(pType);
      malloc.free(pLabel);
    }
  }

  /// Close a window in the active lab session.
  bool labCloseWindow(String windowId, int endedAtMs) {
    return _withCString(
      windowId,
      (p) => _ffi.labCloseWindow(_handle, p, endedAtMs) == 0,
    );
  }

  /// Set protocol-specific values on a lab window.
  bool labSetWindowValues(String windowId, String valuesJson) {
    final pId = windowId.toNativeUtf8();
    final pJson = valuesJson.toNativeUtf8();
    try {
      return _ffi.labSetWindowValues(_handle, pId.cast(), pJson.cast()) == 0;
    } finally {
      malloc.free(pId);
      malloc.free(pJson);
    }
  }

  /// Merge session-level metadata into extra_data. Returns null on success,
  /// or `'lab_merge_extra_data: error code N'` when the runtime rejected
  /// the patch (e.g. no active lab session, malformed JSON).
  String? labMergeExtraData(String patchJson) {
    return _withCString(patchJson, (p) {
      final rc = _ffi.labMergeExtraData(_handle, p);
      if (rc == 0) return null;
      return 'lab_merge_extra_data: error code $rc';
    });
  }

  /// Set per-window state-data overrides.
  bool labSetStateOverrides(String windowId, String overridesJson) {
    final pId = windowId.toNativeUtf8();
    final pJson = overridesJson.toNativeUtf8();
    try {
      return _ffi.labSetStateOverrides(_handle, pId.cast(), pJson.cast()) == 0;
    } finally {
      malloc.free(pId);
      malloc.free(pJson);
    }
  }

  /// Finalize the lab session. Returns the complete payload JSON.
  String? labFinalize(int endedAtMs) {
    return _readAndFree(_ffi.labFinalize(_handle, endedAtMs));
  }

  /// Get the last lab export JSON (populated after session end in research mode).
  String? labExportJson() => _readAndFree(_ffi.labExportJson(_handle));

  /// Whether the runtime exports the lab re-enqueue symbol
  /// (`synheart_core_reenqueue_lab_session`, engine v0.8.1+). Older
  /// runtime binaries return false; callers can fall back to running
  /// a fresh session.
  bool get isLabReenqueueAvailable => _ffi.labReenqueueSession != null;

  /// Re-enqueue a previously-finalized lab session JSON for cloud upload.
  ///
  /// Used to retry sessions whose initial upload was dropped on a 4xx
  /// (typically a cloud schema mismatch — the runtime deletes those rows
  /// from the upload queue per `ingest/hsi/connector.rs`). Read the
  /// persisted payload from `lab_payloads` SQLite (or your host-side
  /// equivalent) and pass it back here.
  ///
  /// Return codes mirror the underlying FFI:
  ///   * [LabReenqueueResult.queued] — payload queued; HTTP happens async
  ///   * [LabReenqueueResult.researchNotAllowed] — research consent not granted
  ///   * [LabReenqueueResult.cloudNotConfigured] — no cloud connector
  ///   * [LabReenqueueResult.parseError] — supplied JSON did not parse
  ///   * [LabReenqueueResult.invalidArgument] — null handle / empty JSON
  ///   * [LabReenqueueResult.unsupported] — runtime binary doesn't export
  ///     the symbol; rebuild against engine v0.8.1+
  LabReenqueueResult labReenqueueSession(String sessionJson) {
    final fn = _ffi.labReenqueueSession;
    if (fn == null) return LabReenqueueResult.unsupported;
    final ptr = sessionJson.toNativeUtf8();
    try {
      final code = fn(_handle, ptr);
      return LabReenqueueResult.fromCode(code);
    } finally {
      malloc.free(ptr);
    }
  }

  // ── Lab metadata ───────────────────────────────────────────────────

  /// Whether the runtime exports the lab metadata symbols (older builds may not).
  bool get isLabMetadataAvailable => _ffi.labEnsureMetadata != null;

  /// Build the metadata payload from current config + caller-supplied device
  /// and user info, then upload it if the canonical hash differs from the
  /// cached copy or the dirty flag is set. Returns the active `meta_id`, or
  /// null on error.
  ///
  /// Blocks the calling thread; run this off the UI thread (the bootstrapper
  /// already does so during app start). Both `userInfoJson` and
  /// `deviceExtraJson` may be null.
  String? labEnsureMetadata({
    required String deviceId,
    required String platform,
    required String osVersion,
    String? userInfoJson,
    String? deviceExtraJson,
  }) {
    final fn = _ffi.labEnsureMetadata;
    if (fn == null) return null;
    final pDev = deviceId.toNativeUtf8();
    final pPlat = platform.toNativeUtf8();
    final pOs = osVersion.toNativeUtf8();
    final pUser = (userInfoJson ?? '').toNativeUtf8();
    final pExtra = (deviceExtraJson ?? '').toNativeUtf8();
    try {
      return _readAndFree(
        fn(
          _handle,
          pDev.cast(),
          pPlat.cast(),
          pOs.cast(),
          pUser.cast(),
          pExtra.cast(),
        ),
      );
    } finally {
      malloc.free(pDev);
      malloc.free(pPlat);
      malloc.free(pOs);
      malloc.free(pUser);
      malloc.free(pExtra);
    }
  }

  /// Mark the cached lab metadata as needing re-upload (profile edit, device
  /// swap, app version bump, consent change). The next [labEnsureMetadata]
  /// call will POST regardless of hash.
  bool labMarkMetadataDirty(String reason) {
    final fn = _ffi.labMarkMetadataDirty;
    if (fn == null) return false;
    return _withCString(reason, (p) => fn(_handle, p) == 0);
  }

  /// Cached `meta_id` to stamp on lab sessions, or null if nothing is cached.
  String? labCurrentMetadataId() {
    final fn = _ffi.labCurrentMetadataId;
    if (fn == null) return null;
    return _readAndFree(fn(_handle));
  }

  // ── Build info / Version ────────────────────────────────────────────

  /// All synheart crate versions, target, profile, and features as JSON.
  /// No handle needed — compile-time info.
  static Map<String, dynamic>? buildInfo() {
    final ffi = SynheartCoreFFI.load();
    if (ffi == null) return null;
    final ptr = ffi.buildInfo();
    if (ptr == nullptr) return null;
    final json = ptr.toDartString();
    ffi.coreFreeString(ptr);
    try {
      return jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// The native synheart-engine version string, or null.
  static String? version() {
    final ffi = SynheartCoreFFI.load();
    if (ffi == null || ffi.version == null) return null;
    final ptr = ffi.version!();
    if (ptr == nullptr) return null;
    final str = ptr.toDartString();
    ffi.coreFreeString(ptr);
    return str;
  }

  /// Number of HSI frames produced in the current session.
  int frameCount() => _ffi.frameCount(_handle);

  // ── Internal helpers ─────────────────────────────────────────────────

  /// Read a C string pointer, convert to Dart String, and free it.
  String? _readAndFree(Pointer<Utf8> ptr) {
    if (ptr == nullptr) return null;
    final str = ptr.toDartString();
    _ffi.coreFreeString(ptr);
    return str;
  }

  /// Call a function that returns a JSON pointer, parse it as a Map.
  Map<String, dynamic>? _callJson(Pointer<Utf8> Function() fn) {
    final json = _readAndFree(fn());
    if (json == null) return null;
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// Call a sync FFI function and unwrap the response envelope.
  ///
  /// See [unwrapSyncEnvelope] — success returns the `data` map, a failure
  /// envelope throws [SyncNativeException], and a legacy bare payload (from an
  /// older vendored native lib) is passed through unchanged.
  Map<String, dynamic>? _callSyncEnvelope(Pointer<Utf8> Function() fn) {
    return unwrapSyncEnvelope(_callJson(fn));
  }

  /// Allocate a native UTF-8 string, call the function, then free it.
  T _withCString<T>(String s, T Function(Pointer<Utf8>) fn) {
    final ptr = s.toNativeUtf8();
    try {
      return fn(ptr.cast());
    } finally {
      malloc.free(ptr);
    }
  }
}

enum _SyniFfiOperation {
  chat,
  listSessions,
  getSession,
  getSessionMessages,
  closeSession,
}

const Map<String, dynamic> _syniUnsupportedEnvelope = {
  'error':
      'ERR_UNSUPPORTED: linked Synheart Core runtime does not expose the '
      'Syni service API (requires runtime 0.21.0+)',
};

/// Result of a [CoreRuntimeBridge.labReenqueueSession] call. Mirrors
/// the return codes from the underlying
/// `synheart_core_reenqueue_lab_session` FFI.
enum LabReenqueueResult {
  /// Payload queued for upload (HTTP happens async on the same flush
  /// cadence as HSI).
  queued,

  /// Research consent is not granted for this session — caller must
  /// re-prompt or upgrade the consent tier before retrying.
  researchNotAllowed,

  /// No cloud connector is configured (SDK not initialized with
  /// `cloudConfig`).
  cloudNotConfigured,

  /// The supplied JSON did not parse. Treat the row as unrecoverable
  /// without manual intervention.
  parseError,

  /// Null handle or empty `sessionJson` — caller bug.
  invalidArgument,

  /// The currently-linked runtime binary doesn't export the re-enqueue
  /// symbol. Rebuild against engine v0.8.1+ and re-link.
  unsupported;

  /// Decode the FFI return code from
  /// `synheart_core_reenqueue_lab_session`. Unknown codes map to
  /// [parseError] (caller-side defensive default).
  static LabReenqueueResult fromCode(int code) {
    switch (code) {
      case 0:
        return LabReenqueueResult.queued;
      case 1:
        return LabReenqueueResult.researchNotAllowed;
      case 2:
        return LabReenqueueResult.cloudNotConfigured;
      case 3:
        return LabReenqueueResult.parseError;
      case 4:
        return LabReenqueueResult.invalidArgument;
      default:
        return LabReenqueueResult.parseError;
    }
  }
}
