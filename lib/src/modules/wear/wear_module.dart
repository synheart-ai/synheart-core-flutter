import 'dart:async';
import 'dart:convert';
import 'package:synheart_wear/synheart_wear.dart' as wear;
import '../../core/logger.dart';
import '../../core_runtime/core_runtime_bridge.dart';
import '../../models/canonical_wearable_event.dart';
import '../base/synheart_module.dart';
import '../interfaces/consent_provider.dart';
import '../interfaces/feature_providers.dart';
import '../interfaces/raw_data_provider.dart';
import 'wear_source_handler.dart';
import 'wear_cache.dart';
import 'wear_module_status.dart';
import 'synheart_wear_source_handler.dart';
import 'wearable_event_processor.dart';

/// Wear Module
///
/// Collects and buffers raw biosignals from wearables.
class WearModule extends BaseSynheartModule implements RawWearDataProvider {
  @override
  String get moduleId => 'wear';

  final List<WearSourceHandler> _sources;
  final WearCache _cache = WearCache();
  final ConsentProvider _consent;

  final List<StreamSubscription<WearSample>> _subscriptions = [];
  StreamSubscription<ConsentSnapshot>? _consentSubscription;
  bool _isStartingCollection = false;

  // Stream controller for raw samples (broadcast for multiple subscribers)
  StreamController<WearSample>? _rawSampleController;

  // Stream controller for module status events
  final StreamController<WearModuleStatus> _statusController =
      StreamController<WearModuleStatus>.broadcast();

  // Vendor sync state — emits true/false when vendor_sync consent changes.
  // The wear SDK (synheart_wear) subscribes to this to start/stop RAMEN.
  final StreamController<bool> _vendorSyncController =
      StreamController<bool>.broadcast();
  bool _lastVendorSyncState = false;

  // Canonical vendor event stream — emits after normalization + storage.
  final StreamController<CanonicalWearableEvent> _canonicalEventController =
      StreamController<CanonicalWearableEvent>.broadcast();

  /// Bridge to native runtime for vendor event storage.
  CoreRuntimeBridge? _bridge;

  // Wearable event processor — bridges RAMEN events to the SRM pipeline.
  // Set via setEventProcessor() after Synheart.configure() provides storage + runtime.
  WearableEventProcessor? _eventProcessor;

  WearModule({
    required ConsentProvider consent,
    List<WearSourceHandler>? sources,
    @Deprecated(
      'Passing false now yields no sources rather than a mock. Inject your own '
      'WearSourceHandler via `sources:` for tests. Will be removed in 0.12.0.',
    )
    bool useSynheartWear = true,
    bool focusEnabled = false,
    bool emotionEnabled = false,
    this.autoStartOnConsent = true,
  }) : _consent = consent,
       _sources =
           sources ??
           (useSynheartWear
               ? [
                   SynheartWearSourceHandler(
                     focusEnabled: focusEnabled,
                     emotionEnabled: emotionEnabled,
                   ),
                 ]
               // No sources. This used to fall back to a MockWearSourceHandler
               // that synthesised heart rate, HRV, RR intervals and sleep
               // stages from `Random()`. Those samples were indistinguishable
               // from real ones downstream and fed the runtime's longitudinal
               // baselines, so a host that flipped this flag silently corrupted
               // the user's on-device reference ranges with invented numbers.
               //
               // Nothing is lost: `sources:` already accepts an injected
               // WearSourceHandler, which is the supported way to supply a fake
               // in tests. No sources means no data, which is honest.
               : const <WearSourceHandler>[]);

  /// Whether consent alone starts the sources (see
  /// [WearConfig.autoStartPlatformHealth]). When false they start only after
  /// [requestCollection].
  final bool autoStartOnConsent;

  bool _collectionRequested = false;

  bool get _mayCollect => autoStartOnConsent || _collectionRequested;

  /// Ask for collection explicitly — what [Synheart.startWearCollection]
  /// does. With [autoStartOnConsent] false this is the only thing that
  /// starts the sources; it still waits for biosignals consent.
  Future<void> requestCollection() async {
    _collectionRequested = true;
    if (status == ModuleStatus.running &&
        _consent.current().allowsChannel('biosignals.vitals')) {
      await _startDataCollection();
    }
  }

