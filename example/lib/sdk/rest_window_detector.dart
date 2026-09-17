/// Decides when to call `declareRestWindow` (mobile host guide §6.5).
///
/// ## What breaks without it
///
/// There is no context module on mobile to derive rest, so an undeclared host
/// scores every break window as engaged: Focus is never zeroed and Capacity
/// never takes the recovery path. Someone who put the phone down for twenty
/// minutes looks, to the engine, like someone who worked through it.
///
/// ## Rest is a composite, not a screen-off event
///
/// Screen off alone is wrong in both directions: a person watching a video is
/// screen-on and resting, and a person in a meeting is screen-off and working.
/// The definition this implements is the one the guide specifies — screen off
/// for at least [screenOffThresholdMs] **and** no interaction **and** low
/// motion — with a wall-clock sleep window as an override for the case where a
/// phone on a nightstand registers no motion but also no screen event.
///
/// ## One-shot per window, and why that is not a detail
///
/// The ABI call is deliberately one-shot. A sticky flag a host forgot to clear
/// would pin Focus at exactly `0.0`, stop Capacity depleting and freeze Mental
/// Fatigue's engaged clock for the rest of the session — silently, with a
/// plausible-looking `0.0` on the wire the whole time. So this class hands out
/// at most one declaration per window and remembers which ones it has already
/// spent.
///
/// ## The window-alignment caveat
///
/// Window identity here is `ts ~/ windowMs`, which tiles epoch time. The
/// engine's windows are aligned to its own pipeline clock, so the two grids
/// need not coincide. The consequence is bounded and one-directional: at a
/// boundary this may declare twice inside one engine window (the second is
/// applied to the same window, which is idempotent in effect) or once for a
/// window already emitted (discarded by the runtime, not misapplied). What it
/// cannot do is leave a rest period undeclared, which is the failure that
/// actually costs a reading. A host that wants exact alignment should drive
/// [evaluate] from HSI emission instead of from a timer — right after a window
/// emits, `now` is inside the freshly opened one.
class RestWindowDetector {
  RestWindowDetector({
    this.windowMs = 60_000,
    this.screenOffThresholdMs = 120_000,
    this.interactionQuietMs = 120_000,
    this.motionRmsCeiling = 0.35,
    this.sleepWindowStartHour = 23,
    this.sleepWindowEndHour = 6,
  });

  /// Engine inference window length, for the one-shot bookkeeping. Must match
  /// the `window_ms` the config declared, or the guard is counting the wrong
  /// grid.
  final int windowMs;

  /// How long the screen must have been off. The guide's floor is 2 minutes.
  final int screenOffThresholdMs;

  /// How long since the last interaction. Kept separate from the screen-off
  /// clock because they answer different questions: the screen can be off
  /// while a person is still handling the device.
  final int interactionQuietMs;

  /// Accelerometer RMS below which motion counts as low, in m/s² with gravity
  /// removed. Above this the person is moving, which is not rest even with the
  /// screen off and no taps — walking with the phone in a pocket hits both of
  /// those.
  final double motionRmsCeiling;

  /// Wall-clock sleep window, local hours, `[start, end)` crossing midnight.
  /// Inside it, rest is declared without waiting on the screen-off clock.
  final int sleepWindowStartHour;
  final int sleepWindowEndHour;

  int? _screenOffSinceMs;
  int? _lastInteractionMs;
  double? _latestMotionRms;

  /// Windows already declared, so the one-shot contract holds.
  ///
  /// Bounded below, because an all-night session would otherwise grow this
  /// forever.
  final Set<int> _declaredWindows = <int>{};

  /// Declarations made since construction, for the UI.
  int get declaredCount => _totalDeclared;
  int _totalDeclared = 0;

  /// Why the last [evaluate] declined, for a UI that needs to explain itself.
  /// Null when the last call declared.
  String? get lastDeclineReason => _lastDeclineReason;
  String? _lastDeclineReason;

