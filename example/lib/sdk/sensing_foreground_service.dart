import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart';

/// Starts and stops the Android foreground service that keeps the sensing
/// session alive (mobile host guide §6.2).
///
/// ## Why this is not optional on Android
///
/// The runtime has no internal ticker — [MobileHostRunner] drives `tick_all`
/// once a second — so a backgrounded process that Android stops scheduling
/// stops closing windows entirely. Not slowly, not at reduced fidelity: the
/// session emits nothing from the moment the person leaves the app, while the
/// UI still reads as "collecting" when they come back.
///
/// ## iOS is a different mechanism, not a missing one
///
/// There is no equivalent call here for iOS, and adding one would be a lie.
/// What keeps an iOS runtime alive is `bluetooth-central` plus a **connected
/// peripheral** — a strap holding the process up. Without one, the app gets
/// whatever foreground slices the user grants, which is exactly why
/// `MobileHostRunner` declares `episodic` there. So every call below is a
/// no-op off Android, and the honest declaration does the work instead.
class SensingForegroundService {
  const SensingForegroundService._();

  static const MethodChannel _channel = MethodChannel(
    'ai.synheart.core.example/sensing_service',
  );

  /// Whether this platform has a foreground service to start at all.
  static bool get isSupported =>
      defaultTargetPlatform == TargetPlatform.android;

  /// Start the service. Safe to call more than once — Android treats a repeat
  /// `startForegroundService` on a running service as another
  /// `onStartCommand`, which re-posts the same notification id.
  ///
  /// Never throws: a host must not fail to start a session because the
  /// keep-alive could not be established. The session still runs, it just
  /// stops collecting when backgrounded — which is worth reporting, hence the
  /// bool, but not worth aborting for.
  static Future<bool> start() => _invoke('start');

  static Future<bool> stop() => _invoke('stop');

  static Future<bool> _invoke(String method) async {
    if (!isSupported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>(method);
      return ok ?? false;
    } on PlatformException {
      // The most likely cause on a 14+ device is a missing typed permission
      // (FOREGROUND_SERVICE_DATA_SYNC) or a start attempt from the background,
      // which Android forbids outright. Both are configuration, not runtime
      // conditions a retry would fix.
      return false;
    } on MissingPluginException {
      // The channel is registered in MainActivity; absent means this build is
      // running against a host that has not adopted it.
      return false;
    }
  }
}
