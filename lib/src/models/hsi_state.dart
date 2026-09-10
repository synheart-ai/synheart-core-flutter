import 'dart:convert';

import '../core/logger.dart';

/// A single HSI axis reading with value and confidence.
class HSIAxisValue {
  final double value;
  final double confidence;

  const HSIAxisValue({required this.value, required this.confidence});

  factory HSIAxisValue.fromJson(Map<String, dynamic> json) => HSIAxisValue(
    value: (json['value'] as num?)?.toDouble() ?? 0.0,
    confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
  );

  Map<String, dynamic> toJson() => {'value': value, 'confidence': confidence};
}

/// The canonical HSI axes surfaced to hosts.
class HSIAxes {
  final HSIAxisValue? focus;
  final HSIAxisValue? arousal;
  final HSIAxisValue? capacity;
  final HSIAxisValue? sleep;

  /// Multimodal stress reading (motion-gated autonomic primary fused with a
  /// behavioral corroborator). New in engine v0.10.0; carried on
  /// `axes.affective[]` in HSI 1.3 only — null on the legacy/1.2 path.
  final HSIAxisValue? stress;

  // ── Digital axes (`axes.digital[]`, HSI 1.3) ──────────────────────────
  //
  // Derived from interaction events — taps, scrolls, swipes, app switches,
  // notifications — by the runtime's interaction adapter. They need no
  // wearable and no biosignal, which makes them the only axes that resolve on
  // a phone with nothing attached.
  //
  // These were parsed by nothing before: `_parseAxesV13` read `cognitive`,
  // `affective` and `physiological` and dropped the `digital` domain on the
  // floor, so behavior data reached the runtime, produced readings, and then
  // vanished at the SDK boundary. A host with no wearable saw five empty axes
  // and no way to tell that anything had been computed at all.
  //
  // Note the one-window lag: the runtime flushes interaction events for the
  // window that just closed and attaches the result to the NEXT emission, so
  // the first window of a session carries none of them.

  /// Sustained-attention quality over the window. Higher is more focused.
  final HSIAxisValue? focusQuality;

  /// Interruption load — notifications and app switching against the user's
  /// own baseline. `direction: lower_is_more`, so a LOW score means MORE
  /// pressure; do not render it as if higher were better.
  final HSIAxisValue? interruptionPressure;

  /// Where the interaction sits between passive consumption and active input.
  /// `direction: bidirectional` — neither end is "good".
  final HSIAxisValue? interactionMode;

  const HSIAxes({
    this.focus,
    this.arousal,
    this.capacity,
    this.sleep,
    this.stress,
    this.focusQuality,
    this.interruptionPressure,
    this.interactionMode,
  });

  /// True when at least one digital reading resolved.
  bool get hasDigital =>
      focusQuality != null ||
      interruptionPressure != null ||
      interactionMode != null;

  /// Pre-1.3 (legacy) parse: each axis is a flat object `{value, confidence}`
  /// at the top of the `hsi` map. Used for the in-process runtime contract
  /// and for HSI 1.2 payloads that don't fit the canonical wire shape.
  factory HSIAxes.fromJson(Map<String, dynamic> json) => HSIAxes(
    focus: json['focus'] is Map
        ? HSIAxisValue.fromJson(json['focus'] as Map<String, dynamic>)
        : null,
    arousal: json['arousal'] is Map
        ? HSIAxisValue.fromJson(json['arousal'] as Map<String, dynamic>)
        : null,
    capacity: json['capacity'] is Map
        ? HSIAxisValue.fromJson(json['capacity'] as Map<String, dynamic>)
        : null,
    sleep: json['sleep'] is Map
        ? HSIAxisValue.fromJson(json['sleep'] as Map<String, dynamic>)
        : null,
    // Stress is 1.3-only; tolerate a flat `hsi.stress` from a forward-compat
    // producer but expect null on the legacy path.
    stress: json['stress'] is Map
        ? HSIAxisValue.fromJson(json['stress'] as Map<String, dynamic>)
        : null,
  );
}

