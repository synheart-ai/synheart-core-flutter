/// Typed payloads for `synheart_core_push_behavior_event`.
///
/// The legacy `synheart_core_push_behavior(ts, code, value)` carries a scalar
/// and nothing else, so a notification pushed that way reaches the engine with
/// `action: None` and a typing event with an all-`None` `TypingSessionData`.
/// These types are the other half — the `data` object the rich FFI parses into
/// the engine's variant-specific fields.
///
/// ## The null contract
///
/// Every optional field here is emitted **only when non-null**. That is not a
/// serialization nicety: the engine withholds a `null` and renormalises it out
/// of the feature set, whereas `0.0` is a *measured zero* that moves the score.
/// Reporting a field you did not measure as `0` fabricates evidence. Set what
/// you can measure and leave the rest alone.
///
/// ## Key names
///
/// The JSON keys below match core-runtime's `behavior::engine_event`
/// translation table exactly. Two are easy to get wrong because the engine's
/// Rust field names differ from the wire keys: `AppSwitch` reads `from_app` /
/// `to_app` (not `from_app_id` / `to_app_id`) and `NotificationReceived` reads
/// `source_app` (not `source_app_id`). An unrecognised key is silently ignored,
/// so a mis-spelling costs the whole field with no error.
///
/// An unknown `kind` is dropped by the runtime rather than defaulted, which is
/// why this file models kinds as a closed set instead of a free string.
library;

/// Scroll / swipe direction. Anything outside this set is read as absent.
enum ScrollDirection {
  up('up'),
  down('down'),
  left('left'),
  right('right');

  final String wire;
  const ScrollDirection(this.wire);
}

/// How the person responded to an interruption (notification or call).
///
/// This is the field that makes an interruption measurable: without it the
/// engine sees that something arrived but not what it cost. On iOS it is
/// structurally unavailable — there is no API that reports it — so an iOS host
/// leaves it null rather than guessing.
enum InterruptionAction {
  ignored('ignored'),
  opened('opened'),
  answered('answered'),
  dismissed('dismissed');

  final String wire;
  const InterruptionAction(this.wire);
}

/// A 10-second typing micro-window summary.
///
/// The richest input the engine takes. Desktop aggregates raw key events into
/// 10 s micro-windows and emits one `Typing` event per window stamped at
/// `window_start_ms`; mobile hosts mirror that shape.
///
/// Do not also push the raw keystrokes that fed this summary — the engine
/// would count both and every rate feature roughly doubles.
///
/// Highest-value fields, in order: [typingTapCount]; [numberOfBackspace] and
/// [numberOfDelete] (these two produce `typing.correction_rate`, which feeds
/// the `TypingFluency` reading); [typingSpeedCpm] and [durationSec]; then
/// cadence and pauses.
///
/// **This is not the channel that feeds CFI.** Cognitive Load's friction index
/// reads `context.deviation.err_elevation`, computed from `ContextEventInput`
/// keyboard events — a separate push on a separate buffer. A rich typing
/// summary with no context events leaves CFI with nothing, however complete the
/// summary is. See `ContextEventInput` for why both channels exist.
class TypingSessionData {
  /// Measured first-tap→last-tap span, **not** the window length. A window
  /// with two taps 1.2 s apart has `durationSec: 1.2`, not `10.0`.
  final double? durationSec;

  final double? typingSpeedCpm;
  final int? typingTapCount;

  /// Gaps longer than 500 ms.
  final int? pauseCount;
  final double? meanInterTapIntervalMs;
  final double? typingCadenceStability;
  final double? typingCadenceVariability;

  /// Legacy alias the engine reads alongside [typingCadenceStability].
  final double? cadenceStability;

  final int? typingGapCount;
  final double? typingGapRatio;
  final double? typingBurstiness;
  final double? typingActivityRatio;
  final double? typingInteractionIntensity;
  final bool? deepTyping;

  final int? numberOfBackspace;
  final int? numberOfDelete;
  final int? numberOfCut;
  final int? numberOfPaste;
  final int? numberOfCopy;

  final double? keyboardScrollRate;
  final int? shortcutCount;
  final double? shortcutRate;
  final double? typingEfficiency;
  final double? holdTimeMean;
  final double? latencyVariability;

