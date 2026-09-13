/// A full roll call of every canonical HSI 1.3 axis for one window.
///
/// The typed [HSIAxes] on `HSIState` carries the eight members this SDK has
/// accessors for. That is enough to build a product, and not enough to answer
/// the question a host asks first: *of everything the engine can produce, how
/// much is actually arriving?* An axis with no accessor is invisible, so a
/// build that silently produces none of the kinematic domain looks exactly
/// like one that produces all of it.
///
/// This file exists to make the whole set visible, and specifically to keep
/// three states apart that every product surface blurs together:
///
///  * **present**  — the engine emitted a reading. It may be a *measured
///    zero*, which is a real claim about the person, not an absence.
///  * **withheld** — the engine computed and then refused to publish, naming a
///    reason in `meta.synheart.state_withheld`. A deliberate silence.
///  * **absent**   — nothing at all. No head ran, or none exists in this
///    build. Structurally different from a refusal.
///
/// Per §9.1 a canonical member is complete over `axes.<domain>` ∪ the withhold
/// maps, so anything in none of them is the third case — and a UI that reads
/// only the axes cannot tell the three apart.
///
/// There are **two** withhold maps, and missing the second one turns a
/// documented refusal into a false "absent":
///
///  * `meta.synheart.state_withheld` — cognitive/affective members dropped for
///    want of any contributing modality (`no_signal`, `episodic_sensing`, …).
///  * `meta.synheart.motion.kinematic_withheld` — the four kinematic heads
///    file their refusals here instead, refined by placement:
///    `out_of_envelope` (mount is not pocket/waist, so they withhold by
///    design), `head_not_enabled` (host never opted in), `unavailable`,
///    `device_resting`, `low_movement`, … The block exists only on a window
///    that carried accelerometer data at all.
library;

import 'dart:convert';

/// The five closed HSI 1.3 wire domains, in the order this app renders them.
enum AxisDomain {
  physiological('physiological'),
  digital('digital'),
  cognitive('cognitive'),
  affective('affective'),
  kinematic('kinematic');

  const AxisDomain(this.wire);

  /// The `axes.<wire>` key on the payload.
  final String wire;
}

/// The canonical HSI 1.3 membership: eighteen members across five domains.
///
/// Hardcoded on purpose. The whole point is to report on members this build
/// may never emit, so the roster cannot be derived from a payload — reading it
/// off the wire would make an absent axis unreportable, which is the exact
/// blind spot this file removes.
const Map<AxisDomain, List<String>> kCanonicalAxes = {
  AxisDomain.physiological: ['recovery', 'readiness', 'strain', 'sleep_score'],
  AxisDomain.digital: [
    'focus_quality',
    'interaction_mode',
    'interruption_pressure',
  ],
  AxisDomain.cognitive: [
    'focus',
    'capacity',
    'cognitive_load',
    'mental_fatigue',
  ],
  AxisDomain.affective: ['valence', 'arousal', 'stress'],
  AxisDomain.kinematic: [
    'movement_regularity',
    'activity_state',
    'postural_state',
    'locomotion_state',
  ],
};

enum AxisPresence { present, withheld, absent }

/// What became of one canonical axis in one window.
class AxisCoverage {
  const AxisCoverage({
    required this.name,
    required this.domain,
    required this.presence,
    this.score,
    this.confidence,
    this.direction,
    this.withheldReason,
  });

  final String name;
  final AxisDomain domain;
  final AxisPresence presence;

  /// 0–1 as the engine emitted it.
  ///
  /// Null when this axis is not [AxisPresence.present], **and also** when the
  /// reading carried an explicit `"score": null` — the engine's way of saying
  /// "computed, no value". Never padded to zero: `0.0` moves a downstream
  /// score and null is renormalised out of it, so the two are not
  /// interchangeable.
  final double? score;

  /// This axis's own confidence, which is not the window's.
  ///
  /// A window's confidence is the maximum across its readings, so it can
  /// report a healthy number while the axis you are reading sits at zero.
  final double? confidence;

  /// `direction` as the wire declared it — `higher_is_more`, `lower_is_more`
  /// or `bidirectional`. Read from the payload rather than assumed, because
  /// `interruption_pressure` is `lower_is_more` and `interaction_mode` is
  /// bidirectional: render either as if higher were better and the sign of the
  /// finding flips.
  final String? direction;

  /// Why the engine refused, as the engine spelled it. The raw code, not a
  /// gloss — a reason this app has never seen must reach the screen unaltered
  /// rather than be flattened into a guess. Null unless withheld.
  final String? withheldReason;