/// Find a reading by `name` in an axis-domain readings array (HSI 1.2/1.3
/// `axes.<domain>: [{name, score, confidence, ...}]`).
///
/// Returns null when the domain is missing, not a list, or when no matching
/// reading is found. Skips readings with `score: null` (categorical or
/// "could not compute" — consumers MUST NOT treat null
/// as zero), since the `HSIAxisValue` shape requires a numeric value.
HSIAxisValue? _findAxisReading(Object? domain, String name) {
  if (domain is! List) return null;
  for (final r in domain) {
    if (r is! Map) continue;
    if (r['name'] != name) continue;
    final s = r['score'];
    if (s is! num) return null;
    final c = r['confidence'];
    return HSIAxisValue(
      value: s.toDouble(),
      confidence: c is num ? c.toDouble() : 0.0,
    );
  }
  return null;
}

/// HSI 1.3 parse path (canonical 5-domain set).
/// `focus`/`capacity` → `axes.cognitive[]`, `valence`/`arousal`/`stress` →
/// `axes.affective[]`, `sleep_score` → `axes.physiological[]`. We surface
/// `arousal` (not `valence`) as the affective axis to keep parity with the
/// legacy 4-axis model. The canonical `sleep_score` member is preferred;
/// `sleep` is tolerated for forward-compat producers.
HSIAxes _parseAxesV13(Object? axes) {
  if (axes is! Map) return const HSIAxes();
  return HSIAxes(
    focus: _findAxisReading(axes['cognitive'], 'focus'),
    capacity: _findAxisReading(axes['cognitive'], 'capacity'),
    arousal: _findAxisReading(axes['affective'], 'arousal'),
    sleep:
        _findAxisReading(axes['physiological'], 'sleep_score') ??
        _findAxisReading(axes['physiological'], 'sleep'),
    stress: _findAxisReading(axes['affective'], 'stress'),
    // The digital domain. Produced from interaction events alone, so these
    // resolve on hardware that can supply no biosignal at all.
    focusQuality: _findAxisReading(axes['digital'], 'focus_quality'),
    interruptionPressure: _findAxisReading(
      axes['digital'],
      'interruption_pressure',
    ),
    interactionMode: _findAxisReading(axes['digital'], 'interaction_mode'),
  );
}

/// Modality availability derived from `meta.provenance.sources[*].signals` per
/// the Synheart Runtime signal-modality mapping spec.
///
/// Apps gate UX on these booleans (e.g. drop physiology copy when
/// `physiological == false`).
class Modalities {
  final bool physiological;
  final bool kinematic;
  final bool digital;

  const Modalities({
    this.physiological = false,
    this.kinematic = false,
    this.digital = false,
  });

  bool get isEmpty => !physiological && !kinematic && !digital;
}

/// Per-modality fidelity bundle. Pre-canonical: in HSI 1.3 this becomes
/// per-axis `tiers`. Lower-numbered tier = higher fidelity.
class Tiers {
  final int? physiological; // 1..=4 from `source.source_tier`
  final int? kinematic; // 1..=3 from `meta.synheart.tiers.kinematic`
  final int? digital; // 1..=3 from `meta.synheart.tiers.digital`

  const Tiers({this.physiological, this.kinematic, this.digital});

  bool get isEmpty =>
      physiological == null && kinematic == null && digital == null;
}

/// Map a single signal name to its modality per the contract doc.
String? _signalToModality(String signal) {
  switch (signal) {
    case 'hrv':
    case 'rr':
    case 'ecg':
    case 'ppg':
    case 'spo2':
    case 'resp':
    case 'eda':
    case 'gsr':
    case 'temp':
    case 'hr':
      return 'physiological';
    case 'accel':
    case 'gyro':
    case 'mag':
      return 'kinematic';
    case 'touch':
    case 'scroll':
    case 'app_switch':
    case 'typing':
    case 'notification':
    case 'clipboard':
      return 'digital';
    default:
      return null; // unknown / future signal — ignore
  }
}

