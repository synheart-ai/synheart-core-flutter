import 'dart:async';
import 'package:flutter/material.dart';
import 'package:synheart_behavior/synheart_behavior.dart' as sb;
import '../../core/logger.dart';
import '../base/synheart_module.dart';
import '../interfaces/consent_provider.dart';
import '../interfaces/feature_providers.dart';
import '../interfaces/raw_data_provider.dart';
import '../../models/behavior_event_input.dart';
import '../../models/context_event_input.dart';
import 'behavior_code.dart';
import 'behavior_events.dart';
import 'behavior_event_stream.dart';
import 'motion_state_snapshot.dart';
import 'context_event_translator.dart';
import 'native_event_translator.dart';
import 'window_aggregator.dart';

/// Standard gravity in m/s².
///
/// `synheart_behavior` reports accelerometer samples in m/s² (gravity
/// included); the engine's `push_accel` takes **g**. This is the conversion
/// between them, and it must not be "simplified away" — see the call site.
const double _standardGravityMs2 = 9.80665;

/// Behavior Module
///
/// Captures user-device interaction patterns using synheart_behavior package.
///
/// Consent gating policy: no collection at all without consent.
/// synheart_behavior.initialize() starts native collection, so we only
/// initialize when `behavior` consent is granted (inside onStart).
class BehaviorModule extends BaseSynheartModule
    implements RawBehaviorDataProvider {
  @override
  String get moduleId => 'behavior';

  final BehaviorEventStream _eventStream = BehaviorEventStream();
  final WindowAggregator _aggregator = WindowAggregator();

  final ConsentProvider _consent;
  final bool _enableMotionLite;
  final bool _emitRawMotionSamples;

  StreamSubscription<BehaviorEvent>? _eventSubscription;
  StreamSubscription? _synheartBehaviorSubscription;
  StreamSubscription<List<sb.MotionSample>>? _motionSampleSubscription;
  Timer? _cleanupTimer;
  sb.SynheartBehavior? _synheartBehavior;
  StreamSubscription<ConsentSnapshot>? _consentSubscription;
  bool _isStarting = false;

  /// The open `synheart_behavior` session, when raw motion is being collected.
  ///
  /// Only motion needs one. The input and gesture collectors attach to the
  /// view at `initialize()` and emit without a session, which is why this was
  /// never noticed: `emitRawMotionSamples: true` reached the native config and
  /// still produced nothing, because `MotionSignalCollector.startSession` runs
  /// only from `BehaviorSDK.startSession()` and nothing ever called it. Its
  /// `updateConfig` cannot rescue that either — the start branch there is
  /// guarded on `sessionStartTime > 0`, which only a session sets.
  sb.BehaviorSession? _motionSession;

  /// Open a session so the accelerometer listener is actually registered.
  ///
  /// Scoped to the motion case on purpose. A session also resets app-switch
  /// counts and captures device context, so opening one unconditionally would
  /// change behaviour for every host that never asked for motion; hosts that
  /// leave `emitRawMotionSamples` off keep exactly the lifecycle they had.
  Future<void> _startMotionSessionIfNeeded() async {
    if (!_emitRawMotionSamples || _synheartBehavior == null) return;
    if (_motionSession != null) return;
    try {
      _motionSession = await _synheartBehavior!.startSession();
      SynheartLogger.log(
        '[BehaviorModule] motion session started — raw accel sampling active',
      );
    } catch (e, st) {
      // Non-fatal: everything else the module collects is session-independent.
      SynheartLogger.log(
        '[BehaviorModule] Failed to start motion session: $e',
        error: e,
        stackTrace: st,
      );
      _motionSession = null;
    }
  }

  Future<void> _endMotionSession() async {
    final session = _motionSession;
    _motionSession = null;
    if (session == null) return;
    try {
      await session.end();
    } catch (e) {
      SynheartLogger.log(
        '[BehaviorModule] Error ending motion session: $e',
        error: e,
      );
    }
  }

  /// When set, all behavior events are pushed to the runtime via this callback
  /// (so the runtime receives events even if stream delivery is delayed).
  ///
  /// Signature stays `(int eventType, …)` to avoid churning external host
  /// callers; the typed mapping ([RuntimeBehaviorEvent]) is enforced
  /// internally by [_behaviorEventToRuntimeCode] before we drop down to
  /// the int code at the call boundary.
  void Function(int tsMs, int eventType, double value)? _pushBehaviorToRuntime;
  set pushBehaviorToRuntime(
    void Function(int tsMs, int eventType, double value)? f,
  ) {
    _pushBehaviorToRuntime = f;
  }

  /// The rich behavior-event sink, preferred over [pushBehaviorToRuntime].
  ///
  /// Must return the runtime's status, or `null` when the loaded runtime does
  /// not export `synheart_core_push_behavior_event` — that `null` is what
  /// makes the module fall back to the legacy int-coded path, so a sink that
  /// swallowed it would silently drop every event on an older runtime.
  int? Function(BehaviorEventInput event)? _pushBehaviorEventToRuntime;
  set pushBehaviorEventToRuntime(int? Function(BehaviorEventInput event)? f) {
    _pushBehaviorEventToRuntime = f;
  }

  /// The context-evidence sink — a *second*, independent channel, not an
  /// alternative to [pushBehaviorEventToRuntime].
  ///
  /// The two land in different runtime buffers with different consumers: the
  /// behaviour channel feeds the interaction adapter and session-runtime's
  /// behavioural features, while this one feeds the person-relative context
  /// window, which is the only source of `context.deviation.*` — and therefore
  /// the only source of Cognitive Load's friction index. Pushing one event on
  /// each channel for one user action is correct and is **not** a double count;
  /// pushing the same event twice on the *same* channel is.
  ///
  /// Returns the runtime status (`0` = accepted), or `null` when the symbol is
  /// absent. A non-zero status most often means the runtime was built without
  /// the `app-context` cargo feature, which compiles the call as an inert stub.
  int? Function(ContextEventInput event)? _pushContextEventToRuntime;
  set pushContextEventToRuntime(int? Function(ContextEventInput event)? f) {
    _pushContextEventToRuntime = f;
  }

  /// Context events accepted / rejected by the runtime this session.
  int get contextEventsAccepted => _contextEventsAccepted;
  int _contextEventsAccepted = 0;

  int get contextEventsRejected => _contextEventsRejected;
  int _contextEventsRejected = 0;

  bool _contextRejectionLogged = false;

  /// When set, every raw 50 Hz accel sample is pushed to the runtime so
  /// the Synheart Runtime can derive motion features and the on-device
  /// motion classifier can classify posture. Wire this to
  /// `coreRuntime.pushAccel` from the host integration.
  void Function(int tsMs, double ax, double ay, double az)? _pushAccelToRuntime;
  set pushAccelToRuntime(
    void Function(int tsMs, double ax, double ay, double az)? f,
  ) {
    _pushAccelToRuntime = f;
  }

  BehaviorModule({
    required ConsentProvider consent,
    bool enableMotionLite = false,
    bool emitRawMotionSamples = false,
  }) : _consent = consent,
       _enableMotionLite = enableMotionLite,
       _emitRawMotionSamples = emitRawMotionSamples;

  /// Get the event stream for recording events (for manual instrumentation)
  BehaviorEventStream get eventStream => _eventStream;

  // Latest motion-state snapshot extracted from HSI
  // windows pushed via [ingestHsi]. Updates fire on `motionStateUpdates`.
  MotionStateSnapshot? _latestMotionState;
  final StreamController<MotionStateSnapshot> _motionStateController =
      StreamController<MotionStateSnapshot>.broadcast();

  /// Latest motion-state snapshot from the runtime, or `null` if none has been
  /// observed yet (for example when motion-state classification is disabled in
  /// the engine config). Updated by [ingestHsi].
  MotionStateSnapshot? get latestMotionState => _latestMotionState;

  /// Stream of motion-state updates extracted from HSI snapshots.
  /// Emits one event per HSI window that carries a `motion_state` reading.
  Stream<MotionStateSnapshot> get motionStateUpdates =>
      _motionStateController.stream;

  /// Feed an HSI 1.2 JSON snapshot in and surface the `motion_state` reading
  /// (when present) on [latestMotionState] and [motionStateUpdates]. Cheap
  /// to call on every HSI window — bails out fast when the snapshot has no
  /// behavior axis or no `motion_state` reading.
  void ingestHsi(String hsiJson) {
    final snap = MotionStateSnapshot.parseFromHsiJson(hsiJson);
    if (snap == null) return;
    _latestMotionState = snap;
    if (!_motionStateController.isClosed) {
      _motionStateController.add(snap);
    }
  }

  /// Get the synheart_behavior instance for wrapping your app
  ///
  /// Usage:
  /// ```dart
  /// Widget build(BuildContext context) {
  /// return hsi.behaviorModule!.synheartBehavior!.wrapWithGestureDetector(
  /// MaterialApp(..)
  /// );
  /// }
  /// ```
  sb.SynheartBehavior? get synheartBehavior => _synheartBehavior;

  @override
  List<BehaviorEvent> rawEvents(WindowType window) {
    if (!_consent.current().allowsChannel('behavior.digital_activity'))
      return [];
    return _aggregator.getEvents(window);
  }

  @override
  Future<void> onInitialize() async {
    // Intentionally do not initialize synheart_behavior here.
    //
    // Consent gating policy: no collection at all without consent.
    // synheart_behavior.initialize() starts native collection, so we only
    // initialize when `behavior` consent is granted (inside onStart).
  }

  /// Handle events from synheart_behavior, forwarding to event stream and runtime.
  ///
  /// Per-call diagnostics are gated to the first few events so we don't
  /// spam logs at the native event rate — just enough to answer the
  /// "are events flowing through the Dart bridge at all?" question when
  /// `behavior_events` shows up empty in an export.
  int _synheartBehaviorEventLogCount = 0;
  void _onSynheartBehaviorEvent(sb.BehaviorEvent event) {
    if (_synheartBehaviorEventLogCount < 3) {
      SynheartLogger.log(
        '[BehaviorModule] _onSynheartBehaviorEvent: received event '
        'type=${event.eventType.name}',
      );
      _synheartBehaviorEventLogCount++;
    }
    if (!_consent.current().allowsChannel('behavior.digital_activity')) {
      if (_synheartBehaviorEventLogCount <= 3) {
        SynheartLogger.log(
          '[BehaviorModule] _onSynheartBehaviorEvent: DROPPED '
          '(consent channel "behavior.digital_activity" not allowed — '
          'events are NOT forwarding to Synheart.behaviorEventStream, '
          'behavior_events will be empty)',
        );
      }
      return;
    }
    final behaviorEvent = _convertSynheartEvent(event);
    if (behaviorEvent != null) {
      _eventStream.addEvent(behaviorEvent);
      // Push directly to runtime so app_switch, notification, etc. are never
      // missed.
      //
      // Two paths, and the rich one is tried first. It carries the payload the
      // native collectors already captured — scroll direction and reversal,
      // the notification's source app, tap duration — all of which the legacy
      // int-coded call flattens to a single double. The legacy path is the
      // fallback for a vendored runtime that predates
      // `synheart_core_push_behavior_event`, and the two are mutually
      // exclusive per event: pushing both would count every interaction twice.
      final tsMs = behaviorEvent.timestamp.millisecondsSinceEpoch;
      final rich = translateNativeBehaviorEvent(event);
      final richStatus = rich == null
          ? null
          : _pushBehaviorEventToRuntime?.call(rich);
      if (richStatus == null) {
        final mapped = _behaviorEventToRuntimeCode(behaviorEvent);
        if (mapped != null) {
          _pushBehaviorToRuntime?.call(tsMs, mapped.$1.code, mapped.$2);
        }
      }

      // The context channel, in addition to whichever behaviour path ran
      // above. Independent buffer, independent consumer — see
      // [pushContextEventToRuntime]. Without this the context window sees no
      // events, so `pause_elevation` / `err_elevation` / `scroll_deviation`
      // are structurally zero and CFI has no inputs.
      _pushContextEvent(translateNativeContextEvent(event));
    } else if (_synheartBehaviorEventLogCount <= 3) {
      SynheartLogger.log(
        '[BehaviorModule] _onSynheartBehaviorEvent: DROPPED '
        '(_convertSynheartEvent returned null for type=${event.eventType.name})',
      );
    }
  }

  /// Push one context event, counting the outcome. A `null` event is a
  /// deliberate no-representation case and is not an error.
  void _pushContextEvent(ContextEventInput? event) {
    if (event == null) return;
    final status = _pushContextEventToRuntime?.call(event);
    if (status == null) return;
    if (status == 0) {
      _contextEventsAccepted++;
      return;
    }
    _contextEventsRejected++;
    if (!_contextRejectionLogged) {
      _contextRejectionLogged = true;
      SynheartLogger.log(
        '[BehaviorModule] push_context_event returned $status. Far more likely '
        'to mean the runtime was built without the `app-context` cargo feature '
        '(which compiles the symbol as an inert stub that always returns 1) '
        'than that the payload was malformed — the payload shape is pinned by '
        'test/context_event_input_test.dart. Without a context layer, CFI and '
        'the context deviation terms stay at zero.',
      );
    }
  }

  /// Push a context event the host derived itself.
  ///
  /// This is how **keyboard** evidence reaches the engine. Native taps are
  /// keystroke-ambiguous on Android (the input collector emits every keystroke
  /// as a `tap`), so the translator drops them and text-entry classification
  /// has to come from the layer that can actually see it — a `TextField`
  /// listener, an IME, or a keyboard extension. Send
  /// [ContextEventInput.textChange] for every insertion *and* every deletion:
  /// `err_rate` is `N_corr / N_key`, so corrections without keystrokes leave
  /// the denominator at zero.
  void pushHostContextEvent(ContextEventInput event) =>
      _pushContextEvent(event);

  /// Maps internal [BehaviorEvent] → ([RuntimeBehaviorEvent], value).
  /// Returns null when the event has no runtime representation.
  (RuntimeBehaviorEvent, double)? _behaviorEventToRuntimeCode(
    BehaviorEvent event,
  ) {
    switch (event.type) {
      case BehaviorEventType.screenOn:
        return (RuntimeBehaviorEvent.screenOn, 1.0);
      case BehaviorEventType.screenOff:
        return (RuntimeBehaviorEvent.screenOff, 1.0);
      case BehaviorEventType.tap:
      case BehaviorEventType.keyDown:
      case BehaviorEventType.keyUp:
        return (RuntimeBehaviorEvent.input, 1.0);
      case BehaviorEventType.appSwitch:
        return (RuntimeBehaviorEvent.appSwitch, 1.0);
      case BehaviorEventType.notificationReceived:
      case BehaviorEventType.notificationOpened:
        return (RuntimeBehaviorEvent.notification, 1.0);
      case BehaviorEventType.scroll:
        final delta = event.metadata?['delta'] is num
            ? (event.metadata!['delta'] as num).toDouble()
            : 1.0;
        return (RuntimeBehaviorEvent.scroll, delta);
      case BehaviorEventType.swipe:
        final vel = event.metadata?['velocity'] is num
            ? (event.metadata!['velocity'] as num).toDouble()
            : 1.0;
        return (RuntimeBehaviorEvent.swipe, vel);
      case BehaviorEventType.call:
        return (RuntimeBehaviorEvent.call, 1.0);
    }
  }

  @override
  Future<void> onStart() async {
    SynheartLogger.log('[BehaviorModule] Starting behavior tracking..');

    // Observe consent so we can start/stop dynamically.
    _consentSubscription ??= _consent.observe().listen(
      (consent) async {
        if (!consent.allowsChannel('behavior.digital_activity')) {
          await _stopTracking(disposeSdk: true);
        } else {
          await _startTrackingIfNeeded();
        }
      },
      onError: (e, st) => SynheartLogger.log(
        '[BehaviorModule] Consent observation error: $e',
        error: e,
        stackTrace: st,
      ),
    );

    // Start only if consent is granted.
    await _startTrackingIfNeeded();
  }

  Future<void> _startTrackingIfNeeded() async {
    if (_isStarting) {
      SynheartLogger.log(
        '[BehaviorModule] _startTrackingIfNeeded: SKIP (already starting)',
      );
      return;
    }
    if (_eventSubscription != null || _cleanupTimer != null) {
      SynheartLogger.log(
        '[BehaviorModule] _startTrackingIfNeeded: SKIP (already running: '
        'eventSub=${_eventSubscription != null}, '
        'cleanupTimer=${_cleanupTimer != null}, '
        'synheart_behavior=${_synheartBehavior != null})',
      );
      return;
    }
    if (!_consent.current().allowsChannel('behavior.digital_activity')) {
      SynheartLogger.log(
        '[BehaviorModule] _startTrackingIfNeeded: SKIP (consent channel '
        '"behavior.digital_activity" not granted)',
      );
      return;
    }

    SynheartLogger.log(
      '[BehaviorModule] _startTrackingIfNeeded: proceeding '
      '(synheart_behavior currently ${_synheartBehavior == null ? "null" : "set"})',
    );

    _isStarting = true;
    try {
      // Initialize synheart_behavior only after consent is granted.
      if (_synheartBehavior == null) {
        SynheartLogger.log(
          '[BehaviorModule] Calling SynheartBehavior.initialize()…',
        );
        try {
          _synheartBehavior = await sb.SynheartBehavior.initialize(
            config: sb.BehaviorConfig(
              enableInputSignals: true,
              enableAttentionSignals: true,
              enableMotionLite: _enableMotionLite,
              emitRawMotionSamples: _emitRawMotionSamples,
            ),
          );
          SynheartLogger.log(
            '[BehaviorModule] synheart_behavior initialized successfully '
            '(instance=${_synheartBehavior != null})',
          );
          await _startMotionSessionIfNeeded();
        } catch (e, st) {
          SynheartLogger.log(
            '[BehaviorModule] Failed to initialize synheart_behavior: $e',
            error: e,
            stackTrace: st,
          );
          _synheartBehavior = null;
        }
      }

      // Subscribe to manual event stream only when consent is granted.
      _eventSubscription = _eventStream.events.listen(
        (event) {
          if (!_consent.current().allowsChannel('behavior.digital_activity'))
            return;
          _aggregator.addEvent(event);
        },
        onError: (e, st) => SynheartLogger.log(
          '[BehaviorModule] Event stream error: $e',
          error: e,
          stackTrace: st,
        ),
      );

      // Subscribe to synheart_behavior automatic events (if available).
      final synheartBehavior = _synheartBehavior;
      if (synheartBehavior != null) {
        _synheartBehaviorSubscription = synheartBehavior.onEvent.listen(
          _onSynheartBehaviorEvent,
          onError: (e, st) => SynheartLogger.log(
            '[BehaviorModule] synheart_behavior event error: $e',
            error: e,
            stackTrace: st,
          ),
        );

        // Forward raw 50 Hz accel batches into the runtime so the kinematic
        // heads can classify posture, activity and locomotion.
        // Only subscribed when both `emitRawMotionSamples` is enabled and
        // the host has wired a runtime push callback — otherwise we'd
        // accumulate batches with nowhere to send them.
        if (_emitRawMotionSamples) {
          _motionSampleSubscription = synheartBehavior.onMotionSample.listen(
            (samples) {
              final push = _pushAccelToRuntime;
              if (push == null) return;
              for (final s in samples) {
                // Unit conversion, and it is not cosmetic. `MotionSample` is
                // documented as m/s² with gravity included (Android's raw
                // `TYPE_ACCELEROMETER`), whereas the engine's `push_accel`
                // takes **g** and multiplies by `G` internally to store m/s².
                // Forwarded raw, a phone at rest reported ~9.81 and the engine
                // stored ~96 m/s² — every magnitude-based cut-point in
                // `activity_state` and `locomotion_state` was ~9.8x off, the
                // RulePack still-gate never saw stillness (so no personal
                // physiological baseline could ever accumulate), and any host
                // reading `meta.synheart.motion.accel_rms` back out for its own
                // rest detection never satisfied a low-motion clause.
                //
                // It cleared the runtime's own ±50 sanity gate because that
                // gate runs on the pre-multiply value. `synheart-wear-rust`
                // converts explicitly for the same reason (Polar reports
                // milli-g, it divides by 1000) — g is the engine's contract
                // across the whole ecosystem, not a Flutter-side choice.
                push(
                  s.tsMs,
                  s.ax / _standardGravityMs2,
                  s.ay / _standardGravityMs2,
                  s.az / _standardGravityMs2,
                );
              }
            },
            onError: (e, st) => SynheartLogger.log(
              '[BehaviorModule] motion sample stream error: $e',
              error: e,
              stackTrace: st,
            ),
          );
        }
      }

      // Start cleanup timer (every minute) only while collecting.
      _cleanupTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        _aggregator.cleanOldWindows();
      });

      SynheartLogger.log('[BehaviorModule] Behavior tracking started');
    } finally {
      _isStarting = false;
    }
  }

  Future<void> _stopTracking({required bool disposeSdk}) async {
    await _eventSubscription?.cancel();
    _eventSubscription = null;

    await _synheartBehaviorSubscription?.cancel();
    _synheartBehaviorSubscription = null;

    await _motionSampleSubscription?.cancel();
    _motionSampleSubscription = null;

    _cleanupTimer?.cancel();
    _cleanupTimer = null;

    // End the motion session before tearing the SDK down: `endSession` is
    // what calls `motionSignalCollector.stopSession()`, so skipping it leaves
    // the accelerometer listener registered against a disposed SDK.
    await _endMotionSession();

    if (disposeSdk) {
      try {
        await _synheartBehavior?.dispose();
      } catch (e) {
        SynheartLogger.log(
          '[BehaviorModule] Error disposing synheart_behavior: $e',
          error: e,
        );
      } finally {
        _synheartBehavior = null;
      }
    }
  }

  /// Convert synheart_behavior event to internal BehaviorEvent format
  BehaviorEvent? _convertSynheartEvent(sb.BehaviorEvent event) {
    final eventType = event.eventType;

    switch (eventType) {
      case sb.BehaviorEventType.tap:
        // Preserve the native tap coordinates when the iOS plugin
        // provides them (UITapGestureRecognizer.location(in:) on a
        // non-zero view). Falls back to Offset.zero when absent so
        // downstream consumers always receive a well-formed event.
        final x = (event.metrics['x'] as num?)?.toDouble() ?? 0.0;
        final y = (event.metrics['y'] as num?)?.toDouble() ?? 0.0;
        return BehaviorEvent.tap(Offset(x, y));
      case sb.BehaviorEventType.scroll:
        final velocity = event.metrics['velocity'] as double? ?? 0.0;
        return BehaviorEvent.scroll(velocity);
      case sb.BehaviorEventType.typing:
        return BehaviorEvent.keyDown();
      case sb.BehaviorEventType.notification:
        final action = event.metrics['action'] as String?;
        if (action == 'opened') {
          return BehaviorEvent.notificationOpened();
        } else {
          return BehaviorEvent.notificationReceived();
        }
      case sb.BehaviorEventType.call:
        return BehaviorEvent.call();
      case sb.BehaviorEventType.swipe:
        final velocity = event.metrics['velocity'] is num
            ? (event.metrics['velocity'] as num).toDouble()
            : 1.0;
        final direction = event.metrics['direction'] is String
            ? event.metrics['direction'] as String
            : null;
        return BehaviorEvent.swipe(velocity: velocity, direction: direction);
      case sb.BehaviorEventType.app_switch:
        // Required for HSI 1.3 axes.digital[] computation: the runtime's
        // interaction_adapter pairs each app_switch with the next
        // foreground transition for notification-response detection
        // (PRD §1 NR / §2 attentional cost). Dropping app_switch here
        // would leave the digital axis silent on iOS / Android.
        return BehaviorEvent.appSwitch();
      case sb.BehaviorEventType.clipboard:
        return null;
      // Forward-compat: newer synheart_behavior versions may add variants
      // that this SDK doesn't yet map. Drop them silently.
      // ignore: unreachable_switch_default
      default:
        return null;
    }
  }

  @override
  Future<void> onStop() async {
    SynheartLogger.log('[BehaviorModule] Stopping behavior tracking..');
    await _consentSubscription?.cancel();
    _consentSubscription = null;
    await _stopTracking(disposeSdk: true);
  }

  /// Clear all cached data
  Future<void> clearCache() async {
    _aggregator.clear();
    SynheartLogger.log('[BehaviorModule] Cache cleared');
  }

  @override
  Future<void> onDispose() async {
    SynheartLogger.log('[BehaviorModule] Disposing behavior module..');
    await _eventStream.dispose();
    await _motionStateController.close();
    _synheartBehavior = null;
  }
}
