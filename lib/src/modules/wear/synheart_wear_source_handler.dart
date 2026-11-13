import 'dart:async';
import 'package:synheart_wear/synheart_wear.dart' as wear;
import 'wear_source_handler.dart';

/// WearSourceHandler implementation using synheart_wear package
///
/// This adapter bridges the synheart_wear SDK to the Core SDK's WearModule.
/// It supports all devices that synheart_wear supports:
/// - Apple Watch (via HealthKit)
/// - Fitbit (via REST API)
/// - Garmin, Whoop, Samsung (when available)
///
/// See: https://pub.dev/packages/synheart_wear
class SynheartWearSourceHandler implements WearSourceHandler {
  wear.SynheartWear? _synheartWear;
  final wear.SynheartWearConfig? _config;

  StreamController<WearSample>? _controller;
  StreamSubscription<wear.WearMetrics>? _hrSubscription;
  StreamSubscription<wear.WearMetrics>? _hrvSubscription;

  bool _isInitialized = false;
  bool _focusEnabled = false;
  bool _emotionEnabled = false;

  SynheartWearSourceHandler({
    wear.SynheartWearConfig? config,
    bool focusEnabled = false,
    bool emotionEnabled = false,
  }) : _config = config,
       _focusEnabled = focusEnabled,
       _emotionEnabled = emotionEnabled;

  @override
  WearSourceType get sourceType {
    // Determine source type from config if available
    if (_config?.enabledAdapters.contains(wear.DeviceAdapter.platformHealth) ==
        true) {
      return WearSourceType.appleHealth;
    }
    if (_config?.enabledAdapters.contains(wear.DeviceAdapter.fitbit) == true) {
      return WearSourceType.whoop; // Using whoop as placeholder for Fitbit
    }
    // Default to Apple Health if no specific adapter configured
    return WearSourceType.appleHealth;
  }

  @override
  bool get isAvailable {
    // synheart_wear handles platform availability internally
    // We assume it's available if the package is imported
    return true;
  }

  @override
  Future<void> initialize() async {
    // If already initialized and SDK exists, skip
    if (_isInitialized && _synheartWear != null) {
      return;
    }

    // If SDK was disposed (e.g., after stop()), we need to recreate it
    if (_synheartWear == null) {
      // Initialize synheart_wear SDK with config or default
      _synheartWear = wear.SynheartWear(
        config:
            _config ??
            wear.SynheartWearConfig.withAdapters({
              wear.DeviceAdapter.platformHealth,
            }),
      );

      // Initialize the wear SDK — this handles permissions, adapter setup,
      // and data validation internally. No need to call requestPermissions()
      // separately; doing so would trigger a duplicate HealthKit dialog.
      try {
        await _synheartWear!.initialize();
      } on wear.SynheartWearError {
        rethrow;
      } catch (e) {
        throw Exception('Failed to initialize synheart_wear: $e');
      }
    }

    // Create stream controller if it doesn't exist
    _controller ??= StreamController<WearSample>.broadcast();

    // Note: Don't start streaming here - let the caller control when to start
    // Streaming will be started explicitly via _startStreaming() when needed

    _isInitialized = true;
  }

  /// Start streaming HR data
  ///
  /// This should be called explicitly after initialization and consent check
  /// to ensure we only stream when consent is granted
  void startStreaming() {
    if (_hrSubscription == null &&
        _synheartWear != null &&
        _controller != null) {
      // SynheartLogger.log(
      //   '[SynheartWearSourceHandler] Starting HR streaming...',
      // );
      _startStreaming();
    } else {
      // SynheartLogger.log(
      //   '[SynheartWearSourceHandler] Cannot start streaming: hrSubscription=${_hrSubscription != null}, sdk=${_synheartWear != null}, controller=${_controller != null}',
      // );
    }
  }

  void _startStreaming() {
    if (_synheartWear == null || _controller == null) {
      return;
    }

    // Determine optimal interval based on enabled modules
    // If Focus or Emotion enabled, use 1s (required for 30+ HR points in 60s window)
    // For HSV-only, 2-3s is sufficient (20-30 calls/min, still accurate for HRV)
    final hrInterval = _getOptimalInterval();

    _hrSubscription = _synheartWear!
        .streamHR(interval: hrInterval)
        .listen(
          (wearMetrics) {
            _emitSample(wearMetrics);
          },
          onError: (error) {
            _controller?.addError(error);
          },
        );

    // Removed HRV stream subscription - HR stream already includes HRV data
    // Note: readMetrics() returns all available metrics including HRV, so we don't need
    // a separate HRV stream subscription. Using a single stream reduces Health Connect
    // API calls and prevents rate limiting issues.
  }