  /// A reading the engine published while reporting no evidence for it.
  ///
  /// Worth its own flag: `0.0` confidence is the head saying "I had nothing",
  /// which no threshold change rescues, whereas `0.05` is a real if thin
  /// measurement. On screen the two look identical, and mistaking one for the
  /// other sends you looking for a display bug that is not there.
  bool get isZeroConfidence =>
      presence == AxisPresence.present && (confidence ?? 0) <= 0;

  /// 0–100 for display, or null when there is no score.
  int? get score100 => score == null ? null : (score! * 100).round();

  /// One fixed-width line for a monospace block.
  ///
  /// ```
  /// focus               62  c0.70
  /// cognitive_load       0  c0.00  !
  /// arousal            withheld · no_signal
  /// strain             absent
  /// ```
  ///
  /// `!` marks [isZeroConfidence].
  String get line {
    final padded = name.padRight(20);
    switch (presence) {
      case AxisPresence.absent:
        return '${padded}absent';
      case AxisPresence.withheld:
        return '${padded}withheld · ${withheldReason ?? 'no reason given'}';
      case AxisPresence.present:
        final v = (score100?.toString() ?? '—').padLeft(3);
        final c = (confidence ?? 0).toStringAsFixed(2);
        return '$padded$v  c$c${isZeroConfidence ? '  !' : ''}';
    }
  }
}

/// Coverage across every canonical axis for one window.
class AxisCoverageReport {
  const AxisCoverageReport({
    required this.rows,
    required this.unknownMembers,
    this.windowConfidence,
    this.placement,
    this.inKinematicEnvelope,
  });

  /// One row per canonical member, grouped by domain in [AxisDomain] order.
  final List<AxisCoverage> rows;

  /// Members the payload carried that [kCanonicalAxes] does not list.
  ///
  /// Not an error. The engine is allowed to grow a head before this app learns
  /// it, and surfacing the name is how you notice the day one starts arriving
  /// instead of dropping it on the floor.
  final List<String> unknownMembers;

  /// The window-level confidence, for contrast with the per-axis ones.
  final double? windowConfidence;

  /// `meta.synheart.motion.placement` — where the host said the accelerometer
  /// sits (`unknown`, `pocket`, `wrist`, `chest`, `desk`, `waist`). Null when
  /// the window carried no accelerometer data, in which case the motion block
  /// is not on the wire at all.
  final String? placement;

  /// `meta.synheart.motion.in_kinematic_envelope` — true only for `pocket`
  /// and `waist`. Outside it all four kinematic heads withhold **by design**;
  /// that is the fact that explains a dark kinematic domain, not the heads.
  final bool? inKinematicEnvelope;

  int get presentCount =>
      rows.where((r) => r.presence == AxisPresence.present).length;
  int get withheldCount =>
      rows.where((r) => r.presence == AxisPresence.withheld).length;
  int get absentCount =>
      rows.where((r) => r.presence == AxisPresence.absent).length;

  /// Published readings whose own confidence is zero.
  int get zeroConfidenceCount => rows.where((r) => r.isZeroConfidence).length;

  int get total => rows.length;

  /// `"9/18 present · 3 withheld · 6 absent"` — the one line worth logging.
  String get summary =>
      '$presentCount/$total present · $withheldCount withheld · '
      '$absentCount absent'
      '${zeroConfidenceCount > 0 ? ' · $zeroConfidenceCount at zero confidence' : ''}';

  List<AxisCoverage> inDomain(AxisDomain domain) =>
      rows.where((r) => r.domain == domain).toList(growable: false);

  /// [AxisCoverage.line] for every member of one domain.
  List<String> domainLines(AxisDomain domain) => [
    for (final r in inDomain(domain)) r.line,
  ];

  /// Directions worth calling out: the axes on screen whose scale is not
  /// "higher is better". Built from what is actually present so the note never
  /// warns about an axis the reader cannot see.
  List<String> get directionNotes => [
    for (final r in rows)
      if (r.presence == AxisPresence.present &&
          r.direction != null &&
          r.direction != 'higher_is_more')
        '${r.name} — ${r.direction}',
  ];
}

