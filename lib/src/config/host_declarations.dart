/// Host declarations that change engine output (engine 0.16.0, blockers B-0,
/// B-2, B-5, B-6).
///
/// All four are **opt-in rather than derived from `platform`**, and the default
/// — declaring nothing — reproduces pre-0.16.0 behaviour exactly. That is
/// deliberate: each one changes the output of a host already in the field.
///
/// | Declaration | What changes the moment you declare it |
/// |---|---|
/// | [deviceClass] | Folds into the SRM `config_hash`. **Every persisted baseline snapshot stops loading** (`ERR_SRM_CONFIG_MISMATCH`) and the person re-warms 30 observations across 3 distinct days. |
/// | [sensing] | Appended to `config_id`. `episodic` additionally **withholds Capacity and Mental Fatigue** from every frame. |
/// | [maskProfile] `mobile` | Admits the hesitation bit in the `Communication` and `WritingEditing` context rows — moves Focus and Cognitive Load. |
/// | [cfiStructuralComponents] `4` | **Lowers** `conf_CFI` for identical evidence: it widens the coverage denominator. That direction surprises people. |
///
/// Declare them once at first launch and keep them stable. Changing
/// [deviceClass] mid-life is a baseline reset, not a config tweak.
///
/// `"auto"` resolves through core-runtime's `engine::host_declarations` tables
/// from the config's `platform` string, and is the recommended setting for a
/// new mobile integration — the tables are the maintained answer.
library;

/// Whether the host senses continuously or in episodes. There is no default:
/// continuous-vs-episodic is the whole claim, and guessing it is what ruling
/// B-0 forbids.
enum SensingMode {
  continuous('continuous'),
  episodic('episodic');

  final String wire;
  const SensingMode(this.wire);
}

/// The closed, versioned stream roster.
///
/// A stream you do not name is declared **unavailable**, not merely absent —
/// that is what lets a consumer distinguish "iOS structurally cannot see
/// notifications" from "this host predates the field". The roster id rides on
/// the wire as `meta.synheart.sensing.roster_version`.
///
/// Omit the whole roster to take the platform default: Android → `ANDROID`
/// continuous, desktop → `DESKTOP`, watch → `WATCH`, iOS → `IOS_EPISODIC`.
class SensingStreams {
  final bool? cardiac;
  final bool? accelerometer;
  final bool? keystrokes;
  final bool? pointer;
  final bool? appFocus;
  final bool? notificationArrivals;
  final bool? notificationResponses;
  final bool? screenState;

  const SensingStreams({
    this.cardiac,
    this.accelerometer,
    this.keystrokes,
    this.pointer,
    this.appFocus,
    this.notificationArrivals,
    this.notificationResponses,
    this.screenState,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (cardiac != null) 'cardiac': cardiac,
    if (accelerometer != null) 'accelerometer': accelerometer,
    if (keystrokes != null) 'keystrokes': keystrokes,
    if (pointer != null) 'pointer': pointer,
    if (appFocus != null) 'app_focus': appFocus,
    if (notificationArrivals != null)
      'notification_arrivals': notificationArrivals,
    if (notificationResponses != null)
      'notification_responses': notificationResponses,
    if (screenState != null) 'screen_state': screenState,
  };
}

/// An explicit sensing declaration.
///
/// ## iOS `continuous` is a claim only the host can make
///
/// An iOS app holding a BLE connection to a strap stays alive and streams all
/// day; the same app without one gets whatever foreground slices the user
/// grants. `"auto"` picks `episodic` because its failure mode is honest — it
/// withholds the two stateful heads with a reason rather than publishing torn
/// session clocks as trajectories. If you *do* hold a live peripheral
/// connection, declare [SensingMode.continuous] explicitly and both heads come
/// back.
class SensingProfile {
  /// Required. An object with no valid mode is dropped entirely (with a log
  /// line), leaving you undeclared rather than partially declared.
  final SensingMode mode;

