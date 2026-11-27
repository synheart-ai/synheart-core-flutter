import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

import 'sdk_ffi.dart';

/// Resolves process-exported native crypto symbols into a
/// [SynheartSdkCryptoCallbacks] table the runtime calls directly (no Dart
/// trampoline in the hot path).
///
/// Expected native symbols:
/// - `synheart_native_generate_key`
/// - `synheart_native_sign_bytes`
/// - `synheart_native_get_attestation`
/// - `synheart_native_key_exists`
/// - `synheart_native_delete_key`
/// - `synheart_native_key_agreement` (optional, space sharing; see
///   [tryKeyAgreementFn])
///
/// Android: symbols live in `libsynheart_native_crypto.so` (loaded by
/// `SynheartAuthPlugin` via `System.loadLibrary`). iOS: `@_cdecl` symbols
/// are linked into the main binary and reachable via `DynamicLibrary.process()`.
abstract final class PlatformNativeSdkCryptoCallbacks {
  /// Returns a populated callback table, or null when symbols are missing.
  static Pointer<SynheartSdkCryptoCallbacks>? tryCreateRawTable() {
    try {
      final lib = _openNativeLib();
      final table = calloc<SynheartSdkCryptoCallbacks>();
      table.ref.generate_key = lib
          .lookup<NativeFunction<SynheartGenerateKeyNative>>(
            'synheart_native_generate_key',
          );
      table.ref.sign_bytes = lib
          .lookup<NativeFunction<SynheartSignBytesNative>>(
            'synheart_native_sign_bytes',
          );
      table.ref.get_attestation = lib
          .lookup<NativeFunction<SynheartGetAttestationNative>>(
            'synheart_native_get_attestation',
          );
      table.ref.key_exists = lib
          .lookup<NativeFunction<SynheartKeyExistsNative>>(
            'synheart_native_key_exists',
          );
      table.ref.delete_key = lib
          .lookup<NativeFunction<SynheartDeleteKeyNative>>(
            'synheart_native_delete_key',
          );
      return table;
    } catch (_) {
      return null;
    }
  }

  /// `synheart_native_key_agreement` (synheart_auth 0.1.14 / SynheartAuth
  /// 0.1.5 and later), or null when the host's auth plugin predates it. Space
  /// sharing needs it; everything else works without it.
  static Pointer<NativeFunction<SynheartKeyAgreementNative>>?
  tryKeyAgreementFn() {
    try {
      return _openNativeLib().lookup<NativeFunction<SynheartKeyAgreementNative>>(
        'synheart_native_key_agreement',
      );
    } catch (_) {
      return null;
    }
  }

  static DynamicLibrary _openNativeLib() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libsynheart_native_crypto.so');
    }
    return DynamicLibrary.process();
  }
}
