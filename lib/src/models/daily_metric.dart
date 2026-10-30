/// The daily metrics the personal baselines accept from
/// `Synheart.srmPushWearableDaily`, by their runtime names (C ABI 4.2). The
/// unit is part of each name: push seconds to `sleep.duration_s`, minutes to
/// `sleep.deep_min`, a `0..1` fraction to `vendor.recovery_frac`.
///
/// Any other name is refused with `1004`, and so are the names these replaced
/// (`hrv_rmssd`, `resting_hr`, `sleep_need`, …).
abstract final class DailyMetric {
  /// Total sleep for the night, in seconds.
  static const sleepDurationS = 'sleep.duration_s';

  /// Midpoint of the sleep period, in hours since local midnight.
  static const sleepMidpointH = 'sleep.midpoint_h';

  /// The vendor's whole-night RMSSD, in milliseconds: the Recovery and
  /// Readiness HRV baseline.
  static const overnightRmssdMs = 'cardiac.overnight_rmssd_ms';

  /// Waking-rest RMSSD, in milliseconds. The engine writes it itself when it
  /// closes a day, and its value wins over a pushed one: do not push it.
  static const restRmssdMs = 'cardiac.rest_rmssd_ms';

  /// The night's mean heart rate while asleep, in beats per minute: the Sleep
  /// Score's heart-rate baseline. A vendor with only one overnight heart-rate
  /// figure pushes it here and as [restingHrBpm].
  static const overnightHrBpm = 'cardiac.overnight_hr_bpm';

  /// Overnight SDNN, in milliseconds (e.g. Apple Health's HRV).
  static const overnightSdnnMs = 'cardiac.overnight_sdnn_ms';

  /// The vendor's resting heart rate, in beats per minute: the Recovery and
  /// Readiness heart-rate baseline.
  static const restingHrBpm = 'cardiac.resting_hr_bpm';

  /// A provider's recovery score as a fraction, `0..1`.
  static const vendorRecoveryFrac = 'vendor.recovery_frac';

  /// Deep sleep, in minutes.
  static const sleepDeepMin = 'sleep.deep_min';

  /// REM sleep, in minutes.
  static const sleepRemMin = 'sleep.rem_min';

  /// A provider's daily strain as a fraction, `0..1`.
  static const vendorStrainFrac = 'vendor.strain_frac';

  /// Step count for the day.
  static const stepsCount = 'motion.steps_count';

  /// Active minutes in the day, pushed once the day is over (Strain).
  static const activeMin = 'motion.active_min';

  /// Heart-rate-reserve load for the day, in arbitrary units.
  static const hrrLoadAu = 'cardiac.hrr_load_au';

  /// Standard deviation of overnight heart rate, in beats per minute.
  static const overnightHrSdBpm = 'cardiac.overnight_hr_sd_bpm';

  static const all = <String>{
    sleepDurationS,
    sleepMidpointH,
    overnightRmssdMs,
    restRmssdMs,
    overnightHrBpm,
    overnightSdnnMs,
    restingHrBpm,
    vendorRecoveryFrac,
    sleepDeepMin,
    sleepRemMin,
    vendorStrainFrac,
    stepsCount,
    activeMin,
    hrrLoadAu,
    overnightHrSdBpm,
  };
}