  /// Update module enablement status
  ///
  /// This allows dynamic adjustment of collection frequency when
  /// Focus/Emotion modules are enabled or disabled at runtime.
  Future<void> updateModuleStatus({
    bool? focusEnabled,
    bool? emotionEnabled,
  }) async {
    // Update all SynheartWearSourceHandler instances
    for (final source in _sources) {
      if (source is SynheartWearSourceHandler) {
        await source.updateModuleStatus(
          focusEnabled: focusEnabled,
          emotionEnabled: emotionEnabled,
        );
      }
    }
  }

  /// Update collection interval
  ///
  /// Changes the collection frequency for wear data.
  /// This will restart streaming with the new interval if already running.
  ///
  /// Example:
  /// ```dart
  /// await wearModule.updateCollectionInterval(Duration(seconds: 1));
  /// ```
  Future<void> updateCollectionInterval(Duration interval) async {
    for (final source in _sources) {
      if (source is SynheartWearSourceHandler) {
        await source.updateCollectionInterval(interval);
      }
    }
  }

  @override
  List<WearSample> rawSamples(WindowType window) {
    if (!_consent.current().allowsChannel('biosignals.vitals')) return [];
    return _cache.getSamples(window);
  }

  @override
  Future<void> onInitialize() async {
    // Intentionally do not initialize sources here.
    //
    // `synheart_wear.initialize()` may trigger OS permission dialogs (HealthKit /
    // Health Connect). We must not prompt until the user has granted Synheart
    // biosignals consent. Sources are initialized on-demand inside
    // `_startDataCollection()` when consent is granted.
  }

  @override
  Future<void> onStart() async {
    // SynheartLogger.log('[WearModule] Starting wear data collection...');

    // Create the raw sample stream controller before starting collection so
    // early samples reach the runtime. Lazy creation on first subscribe would
    // drop samples that arrive between Wear start and runtime subscribe.
    _rawSampleController ??= StreamController<WearSample>.broadcast();

    // Listen to consent changes to dynamically stop/start collection
    // Use asyncMap to properly handle async operations in the stream
    _consentSubscription = _consent
        .observe()
        .asyncMap((consent) async {
          if (!consent.allowsChannel('biosignals.vitals')) {
            // Consent revoked - stop data collection immediately
            // SynheartLogger.log(
            //   '[WearModule] Biosignals consent revoked - stopping data collection',
            // );
            await _stopDataCollection();
          } else if (consent.allowsChannel('biosignals.vitals') &&
              _subscriptions.isEmpty &&
              _mayCollect) {
            // Consent granted (either initially or after revoke) — start data collection.
            await _startDataCollection();
          }

          // Track vendor sync state changes
          final vendorSyncNow = consent.vendorSync;
          if (vendorSyncNow != _lastVendorSyncState) {
            _lastVendorSyncState = vendorSyncNow;
            _vendorSyncController.add(vendorSyncNow);
            SynheartLogger.log(
              '[WearModule] Vendor sync ${vendorSyncNow ? "enabled" : "disabled"}',
            );
          }

          return consent;
        })
        .listen(
          (_) {
            // Stream processed
          },
          onError: (error) {
            _emitStatus(
              WearModuleStatus(
                type: WearModuleStatusType.consentStreamError,
                error: error,
                message: 'Consent observation stream error',
              ),
            );
          },
        );

    // Initialize vendor sync state
    _lastVendorSyncState = _consent.current().vendorSync;
    if (_lastVendorSyncState) {
      _vendorSyncController.add(true);
    }

    // Start data collection only when consent is granted.
    // This prevents OS health permission dialogs from appearing before the user
    // grants Synheart biosignals consent.
    if (_consent.current().allowsChannel('biosignals.vitals') && _mayCollect) {
      await _startDataCollection();
    }
  }

