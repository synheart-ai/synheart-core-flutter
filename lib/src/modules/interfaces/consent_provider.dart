import '../consent/consent_profile.dart';

/// Processing tier for consent.
enum ConsentTier {
  /// On-device only — nothing leaves the device
  local,

  /// Derived/aggregated data may be uploaded to cloud
  cloud,

  /// Raw data may be exported to research lab (requires cloud)
  research,
}

/// Types of consent. Interpretation flags (focus/emotion estimation) are
/// expressed at the channel level via [ConsentChannels] rather than as
/// top-level consent types.
enum ConsentType {
  /// Consent for biosignal collection
  biosignals,

  /// Consent for behavioral data collection
  behavior,

  /// Consent for phone context data collection
  phoneContext,

  /// Consent for cloud uploads
  cloudUpload,

  /// Consent for Syni personalization
  syni,

  /// Consent for vendor sync (Wear Ramen service)
  vendorSync,

  /// Consent for research data export
  research,
}

/// Snapshot of user consent at a point in time
class ConsentSnapshot {
  /// Consent for biosignal collection
  final bool biosignals;

  /// Consent for behavioral data collection
  final bool behavior;

  /// Consent for phone context data collection
  final bool phoneContext;

  /// Consent for cloud uploads
  final bool cloudUpload;

  /// Consent for Syni personalization
  final bool syni;

  /// Consent for vendor sync (Wear Ramen service — sleep, recovery, strain from Whoop/Garmin)
  final bool vendorSync;

  /// Consent for research data export
  final bool research;

  /// Timestamp when this consent was given
  final DateTime timestamp;

  /// Schema version for this consent snapshot
  final String version;

  /// Whether user explicitly denied consent (vs never asked)
  /// This distinguishes "pending" (never asked) from "denied" (user declined)
  final bool explicitlyDenied;

  /// Processing tier. Defaults to local.
  final ConsentTier tier;

  /// Granular per-channel consent.
  /// Nullable for backward compat — when null, module-level booleans are used.
  final ConsentChannels? channels;

  /// Whether [channels] is the runtime's own per-channel decision.
  ///
  /// Set when the SDK fills [channels] from the runtime with
  /// `SynheartConfig.strictChannelConsent` on. [allowsChannel] then reads the
  /// channel alone and never falls back to the category flag.
  final bool channelsAuthoritative;

  const ConsentSnapshot({
    required this.biosignals,
    required this.behavior,
    required this.phoneContext,
    required this.cloudUpload,
    this.syni = false,
    this.vendorSync = false,
    this.research = false,
    required this.timestamp,
    this.version = '1.0.0',
    this.explicitlyDenied = false,
    this.tier = ConsentTier.local,
    this.channels,
    this.channelsAuthoritative = false,
  });

  /// Check if a specific consent type is allowed
  bool allows(ConsentType type) {
    switch (type) {
      case ConsentType.biosignals:
        return biosignals;
      case ConsentType.behavior:
        return behavior;
      case ConsentType.phoneContext:
        return phoneContext;
      case ConsentType.cloudUpload:
        return cloudUpload;
      case ConsentType.syni:
        return syni;
      case ConsentType.vendorSync:
        return vendorSync;
      case ConsentType.research:
        return research;
    }
  }

  /// Check if a specific channel is allowed.
  ///
  /// Uses the granular [channels] map if available, otherwise falls back
  /// to module-level booleans for backward compatibility.
  ///
  /// Channel format: "biosignals.vitals", "behavior.digital_activity", etc.
  bool allowsChannel(String channel) {
    if (channelsAuthoritative && channels != null) {
      return _checkChannel(channel);
    }
    // Granular channels take precedence when explicitly set — but if the
    // granular map exists yet reports `false` for a channel whose parent
    // module IS granted, fall back to the module boolean. This catches
    // the common case where a consent submit sets the module-level
    // toggle (`behavior = true`) but doesn't materialize the granular
    // map (or materializes it with all subchannels false by default).
    // Without the fallback, events silently drop here even though the
    // user clearly consented to the parent module.
    if (channels != null) {
      final granular = _checkChannel(channel);
      if (granular) return true;
    }
    // Module-level fallback.
    if (channel.startsWith('biosignals.')) return biosignals;
    if (channel.startsWith('behavior.')) return behavior;
    if (channel.startsWith('phone_context.')) return phoneContext;
    return false;
  }