  /// Get optimal collection interval based on enabled modules
  ///
  /// - Focus/Emotion enabled: 1s (60 calls/min) - required for 30+ HR points in 60s window
  /// - HSV-only: 5s (12 calls/min) - sufficient for accurate HRV, significantly reduces API calls
  Duration _getOptimalInterval() {
    // Use custom interval override if set
    if (_customInterval != null) {
      return _customInterval!;
    }

    // Use config override if provided
    if (_config?.streamInterval != null) {
      return _config!.streamInterval;
    }

    // If Focus or Emotion enabled, use 1s (required)
    if (_focusEnabled || _emotionEnabled) {
      return const Duration(seconds: 1);
    }

    // For HSV-only, 5s is sufficient (12 calls/min)
    // This provides:
    // - 12 HR points/min (enough for accurate HRV calculations over longer windows)
    // - 6 points in 30s window (sufficient for window aggregation)
    // - 80% reduction in API calls vs 1s interval
    // - Well within Health Connect limits (12 calls/min << 30-60 limit)
    return const Duration(seconds: 5);
  }

  /// Update module enablement status and restart streaming if needed
  ///
  /// This allows dynamic adjustment of collection frequency when
  /// Focus/Emotion modules are enabled or disabled at runtime.
  Future<void> updateModuleStatus({
    bool? focusEnabled,
    bool? emotionEnabled,
  }) async {
    final oldFocus = _focusEnabled;
    final oldEmotion = _emotionEnabled;

    // Calculate old interval before updating values
    final oldInterval = (oldFocus || oldEmotion)
        ? const Duration(seconds: 1)
        : const Duration(seconds: 5);

    if (focusEnabled != null) {
      _focusEnabled = focusEnabled;
    }
    if (emotionEnabled != null) {
      _emotionEnabled = emotionEnabled;
    }

    // If status changed and we're already streaming, restart with new interval
    if (_isInitialized &&
        _hrSubscription != null &&
        (oldFocus != _focusEnabled || oldEmotion != _emotionEnabled)) {
      final newInterval = _getOptimalInterval();

      // Only restart if interval actually changed
      if (oldInterval != newInterval) {
        await _hrSubscription?.cancel();
        _hrSubscription = null;
        _startStreaming();
      }
    }
  }

  Duration? _customInterval; // Store custom interval override

  /// Update collection interval
  ///
  /// Changes the collection frequency. If already streaming, restarts with new interval.
  Future<void> updateCollectionInterval(Duration interval) async {
    // Store custom interval override
    _customInterval = interval;

    // If already streaming, restart with new interval
    if (_isInitialized && _hrSubscription != null) {
      await _hrSubscription?.cancel();
      _hrSubscription = null;
      _startStreaming();
    }
  }

  void _emitSample(wear.WearMetrics wearMetrics) {
    if (_controller == null || _controller!.isClosed) {
      return;
    }

    // Convert WearMetrics to WearSample
    final hr = wearMetrics.getMetric(wear.MetricType.hr)?.toDouble();
    final hrvRmssd = wearMetrics
        .getMetric(wear.MetricType.hrvRmssd)
        ?.toDouble();
    final hrvSdnn = wearMetrics.getMetric(wear.MetricType.hrvSdnn)?.toDouble();

    // RMSSD and SDNN are different statistics; never report one as the other.

    // Get RR intervals if available
    final rrIntervals = wearMetrics.rrIntervalsMs;

    // Pass raw steps as motion input — the Core runtime normalizes
    // and computes motion intensity from this + accelerometer data.
    final steps =
        wearMetrics.getMetric(wear.MetricType.steps)?.toDouble() ?? 0.0;

    final sample = WearSample(
      timestamp: wearMetrics.timestamp, // Use timestamp from metrics
      hr: hr,
      hrvRmssd: hrvRmssd,
      hrvSdnn: hrvSdnn,
      respRate: null, // Not provided by synheart_wear yet
      motionLevel: steps, // Raw steps — runtime normalizes
      sleepStage: null, // Not provided by synheart_wear yet
      rrIntervals: rrIntervals,
    );

    _controller!.add(sample);
  }

  @override
  Stream<WearSample> get sampleStream {
    if (_controller == null) {
      throw StateError(
        'SynheartWearSourceHandler not initialized. Call initialize() first.',
      );
    }
    return _controller!.stream;
  }

  @override
  Future<void> stop() async {
    // SynheartLogger.log('[SynheartWearSourceHandler] Stopping HR streaming...');

    // Cancel subscriptions to stop receiving data
    await _hrSubscription?.cancel();
    _hrSubscription = null;
    await _hrvSubscription?.cancel();
    _hrvSubscription = null;

    // Explicitly dispose synheart_wear SDK to stop its internal timers
    // This ensures streaming stops immediately, not waiting for timer checks
    // The SDK will be re-initialized if needed when restarting
    if (_synheartWear != null) {
      _synheartWear!.dispose();
      _synheartWear = null;
      // SynheartLogger.log(
      //   '[SynheartWearSourceHandler] synheart_wear SDK disposed',
      // );
    }

    // Note: _isInitialized remains true to allow checking if re-init is needed
    // The controller stays open for potential restart
  }

  @override
  Future<void> dispose() async {
    // Stop streaming first
    await stop();

    // Close the stream controller
    await _controller?.close();
    _controller = null;
    _isInitialized = false;
  }
}