  /// Start data collection from all sources
  Future<void> _startDataCollection() async {
    // Synchronous flag guards against async race: BehaviorSubject emits
    // immediately in onStart, so both the asyncMap callback and the
    // explicit call can enter this method before either awaits.
    if (_isStartingCollection || _subscriptions.isNotEmpty) {
      SynheartLogger.log(
        '[WearModule] Data collection already active/starting, skipping',
      );
      return;
    }
    _isStartingCollection = true;

    try {
      // Check consent again before starting
      if (!_consent.current().allowsChannel('biosignals.vitals')) {
        // SynheartLogger.log(
        //   '[WearModule] Cannot start: biosignals consent denied',
        // );
        return;
      }

      // Ensure all sources are initialized (in case they were stopped)
      for (final source in _sources) {
        if (source.isAvailable) {
          try {
            // Re-initialize if needed (e.g., after stop() disposed the SDK)
            await source.initialize();

            // For SynheartWearSourceHandler, explicitly start streaming after initialization
            // This ensures we only start streaming when consent is granted
            if (source is SynheartWearSourceHandler) {
              source.startStreaming();
              // SynheartLogger.log(
              //   '[WearModule] Started HR streaming for ${source.sourceType.name}',
              // );
            }
          } catch (e) {
            final isPermission =
                e is wear.PermissionDeniedError ||
                (e is wear.SynheartWearError && e.code == 'PERMISSION_DENIED');

            _emitStatus(
              WearModuleStatus(
                type: isPermission
                    ? WearModuleStatusType.permissionDenied
                    : WearModuleStatusType.sourceInitFailed,
                source: source.sourceType.name,
                error: e,
                message: isPermission
                    ? 'Health data permissions not granted'
                    : 'Failed to re-initialize ${source.sourceType.name}',
              ),
            );
            // Continue with other sources even if one fails
          }
        }
      }

      // Subscribe to each source
      for (final source in _sources) {
        if (source.isAvailable) {
          final subscription = source.sampleStream.listen(
            (sample) {
              // Check consent before caching or streaming - don't process if consent is denied
              if (!_consent.current().allowsChannel('biosignals.vitals')) {
                // SynheartLogger.log(
                //   '[WearModule] Sample ignored: biosignals consent denied',
                // );
                return;
              }
              // Add to cache only if consent is granted
              _cache.addSample(sample);

              // Emit to raw sample stream only if consent is granted and controller exists
              // Double-check consent here for extra safety
              if (_consent.current().biosignals &&
                  _rawSampleController != null &&
                  !_rawSampleController!.isClosed) {
                _rawSampleController!.add(sample);
              }
            },
            onError: (error) {
              _emitStatus(
                WearModuleStatus(
                  type: WearModuleStatusType.streamingError,
                  source: source.sourceType.name,
                  error: error,
                  message: 'Streaming error from ${source.sourceType.name}',
                ),
              );
              // Do not forward to rawSampleStream to avoid unhandled exceptions
              // (e.g. Health Connect PERMISSION_DENIED). Listeners still get samples.
            },
          );

          _subscriptions.add(subscription);
        }
      }
      _emitStatus(
        const WearModuleStatus(
          type: WearModuleStatusType.dataCollectionStarted,
        ),
      );
    } finally {
      _isStartingCollection = false;
    }
  }

  /// Stop data collection from all sources (but keep module initialized)
  Future<void> _stopDataCollection() async {
    // Cancel all subscriptions to stop receiving data
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();

    // Stop all sources to stop their internal streaming
    for (final source in _sources) {
      if (source.isAvailable) {
        try {
          await source.stop();
        } catch (e) {
          _emitStatus(
            WearModuleStatus(
              type: WearModuleStatusType.streamingError,
              source: source.sourceType.name,
              error: e,
              message: 'Error stopping ${source.sourceType.name}',
            ),
          );
        }
      }
    }

    _emitStatus(
      const WearModuleStatus(type: WearModuleStatusType.dataCollectionStopped),
    );
  }

  @override
  Future<void> onStop() async {
    // Cancel consent subscription
    await _consentSubscription?.cancel();
    _consentSubscription = null;

    // Stop data collection; a later start waits for a new request again.
    _collectionRequested = false;
    await _stopDataCollection();
  }

  /// Clear all cached data
  Future<void> clearCache() async {
    _cache.clear();
    // SynheartLogger.log('[WearModule] Cache cleared');
  }

  /// Stream of raw wear samples
  ///
  /// Subscribe to this stream to receive real-time biosignal data.
  /// The stream respects consent - no data is emitted if consent is denied.
  ///
  /// Example:
  /// ```dart
  /// wearModule.rawSampleStream.listen((sample) {
  ///   print('HR: ${sample.hr} BPM');
  ///   print('RR Intervals: ${sample.rrIntervals}');
  /// });
  /// ```
  Stream<WearSample> get rawSampleStream {
    _rawSampleController ??= StreamController<WearSample>.broadcast();
    return _rawSampleController!.stream;
  }