  bool _checkChannel(String channel) {
    final ch = channels!;
    switch (channel) {
      case 'biosignals.vitals':
        return ch.biosignals.vitals;
      case 'biosignals.cardio_advanced':
        return ch.biosignals.cardioAdvanced;
      case 'biosignals.neuromuscular':
        return ch.biosignals.neuromuscular;
      case 'biosignals.wearable_motion':
        return ch.biosignals.wearableMotion;
      case 'biosignals.sleep':
        return ch.biosignals.sleep;
      case 'phone_context.device_motion':
        return ch.phoneContext.deviceMotion;
      case 'phone_context.device_context':
        return ch.phoneContext.deviceContext;
      case 'phone_context.system_state':
        return ch.phoneContext.systemState;
      case 'behavior.digital_activity':
        return ch.behavior.digitalActivity;
      case 'behavior.notification_patterns':
        return ch.behavior.notificationPatterns;
      case 'behavior.app_context':
        return ch.behavior.appContext;
      case 'interpretation.focus_estimation':
        return ch.interpretation.focusEstimation;
      case 'interpretation.emotion_estimation':
        return ch.interpretation.emotionEstimation;
      default:
        return false;
    }
  }

  /// Create a copy with updated values
  ConsentSnapshot copyWith({
    bool? biosignals,
    bool? behavior,
    bool? phoneContext,
    bool? cloudUpload,
    bool? syni,
    bool? vendorSync,
    bool? research,
    DateTime? timestamp,
    String? version,
    bool? explicitlyDenied,
    ConsentTier? tier,
    ConsentChannels? channels,
    bool? channelsAuthoritative,
  }) {
    return ConsentSnapshot(
      biosignals: biosignals ?? this.biosignals,
      behavior: behavior ?? this.behavior,
      phoneContext: phoneContext ?? this.phoneContext,
      cloudUpload: cloudUpload ?? this.cloudUpload,
      syni: syni ?? this.syni,
      vendorSync: vendorSync ?? this.vendorSync,
      research: research ?? this.research,
      timestamp: timestamp ?? this.timestamp,
      version: version ?? this.version,
      explicitlyDenied: explicitlyDenied ?? this.explicitlyDenied,
      tier: tier ?? this.tier,
      channels: channels ?? this.channels,
      channelsAuthoritative:
          channelsAuthoritative ?? this.channelsAuthoritative,
    );
  }

  /// Create a consent snapshot with all consents denied
  ///
  /// [explicitlyDenied] indicates if user explicitly declined (true)
  /// or if consent was never requested (false, default)
  factory ConsentSnapshot.none({bool explicitlyDenied = false}) {
    return ConsentSnapshot(
      biosignals: false,
      behavior: false,
      phoneContext: false,
      cloudUpload: false,
      syni: false,
      vendorSync: false,
      research: false,
      timestamp: DateTime.now(),
      explicitlyDenied: explicitlyDenied,
    );
  }

  /// Create a consent snapshot with all consents granted
  factory ConsentSnapshot.all() {
    return ConsentSnapshot(
      biosignals: true,
      behavior: true,
      phoneContext: true,
      cloudUpload: true,
      syni: true,
      vendorSync: true,
      research: true,
      timestamp: DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'biosignals': biosignals,
      'behavior': behavior,
      'phoneContext': phoneContext,
      'cloudUpload': cloudUpload,
      'syni': syni,
      'vendorSync': vendorSync,
      'research': research,
      'timestamp': timestamp.toIso8601String(),
      'version': version,
      'explicitlyDenied': explicitlyDenied,
      'tier': tier.name,
      if (channels != null) 'channels': channels!.toJson(),
      if (channelsAuthoritative) 'channelsAuthoritative': true,
    };
  }

  factory ConsentSnapshot.fromJson(Map<String, dynamic> json) {
    final tierStr = json['tier'] as String?;
    final tier = tierStr != null
        ? ConsentTier.values.firstWhere(
            (t) => t.name == tierStr,
            orElse: () => ConsentTier.local,
          )
        : ConsentTier.local;

    return ConsentSnapshot(
      biosignals: json['biosignals'] as bool,
      behavior: json['behavior'] as bool,
      phoneContext: json['phoneContext'] as bool,
      cloudUpload: json['cloudUpload'] as bool,
      syni: json['syni'] as bool? ?? false,
      vendorSync: json['vendorSync'] as bool? ?? false,
      research: json['research'] as bool? ?? false,
      timestamp: DateTime.parse(json['timestamp'] as String),
      version: json['version'] as String? ?? '1.0.0',
      explicitlyDenied: json['explicitlyDenied'] as bool? ?? false,
      tier: tier,
      channels: json['channels'] != null
          ? ConsentChannels.fromJson(json['channels'] as Map<String, dynamic>)
          : null,
      channelsAuthoritative: json['channelsAuthoritative'] as bool? ?? false,
    );
  }
}

/// Provider interface for consent management
abstract class ConsentProvider {
  /// Get the current consent snapshot
  ConsentSnapshot current();

  /// Observe consent changes
  Stream<ConsentSnapshot> observe();

  /// Update consent (internal use)
  Future<void> updateConsent(ConsentSnapshot newConsent);
}