  /// The screen turned off. On a Flutter host this is the app lifecycle's
  /// `paused`/`hidden`, which is a proxy rather than a true screen-off: the
  /// app also pauses when the person switches to another app with the screen
  /// very much on. A production host should read the platform's screen-state
  /// broadcast (`ACTION_SCREEN_OFF` / `UIScreen` brightness) instead, and the
  /// difference matters — this proxy will call an app switch "rest" if nothing
  /// else contradicts it, which is why the interaction and motion clauses are
  /// not optional.
  void noteScreenOff(int tsMs) => _screenOffSinceMs ??= tsMs;

  void noteScreenOn(int tsMs) {
    _screenOffSinceMs = null;
    // Waking the screen is itself an interaction; without this the quiet clock
    // would still read as two minutes idle the instant the person picks the
    // phone up.
    _lastInteractionMs = tsMs;
  }

  /// Any behavior event — tap, scroll, swipe, keystroke.
  void noteInteraction(int tsMs) {
    final current = _lastInteractionMs;
    if (current == null || tsMs > current) _lastInteractionMs = tsMs;
  }

  /// Latest gravity-removed accelerometer RMS.
  void noteMotionRms(double rms) => _latestMotionRms = rms;

  /// Reset the observation state, keeping nothing from a previous session.
  void reset() {
    _screenOffSinceMs = null;
    _lastInteractionMs = null;
    _latestMotionRms = null;
    _declaredWindows.clear();
    _lastDeclineReason = null;
  }

  /// The timestamp to hand `declareRestWindow`, or null when this moment is
  /// not rest or its window has already been declared.
  int? evaluate(int nowMs, {DateTime? localNow}) {
    final windowIndex = nowMs ~/ windowMs;
    if (_declaredWindows.contains(windowIndex)) {
      _lastDeclineReason = 'already declared for this window';
      return null;
    }

    if (!_isRestingNow(nowMs, localNow ?? DateTime.now())) return null;

    _declaredWindows.add(windowIndex);
    // Two windows of history is enough for the one-shot guard and keeps this
    // from growing across a long session.
    if (_declaredWindows.length > 4) {
      final oldest = _declaredWindows.reduce((a, b) => a < b ? a : b);
      _declaredWindows.remove(oldest);
    }
    _totalDeclared++;
    _lastDeclineReason = null;
    return nowMs;
  }

  bool _isRestingNow(int nowMs, DateTime localNow) {
    // The sleep-window override comes first, because it exists precisely for
    // the case the composite cannot see: a phone face-down on a nightstand
    // fires no screen-off transition after the first one and reports no
    // motion, so the composite is satisfied only by accident.
    if (_isInSleepWindow(localNow)) return true;

    final screenOffSince = _screenOffSinceMs;
    if (screenOffSince == null) {
      _lastDeclineReason = 'screen is on';
      return false;
    }
    if (nowMs - screenOffSince < screenOffThresholdMs) {
      final held = ((nowMs - screenOffSince) / 1000).round();
      _lastDeclineReason =
          'screen off for ${held}s, needs '
          '${screenOffThresholdMs ~/ 1000}s';
      return false;
    }

    final lastInteraction = _lastInteractionMs;
    if (lastInteraction != null &&
        nowMs - lastInteraction < interactionQuietMs) {
      final since = ((nowMs - lastInteraction) / 1000).round();
      _lastDeclineReason = 'interaction ${since}s ago';
      return false;
    }

    final motion = _latestMotionRms;
    // A null motion reading is not treated as low motion. With no
    // accelerometer forwarding, the motion clause is simply unverifiable, and
    // declaring rest on two of three conditions would call a walk with the
    // phone pocketed a rest window.
    if (motion == null) {
      _lastDeclineReason = 'no motion reading — cannot verify low motion';
      return false;
    }
    if (motion > motionRmsCeiling) {
      _lastDeclineReason = 'motion ${motion.toStringAsFixed(2)} m/s² too high';
      return false;
    }

    return true;
  }

  bool _isInSleepWindow(DateTime localNow) {
    final hour = localNow.hour;
    if (sleepWindowStartHour <= sleepWindowEndHour) {
      return hour >= sleepWindowStartHour && hour < sleepWindowEndHour;
    }
    // Crosses midnight.
    return hour >= sleepWindowStartHour || hour < sleepWindowEndHour;
  }
}