  const TypingSessionData({
    this.durationSec,
    this.typingSpeedCpm,
    this.typingTapCount,
    this.pauseCount,
    this.meanInterTapIntervalMs,
    this.typingCadenceStability,
    this.typingCadenceVariability,
    this.cadenceStability,
    this.typingGapCount,
    this.typingGapRatio,
    this.typingBurstiness,
    this.typingActivityRatio,
    this.typingInteractionIntensity,
    this.deepTyping,
    this.numberOfBackspace,
    this.numberOfDelete,
    this.numberOfCut,
    this.numberOfPaste,
    this.numberOfCopy,
    this.keyboardScrollRate,
    this.shortcutCount,
    this.shortcutRate,
    this.typingEfficiency,
    this.holdTimeMean,
    this.latencyVariability,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (durationSec != null) 'duration_sec': durationSec,
    if (typingSpeedCpm != null) 'typing_speed_cpm': typingSpeedCpm,
    if (typingTapCount != null) 'typing_tap_count': typingTapCount,
    if (pauseCount != null) 'pause_count': pauseCount,
    if (meanInterTapIntervalMs != null)
      'mean_inter_tap_interval_ms': meanInterTapIntervalMs,
    if (typingCadenceStability != null)
      'typing_cadence_stability': typingCadenceStability,
    if (typingCadenceVariability != null)
      'typing_cadence_variability': typingCadenceVariability,
    if (cadenceStability != null) 'cadence_stability': cadenceStability,
    if (typingGapCount != null) 'typing_gap_count': typingGapCount,
    if (typingGapRatio != null) 'typing_gap_ratio': typingGapRatio,
    if (typingBurstiness != null) 'typing_burstiness': typingBurstiness,
    if (typingActivityRatio != null)
      'typing_activity_ratio': typingActivityRatio,
    if (typingInteractionIntensity != null)
      'typing_interaction_intensity': typingInteractionIntensity,
    if (deepTyping != null) 'deep_typing': deepTyping,
    if (numberOfBackspace != null) 'number_of_backspace': numberOfBackspace,
    if (numberOfDelete != null) 'number_of_delete': numberOfDelete,
    if (numberOfCut != null) 'number_of_cut': numberOfCut,
    if (numberOfPaste != null) 'number_of_paste': numberOfPaste,
    if (numberOfCopy != null) 'number_of_copy': numberOfCopy,
    if (keyboardScrollRate != null) 'keyboard_scroll_rate': keyboardScrollRate,
    if (shortcutCount != null) 'shortcut_count': shortcutCount,
    if (shortcutRate != null) 'shortcut_rate': shortcutRate,
    if (typingEfficiency != null) 'typing_efficiency': typingEfficiency,
    if (holdTimeMean != null) 'hold_time_mean': holdTimeMean,
    if (latencyVariability != null) 'latency_variability': latencyVariability,
  };
}

/// One rich behavioral event, ready for `pushBehaviorEvent`.
///
/// Construct via the named factories rather than the raw constructor — they
/// pin the `kind` string to the engine's table, which is the one part a host
/// cannot get wrong and still see an error.
class BehaviorEventInput {
  /// UTC epoch milliseconds, on the same clock as every other `push_*`.
  final int tsMs;

  /// Engine event kind. Closed set — an unknown kind is dropped, not defaulted.
  final String kind;

  /// Back-compat scalar. Only `system_failure` reads it as a fallback.
  final double value;

  /// Variant-specific payload, already null-stripped.
  final Map<String, dynamic> data;

  const BehaviorEventInput._({
    required this.tsMs,
    required this.kind,
    this.value = 0.0,
    this.data = const <String, dynamic>{},
  });

  /// `Touch { duration_ms, long_press }`.
  factory BehaviorEventInput.touch(
    int tsMs, {
    int? durationMs,
    bool? longPress,
  }) => BehaviorEventInput._(
    tsMs: tsMs,
    kind: 'touch',
    data: <String, dynamic>{
      if (durationMs != null) 'duration_ms': durationMs,
      if (longPress != null) 'long_press': longPress,
    },
  );

  /// `Scroll { velocity, direction, direction_reversal }`.
  ///
  /// All three matter. A scroll with direction and velocity stripped tells the
  /// engine only that scrolling happened, which is the state mobile hosts have
  /// historically shipped in.
  factory BehaviorEventInput.scroll(
    int tsMs, {
    double? velocity,
    ScrollDirection? direction,
    bool? directionReversal,
  }) => BehaviorEventInput._(
    tsMs: tsMs,
    kind: 'scroll',
    data: <String, dynamic>{
      if (velocity != null) 'velocity': velocity,
      if (direction != null) 'direction': direction.wire,
      if (directionReversal != null) 'direction_reversal': directionReversal,
    },
  );

  /// `Swipe { direction, velocity }`.
  factory BehaviorEventInput.swipe(
    int tsMs, {
    ScrollDirection? direction,
    double? velocity,
  }) => BehaviorEventInput._(
    tsMs: tsMs,
    kind: 'swipe',
    data: <String, dynamic>{
      if (direction != null) 'direction': direction.wire,
      if (velocity != null) 'velocity': velocity,
    },
  );

