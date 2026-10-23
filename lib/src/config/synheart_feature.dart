/// Feature identifiers for the four-authority activation model.
///
/// A feature is **operational** when all four conditions hold:
/// ```
/// FeatureOperational = Activation AND Consent AND Capability AND SessionActive
/// ```
enum SynheartFeature {
  /// Biosignal collection (HR, HRV) via wearable
  wear('biosignals'),

  /// User interaction tracking (taps, keystrokes, gestures)
  behavior('behavior'),

  /// Device motion, screen state, and app context
  phoneContext('phoneContext'),

  /// Cloud upload connector
  cloud('cloudUpload'),

  /// Synsync — cross-device baseline-snapshot sync.
  /// Lets a baseline computed on Device A reach Device B for the same
  /// user. Hosts set up a space with `Synheart.syncCreateSpace(...)` /
  /// `syncJoinSpace(...)` and run a cycle with `Synheart.syncNow()`.
  /// Gates on `cloudUpload` consent — synsync is fundamentally a
  /// cloud-bound operation, same tier as the existing cloud feature.
  synsync('cloudUpload'),

  /// Syni hooks integration
  syni('syni');

  const SynheartFeature(this.requiredConsent);

  /// The consent type required for this feature to operate.
  final String requiredConsent;
}
