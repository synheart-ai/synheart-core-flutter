/// The daily metrics the personal baselines accept from
/// `Synheart.srmPushWearableDaily`, by their runtime names (C ABI 3.5+). The
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

  /// Overnight RMSSD, in milliseconds.
  static const overnightRmssdMs = 'cardiac.overnight_rmssd_ms';

  /// Overnight SDNN, in milliseconds (e.g. Apple Health's HRV).
  static const overnightSdnnMs = 'cardiac.overnight_sdnn_ms';

  /// Resting heart rate, in beats per minute.
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

  /// Heart-rate-reserve load for the day, in arbitrary units.
  static const hrrLoadAu = 'cardiac.hrr_load_au';

  /// Standard deviation of overnight heart rate, in beats per minute.
  static const overnightHrSdBpm = 'cardiac.overnight_hr_sd_bpm';

  static const all = <String>{
    sleepDurationS,
    sleepMidpointH,
    overnightRmssdMs,
    overnightSdnnMs,
    restingHrBpm,
    vendorRecoveryFrac,
    sleepDeepMin,
    sleepRemMin,
    vendorStrainFrac,
    stepsCount,
    hrrLoadAu,
    overnightHrSdBpm,
  };
}