  /// Stream of module status events.
  ///
  /// Subscribe to this stream to observe initialization outcomes, permission
  /// failures, and streaming errors. Callers that don't subscribe are
  /// unaffected — existing behavior is preserved.
  ///
  /// Example:
  /// ```dart
  /// wearModule.statusStream.listen((status) {
  ///   if (status.type == WearModuleStatusType.permissionDenied) {
  ///     // Prompt user to grant health permissions
  ///   }
  /// });
  /// ```
  Stream<WearModuleStatus> get statusStream => _statusController.stream;

  /// Stream that emits `true` when vendor_sync consent is granted,
  /// `false` when revoked. The wear SDK (synheart_wear) uses this to
  /// start/stop the RAMEN real-time event connection.
  Stream<bool> get vendorSyncState => _vendorSyncController.stream;

  /// Current vendor sync consent state.
  bool get isVendorSyncEnabled => _lastVendorSyncState;

  /// Stream of canonical vendor events, emitted after normalization and storage.
  Stream<CanonicalWearableEvent> get canonicalEvents =>
      _canonicalEventController.stream;

  /// Set the runtime bridge for vendor event storage.
  void setBridge(CoreRuntimeBridge? bridge) {
    _bridge = bridge;
  }

  /// Set the wearable event processor (called by Synheart after configure).
  void setEventProcessor(WearableEventProcessor processor) {
    _eventProcessor = processor;
  }

  /// Process a vendor event from RAMEN into the SRM pipeline.
  ///
  /// Call this when a [RamenEvent] arrives from the wear SDK.
  /// The processor normalizes the event, stores it in SQLite,
  /// and pushes daily values to the runtime for baseline computation.
  ///
  /// Returns the [CanonicalWearableEvent] the vendor event was mapped to,
  /// or `null` if dropped (consent denied, no processor, mapping miss).
  Future<CanonicalWearableEvent?> processVendorEvent({
    required String provider,
    required String eventType,
    required Map<String, dynamic> payload,
    required String eventId,
    required int seq,
  }) async {
    // Read consent live rather than relying on the cached
    // `_lastVendorSyncState` mirror. The cache is updated by the
    // `_consentSubscription` asyncMap, but if consent is granted before
    // that subscription is wired (e.g. WearModule.onStart races with
    // consentSubmitForm), the cache stays stuck at false and every event
    // gets silently dropped here — even though `_consent.current()`
    // reports the truth.
    final vendorSyncNow = _consent.current().vendorSync;
    if (!vendorSyncNow) {
      SynheartLogger.stream(
        'vendor_sync consent not granted — dropping $provider/$eventType',
      );
      return null;
    }
    if (_eventProcessor == null) {
      SynheartLogger.stream(
        'event processor not configured — dropping $provider/$eventType',
      );
      return null;
    }
    final event = await _eventProcessor!.processRamenEvent(
      provider: provider,
      eventType: eventType,
      payload: payload,
      eventId: eventId,
      seq: seq,
    );

    if (event != null) {
      // Store in native SQLite via runtime bridge.
      try {
        _bridge?.ingestVendorEvent(jsonEncode(event.toMap()));
      } catch (e) {
        SynheartLogger.stream('event storage failed: $e', error: e);
      }

      // Emit for UI subscribers.
      if (!_canonicalEventController.isClosed) {
        _canonicalEventController.add(event);
      }
    }
    return event;
  }

  void _emitStatus(WearModuleStatus status) {
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  @override
  Future<void> onDispose() async {
    // Close canonical vendor event stream
    await _canonicalEventController.close();

    // Close vendor sync stream
    await _vendorSyncController.close();

    // Close raw sample stream controller
    await _rawSampleController?.close();
    _rawSampleController = null;

    // Dispose all sources
    for (final source in _sources) {
      try {
        await source.dispose();
      } catch (e) {
        _emitStatus(
          WearModuleStatus(
            type: WearModuleStatusType.streamingError,
            source: source.sourceType.name,
            error: e,
            message: 'Error disposing ${source.sourceType.name}',
          ),
        );
      }
    }

    // Close status stream last so all status events are delivered
    await _statusController.close();
  }
}
