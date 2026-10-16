import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../core/logger.dart';

const MethodChannel _channel = MethodChannel('ai.synheart.core/platform');

/// Keeps a runtime data directory out of iCloud / iTunes backup and device
/// migration on iOS (the flag covers everything inside the directory).
///
/// Everything in it is sealed with keys held in Keychain items that never
/// leave this device, so a restored copy can never be decrypted. Worse, it
/// brings back the runtime's `.smk-provisioned-<subject>` markers without
/// their key, and the runtime then refuses to mint a new storage master key
/// (`ERR_SECURE_STORAGE_UNAVAILABLE`) on the new device.
///
/// Android needs no call here: the host excludes its data with
/// `allowBackup="false"` and `dataExtractionRules`. Best-effort; a failure is
/// logged and the directory still works.
Future<void> excludeFromBackup(String path) async {
  if (!Platform.isIOS) return;
  try {
    final ok = await _channel.invokeMethod<bool>('excludeFromBackup', {
      'path': path,
    });
    SynheartLogger.log(
      ok == true
          ? '[Synheart] excluded $path from backup'
          : '[Synheart] could not exclude $path from backup',
    );
  } on MissingPluginException {
    // Unit tests and hosts without the iOS plugin registered.
  } catch (e) {
    SynheartLogger.log('[Synheart] could not exclude $path from backup: $e');
  }
}