Modalities _deriveModalities(Map<String, dynamic> payload) {
  bool physio = false;
  bool kin = false;
  bool dig = false;
  final sources = payload['meta'] is Map
      ? (payload['meta'] as Map)['provenance'] is Map
            ? ((payload['meta'] as Map)['provenance'] as Map)['sources']
            : null
      : null;
  if (sources is Map) {
    for (final entry in sources.values) {
      if (entry is! Map) continue;
      final signals = entry['signals'];
      if (signals is! List) continue;
      for (final sig in signals) {
        if (sig is! String) continue;
        switch (_signalToModality(sig)) {
          case 'physiological':
            physio = true;
            break;
          case 'kinematic':
            kin = true;
            break;
          case 'digital':
            dig = true;
            break;
        }
      }
    }
  }
  return Modalities(physiological: physio, kinematic: kin, digital: dig);
}

Tiers _deriveTiers(Map<String, dynamic> payload) {
  int? physio;
  int? kin;
  int? dig;

  // Physiological: walk sources, take worst-numbered (highest int) from any
  // source emitting a physiological signal.
  final sources = payload['meta'] is Map
      ? (payload['meta'] as Map)['provenance'] is Map
            ? ((payload['meta'] as Map)['provenance'] as Map)['sources']
            : null
      : null;
  if (sources is Map) {
    for (final entry in sources.values) {
      if (entry is! Map) continue;
      final signals = entry['signals'];
      if (signals is! List) continue;
      final isPhysio = signals.any(
        (s) => s is String && _signalToModality(s) == 'physiological',
      );
      if (!isPhysio) continue;
      final st = entry['source_tier'];
      if (st is num) {
        final v = st.toInt();
        physio = (physio == null) ? v : (physio > v ? physio : v);
      }
    }
  }

  // Kinematic / digital: residual shim under meta.synheart.tiers.
  final shim = payload['meta'] is Map
      ? (payload['meta'] as Map)['synheart'] is Map
            ? ((payload['meta'] as Map)['synheart'] as Map)['tiers']
            : null
      : null;
  if (shim is Map) {
    final k = shim['kinematic'];
    if (k is num) kin = k.toInt();
    final d = shim['digital'];
    if (d is num) dig = d.toInt();
  }

  return Tiers(physiological: physio, kinematic: kin, digital: dig);
}

/// Read `meta.synheart` off a parsed payload, or null when it is absent.
///
/// Both of the maps below hang off this one block, and it is legitimately
/// missing: `sensing` appears only when the host declared a profile, and a
/// runtime that predates the block emits neither.
Map<String, dynamic>? _synheartMeta(Map<String, dynamic> payload) {
  final meta = payload['meta'];
  if (meta is! Map) return null;
  final synheart = meta['synheart'];
  return synheart is Map ? synheart.cast<String, dynamic>() : null;
}

/// `meta.synheart.state_withheld` — axis name to the reason it was omitted.
///
/// A reading with no contributing modality is omitted rather than defaulted,
/// and this map is where the omission is explained (`episodic_sensing`,
/// `cold_start_confidence_exhausted`, …). On mobile that is the common case,
/// not the exception, so a UI that only reads `axes.*` cannot tell "withheld
/// with a reason" from "this build does not produce that axis".
///
/// A canonical member is complete over `axes.<domain>` ∪ this map — check both
/// before concluding a member is unsupported, and never paint a default in
/// place of a withheld value.
Map<String, String> _deriveStateWithheld(Map<String, dynamic> payload) {
  final withheld = _synheartMeta(payload)?['state_withheld'];
  if (withheld is! Map) return const <String, String>{};
  return <String, String>{
    for (final entry in withheld.entries)
      if (entry.key is String && entry.value is String)
        entry.key as String: entry.value as String,
  };
}

/// Typed HSI state emitted by `Synheart.onStateUpdate`.
///
/// Provides typed axis accessors and retains `rawJson` for diagnostic use.
/// `modalities` and `tiers` are derived from `meta.provenance.sources[*]
/// .signals` and `meta.synheart.tiers` per the Synheart signal-modality
/// mapping contract.
class HSIState {
  final String subjectId;
  final int timestampMs;
  final HSIAxes hsi;
  final Modalities modalities;
  final Tiers tiers;
  final String rawJson;