  /// How long the engine holds a completed window before emitting it, so a
  /// retroactive source flushing less often than once per window still lands
  /// inside its own window. The frame's content is unchanged; only its
  /// emission tick moves. The hold is pipeline-wide, not per-channel.
  final int? latenessBudgetMs;

  final SensingStreams? streams;

  const SensingProfile({
    required this.mode,
    this.latenessBudgetMs,
    this.streams,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'mode': mode.wire,
    if (latenessBudgetMs != null) 'lateness_budget_ms': latenessBudgetMs,
    if (streams != null) 'streams': streams!.toJson(),
  };
}

/// SRM baseline partition. Folds into the SRM `config_hash` — see the table on
/// [HostDeclarations].
enum DeviceClass {
  desktop('desktop'),
  phone('phone'),
  tablet('tablet'),
  watch('watch');

  final String wire;
  const DeviceClass(this.wire);
}

/// Which interpretation-mask table the engine reads.
enum MaskProfile {
  desktop('desktop'),
  mobile('mobile');

  final String wire;
  const MaskProfile(this.wire);
}

/// The four declarations, plus the `"auto"` escape hatch for each.
///
/// Every field is null by default, which sends nothing and leaves the runtime
/// in its pre-0.16.0 behaviour. [HostDeclarations.auto] declares all four as
/// `"auto"`, which is a valid first cut for a new mobile integration.
class HostDeclarations {
  /// `"auto"`, or an explicit [SensingProfile]. Null sends nothing.
  final Object? sensing;

  /// `"auto"` or a [DeviceClass]. Null sends nothing.
  ///
  /// **Declaring this invalidates every persisted SRM baseline.**
  final Object? deviceClass;

  /// `"auto"` or a [MaskProfile]. Null sends nothing.
  final Object? maskProfile;

  /// Android + mobile mask only. `4` is the documented mobile value.
  final int? cfiStructuralComponents;

  const HostDeclarations({
    this.sensing,
    this.deviceClass,
    this.maskProfile,
    this.cfiStructuralComponents,
  });

  /// All four resolved from the config's `platform` string by core-runtime's
  /// own tables. The maintained answer — prefer it to re-deriving per app.
  ///
  /// Note this includes [deviceClass], so the first launch after adopting it
  /// resets persisted SRM baselines.
  static const HostDeclarations auto = HostDeclarations(
    sensing: 'auto',
    deviceClass: 'auto',
    maskProfile: 'auto',
    cfiStructuralComponents: 4,
  );

  bool get isEmpty =>
      sensing == null &&
      deviceClass == null &&
      maskProfile == null &&
      cfiStructuralComponents == null;

  static Object? _wire(Object? v) => switch (v) {
    null => null,
    String s => s,
    SensingProfile p => p.toJson(),
    DeviceClass d => d.wire,
    MaskProfile m => m.wire,
    _ => throw ArgumentError(
      'HostDeclarations field must be "auto", a SensingProfile, a DeviceClass '
      'or a MaskProfile — got ${v.runtimeType}',
    ),
  };

  /// Keys merged into the config JSON handed to `synheart_core_new`. Absent
  /// keys mean "undeclared", which is not the same as a declared default.
  Map<String, dynamic> toJson() => <String, dynamic>{
    if (sensing != null) 'sensing': _wire(sensing),
    if (deviceClass != null) 'device_class': _wire(deviceClass),
    if (maskProfile != null) 'mask_profile': _wire(maskProfile),
    if (cfiStructuralComponents != null)
      'cfi_structural_components': cfiStructuralComponents,
  };
}

/// Opt-in kinematic heads.
///
/// These do not appear in HSI frames unless requested, and they withhold even
/// when requested until a body-worn accelerometer placement is declared — see
/// `AccelPlacement`. Enabling a head is necessary but not sufficient.
///
/// Unrecognised names are ignored by the runtime with a warning, so this is a
/// closed set rather than a free string list.
enum ExtraHead {
  movementRegularity('movement_regularity'),
  posturalState('postural_state'),
  activityState('activity_state'),
  locomotionState('locomotion_state');

  final String wire;
  const ExtraHead(this.wire);
}