  /// `AppSwitch { from_app_id, to_app_id }` — wire keys `from_app` / `to_app`.
  ///
  /// Both ids are what make the switch identifiable; a duration alone gives the
  /// engine no app identity and therefore no context row. Android sources them
  /// from `UsageStatsManager`; iOS has no API for this at all.
  factory BehaviorEventInput.appSwitch(
    int tsMs, {
    String? fromApp,
    String? toApp,
  }) => BehaviorEventInput._(
    tsMs: tsMs,
    kind: 'app_switch',
    data: <String, dynamic>{
      if (fromApp != null) 'from_app': fromApp,
      if (toApp != null) 'to_app': toApp,
    },
  );

  /// `app_foreground` — the host's foreground **resolve**, as opposed to the
  /// [appSwitch] *edge*.
  ///
  /// This is the call that gives the engine an app identity at all, and without
  /// it a whole class of readings is silently zeroed. [appSwitch] only fires on
  /// a transition, so a session where the person opened one app and stayed in
  /// it produces no edge — the runtime's `current_app` stays `None`, `None`
  /// resolves to the `Unknown` app category, and `Unknown`'s interpretation-mask
  /// row is **all zeros**. Every behavioural evidence term (CFI / Cognitive
  /// Load, Stress `B`, Mental Fatigue `B`, Focus's deviation sub-terms) then
  /// reads `0` for someone who was working the whole time.
  ///
  /// Send it at session start and on every foreground resume, and re-send it
  /// periodically. Re-sending is cheap and safe: the runtime treats an
  /// unchanged app as a steady-state observation and deliberately does **not**
  /// bump the app-switch count, because switch count is itself a fragmentation
  /// feature. A resolve that reveals a *different* app does count as a switch —
  /// the engine infers the transition your edge detector missed.
  ///
  /// [app] is a platform application identifier: an Android package name
  /// (`com.google.android.gm`), an iOS bundle id. Matched case-insensitively
  /// against the app taxonomy, which is keyed by platform. An id the taxonomy
  /// does not know still counts as *an* identity — it holds the switch and
  /// same-app clocks — it just resolves to the `Unknown` category.
  factory BehaviorEventInput.appForeground(int tsMs, String app) =>
      BehaviorEventInput._(
        tsMs: tsMs,
        kind: 'app_foreground',
        data: <String, dynamic>{'app': app},
      );

  /// `NotificationReceived { action, source_app_id }` — wire key `source_app`.
  factory BehaviorEventInput.notification(
    int tsMs, {
    InterruptionAction? action,
    String? sourceApp,
  }) => BehaviorEventInput._(
    tsMs: tsMs,
    kind: 'notification',
    data: <String, dynamic>{
      if (action != null) 'action': action.wire,
      if (sourceApp != null) 'source_app': sourceApp,
    },
  );

  /// `Call { action }`.
  factory BehaviorEventInput.call(int tsMs, {InterruptionAction? action}) =>
      BehaviorEventInput._(
        tsMs: tsMs,
        kind: 'call',
        data: <String, dynamic>{if (action != null) 'action': action.wire},
      );

  /// `Typing { session }` — one 10 s micro-window summary.
  ///
  /// Stamp [tsMs] at the window **start**, matching desktop.
  factory BehaviorEventInput.typing(
    int windowStartMs,
    TypingSessionData session,
  ) => BehaviorEventInput._(
    tsMs: windowStartMs,
    kind: 'typing',
    data: session.toJson(),
  );

  factory BehaviorEventInput.screenOn(int tsMs) =>
      BehaviorEventInput._(tsMs: tsMs, kind: 'screen_on');

  factory BehaviorEventInput.screenOff(int tsMs) =>
      BehaviorEventInput._(tsMs: tsMs, kind: 'screen_off');

  factory BehaviorEventInput.taskSuccess(int tsMs) =>
      BehaviorEventInput._(tsMs: tsMs, kind: 'task_success');

  factory BehaviorEventInput.taskFailure(int tsMs) =>
      BehaviorEventInput._(tsMs: tsMs, kind: 'task_failure');

  factory BehaviorEventInput.taskReturn(int tsMs) =>
      BehaviorEventInput._(tsMs: tsMs, kind: 'task_return');

  factory BehaviorEventInput.taskAbandonment(int tsMs) =>
      BehaviorEventInput._(tsMs: tsMs, kind: 'task_abandonment');

  /// `SystemFailure { duration_secs }` — a stall the person waited through.
  factory BehaviorEventInput.systemFailure(
    int tsMs, {
    required double durationSecs,
  }) => BehaviorEventInput._(
    tsMs: tsMs,
    kind: 'system_failure',
    value: durationSecs,
    data: <String, dynamic>{'duration_secs': durationSecs},
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ts_ms': tsMs,
    'kind': kind,
    'value': value,
    if (data.isNotEmpty) 'data': data,
  };
}
