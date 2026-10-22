import 'dart:async';
import '../../core/logger.dart';
import '../base/runtime_channel_gate.dart';
import '../base/synheart_module.dart';
import '../interfaces/capability_provider.dart';
import '../interfaces/consent_provider.dart';
import '../interfaces/feature_providers.dart';
import '../interfaces/raw_data_provider.dart';
import 'phone_collectors.dart';
import 'phone_cache.dart';

/// Phone Module
///
/// Captures device-level motion and context signals.
class PhoneModule extends BaseSynheartModule
    with RuntimeChannelGate
    implements RawPhoneDataProvider {
  @override
  String get moduleId => 'phone';

  final MotionCollector _motionCollector = MotionCollector();
  final ScreenStateTracker _screenTracker = ScreenStateTracker();
  final AppFocusTracker _appTracker = AppFocusTracker();
  final NotificationTracker _notificationTracker = NotificationTracker();
  final PhoneCache _cache = PhoneCache();

  final CapabilityProvider _capabilities;
  final ConsentProvider _consent;

  final List<StreamSubscription> _subscriptions = [];
  StreamSubscription<ConsentSnapshot>? _consentSubscription;
  bool _isStartingCollection = false;

  PhoneModule({
    required CapabilityProvider capabilities,
    required ConsentProvider consent,
  }) : _capabilities = capabilities,
       _consent = consent;

  /// Each collector needs phone-context consent and, with a runtime attached,
  /// the runtime's acceptance of its own channel.
  bool _collects(String channel) =>
      _consent.current().phoneContext && runtimeAllows(channel);

  @override
  List<PhoneDataPoint> rawDataPoints(WindowType window) {
    if (!_consent.current().phoneContext) return [];
    return _cache.getDataPoints(window);
  }

  @override
  Future<void> onInitialize() async {
    SynheartLogger.log('[PhoneModule] Initializing phone collectors...');
    // The collectors have no platform source; see phone_collectors.dart.
  }

  @override
  Future<void> onStart() async {
    SynheartLogger.log('[PhoneModule] Starting phone data collection...');

    // Consent gating policy: no collection at all without consent.
    // Always observe consent so we can start/stop dynamically.
    _consentSubscription ??= _consent.observe().listen(
      (consent) async {
        if (!consent.phoneContext) {
          await _stopDataCollection();
        } else {
          await _startDataCollectionIfNeeded();
        }
      },
      onError: (e, st) => SynheartLogger.log(
        '[PhoneModule] Consent observation error: $e',
        error: e,
        stackTrace: st,
      ),
    );

    // Start only if consent is granted.
    await _startDataCollectionIfNeeded();
  }

  Future<void> _startDataCollectionIfNeeded() async {
    if (_isStartingCollection || _subscriptions.isNotEmpty) return;
    if (!_consent.current().phoneContext) return;
    _isStartingCollection = true;
    try {
      // Start motion collection
      if (runtimeAllows('phone_context.device_motion')) {
        await _motionCollector.start();
        _subscriptions.add(
          _motionCollector.motionStream.listen(
            (motion) {
              if (!_collects('phone_context.device_motion')) return;
              _cache.addMotionData(motion);
            },
            onError: (e, st) => SynheartLogger.log(
              '[PhoneModule] Motion error: $e',
              error: e,
              stackTrace: st,
            ),
          ),
        );
      }

      // Start screen state tracking
      if (runtimeAllows('phone_context.system_state')) {
        await _screenTracker.start();
        _subscriptions.add(
          _screenTracker.screenStream.listen(
            (state) {
              if (!_collects('phone_context.system_state')) return;
              _cache.addScreenState(state, DateTime.now());
            },
            onError: (e, st) => SynheartLogger.log(
              '[PhoneModule] Screen state error: $e',
              error: e,
              stackTrace: st,
            ),
          ),
        );
      }

      // Start app tracking (if capability allows)
      if (_capabilities.capability(Module.phone).index >=
              CapabilityLevel.extended.index &&
          runtimeAllows('behavior.app_context')) {
        await _appTracker.start();
        _subscriptions.add(
          _appTracker.appSwitchStream.listen(
            (_) {
              if (!_collects('behavior.app_context')) return;
              _cache.addAppSwitch(DateTime.now());
            },
            onError: (e, st) => SynheartLogger.log(
              '[PhoneModule] App tracking error: $e',
              error: e,
              stackTrace: st,
            ),
          ),
        );
      }

      // Start notification tracking (if capability allows)
      if (_capabilities.capability(Module.phone).index >=
              CapabilityLevel.extended.index &&
          runtimeAllows('behavior.notification_patterns')) {
        await _notificationTracker.start();
        _subscriptions.add(
          _notificationTracker.notificationStream.listen(
            (event) {
              if (!_collects('behavior.notification_patterns')) return;
              _cache.addNotification(event);
            },
            onError: (e, st) => SynheartLogger.log(
              '[PhoneModule] Notification error: $e',
              error: e,
              stackTrace: st,
            ),
          ),
        );
      }

      SynheartLogger.log(
        '[PhoneModule] Started ${_subscriptions.length} collectors',
      );
    } finally {
      _isStartingCollection = false;
    }
  }

  Future<void> _stopDataCollection() async {
    if (_subscriptions.isEmpty) return;

    // Cancel all subscriptions
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();

    // Stop all collectors
    await _motionCollector.stop();
    await _screenTracker.stop();
    await _appTracker.stop();
    await _notificationTracker.stop();
    SynheartLogger.log('[PhoneModule] Phone collectors stopped');
  }

  @override
  Future<void> onStop() async {
    SynheartLogger.log('[PhoneModule] Stopping phone data collection...');

    await _consentSubscription?.cancel();
    _consentSubscription = null;
    await _stopDataCollection();
  }

  /// Clear all cached data
  Future<void> clearCache() async {
    _cache.clear();
    SynheartLogger.log('[PhoneModule] Cache cleared');
  }

  @override
  Future<void> onDispose() async {
    SynheartLogger.log('[PhoneModule] Disposing phone module...');

    await _motionCollector.dispose();
    await _screenTracker.dispose();
    await _appTracker.dispose();
    await _notificationTracker.dispose();
  }
}
