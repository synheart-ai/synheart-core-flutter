import 'dart:async';

import '../../core/logger.dart';
import '../../models/behavior_event_input.dart';

/// Where the foreground application identifier comes from.
///
/// Implement this to plug a real platform source in. The default
/// ([SelfForegroundAppSource]) reports the host's own application id, which is
/// honest and useful for an app the person is actively using, but it cannot see
/// what is in front when the person leaves.
///
/// | Platform | Real source | Status |
/// |---|---|---|
/// | Android | `UsageStatsManager.queryEvents` (`PACKAGE_USAGE_STATS`, a Settings-granted permission) | not built — implement this interface |
/// | iOS | none exists | structurally unavailable; the self source is the ceiling |
///
/// A source that cannot answer right now returns `null`, and the reporter sends
/// nothing rather than re-asserting a stale app.
abstract class ForegroundAppSource {
  /// The application id in front, or `null` when unknown.
  ///
  /// Android package name (`com.google.android.gm`) or iOS bundle id. Matched
  /// case-insensitively against the engine's app taxonomy.
  FutureOr<String?> currentForegroundApp();
}

/// Reports the host's own application id.
///
/// Not a placeholder — for a foreground-only mobile session this is the *true*
/// answer, and it is the difference between the engine having an app identity
/// and having none. With no identity at all the runtime's `current_app` stays
/// `None`, which resolves to the `Unknown` app category, whose
/// interpretation-mask row is all zeros: every behavioural evidence term reads
/// `0` for a person who was working the whole time.
///
/// Its limit is real and worth stating in a host's own docs: while the person
/// is in another app this keeps naming *your* app, which is wrong rather than
/// merely incomplete. Pair it with a lifecycle gate — the reporter below stops
/// while backgrounded for exactly that reason.
class SelfForegroundAppSource implements ForegroundAppSource {
  const SelfForegroundAppSource(this.appId);

  /// The host's platform application id.
  final String appId;

  @override
  String? currentForegroundApp() => appId.isEmpty ? null : appId;
}

/// Pushes `app_foreground` resolves for the life of a session.
///
/// ## Why a heartbeat and not just an edge
///
/// `app_switch` fires on a *transition*. A mobile session where the person
/// opens one app and stays in it — the common case — produces no transition at
/// all, so an edge-only host never gives the engine an app identity. The
/// runtime has a separate entry point for exactly this (`note_app_resolved`),
/// and it is explicitly safe to call repeatedly: an unchanged app is treated as
/// a steady-state observation and deliberately does **not** bump the switch
/// count, because switch count is itself a fragmentation feature. A resolve
/// that reveals a *different* app does count as a switch — the engine infers
/// the transition the host's edge detector missed.
///
/// So: resolve at session start, on every foreground resume, and on a slow
/// heartbeat. The heartbeat is what makes a long single-app session legible.
///
/// ## Cadence
///
/// [defaultInterval] is deliberately shorter than the default 60 s HSI window,
/// so every window contains at least one resolve. A resolve is a few bytes and
/// a lock — this is not a cost worth tuning down.
class ForegroundAppReporter {
  ForegroundAppReporter({
    required ForegroundAppSource source,
    required int? Function(BehaviorEventInput event) push,
    Duration interval = defaultInterval,
  }) : _source = source,
       _push = push,
       _interval = interval;

  /// One resolve per half-window, so no HSI window goes without an identity.
  static const Duration defaultInterval = Duration(seconds: 30);

  final ForegroundAppSource _source;

  /// The rich-event sink. Returns the runtime status, or `null` when the loaded
  /// runtime does not export `push_behavior_event` — in which case there is no
  /// path for `app_foreground` at all, since the legacy int-coded call carries
  /// no payload and so cannot name an app.
  final int? Function(BehaviorEventInput event) _push;

  final Duration _interval;

  Timer? _timer;
  bool _abiUnavailableLogged = false;

  /// The last id actually delivered, for diagnostics.
  String? get lastReportedApp => _lastReportedApp;
  String? _lastReportedApp;

  /// Resolves delivered this session.
  int get reportCount => _reportCount;
  int _reportCount = 0;

  bool get isRunning => _timer != null;

  /// Resolve immediately, then keep resolving on the heartbeat.
  ///
  /// Call right after the session starts. The immediate resolve matters: window
  /// 1 is otherwise typed against no app at all, and a window is never
  /// re-emitted.
  Future<void> start() async {
    if (_timer != null) return;
    await report();
    _timer = Timer.periodic(_interval, (_) => report());
  }

  /// Stop resolving.
  ///
  /// Call on backgrounding as well as on session end. Continuing to assert the
  /// host's own id while the person is in another app is worse than silence:
  /// the engine would attribute another app's window to this one.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Resolve once, now. Safe to call on top of the heartbeat — a repeat of the
  /// same app is a steady-state observation to the engine, not a switch.
  Future<void> report() async {
    final app = await _source.currentForegroundApp();
    if (app == null || app.isEmpty) return;

    final status = _push(
      BehaviorEventInput.appForeground(
        DateTime.now().millisecondsSinceEpoch,
        app,
      ),
    );

    if (status == null) {
      // The runtime predates `push_behavior_event`. Log once — at a 30 s
      // heartbeat this would otherwise be a slow drip for the whole session.
      if (!_abiUnavailableLogged) {
        _abiUnavailableLogged = true;
        SynheartLogger.log(
          '[ForegroundAppReporter] push_behavior_event is absent from this '
          'runtime, so app_foreground cannot be delivered. The engine will '
          'type every window against the Unknown app category, whose '
          'interpretation-mask row is all zeros — CFI, Stress B, Mental '
          'Fatigue B and Focus deviation terms will read 0. Re-vendor the '
          'runtime to fix.',
        );
      }
      return;
    }

    _lastReportedApp = app;
    _reportCount++;
  }

  void dispose() => stop();
}
