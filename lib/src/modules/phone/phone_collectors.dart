import 'dart:async';

/// Motion data from accelerometer/gyroscope
class MotionData {
  final double x;
  final double y;
  final double z;
  final double energy;
  final DateTime timestamp;

  const MotionData({
    required this.x,
    required this.y,
    required this.z,
    required this.energy,
    required this.timestamp,
  });
}

/// Screen state information
enum ScreenState { on, off, locked, unlocked }

/// Notification event
class NotificationEvent {
  final DateTime timestamp;
  final bool opened; // true if opened, false if just received

  const NotificationEvent({required this.timestamp, required this.opened});
}

// ── Phone-context collectors ─────────────────────────────────────────────────
//
// These four collectors have no platform source in this package. They used to
// emit `Random()` values on timers — fake accelerometer samples every 100 ms,
// random screen-state flips, invented app switches and notifications — which
// reached hosts through `PhoneModule.rawDataPoints` as if they were measured.
//
// They now emit nothing. An empty stream is the honest answer: no source, no
// data, so a consumer sees absence rather than a plausible-looking fabrication.
//
// The real signals arrive elsewhere:
// - accelerometer: synheart_behavior's motion samples, forwarded to
//   `push_accel` by the behavior module when raw motion samples are enabled
//   (see `BehaviorConfig.emitRawMotionSamples`; on in research capture);
// - foreground app, notifications, screen state: the behavior module's event
//   stream and the host's own `pushBehaviorEvent` / `pushAppForeground`.

/// Phone motion source. Emits nothing: there is no sensor binding here.
class MotionCollector {
  final StreamController<MotionData> _controller =
      StreamController<MotionData>.broadcast();

  Stream<MotionData> get motionStream => _controller.stream;

  Future<void> start() async {}

  Future<void> stop() async {}

  Future<void> dispose() async {
    await _controller.close();
  }
}

/// Screen-state source. Emits nothing: there is no platform binding here.
class ScreenStateTracker {
  final StreamController<ScreenState> _controller =
      StreamController<ScreenState>.broadcast();

  Stream<ScreenState> get screenStream => _controller.stream;

  Future<void> start() async {}

  Future<void> stop() async {}

  Future<void> dispose() async {
    await _controller.close();
  }
}

/// App-switch source. Emits nothing: there is no platform binding here.
class AppFocusTracker {
  final StreamController<String> _controller =
      StreamController<String>.broadcast();

  Stream<String> get appSwitchStream => _controller.stream;

  Future<void> start() async {}

  Future<void> stop() async {}

  Future<void> dispose() async {
    await _controller.close();
  }
}

/// Notification source. Emits nothing: there is no platform binding here.
class NotificationTracker {
  final StreamController<NotificationEvent> _controller =
      StreamController<NotificationEvent>.broadcast();

  Stream<NotificationEvent> get notificationStream => _controller.stream;

  Future<void> start() async {}

  Future<void> stop() async {}

  Future<void> dispose() async {
    await _controller.close();
  }
}