/// Build a coverage report from one window's raw HSI document.
///
/// Takes `HSIState.rawJson` rather than the typed state: the typed form has
/// accessors for eight members, so it cannot report on the other ten, and
/// "this build emits no kinematic axis at all" is precisely the finding worth
/// having. Returns null when [rawJson] will not parse — which, if you reached
/// it from a real `HSIState`, means `hasParseError` is already set.
AxisCoverageReport? buildAxisCoverage(String rawJson) {
  final Map<String, dynamic> doc;
  try {
    doc = jsonDecode(rawJson) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }

  final axes = doc['axes'];
  final axesMap = axes is Map ? Map<String, dynamic>.from(axes) : null;

  final meta = doc['meta'];
  final synheart = meta is Map ? meta['synheart'] : null;

  // `meta.synheart.state_withheld` — the engine's record of what it computed
  // and then declined to publish, keyed by member name.
  final withheld = <String, String>{};
  final sw = synheart is Map ? synheart['state_withheld'] : null;
  if (sw is Map) {
    sw.forEach((k, v) {
      if (k is! String) return;
      // Usually a bare code. Valence instead sends a JSON object *encoded as
      // a string* — `state_withheld` is `Map<String, String>` on the wire, so
      // `{"reason":"LOW_DIRECTIONAL_EVIDENCE","source":"none"}` arrives as
      // text. Pull `reason` out of either shape; anything else stays as-is.
      final reason = _unwrapReason(v);
      if (reason != null) withheld[k] = reason;
    });
  }

  // `meta.synheart.motion.kinematic_withheld` — the kinematic heads' own
  // refusals. A separate map from `state_withheld`, and the one that turns
  // four "absent" rows into four "withheld · out_of_envelope" rows on a phone
  // with an undeclared placement. `putIfAbsent`: a member should never be in
  // both, but if it ever is, the modality-level reason is the more specific.
  final motion = synheart is Map ? synheart['motion'] : null;
  final kw = motion is Map ? motion['kinematic_withheld'] : null;
  if (kw is Map) {
    kw.forEach((k, v) {
      if (k is String && v != null) {
        withheld.putIfAbsent(k, () => v.toString());
      }
    });
  }

  // Every reading actually on the payload, by canonical name.
  final readings = <String, Map<String, dynamic>>{};
  if (axesMap != null) {
    for (final domain in AxisDomain.values) {
      final bucket = axesMap[domain.wire];
      if (bucket is! List) continue;
      for (final r in bucket) {
        if (r is! Map) continue;
        final name = r['name'];
        if (name is String && name.isNotEmpty) {
          readings[name] = Map<String, dynamic>.from(r);
        }
      }
    }
  }

  double? asDouble(Object? v) => v is num ? v.toDouble() : null;

  final rows = <AxisCoverage>[];
  for (final entry in kCanonicalAxes.entries) {
    for (final name in entry.value) {
      final r = readings[name];
      if (r != null) {
        rows.add(
          AxisCoverage(
            name: name,
            domain: entry.key,
            presence: AxisPresence.present,
            score: asDouble(r['score']),
            confidence: asDouble(r['confidence']) ?? 0.0,
            direction: r['direction'] as String?,
          ),
        );
        continue;
      }
      final reason = withheld[name];
      rows.add(
        reason != null
            ? AxisCoverage(
                name: name,
                domain: entry.key,
                presence: AxisPresence.withheld,
                withheldReason: reason,
              )
            : AxisCoverage(
                name: name,
                domain: entry.key,
                presence: AxisPresence.absent,
              ),
      );
    }
  }

  final known = {for (final names in kCanonicalAxes.values) ...names};
  final unknown =
      readings.keys.where((k) => !known.contains(k)).toList(growable: false)
        ..sort();

  final placement = motion is Map ? motion['placement'] : null;
  final envelope = motion is Map ? motion['in_kinematic_envelope'] : null;

  return AxisCoverageReport(
    rows: rows,
    unknownMembers: unknown,
    windowConfidence: asDouble(
      (synheart is Map ? synheart['confidence'] : null) ?? doc['confidence'],
    ),
    placement: placement is String ? placement : null,
    inKinematicEnvelope: envelope is bool ? envelope : null,
  );
}

/// The withhold reason in one of the shapes the engine uses: a bare code, an
/// object with a `reason` field, or that object serialised as a string.
/// Returns the input unchanged when it is none of those, so an unfamiliar
/// shape still reaches the screen rather than being dropped.
String? _unwrapReason(Object? v) {
  if (v == null) return null;
  if (v is Map) return (v['reason'] ?? v).toString();
  if (v is String) {
    final t = v.trim();
    if (t.startsWith('{')) {
      try {
        final decoded = jsonDecode(t);
        if (decoded is Map && decoded['reason'] != null) {
          return decoded['reason'].toString();
        }
      } catch (_) {
        // Not JSON after all; fall through and show the text verbatim.
      }
    }
    return v;
  }
  return v.toString();
}
