/// HSI Canonical Payload — version-tolerant parser for HSI 1.0 / 1.1 /
/// 1.2.
///
/// HSI is the canonical contract maintained at
/// https://github.com/synheart-ai/hsi (also vendored at
/// `/hsi/schema/hsi-1.2.schema.json` in the workspace). The engine
/// emits HSI 1.x payloads (currently 1.2). Historic payloads and external producers
/// may still emit 1.0 / 1.1. The parser accepts all three:
///
///   - `producer.instance_id` is optional (added in 1.1, dropped in 1.2).
///   - Windows accept `start`/`end` (1.1) or `start_utc`/`end_utc` (1.2).
///   - Axes accept either `{readings: [...]}` (1.1) or a bare list (1.2).
///   - Readings accept `axis` (1.1) or `name` (1.2), and `window_id`
///     (1.1) or the first entry of `window_ids` (1.2).
///   - Top-level `window_ids` is optional in 1.2 (derive from
///     `windows.keys`).
///   - `privacy` is optional in 1.2 streaming windows.
///
/// Unrecognised `hsi_version` strings are parsed leniently and logged
/// once via [`_warnUnknownVersionOnce`]. This is the canary for schema
/// drift — if you see that warning in production, the HSI repo has
/// shipped a new version that this parser doesn't yet know about, and
/// `synheart-core-flutter` should pin updated test vectors and
/// regenerate accordingly.
///
/// **Future direction**: replace the hand-rolled factory with code
/// generated from the schema (`json_schema_codegen` / `quicktype`).
/// The hand-rolled parser exists today as a stopgap; canonical
/// fixtures from the HSI repo's `test-vectors/` and `examples/valid/`
/// directories are pinned at `test/fixtures/hsi/` and exercised by
/// `test/hsi_parser_compat_test.dart` — the regression net for drift.
///
/// See: https://github.com/synheart-ai/hsi
class HSIPayload {
  final String hsiVersion;
  final String observedAtUtc;
  final String computedAtUtc;
  final HSI11Producer producer;
  final List<String> windowIds;
  final Map<String, HSI11Window> windows;
  final HSI11Axes? axes;
  final List<HSI11Embedding>? embeddings;
  final HSI11Privacy privacy;
  final Map<String, dynamic>? meta;

  HSIPayload({
    required this.hsiVersion,
    required this.observedAtUtc,
    required this.computedAtUtc,
    required this.producer,
    required this.windowIds,
    required this.windows,
    this.axes,
    this.embeddings,
    required this.privacy,
    this.meta,
  });

