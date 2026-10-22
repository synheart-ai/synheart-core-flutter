import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/src/modules/base/runtime_channel_gate.dart';
import 'package:synheart_core/src/modules/interfaces/consent_provider.dart';
import 'package:synheart_core/src/modules/wear/wear_module.dart';
import 'package:synheart_core/src/modules/wear/wear_source_handler.dart';

class _Gated with RuntimeChannelGate {}

class _Consent implements ConsentProvider {
  _Consent(this._now);
  final ConsentSnapshot _now;

  @override
  ConsentSnapshot current() => _now;

  @override
  Stream<ConsentSnapshot> observe() async* {
    yield _now;
  }

  @override
  Future<void> updateConsent(ConsentSnapshot c) async {}
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
  group('RuntimeChannelGate', () {
    test('with no runtime gate every channel passes', () {
      expect(_Gated().runtimeAllows('biosignals.vitals'), isTrue);
    });

    test('the runtime gate decides per channel', () {
      final g = _Gated()
        ..runtimeAllowsChannel = (c) => c == 'behavior.digital_activity';
      expect(g.runtimeAllows('behavior.digital_activity'), isTrue);
      expect(g.runtimeAllows('biosignals.vitals'), isFalse);
    });
  });

  group('WearModule with a runtime gate', () {
    Future<_Source> started(bool Function(String)? gate) async {
      final source = _Source();
      final m = WearModule(
        consent: _Consent(ConsentSnapshot.all()),
        sources: [source],
      )..runtimeAllowsChannel = gate;
      await m.initialize();
      await m.start();
      await pumpEventQueue();
      return source;
    }

    test('consent alone starts the source when the runtime accepts', () async {
      final source = await started((_) => true);
      expect(source.initialized, 1);
    });

    test('a channel the runtime refuses is never started', () async {
      final source = await started((c) => c != 'biosignals.vitals');
      expect(source.initialized, 0);
    });
  });
}
