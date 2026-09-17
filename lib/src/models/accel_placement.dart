/// Where the accelerometer physically sits, for `set_accel_placement`.
///
/// Enabling a kinematic head via `extra_heads` is necessary but not sufficient:
/// the four kinematic axes stay withheld until a body-worn mount is declared.
/// [unknown] — the default — withholds all of them.
///
/// ## The validated envelope is [pocket] and [waist] only
///
/// [wrist] and [chest] are body-worn but outside the envelope the kinematic
/// heads were validated against; [desk] is not body-worn at all, and the
/// suppression that comes with it exists precisely so desk vibration does not
/// read as physiology-relevant motion.
///
/// ## Placement is dynamic, not a compile-time constant
///
/// There is no hand-held placement, and during exactly the interaction the
/// digital axes measure — typing, scrolling — the phone is in the hand. So the
/// kinematic and behavioural axes are largely disjoint in time on a phone, and
/// a fixed `pocket` declared once at startup is simply wrong the moment the
/// person picks the device up. Re-declare as the placement actually changes.
///
/// Until a labelled 50 Hz dataset validates pocket geometry on phones, treat
/// mobile kinematics as a validation target rather than a shipped capability.
enum AccelPlacement {
  unknown(0),
  pocket(1),
  wrist(2),
  chest(3),
  desk(4),
  waist(5);

  /// Discriminant the C ABI expects.
  final int code;
  const AccelPlacement(this.code);

  /// Whether this placement is inside the validated envelope for the kinematic
  /// heads. `false` for everything but [pocket] and [waist].
  bool get isValidatedEnvelope =>
      this == AccelPlacement.pocket || this == AccelPlacement.waist;
}
