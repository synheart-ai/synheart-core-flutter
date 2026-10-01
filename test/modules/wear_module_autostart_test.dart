import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/src/modules/interfaces/consent_provider.dart';
import 'package:synheart_core/src/modules/wear/wear_module.dart';
import 'package:synheart_core/src/modules/wear/wear_source_handler.dart';

/// `WearConfig.autoStartPlatformHealth: false` — consent alone must not start
/// the platform-health source (no HealthKit / Health Connect dialog, no
/// history read); `requestCollection()` (what `Synheart.startWearCollection`
/// calls) does. Seen in a host that re-grants a remembered consent at launch:
/// the Health Connect dialog came back on every launch.
class _Consent implements ConsentProvider {
  _Consent(this._now);
  ConsentSnapshot _now;
  final _changes = StreamController<ConsentSnapshot>.broadcast();

  @override
  ConsentSnapshot current() => _now;

  @override
  Stream<ConsentSnapshot> observe() async* {
    yield _now;
    yield* _changes.stream;
  }

  @override
  Future<void> updateConsent(ConsentSnapshot c) async {
    _now = c;
    _changes.add(c);
  }
}

class _Source implements WearSourceHandler {
  int initialized = 0;

  @override
  WearSourceType get sourceType => WearSourceType.appleHealth;

  @override
  bool get isAvailable => true;

  @override
  Future<void> initialize() async => initialized++;

  @override
  Stream<WearSample> get sampleStream => const Stream.empty();

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  Future<(WearModule, _Source, _Consent)> started({
    required bool autoStart,
    ConsentSnapshot? consent,
  }) async {
    final source = _Source();
    final c = _Consent(consent ?? ConsentSnapshot.all());
    final m = WearModule(
      consent: c,
      sources: [source],
      autoStartOnConsent: autoStart,
    );
    await m.initialize();
    await m.start();
    await pumpEventQueue();
    return (m, source, c);
  }

  test('default: consent starts the source (unchanged behaviour)', () async {
    final (_, source, _) = await started(autoStart: true);
    expect(source.initialized, 1);
  });

  test(
    'opted out: consent alone does not start it; an explicit request does',
    () async {
      final (m, source, _) = await started(autoStart: false);
      expect(
        source.initialized,
        0,
        reason: 'no permission dialog, no history read',
      );
      await m.requestCollection();
      expect(source.initialized, 1);
    },
  );

  test('opted out: a request before consent waits for consent', () async {
    final (m, source, c) = await started(
      autoStart: false,
      consent: ConsentSnapshot.none(),
    );
    await m.requestCollection();
    expect(source.initialized, 0);
    await c.updateConsent(ConsentSnapshot.all());
    await pumpEventQueue();
    expect(source.initialized, 1);
  });

  test('opted out: after stop, a restart waits for a new request', () async {
    final (m, source, _) = await started(autoStart: false);
    await m.requestCollection();
    await m.stop();
    await m.start();
    await pumpEventQueue();
    expect(source.initialized, 1);
  });
}