  factory HSIPayload.fromJson(Map<String, dynamic> json) {
    final version = json['hsi_version'] as String? ?? '';
    warnUnknownHsiVersionOnce(version);
    final windowsMap = (json['windows'] as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, HSI11Window.fromJson(v as Map<String, dynamic>)),
    );
    // 1.1 carried `window_ids` at the top level; 1.2 dropped that
    // duplicate and lets consumers derive it from `windows.keys`.
    final ids =
        (json['window_ids'] as List<dynamic>?)?.cast<String>() ??
        windowsMap.keys.toList();
    // `privacy` is required in 1.1 but the 1.2 engine may omit it on
    // realtime streaming windows. Default to a conservative no-PII /
    // research-consent stub so downstream consumers don't crash on
    // missing field — they should still treat absence as "unknown".
    final privacy = json['privacy'] is Map
        ? HSI11Privacy.fromJson(json['privacy'] as Map<String, dynamic>)
        : HSI11Privacy(
            containsPii: false,
            rawBiosignalsAllowed: false,
            derivedMetricsAllowed: true,
          );
    return HSIPayload(
      hsiVersion: version,
      observedAtUtc: json['observed_at_utc'] as String,
      computedAtUtc: json['computed_at_utc'] as String,
      producer: HSI11Producer.fromJson(
        json['producer'] as Map<String, dynamic>,
      ),
      windowIds: ids,
      windows: windowsMap,
      axes: json['axes'] is Map
          ? HSI11Axes.fromJson(json['axes'] as Map<String, dynamic>)
          : null,
      embeddings: (json['embeddings'] as List<dynamic>?)
          ?.map((e) => HSI11Embedding.fromJson(e as Map<String, dynamic>))
          .toList(),
      privacy: privacy,
      meta: json['meta'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() => {
    'hsi_version': hsiVersion,
    'observed_at_utc': observedAtUtc,
    'computed_at_utc': computedAtUtc,
    'producer': producer.toJson(),
    'window_ids': windowIds,
    'windows': windows.map((k, v) => MapEntry(k, v.toJson())),
    if (axes != null) 'axes': axes!.toJson(),
    if (embeddings != null)
      'embeddings': embeddings!.map((e) => e.toJson()).toList(),
    'privacy': privacy.toJson(),
    if (meta != null) 'meta': meta,
  };
}

class HSI11Producer {
  final String name;
  final String version;
  final String instanceId;

  HSI11Producer({
    required this.name,
    required this.version,
    required this.instanceId,
  });

  factory HSI11Producer.fromJson(Map<String, dynamic> json) => HSI11Producer(
    name: json['name'] as String,
    version: json['version'] as String,
    // HSI 1.2 dropped `instance_id`. Fall back to empty when
    // absent so 1.2 payloads parse without throwing.
    instanceId: json['instance_id'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'version': version,
    'instance_id': instanceId,
  };
}

class HSI11Window {
  final String start;
  final String end;
  final String? label;

  HSI11Window({required this.start, required this.end, this.label});

  factory HSI11Window.fromJson(Map<String, dynamic> json) => HSI11Window(
    // 1.1 → `start` / `end`, 1.2 → `start_utc` / `end_utc`.
    start: (json['start'] ?? json['start_utc']) as String,
    end: (json['end'] ?? json['end_utc']) as String,
    label: json['label'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'start': start,
    'end': end,
    if (label != null) 'label': label,
  };
}

class HSI11Axes {
  // Domains carried over / introduced across HSI 1.0–1.3.
  // `physiological` is canonical in every version. `engagement`, `behavior`,
  // `context` are 1.0–1.2 only (dissolved in 1.3).
  // `kinematic`, `digital`, `cognitive`, `affective` are introduced in 1.3.
  // The struct intentionally carries the union — older
  // payloads populate the legacy fields, 1.3 payloads populate the new ones.
  final HSI11Domain? physiological;
  final HSI11Domain? engagement;
  final HSI11Domain? behavior;
  final HSI11Domain? context;
  final HSI11Domain? kinematic;
  final HSI11Domain? digital;
  final HSI11Domain? cognitive;
  final HSI11Domain? affective;

  HSI11Axes({
    this.physiological,
    this.engagement,
    this.behavior,
    this.context,
    this.kinematic,
    this.digital,
    this.cognitive,
    this.affective,
  });

  factory HSI11Axes.fromJson(Map<String, dynamic> json) => HSI11Axes(
    physiological: HSI11Domain._tryParse(json['physiological']),
    engagement: HSI11Domain._tryParse(json['engagement']),
    behavior: HSI11Domain._tryParse(json['behavior']),
    context: HSI11Domain._tryParse(json['context']),
    kinematic: HSI11Domain._tryParse(json['kinematic']),
    digital: HSI11Domain._tryParse(json['digital']),
    cognitive: HSI11Domain._tryParse(json['cognitive']),
    affective: HSI11Domain._tryParse(json['affective']),
  );

  Map<String, dynamic> toJson() => {
    if (physiological != null) 'physiological': physiological!.toJson(),
    if (engagement != null) 'engagement': engagement!.toJson(),
    if (behavior != null) 'behavior': behavior!.toJson(),
    if (context != null) 'context': context!.toJson(),
    if (kinematic != null) 'kinematic': kinematic!.toJson(),
    if (digital != null) 'digital': digital!.toJson(),
    if (cognitive != null) 'cognitive': cognitive!.toJson(),
    if (affective != null) 'affective': affective!.toJson(),
  };
}

class HSI11Domain {
  final List<HSI11Reading> readings;

  HSI11Domain({required this.readings});

  factory HSI11Domain.fromJson(Map<String, dynamic> json) => HSI11Domain(
    readings: (json['readings'] as List<dynamic>)
        .map((e) => HSI11Reading.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  /// Accept either the 1.1 shape `{readings: [...]}` or the 1.2 shape
  /// (a bare list of readings). Returns null when the value is neither.
  static HSI11Domain? _tryParse(Object? raw) {
    if (raw is Map<String, dynamic>) {
      if (raw['readings'] is List) {
        return HSI11Domain.fromJson(raw);
      }
      return null;
    }
    if (raw is List) {
      return HSI11Domain(
        readings: raw
            .whereType<Map<String, dynamic>>()
            .map(HSI11Reading.fromJson)
            .toList(),
      );
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'readings': readings.map((e) => e.toJson()).toList(),
  };
}

class HSI11Reading {
  final String axis;

  /// The reading's value, coerced to `0.0` when the wire said `null`.
  ///
  /// **Prefer [scoreOrNull] for anything that renders or aggregates.** The
  /// engine emits `"score": null` to mean *this axis produced no value*, which
  /// is a different claim from a measured zero — and for a `lower_is_more`
  /// axis the two are opposites, since `1 - 0.0` is the maximum magnitude.
  /// This field cannot express that distinction and is kept only so existing
  /// consumers keep compiling.
  final double score;

  /// The reading's value, or `null` when the engine produced none.
  ///
  /// This is the honest form: `null` means withheld/unavailable and `0.0`
  /// means measured zero. Gate on it (or on [confidence]) rather than treating
  /// a zero as absence — a genuine 0.0 is evidence, and dropping it biases
  /// every mean computed over an inverse-sense axis.
  final double? scoreOrNull;

  final double confidence;
  final String windowId;
  final String? direction;
  final String? unit;
  final List<String>? evidenceSourceIds;
  final String? notes;

  /// Construct from a known value. [scoreOrNull] mirrors [score], because a
  /// caller supplying a concrete double is asserting the value exists.
  HSI11Reading({
    required this.axis,
    required this.score,
    required this.confidence,
    required this.windowId,
    this.direction,
    this.unit,
    this.evidenceSourceIds,
    this.notes,
  }) : scoreOrNull = score;

  /// Construct from a possibly-absent value — the wire form.
  ///
  /// Separate from the default constructor because an optional
  /// `double? scoreOrNull` parameter cannot tell "omitted" from "explicitly
  /// null": defaulting it back to `score` silently re-flattens exactly the
  /// distinction this type exists to preserve.
  HSI11Reading.raw({
    required this.axis,
    required double? score,
    required this.confidence,
    required this.windowId,
    this.direction,
    this.unit,
    this.evidenceSourceIds,
    this.notes,
  }) : score = score ?? 0.0,
       scoreOrNull = score;

  factory HSI11Reading.fromJson(Map<String, dynamic> json) {
    // 1.1 → `axis`, 1.2 → `name`. Required either way.
    final axis = (json['axis'] ?? json['name']) as String;
    // 1.1 → single `window_id`, 1.2 → `window_ids: [<one-or-more>]`.
    String windowId;
    if (json['window_id'] is String) {
      windowId = json['window_id'] as String;
    } else if (json['window_ids'] is List &&
        (json['window_ids'] as List).isNotEmpty) {
      windowId = (json['window_ids'] as List).first as String;
    } else {
      windowId = '';
    }
    // 1.2+ allows `score: null` to express "score unavailable" (paired with
    // confidence and an explanatory `notes`). Both forms are kept: `score`
    // coerces to 0 for the existing consumers, `scoreOrNull` preserves the
    // distinction for anything that renders or aggregates.
    final rawScore = (json['score'] as num?)?.toDouble();
    return HSI11Reading.raw(
      axis: axis,
      score: rawScore,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      windowId: windowId,
      direction: json['direction'] as String?,
      unit: json['unit'] as String?,
      evidenceSourceIds: (json['evidence_source_ids'] as List<dynamic>?)
          ?.cast<String>(),
      notes: json['notes'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'axis': axis,
    // Round-trips the withheld form rather than flattening it to 0.
    'score': scoreOrNull,
    'confidence': confidence,
    'window_id': windowId,
    if (direction != null) 'direction': direction,
    if (unit != null) 'unit': unit,
    if (evidenceSourceIds != null) 'evidence_source_ids': evidenceSourceIds,
    if (notes != null) 'notes': notes,
  };
}

class HSI11Embedding {
  final List<double> vector;
  final int dimension;
  final String encoding;
  final double confidence;
  final String windowId;
  final String? vectorHash;
  final String? model;
  final String? notes;

  HSI11Embedding({
    required this.vector,
    required this.dimension,
    required this.encoding,
    required this.confidence,
    required this.windowId,
    this.vectorHash,
    this.model,
    this.notes,
  });

  factory HSI11Embedding.fromJson(Map<String, dynamic> json) => HSI11Embedding(
    // HSI 1.2 commonly ships only `vector_hash` (the actual vector
    // stays on-device for privacy). Treat absent vector as empty
    // — consumers that need the raw values check
    // `vector.isNotEmpty` and fall back to `vectorHash` otherwise.
    vector:
        (json['vector'] as List<dynamic>?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        const <double>[],
    dimension: (json['dimension'] as num).toInt(),
    encoding: json['encoding'] as String,
    confidence: (json['confidence'] as num).toDouble(),
    windowId: json['window_id'] as String,
    vectorHash: json['vector_hash'] as String?,
    model: json['model'] as String?,
    notes: json['notes'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'vector': vector,
    'dimension': dimension,
    'encoding': encoding,
    'confidence': confidence,
    'window_id': windowId,
    if (vectorHash != null) 'vector_hash': vectorHash,
    if (model != null) 'model': model,
    if (notes != null) 'notes': notes,
  };
}

class HSI11Privacy {
  final bool containsPii;
  final bool rawBiosignalsAllowed;
  final bool derivedMetricsAllowed;
  final bool embeddingAllowed;
  final String consent;
  final String? notes;

  HSI11Privacy({
    required this.containsPii,
    required this.rawBiosignalsAllowed,
    required this.derivedMetricsAllowed,
    this.embeddingAllowed = false,
    this.consent = 'explicit',
    this.notes,
  });

  factory HSI11Privacy.fromJson(Map<String, dynamic> json) {
    // HSI 1.0 used flat keys (`raw_biosignals_allowed`,
    // `derived_metrics_allowed`, `embedding_allowed`, `consent` as
    // string). HSI 1.1+ moved them under a nested `consent` object
    // (`{level, raw_biosignals, derived_metrics, embedding}`) and made
    // `contains_pii` non-mandatory in some flavours. Accept both
    // shapes so canonical fixtures across versions parse cleanly.
    final consentObj = json['consent'];
    final consentMap = consentObj is Map<String, dynamic> ? consentObj : null;
    bool readBool(String flat, String nested, {bool fallback = false}) {
      if (json[flat] is bool) return json[flat] as bool;
      if (consentMap != null && consentMap[nested] is bool) {
        return consentMap[nested] as bool;
      }
      return fallback;
    }

    return HSI11Privacy(
      containsPii: json['contains_pii'] is bool
          ? json['contains_pii'] as bool
          : false,
      rawBiosignalsAllowed: readBool(
        'raw_biosignals_allowed',
        'raw_biosignals',
      ),
      derivedMetricsAllowed: readBool(
        'derived_metrics_allowed',
        'derived_metrics',
        fallback: true,
      ),
      embeddingAllowed: readBool('embedding_allowed', 'embedding'),
      consent: consentMap != null
          ? (consentMap['level'] as String? ?? 'explicit')
          : (consentObj is String ? consentObj : 'explicit'),
      notes: json['notes'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'contains_pii': containsPii,
    'raw_biosignals_allowed': rawBiosignalsAllowed,
    'derived_metrics_allowed': derivedMetricsAllowed,
    'embedding_allowed': embeddingAllowed,
    'consent': consent,
    if (notes != null) 'notes': notes,
  };
}

// ── Version-drift canary ─────────────────────────────────────────────
//
// HSI versions this parser is known-good against. Update in lockstep
// with `synheart-core-flutter/test/fixtures/hsi/` — see
// `test/hsi_parser_compat_test.dart`. When a new HSI release ships,
// vendor its test vectors first, then add the version string here.
const Set<String> kKnownHsiVersions = {'1.0', '1.1', '1.2', '1.3'};

final Set<String> _warnedHsiVersions = <String>{};

/// Log once per process per unrecognised `hsi_version` string. Called
/// from [HSIPayload.fromJson] when the payload version isn't in
/// [kKnownHsiVersions]. The warning is the canary for schema drift —
/// if you see it in production logs, the engine has shipped a new HSI
/// version that this parser doesn't know about. Pin updated fixtures
/// from the canonical HSI repo and bump [kKnownHsiVersions].
void warnUnknownHsiVersionOnce(String version) {
  if (kKnownHsiVersions.contains(version)) return;
  if (!_warnedHsiVersions.add(version)) return;
  // Use stderr-style print rather than the SDK's own logger so this
  // surfaces even in environments where SynheartLogger is muted —
  // schema drift warrants visibility.
  // ignore: avoid_print
  print(
    '[HSIPayload] WARNING: unrecognised hsi_version="$version". '
    'Parser may silently mis-handle fields that changed in this version. '
    'Update synheart-core-flutter fixtures from '
    'https://github.com/synheart-ai/hsi and add "$version" to '
    'kKnownHsiVersions to silence this warning.',
  );
}

// ── Backwards-compat alias ───────────────────────────────────────────
//
// The top-level type's canonical name is now version-free (HSI is the
// contract; the version is a field on each payload). This typedef
// preserves compile-time compatibility with call sites that still
// reference `HSI11Payload` — ~80 of them across the workspace at the
// time of writing. New code should use [HSIPayload] directly.
//
// The auxiliary types (`HSI11Producer`, `HSI11Window`, `HSI11Axes`,
// `HSI11Domain`, `HSI11Reading`, `HSI11Embedding`, `HSI11Privacy`)
// keep their version-prefixed names because `HSIAxes` already exists
// in `hsi_state.dart` as an unrelated runtime-state class
// (focus/arousal/capacity/sleep). Renaming would shadow that.
typedef HSI11Payload = HSIPayload;
