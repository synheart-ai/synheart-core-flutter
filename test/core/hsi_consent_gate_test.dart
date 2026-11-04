import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/src/core/hsi_consent_gate.dart';
import 'package:synheart_core/src/modules/interfaces/consent_provider.dart';

/// Drives [hsiDeliveryAllowed], the gate `Synheart._deliverHsiWindow` calls.
void main() {
  ConsentSnapshot local({
    bool biosignals = false,
    bool behavior = false,
    bool phoneContext = false,
    bool cloudUpload = false,
    bool research = false,
  }) => ConsentSnapshot(
    biosignals: biosignals,
    behavior: behavior,
    phoneContext: phoneContext,
    cloudUpload: cloudUpload,
    research: research,
    timestamp: DateTime(2026),
  );

  group('runtime effective state', () {
    for (final key in ['biosignals', 'behavior', 'phone_context', 'research']) {
      test('$key alone delivers', () {
        expect(
          hsiDeliveryAllowed(effective: {key: true}, local: local()),
          isTrue,
        );
      });
    }

    test('cloud upload, syni and vendor sync alone do not deliver', () {
      // None of these collect an input, so no axis could come from them.
      expect(
        hsiDeliveryAllowed(
          effective: {'cloud_upload': true, 'syni': true, 'vendor_sync': true},
          local: local(cloudUpload: true),
        ),
        isFalse,
      );
    });
  });

  group('Dart snapshot', () {
    test('behavior only delivers: the digital-only app', () {
      expect(
        hsiDeliveryAllowed(effective: null, local: local(behavior: true)),
        isTrue,
      );
    });

    test('phone context only delivers', () {
      expect(
        hsiDeliveryAllowed(effective: {}, local: local(phoneContext: true)),
        isTrue,
      );
    });

    test('a stale snapshot does not refuse what the runtime granted', () {
      expect(
        hsiDeliveryAllowed(effective: {'biosignals': true}, local: local()),
        isTrue,
      );
    });
  });

  test('nothing granted refuses', () {
    expect(hsiDeliveryAllowed(effective: {}, local: local()), isFalse);
    expect(hsiDeliveryAllowed(effective: null, local: null), isFalse);
  });
}
