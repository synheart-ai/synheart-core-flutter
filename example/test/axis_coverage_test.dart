import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:example/sdk/axis_coverage.dart';

/// The report exists to keep three states apart: a reading the engine
/// published, one it computed and refused, and one that never existed.
/// Collapsing any two of them is the bug these tests guard.
void main() {
  String payload({
    Map<String, dynamic>? axes,
    Map<String, dynamic>? withheld,
    Map<String, dynamic>? motion,
  }) => jsonEncode({
    'hsi_version': '1.3',
    'observed_at_utc': '2026-09-13T09:30:33Z',
    'axes': axes ?? {},
    if (withheld != null || motion != null)
      'meta': {
        'synheart': {
          if (withheld != null) 'state_withheld': withheld,
          if (motion != null) 'motion': motion,
        },
      },
  });

  /// The motion block the engine emits on a phone whose placement was never
  /// declared: outside the pocket/waist envelope, every kinematic head names
  /// the placement as the cause (flux `rulebook_conformance`).
  Map<String, dynamic> undeclaredPlacementMotion() => {
    'placement': 'unknown',
    'in_kinematic_envelope': false,
    'kinematic_withheld': {
      'activity_state': 'out_of_envelope',
      'locomotion_state': 'out_of_envelope',
      'postural_state': 'out_of_envelope',
      'movement_regularity': 'out_of_envelope',
    },
  };

  Map<String, dynamic> reading(
    String name,
    Object? score,
    double conf, {
    String direction = 'higher_is_more',
  }) => {
    'name': name,
    'score': score,
    'confidence': conf,
    'direction': direction,
  };

  AxisCoverage row(AxisCoverageReport r, String name) =>
      r.rows.firstWhere((x) => x.name == name);

  test('every canonical member gets a row, including ones never emitted', () {
    final r = buildAxisCoverage(payload())!;
    expect(r.total, 18);
    expect(r.absentCount, 18);
    expect(r.presentCount, 0);
    expect(r.withheldCount, 0);
  });

  test('present, withheld and absent are three different answers', () {
    final r = buildAxisCoverage(
      payload(
        axes: {
          'cognitive': [reading('focus', 0.62, 0.7)],
        },
        withheld: {'arousal': 'no_signal'},
      ),
    )!;

    expect(row(r, 'focus').presence, AxisPresence.present);
    expect(row(r, 'focus').score100, 62);
    expect(row(r, 'arousal').presence, AxisPresence.withheld);
    expect(row(r, 'arousal').withheldReason, 'no_signal');
    expect(row(r, 'recovery').presence, AxisPresence.absent);
  });

  test('a measured zero is present, not absent', () {
    // 0.0 is a claim about the person; absence is not. Treating them alike is
    // what paints a confident calm reading over a head that never ran.
    final r = buildAxisCoverage(
      payload(
        axes: {
          'affective': [reading('stress', 0.0, 0.03)],
        },
      ),
    )!;
    expect(row(r, 'stress').presence, AxisPresence.present);
    expect(row(r, 'stress').score100, 0);
  });

  test('a reading published at zero confidence is flagged on its own', () {
    final r = buildAxisCoverage(
      payload(
        axes: {
          'cognitive': [
            reading('cognitive_load', 0.0, 0.0),
            reading('mental_fatigue', 0.31, 0.0),
            reading('capacity', 0.49, 0.21),
          ],
        },
      ),
    )!;
    expect(r.zeroConfidenceCount, 2);
    expect(row(r, 'capacity').isZeroConfidence, isFalse);
    expect(row(r, 'capacity').confidence, closeTo(0.21, 1e-9));
  });

  test('an explicit null score stays null rather than becoming 0', () {
    final r = buildAxisCoverage(
      payload(
        axes: {
          'digital': [reading('focus_quality', null, 0.0)],
        },
      ),
    )!;
    expect(row(r, 'focus_quality').presence, AxisPresence.present);
    expect(row(r, 'focus_quality').score, isNull);
    expect(row(r, 'focus_quality').score100, isNull);
  });

  test('object-shaped withhold reasons are unwrapped', () {
    final r = buildAxisCoverage(
      payload(
        withheld: {
          'valence': {'reason': 'LOW_DIRECTIONAL_EVIDENCE', 'source': 'none'},
        },
      ),
    )!;
    expect(row(r, 'valence').presence, AxisPresence.withheld);
    expect(row(r, 'valence').withheldReason, 'LOW_DIRECTIONAL_EVIDENCE');
  });

  test('an unfamiliar reason reaches the row unaltered', () {
    final r = buildAxisCoverage(payload(withheld: {'strain': 'brand_new'}))!;
    expect(row(r, 'strain').withheldReason, 'brand_new');
  });

  test('members outside the canonical list are reported, not dropped', () {
    final r = buildAxisCoverage(
      payload(
        axes: {
          'cognitive': [reading('brand_new_head', 0.4, 0.5)],
        },
      ),
    )!;
    expect(r.unknownMembers, ['brand_new_head']);
    expect(r.total, 18, reason: 'an unknown member must not join the roster');
  });

  test(
    'direction notes name only the axes that do not read higher-is-better',
    () {
      final r = buildAxisCoverage(
        payload(
          axes: {
            'digital': [
              reading('focus_quality', 0.8, 0.6),
              reading(
                'interruption_pressure',
                0.2,
                0.5,
                direction: 'lower_is_more',
              ),
              reading('interaction_mode', 0.5, 0.5, direction: 'bidirectional'),
            ],
          },
        ),
      )!;
      expect(r.directionNotes.length, 2);
      expect(r.directionNotes.join(), contains('interruption_pressure'));
      expect(r.directionNotes.join(), contains('interaction_mode'));
      expect(r.directionNotes.join(), isNot(contains('focus_quality')));
    },
  );

  test('a line carries the numbers, the reason, or nothing', () {
    final r = buildAxisCoverage(
      payload(
        axes: {
          'cognitive': [
            reading('focus', 0.62, 0.7),
            reading('mental_fatigue', 0.31, 0.0),
          ],
        },
        withheld: {'arousal': 'no_signal'},
      ),
    )!;
    expect(row(r, 'focus').line, contains('62  c0.70'));
    expect(row(r, 'mental_fatigue').line, endsWith('!'));
    expect(row(r, 'focus').line, isNot(endsWith('!')));
    expect(row(r, 'arousal').line, contains('withheld · no_signal'));
    expect(row(r, 'strain').line, contains('absent'));
  });

  test('domain lines cover every member exactly once', () {
    final r = buildAxisCoverage(payload())!;
    var counted = 0;
    for (final d in AxisDomain.values) {
      counted += r.domainLines(d).length;
    }
    expect(counted, 18);
  });

  test('the summary counts every state', () {
    final r = buildAxisCoverage(
      payload(
        axes: {
          'cognitive': [
            reading('focus', 0.6, 0.7),
            reading('capacity', 0.5, 0.0),
          ],
        },
        withheld: {'arousal': 'no_signal'},
      ),
    )!;
    expect(r.summary, contains('2/18 present'));
    expect(r.summary, contains('1 withheld'));
    expect(r.summary, contains('15 absent'));
    expect(r.summary, contains('1 at zero confidence'));
  });

  test('unparseable input returns null rather than throwing', () {
    expect(buildAxisCoverage('not json'), isNull);
  });

  test(
    'kinematic refusals live under meta.synheart.motion, not state_withheld',
    () {
      // The bug this guards: reading only `state_withheld` reports a
      // documented out-of-envelope refusal as "absent", which is the one
      // confusion the whole report exists to prevent.
      final r = buildAxisCoverage(
        payload(motion: undeclaredPlacementMotion()),
      )!;
      for (final name in [
        'activity_state',
        'locomotion_state',
        'postural_state',
        'movement_regularity',
      ]) {
        expect(row(r, name).presence, AxisPresence.withheld, reason: name);
        expect(row(r, name).withheldReason, 'out_of_envelope', reason: name);
      }
      expect(r.withheldCount, 4);
      expect(r.absentCount, 14);
      expect(r.placement, 'unknown');
      expect(r.inKinematicEnvelope, isFalse);
    },
  );

  test('head_not_enabled survives as its own reason', () {
    final r = buildAxisCoverage(
      payload(
        motion: {
          'placement': 'pocket',
          'in_kinematic_envelope': true,
          'kinematic_withheld': {'movement_regularity': 'head_not_enabled'},
        },
      ),
    )!;
    expect(row(r, 'movement_regularity').withheldReason, 'head_not_enabled');
    expect(r.placement, 'pocket');
    expect(r.inKinematicEnvelope, isTrue);
  });

  test('a published kinematic reading beats a stale withhold entry', () {
    final r = buildAxisCoverage(
      payload(
        axes: {
          'kinematic': [reading('activity_state', 0.3, 0.8)],
        },
        motion: undeclaredPlacementMotion(),
      ),
    )!;
    expect(row(r, 'activity_state').presence, AxisPresence.present);
    expect(r.withheldCount, 3);
  });

  test('no motion block means no placement, and the four stay absent', () {
    final r = buildAxisCoverage(payload())!;
    expect(r.placement, isNull);
    expect(r.inKinematicEnvelope, isNull);
    expect(row(r, 'activity_state').presence, AxisPresence.absent);
  });

  test('a reason object serialised as a string is unwrapped too', () {
    // `state_withheld` is Map<String, String> on the wire, so valence's
    // object reason arrives as text. This is the shape seen on-device.
    final r = buildAxisCoverage(
      payload(
        withheld: {
          'valence': '{"reason":"LOW_DIRECTIONAL_EVIDENCE","source":"none"}',
        },
      ),
    )!;
    expect(row(r, 'valence').withheldReason, 'LOW_DIRECTIONAL_EVIDENCE');
  });

  test('a string that merely starts with a brace is shown verbatim', () {
    final r = buildAxisCoverage(payload(withheld: {'strain': '{oops'}))!;
    expect(row(r, 'strain').withheldReason, '{oops');
  });
}
