// Struct fields mirror C symbol names (`generate_key`, …).
// ignore_for_file: non_constant_identifier_names

/// FFI types and optional symbol resolution for `synheart_core_sdk_*` (device auth).
///
/// Older `libsynheart_core_runtime` builds may omit these symbols; resolution is
/// best-effort and leaves fields null when missing.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// ── C callback typedefs (native) ─────────────────────────────────────────

typedef SynheartGenerateKeyNative =
    Pointer<Utf8> Function(Pointer<Utf8> deviceId);
typedef SynheartSignBytesNative =
    Pointer<Utf8> Function(
      Pointer<Utf8> deviceId,
      Pointer<Uint8> data,
      IntPtr dataLen,
    );
typedef SynheartGetAttestationNative =
    Pointer<Utf8> Function(
      Pointer<Utf8> deviceId,
      Pointer<Uint8> challengeHash,
      IntPtr hashLen,
    );
typedef SynheartKeyExistsNative = Int32 Function(Pointer<Utf8> deviceId);
typedef SynheartDeleteKeyNative = Int32 Function(Pointer<Utf8> deviceId);

/// P-256 ECDH for sync-space sharing (C ABI 4.3): agree between the key under
/// `alias` and `peer` (an uncompressed point, 65 bytes), write the 32-byte
/// shared secret to `out`, return 0. Anything else is a failure.
typedef SynheartKeyAgreementNative =
    Int32 Function(
      Pointer<Utf8> alias,
      Pointer<Uint8> peer,
      Size peerLen,
      Pointer<Uint8> out,
    );

// ── Platform secure-storage callback typedefs (native) ───────────────────
//
// Match `SynheartSdkSecureStoreFn` / `…LoadFn` / `…DeleteFn` in the native
// `platform_bridge::ffi_bridge` module. These back consent token persistence
// and any other state the core wants to survive process restarts.
typedef SynheartSecureStoreNative =
    Int32 Function(
      Pointer<Utf8> service,
      Pointer<Utf8> key,
      Pointer<Utf8> value,
    );
typedef SynheartSecureLoadNative =
    Pointer<Utf8> Function(Pointer<Utf8> service, Pointer<Utf8> key);
typedef SynheartSecureDeleteNative =
    Int32 Function(Pointer<Utf8> service, Pointer<Utf8> key);

// ── Host crypto callback table (must match Core Runtime `SynheartSdkCryptoCallbacks`) ─

final class SynheartSdkCryptoCallbacks extends Struct {
  external Pointer<NativeFunction<SynheartGenerateKeyNative>> generate_key;

  external Pointer<NativeFunction<SynheartSignBytesNative>> sign_bytes;

  external Pointer<NativeFunction<SynheartGetAttestationNative>>
  get_attestation;

  external Pointer<NativeFunction<SynheartKeyExistsNative>> key_exists;

  external Pointer<NativeFunction<SynheartDeleteKeyNative>> delete_key;
}

// ── Optional SDK entry points ───────────────────────────────────────────

/// Resolved optional `synheart_core_sdk_*` symbols.
class SynheartSdkFfi {
  SynheartSdkFfi._();

  int Function(
    Pointer<Void> handle,
    Pointer<SynheartSdkCryptoCallbacks> callbacks,
  )?
  setCryptoCallbacks;

  int Function(
    Pointer<Void> handle,
    Pointer<SynheartSdkCryptoCallbacks> callbacks,
  )?
  setCryptoCallbacksAlt;

  Pointer<Utf8> Function(Pointer<Void> handle, Pointer<Utf8> clientId)?
  registerDevice;

  Pointer<Utf8> Function(Pointer<Void> handle)? reattestDevice;

  Pointer<Utf8> Function(Pointer<Void> handle)? logout;

  Pointer<Utf8> Function(Pointer<Void> handle)? deviceAuthStatus;

  Pointer<Utf8> Function(
    Pointer<Void> handle,
    Pointer<Utf8> method,
    Pointer<Utf8> url,
  )?
  buildProofHeader;

  /// `synheart_core_set_storage_callbacks(handle, store, load, delete) -> i32`.
  /// Registers host-provided secure-storage callbacks so the core can persist
  /// consent tokens, device records, etc. across process restarts.
  int Function(
    Pointer<Void> handle,
    Pointer<NativeFunction<SynheartSecureStoreNative>> storeFn,
    Pointer<NativeFunction<SynheartSecureLoadNative>> loadFn,
    Pointer<NativeFunction<SynheartSecureDeleteNative>> deleteFn,
  )?
  setStorageCallbacks;

