import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/synheart_core.dart';

void main() {
  group('HsmSchemaConsent', () {
    test('parses the runtime shape', () {
      final needs = HsmSchemaConsent.fromRuntimeJson(const {
        'schema_version': 3,
        'needs_consent': true,
        'channels': ['behavior.notification_patterns'],
      });

      expect(needs.schemaVersion, 3);
      expect(needs.channels, ['behavior.notification_patterns']);
      expect(needs.needsConsent, isTrue);
    });

    test('no published schema needs nothing', () {
      final needs = HsmSchemaConsent.fromRuntimeJson(const {
        'schema_version': null,
        'needs_consent': false,
        'channels': <String>[],
      });

      expect(needs, HsmSchemaConsent.none);
      expect(needs.needsConsent, isFalse);
    });

    test('reads needs from the channels, not the flag', () {
      final needs = HsmSchemaConsent.fromRuntimeJson(const {
        'schema_version': 2,
        'needs_consent': true,
        'channels': <String>[],
      });

      expect(needs.needsConsent, isFalse);
    });

    test('malformed fields read as nothing to ask', () {
      final needs = HsmSchemaConsent.fromRuntimeJson(const {
        'schema_version': '2',
        'channels': 'behavior.app_context',
      });

      expect(needs.schemaVersion, isNull);
      expect(needs.channels, isEmpty);
      expect(needs.needsConsent, isFalse);
    });

    test('keeps only channel names', () {
      final needs = HsmSchemaConsent.fromRuntimeJson(const {
        'schema_version': 2,
        'channels': ['behavior.app_context', 4, null],
      });

      expect(needs.channels, ['behavior.app_context']);
    });
  });

  group('Synheart.schemaNeedsConsent', () {
    test('is false without a runtime', () {
      expect(Synheart.hsmSchemaConsent(), isNull);
      expect(Synheart.schemaNeedsConsent(), isFalse);
    });
  });
}
