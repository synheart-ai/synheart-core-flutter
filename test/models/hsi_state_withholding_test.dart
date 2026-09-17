import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:synheart_core/synheart_core.dart';

/// `meta.synheart.state_withheld` and `meta.synheart.sensing` are what let a
/// consumer tell "withheld, with a reason" from "this build does not produce
/// that axis". Without them a host reading only `axes.*` sees an absent
/// capacity on an episodic phone and reasonably concludes the SDK is broken —
/// or worse, paints a neutral default over it, which is exactly the "Stress
/// pinned at 100 / Recovery pinned at 50" failure withholding exists to stop.
void main() {
  String hsi({
    Map<String, String>? withheld,
    Map<String, dynamic>? sensing,
    Map<String, dynamic>? extraMeta,
  }) => jsonEncode({
    'hsi_version': '1.3',
    'subject_id': 'sub_test',
    'timestamp_ms': 1_700_000_000_000,
    'axes': {
      'cognitive': [
        {'name': 'focus', 'score': 0.61, 'confidence': 0.8},
      ],
    },
    'meta': {
      'synheart': {
        if (withheld != null) 'state_withheld': withheld,
        if (sensing != null) 'sensing': sensing,
        ...?extraMeta,
      },
    },
  });

  group('state_withheld', () {
    test('is empty when nothing was withheld', () {
      final state = HSIState.fromJson(hsi());
      expect(state.stateWithheld, isEmpty);
      expect(state.hasParseError, isFalse);
    });

    test('parses axis to reason', () {
      final state = HSIState.fromJson(
        hsi(
          withheld: {
            'capacity': 'episodic_sensing',
            'mental_fatigue': 'episodic_sensing',
          },
        ),
      );
      expect(state.stateWithheld, {
        'capacity': 'episodic_sensing',
        'mental_fatigue': 'episodic_sensing',
      });
      // The withheld axes are genuinely absent from the axes too — the two
      // views agree, which is what makes their union the complete member set.
      expect(state.hsi.capacity, isNull);
      expect(state.hsi.focus, isNotNull);
    });

    test('carries the cold-start reason, which is not a score of zero', () {
      final state = HSIState.fromJson(
        hsi(withheld: {'capacity': 'cold_start_confidence_exhausted'}),
      );
      expect(
        state.stateWithheld['capacity'],
        'cold_start_confidence_exhausted',
      );
    });

    test('a non-string value is skipped rather than coerced', () {
      // A reason is a reason. Stringifying a number here would put something
      // meaningless in front of a developer trying to explain a missing axis.
      final raw = jsonDecode(hsi()) as Map<String, dynamic>;
      (raw['meta']['synheart'] as Map)['state_withheld'] = {
        'capacity': 'episodic_sensing',
        'stress': 42,
      };
      final state = HSIState.fromJson(jsonEncode(raw));
      expect(state.stateWithheld, {'capacity': 'episodic_sensing'});
    });

    test('a non-map block degrades to empty', () {
      final raw = jsonDecode(hsi()) as Map<String, dynamic>;
      (raw['meta']['synheart'] as Map)['state_withheld'] = 'nope';
      expect(HSIState.fromJson(jsonEncode(raw)).stateWithheld, isEmpty);
    });
  });

  group('sensing', () {
    test('is null when the host declared no profile', () {
      // Absent is the correct answer for an undeclared host, and it is not
      // the same as a declared default — the block is what a consumer
      // stratifies on rather than pooling across platforms.
      expect(HSIState.fromJson(hsi()).sensing, isNull);
    });

    test('parses the declared block', () {
      final state = HSIState.fromJson(
        hsi(
          sensing: {
            'mode': 'episodic',
            'roster_version': 'IOS_EPISODIC',
            'rest_declared': true,
          },
        ),
      );
      expect(state.sensing, isNotNull);
      expect(state.sensing!['mode'], 'episodic');
      expect(state.sensing!['roster_version'], 'IOS_EPISODIC');
      expect(state.sensing!['rest_declared'], isTrue);
    });

    test('survives a runtime with no meta.synheart block at all', () {
      final state = HSIState.fromJson(
        jsonEncode({
          'hsi_version': '1.3',
          'subject_id': 'sub_test',
          'timestamp_ms': 1,
          'axes': <String, dynamic>{},
        }),
      );
      expect(state.sensing, isNull);
      expect(state.stateWithheld, isEmpty);
      expect(state.hasParseError, isFalse);
    });
  });

  test('a parse failure reports empty rather than guessing', () {
    final state = HSIState.fromJson('{not json');
    expect(state.hasParseError, isTrue);
    expect(state.stateWithheld, isEmpty);
    expect(state.sensing, isNull);
    // The offending payload is retained, so the withheld map being empty is
    // never mistaken for "the engine withheld nothing".
    expect(state.rawJson, '{not json');
  });
}