  /// Axes the engine omitted, mapped to why — `meta.synheart.state_withheld`.
  ///
  /// Empty when nothing was withheld. Read this alongside [hsi]: an axis
  /// missing from both is genuinely unsupported by the build, whereas one
  /// listed here was deliberately not produced and must be rendered as
  /// unavailable rather than as a neutral default.
  ///
  /// Common mobile reasons: `episodic_sensing` withholds `capacity` and
  /// `mental_fatigue` on every frame; `cold_start_confidence_exhausted` marks
  /// a Capacity reading whose confidence chain was consumed by the cold-start
  /// penalty, which is unavailable rather than a score of zero.
  final Map<String, String> stateWithheld;

  /// `meta.synheart.sensing` — the sensing profile this window was produced
  /// under, or null when the host declared none.
  ///
  /// Present only for a host that passed `HostDeclarations.sensing`. Consumers
  /// comparing across platforms should **stratify on this block rather than
  /// pooling**: a Cognitive Load built without notification observation and
  /// without a context layer measures a structurally thinner subset of the
  /// same construct. `rest_declared` also rides here, which is why a
  /// `declareRestWindow` on an undeclared host still gates correctly but has
  /// nothing on the wire to explain the `focus = 0.0`.
  final Map<String, dynamic>? sensing;

  /// Non-null when [fromJson] could not parse [rawJson] and fell back to empty
  /// axes.
  ///
  /// Without this, a malformed payload, a schema drift, or an HSI version the
  /// parser doesn't understand produced a state byte-identical to a legitimate
  /// window whose axes the engine hasn't populated yet — so a developer had no
  /// way to tell "no data" from "parse failed". Check [hasParseError] before
  /// concluding the engine is simply still warming up. [rawJson] is retained
  /// either way, so the offending payload is always available.
  final String? parseError;

  /// True when this state is a parse-failure fallback rather than real output.
  bool get hasParseError => parseError != null;

  const HSIState({
    required this.subjectId,
    required this.timestampMs,
    required this.hsi,
    required this.rawJson,
    this.modalities = const Modalities(),
    this.tiers = const Tiers(),
    this.stateWithheld = const <String, String>{},
    this.sensing,
    this.parseError,
  });

  /// Parse an HSI JSON string from the runtime into a typed [HSIState].
  ///
  /// Version dispatch: when `hsi_version == "1.3"`, axes are read from the
  /// canonical 5-domain layout (`axes.cognitive[]`, `axes.affective[]`,
  /// `axes.physiological[]`). For any other version (legacy / 1.2), the
  /// pre-1.3 path falls back to the flat `hsi.<name>` shape used by the
  /// in-process runtime contract.
  factory HSIState.fromJson(String json, {String subjectId = ''}) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      final timestampMs =
          (map['timestamp_ms'] as num?)?.toInt() ??
          (map['observed_at_ms'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch;

      final sid = (map['subject_id'] as String?) ?? subjectId;
      final HSIAxes axes;
      if (map['hsi_version'] == '1.3') {
        axes = _parseAxesV13(map['axes']);
      } else {
        final hsiMap = (map['hsi'] as Map<String, dynamic>?) ?? map;
        axes = HSIAxes.fromJson(hsiMap);
      }

      return HSIState(
        subjectId: sid,
        timestampMs: timestampMs,
        hsi: axes,
        modalities: _deriveModalities(map),
        tiers: _deriveTiers(map),
        stateWithheld: _deriveStateWithheld(map),
        sensing: _synheartMeta(map)?['sensing'] is Map
            ? (_synheartMeta(map)!['sensing'] as Map).cast<String, dynamic>()
            : null,
        rawJson: json,
      );
    } catch (e) {
      SynheartLogger.log(
        '[Synheart] HSIState.fromJson failed: $e — returning empty axes. '
        'Inspect HSIState.rawJson for the payload.',
        error: e,
      );
      return HSIState(
        subjectId: subjectId,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        hsi: const HSIAxes(),
        rawJson: json,
        parseError: e.toString(),
      );
    }
  }
}
