import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/src/modules/consent/consent_profile.dart';
import 'package:synheart_core/src/modules/interfaces/consent_provider.dart';

/// Every category on, but only `biosignals.sleep` and
/// `behavior.digital_activity` allowed per channel.
ConsentSnapshot _snapshot({required bool authoritative}) => ConsentSnapshot(
  biosignals: true,
  behavior: true,
  phoneContext: true,
  cloudUpload: true,
  timestamp: DateTime(2026),
  channels: ConsentChannels.fromJson({
    'biosignals': {'sleep': true},
    'behavior': {'digital_activity': true},
  }),
  channelsAuthoritative: authoritative,
);

void main() {
  group('ConsentSnapshot.allowsChannel', () {
    test(
      'without runtime decisions, a granted category covers its channels',
      () {
        final snap = _snapshot(authoritative: false);
        expect(snap.allowsChannel('biosignals.vitals'), isTrue);
        expect(snap.allowsChannel('phone_context.device_motion'), isTrue);
      },
    );

    test(
      'runtime decisions are read per channel, with no category fallback',
      () {
        final snap = _snapshot(authoritative: true);
        expect(snap.allowsChannel('biosignals.sleep'), isTrue);
        expect(snap.allowsChannel('behavior.digital_activity'), isTrue);
        expect(snap.allowsChannel('biosignals.vitals'), isFalse);
        expect(snap.allowsChannel('phone_context.device_motion'), isFalse);
        expect(snap.allowsChannel('behavior.app_context'), isFalse);
        expect(snap.allowsChannel('unknown.channel'), isFalse);
      },
    );

    test('authoritative without a channel map keeps category checks', () {
      final snap = ConsentSnapshot(
        biosignals: true,
        behavior: false,
        phoneContext: false,
        cloudUpload: false,
        timestamp: DateTime(2026),
        channelsAuthoritative: true,
      );
      expect(snap.allowsChannel('biosignals.vitals'), isTrue);
      expect(snap.allowsChannel('behavior.digital_activity'), isFalse);
    });

    test('survives a JSON round trip and copyWith', () {
      final snap = _snapshot(authoritative: true);
      final back = ConsentSnapshot.fromJson(snap.toJson());
      expect(back.channelsAuthoritative, isTrue);
      expect(back.allowsChannel('biosignals.vitals'), isFalse);
      expect(snap.copyWith(cloudUpload: false).channelsAuthoritative, isTrue);
      expect(
        ConsentSnapshot.fromJson(
          _snapshot(authoritative: false).toJson(),
        ).channelsAuthoritative,
        isFalse,
      );
    });
  });
}