  /// `synheart_core_sdk_set_key_agreement_callback` (C ABI 4.3). Null on an
  /// older runtime, which has no space sharing.
  int Function(
    Pointer<Void> handle,
    Pointer<NativeFunction<SynheartKeyAgreementNative>> agree,
  )?
  setKeyAgreementCallback;

  bool get _hasCryptoSetter =>
      setCryptoCallbacks != null || setCryptoCallbacksAlt != null;

  /// All symbols required for the documented init → callbacks → register → proof flow.
  bool get isAvailable =>
      _hasCryptoSetter &&
      registerDevice != null &&
      deviceAuthStatus != null &&
      buildProofHeader != null;

  /// Binds symbols from [lib]. Swallows lookup failures.
  static SynheartSdkFfi tryBind(DynamicLibrary lib) {
    final o = SynheartSdkFfi._();

    try {
      o.setCryptoCallbacks = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<SynheartSdkCryptoCallbacks>),
            int Function(Pointer<Void>, Pointer<SynheartSdkCryptoCallbacks>)
          >('synheart_core_sdk_set_crypto_callbacks');
    } catch (_) {}

    // Some builds may use a different name — try common alternates.
    if (o.setCryptoCallbacks == null) {
      try {
        o.setCryptoCallbacksAlt = lib
            .lookupFunction<
              Int32 Function(
                Pointer<Void>,
                Pointer<SynheartSdkCryptoCallbacks>,
              ),
              int Function(Pointer<Void>, Pointer<SynheartSdkCryptoCallbacks>)
            >('synheart_sdk_set_crypto_callbacks');
      } catch (_) {}
    }

    try {
      o.registerDevice = lib
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
          >('synheart_core_sdk_register_device');
    } catch (_) {}

    try {
      o.reattestDevice = lib
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Void>),
            Pointer<Utf8> Function(Pointer<Void>)
          >('synheart_core_sdk_reattest_device');
    } catch (_) {}

    try {
      o.logout = lib
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Void>),
            Pointer<Utf8> Function(Pointer<Void>)
          >('synheart_core_sdk_logout');
    } catch (_) {}

    try {
      o.deviceAuthStatus = lib
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Void>),
            Pointer<Utf8> Function(Pointer<Void>)
          >('synheart_core_sdk_device_auth_status');
    } catch (_) {}

    try {
      o.buildProofHeader = lib
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
          >('synheart_core_sdk_build_proof_header');
    } catch (_) {}

    try {
      o.setStorageCallbacks = lib
          .lookupFunction<
            Int32 Function(
              Pointer<Void>,
              Pointer<NativeFunction<SynheartSecureStoreNative>>,
              Pointer<NativeFunction<SynheartSecureLoadNative>>,
              Pointer<NativeFunction<SynheartSecureDeleteNative>>,
            ),
            int Function(
              Pointer<Void>,
              Pointer<NativeFunction<SynheartSecureStoreNative>>,
              Pointer<NativeFunction<SynheartSecureLoadNative>>,
              Pointer<NativeFunction<SynheartSecureDeleteNative>>,
            )
          >('synheart_core_set_storage_callbacks');
    } catch (_) {}

    try {
      o.setKeyAgreementCallback = lib
          .lookupFunction<
            Int32 Function(
              Pointer<Void>,
              Pointer<NativeFunction<SynheartKeyAgreementNative>>,
            ),
            int Function(
              Pointer<Void>,
              Pointer<NativeFunction<SynheartKeyAgreementNative>>,
            )
          >('synheart_core_sdk_set_key_agreement_callback');
    } catch (_) {}

    return o;
  }

  int setCryptoCallbacksInvoke(
    Pointer<Void> handle,
    Pointer<SynheartSdkCryptoCallbacks> callbacks,
  ) {
    if (setCryptoCallbacks != null) {
      return setCryptoCallbacks!(handle, callbacks);
    }
    if (setCryptoCallbacksAlt != null) {
      return setCryptoCallbacksAlt!(handle, callbacks);
    }
    return -1;
  }
}
