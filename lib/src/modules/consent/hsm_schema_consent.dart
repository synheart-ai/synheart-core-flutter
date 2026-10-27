/// What the app's published HSM Schema needs from the person before the
/// runtime can collect all of it.
///
/// A newer schema version can declare an input the person was never asked
/// about, for example `behavior.notification_patterns`. The runtime does not
/// collect it until they consent, and it does not ask them either: the app
/// does, by showing the consent form again when [needsConsent] is true.
///
/// [channels] lists the declared input channels the person has not consented
/// to and was not asked about when they last chose. A channel they declined is
/// not listed again. Submitting the consent form, whatever they choose, clears
/// the list for the version they saw.
///
/// Mirrors the JSON returned by the native runtime's
/// `synheart_core_hsm_schema_consent`.
class HsmSchemaConsent {
  const HsmSchemaConsent({required this.schemaVersion, required this.channels});

  /// Nothing to ask: the app has not published a schema.
  static const none = HsmSchemaConsent(schemaVersion: null, channels: []);

  /// The schema version the runtime holds; null when the app has not
  /// published one.
  final int? schemaVersion;

  /// Consent channels to ask about (`behavior.notification_patterns`, ...).
  final List<String> channels;

  /// Whether the app should show the consent form again.
  bool get needsConsent => channels.isNotEmpty;

  /// Parse the runtime's JSON. Missing or malformed fields read as "nothing to
  /// ask", never as a reason to prompt.
  factory HsmSchemaConsent.fromRuntimeJson(Map<String, dynamic> json) {
    final version = json['schema_version'];
    final channels = json['channels'];
    return HsmSchemaConsent(
      schemaVersion: version is int ? version : null,
      channels: channels is List
          ? List.unmodifiable(channels.whereType<String>())
          : const [],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HsmSchemaConsent &&
      other.schemaVersion == schemaVersion &&
      other.channels.length == channels.length &&
      Iterable.generate(
        channels.length,
      ).every((i) => other.channels[i] == channels[i]);

  @override
  int get hashCode => Object.hash(schemaVersion, Object.hashAll(channels));

  @override
  String toString() =>
      'HsmSchemaConsent(schemaVersion: $schemaVersion, channels: $channels)';
}
