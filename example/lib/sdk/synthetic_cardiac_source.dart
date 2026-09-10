import 'dart:math';

/// A **simulated** cardiac source, for exercising the ingest path when no
/// wearable is attached.
///
/// ## Read this before using it for anything
///
/// The samples this produces are fabricated. They flow into exactly the same
/// runtime plumbing real beats do — including the SRM, which builds the
/// person's longitudinal reference ranges on this device — so a simulated run
/// leaves a mark on the baselines of whatever `subject_id` it ran under. Use a
/// throwaway subject id for it, and wipe local data afterwards. That is why
/// nothing here is wired to start on its own: the host has to ask.
///
/// It is also tagged honestly on the way in. Every push carries a Tier-3
/// provider rather than `'ble_hrm'`, so it never claims the Tier-1 routing a
/// real chest strap earns. Claiming Tier-1 for invented data would put it into
/// the breathing detector's Tier-1 series, and withholding stops working the
/// moment a host lies about where a number came from.
///
/// ## Cardiac and nothing else
///
/// This is the **only** simulated source in the example, and it stays that
/// way. It models beats — RR intervals and the rate derived from them — and
/// deliberately emits no motion, no speed, no screen state, no app focus and
/// no notifications, even though the activity episodes below would make all of
/// those easy to invent alongside.
///
/// The reason is that a fabricated non-cardiac stream is not a smaller version
/// of the same compromise, it is a worse one. A simulated heart rate is
/// visibly a stand-in for hardware the device does not have; a simulated
/// screen-state or GPS trace is indistinguishable from a real one the phone
/// could genuinely have produced, so nothing downstream — and nobody reading a
/// screenshot — can tell it apart. `activityLabel` is exposed for the UI to
/// explain a rate that just climbed 30 bpm; it is not a locomotion claim and
/// must not be pushed as one.
///
/// ## What makes it physiologically shaped rather than random
///
/// A `Random().nextInt(200)` heart rate is worse than no data: it has no
/// autocorrelation, so every HRV feature computed from it is noise, and it
/// wanders outside any range a living person occupies. This model instead
/// reproduces the four things that actually structure a heart-rate trace:
///
/// 1. **A mean-reverting drift.** The instantaneous rate is pulled toward a
///    target by an Ornstein–Uhlenbeck process, so consecutive seconds are
///    correlated and the series never runs away. Combined with the hard clamp
///    to [minBpm]–[maxBpm], the trace stays inside a healthy adult envelope
///    without being pinned to one value.
/// 2. **Activity episodes.** The target itself moves between rest, light and
///    moderate exertion, then decays back through a recovery phase. This is
///    what stops the output being a flat line with jitter on it — HR has
///    structure on a scale of minutes, not just beats.
/// 3. **Respiratory sinus arrhythmia.** Beat-to-beat interval is modulated by
///    breathing at ~0.2–0.3 Hz. This is the dominant source of short-term HRV
///    in a healthy person and the thing RMSSD is largely measuring.
/// 4. **RSA suppression under load.** The respiratory swing shrinks as rate
///    rises, because vagal tone withdraws during exertion. Without this, a
///    simulated 110 bpm carries resting-level HRV, which reads as a
///    physiological impossibility to anything downstream.
///
/// ## It generates beats, not readings
///
/// The primitive is the RR interval, and heart rate is derived from it — the
/// same direction of causation a real sensor has. Generating a bpm number and
/// inventing RR intervals to match would produce HRV that is an artifact of
/// the generator rather than of the modelled physiology.
///
/// Beats are then delivered in packets, because that is the shape a BLE Heart
/// Rate Measurement notification arrives in: several RR intervals under one
/// arrival timestamp. See [CardiacPacket].
class SyntheticCardiacSource {
  /// [seed] makes a run reproducible, which is what lets the tests assert on
  /// the distribution rather than on a single sample.
  SyntheticCardiacSource({
    int? seed,
    this.restingBpm = 58.0,
    this.minBpm = 48.0,
    this.maxBpm = 132.0,
  }) : _rng = Random(seed) {
    _targetBpm = restingBpm + 4.0;
    _instantBpm = _targetBpm;
    _episodeRemainingMs = _restEpisodeDurationMs();
  }

  final Random _rng;

  /// The person's resting rate. Episode targets are expressed relative to it,
  /// so changing this shifts the whole trace rather than only its floor.
  final double restingBpm;

  /// Hard envelope. The OU process is already mean-reverting, so these are a
  /// backstop against a long tail rather than the mechanism keeping the trace
  /// sane — but they are the guarantee that no consumer ever sees a 0 or a 200.
  final double minBpm;
  final double maxBpm;

  // ── Rate state ────────────────────────────────────────────────────────

  /// Where the OU process is being pulled. Moved by the episode machine.
  double _targetBpm = 62.0;

  /// The current rate. This is what a beat's interval is computed from.
  double _instantBpm = 62.0;

  /// Phase of the respiratory oscillator, in radians. Advanced by real elapsed
  /// time so the breathing rhythm is continuous across packets rather than
  /// restarting each one.
  double _breathPhase = 0.0;

  /// Time until the current activity episode ends.
  int _episodeRemainingMs = 0;
  _Episode _episode = _Episode.rest;

  /// Fractional beat accumulator: how much of the next RR interval has already
  /// elapsed. Carrying this across calls is what keeps beat timing honest when
  /// [advance] is called on a cadence that does not divide evenly into an RR.
  double _beatDebtMs = 0.0;

  /// Beats produced but not yet handed out in a packet.
  final List<double> _pendingRr = <double>[];

  /// Wall-clock stamp of the most recent beat, so a packet's anchor is the
  /// arrival time of its last interval — the BLE convention.
  int _lastBeatTsMs = 0;

  /// A short trailing window of intervals, for the derived bpm a real monitor
  /// reports (an average over several beats, not the reciprocal of the last
  /// one).
  final List<double> _recentRr = <double>[];

  /// Beats emitted since construction. Exposed so a UI can show that the
  /// source is producing rather than merely running.
  int get beatCount => _beatCount;
  int _beatCount = 0;

  /// The current activity episode, as a label a UI can show. Worth surfacing:
  /// it explains a rate that just climbed 30 bpm, which otherwise looks like
  /// the generator misbehaving.
  String get activityLabel => switch (_episode) {
    _Episode.rest => 'rest',
    _Episode.light => 'light activity',
    _Episode.moderate => 'moderate activity',
    _Episode.recovery => 'recovery',
  };

  /// The rate a monitor would currently display, averaged over recent beats.
  ///
  /// Null until enough beats exist to average — deliberately not a
  /// placeholder, since a fabricated first reading is the exact failure this
  /// whole file is careful about elsewhere.
  double? get displayBpm {
    if (_recentRr.isEmpty) return null;
    final meanRr = _recentRr.reduce((a, b) => a + b) / _recentRr.length;
    return 60000.0 / meanRr;
  }

  /// RMSSD over the trailing beats, in ms — the same statistic the engine's
  /// HRV features are built on.
  ///
  /// Surfaced so the UI can show that the *variability* is plausible too, not
  /// only the rate. A healthy adult at rest sits roughly in the 20–70 ms band
  /// and drops sharply under exertion; a flat or absurd number here means the
  /// generator is producing beats that no HRV feature can read.
  double? get rmssdMs {
    if (_recentRr.length < 3) return null;
    var sumSq = 0.0;
    for (var i = 1; i < _recentRr.length; i++) {
      final d = _recentRr[i] - _recentRr[i - 1];
      sumSq += d * d;
    }
    return sqrt(sumSq / (_recentRr.length - 1));
  }

  /// Advance the model by [elapsedMs] of wall clock ending at [nowMs], and
  /// return whichever complete packets that produced.
  ///
  /// Usually zero or one packet. More than one only when the caller was
  /// starved long enough to owe several — which is the case worth getting
  /// right, because collapsing a backlog of beats onto one timestamp is
  /// exactly what `push_rr_batch` exists to prevent.
  List<CardiacPacket> advance(int nowMs, int elapsedMs) {
    if (elapsedMs <= 0) return const <CardiacPacket>[];
    if (_lastBeatTsMs == 0) _lastBeatTsMs = nowMs - elapsedMs;

    _advanceEpisode(elapsedMs);
    _advanceRate(elapsedMs);

    // Breathing advances on wall time, independent of beat timing.
    _breathPhase += 2 * pi * _breathHz * (elapsedMs / 1000.0);
    if (_breathPhase > 2 * pi) _breathPhase -= 2 * pi;

    _generateBeats(nowMs, elapsedMs);
    return _drainPackets(nowMs);
  }

  // ── Episode machine ───────────────────────────────────────────────────
  //
  // Deliberately coarse. The point is that the target moves on a scale of
  // minutes so the trace has shape; modelling any finer would be inventing
  // detail the simulation cannot justify.

  void _advanceEpisode(int elapsedMs) {
    _episodeRemainingMs -= elapsedMs;
    if (_episodeRemainingMs > 0) return;

    switch (_episode) {
      case _Episode.rest:
        // Most rest periods stay restful; occasionally one escalates. Weighted
        // so a demo session spends most of its time near resting rate, which
        // is where a phone-in-pocket day actually is.
        if (_rng.nextDouble() < 0.55) {
          _episode = _Episode.light;
          _targetBpm = restingBpm + 18 + _rng.nextDouble() * 10;
          _episodeRemainingMs = 45_000 + _rng.nextInt(75_000);
        } else {
          _targetBpm = restingBpm + 2 + _rng.nextDouble() * 8;
          _episodeRemainingMs = _restEpisodeDurationMs();
        }
      case _Episode.light:
        if (_rng.nextDouble() < 0.4) {
          _episode = _Episode.moderate;
          _targetBpm = restingBpm + 42 + _rng.nextDouble() * 14;
          _episodeRemainingMs = 40_000 + _rng.nextInt(60_000);
        } else {
          _episode = _Episode.recovery;
          _targetBpm = restingBpm + 8;
          _episodeRemainingMs = 50_000 + _rng.nextInt(40_000);
        }
      case _Episode.moderate:
        _episode = _Episode.recovery;
        // Recovery undershoots slightly toward resting rather than snapping
        // back: post-exertion HR decays, it does not step.
        _targetBpm = restingBpm + 6;
        _episodeRemainingMs = 70_000 + _rng.nextInt(60_000);
      case _Episode.recovery:
        _episode = _Episode.rest;
        _targetBpm = restingBpm + 3 + _rng.nextDouble() * 6;
        _episodeRemainingMs = _restEpisodeDurationMs();
    }
  }

  int _restEpisodeDurationMs() => 90_000 + _rng.nextInt(120_000);

  /// Ornstein–Uhlenbeck step toward [_targetBpm].
  ///
  /// `theta` is the reversion strength per second and `sigma` the diffusion.
  /// Both are scaled by `dt` so the trajectory is the same whether the caller
  /// ticks at 1 Hz or 4 Hz — a generator whose output depends on its own call
  /// cadence would make the UI's numbers an artifact of the timer interval.
  void _advanceRate(int elapsedMs) {
    const theta = 0.08;
    const sigma = 1.4;
    final dt = elapsedMs / 1000.0;
    final drift = theta * (_targetBpm - _instantBpm) * dt;
    final diffusion = sigma * sqrt(dt) * _gaussian();
    _instantBpm = (_instantBpm + drift + diffusion).clamp(minBpm, maxBpm);
  }

  // ── Beat generation ───────────────────────────────────────────────────

  /// Breathing rate in Hz — ~13 breaths/min, inside the normal adult band.
  static const double _breathHz = 0.22;

  void _generateBeats(int nowMs, int elapsedMs) {
    var remaining = elapsedMs.toDouble() + _beatDebtMs;

    // Bounded so a pathological gap (a long background stretch, a debugger
    // pause) cannot mint thousands of beats and blow past the ingest gate. A
    // real monitor would have missed those beats too, and the runtime records
    // the dropout honestly.
    var guard = 0;
    while (remaining > 0 && guard++ < 512) {
      final rr = _nextRrMs();
      if (remaining < rr) break;
      remaining -= rr;
      _lastBeatTsMs = min(nowMs, _lastBeatTsMs + rr.round());
      _pendingRr.add(rr);
      _recentRr.add(rr);
      // ~30 beats: long enough for a stable RMSSD, short enough to track the
      // episode the person is actually in.
      if (_recentRr.length > 30) _recentRr.removeAt(0);
      _beatCount++;
    }
    _beatDebtMs = remaining;
  }

  /// One RR interval in ms, from the current rate plus respiratory modulation
  /// plus beat-level noise.
  double _nextRrMs() {
    final baseRr = 60000.0 / _instantBpm;

    // RSA amplitude as a fraction of the interval, tapering to near zero as
    // rate climbs. At rest this is the dominant HRV term; at 120 bpm it is
    // almost gone, which is what makes the simulated RMSSD collapse under
    // load the way a real one does.
    final exertion = ((_instantBpm - restingBpm) / 55.0).clamp(0.0, 1.0);
    final rsaFraction = 0.055 * (1.0 - exertion) + 0.004;
    final rsa = baseRr * rsaFraction * sin(_breathPhase);

    // Small non-respiratory beat-to-beat noise. Kept well below the RSA term
    // so HRV remains structured rather than white.
    final jitter = _gaussian() * 6.0;

    // Clamped to the interval range implied by the bpm envelope, so no single
    // beat can land outside it even on a long noise tail.
    return (baseRr + rsa + jitter).clamp(60000.0 / maxBpm, 60000.0 / minBpm);
  }

  /// Group pending beats into notification-shaped packets.
  ///
  /// A BLE HRM notifies about once a second and carries however many beats
  /// fell in that second, which at resting rate is one or two. Emitting one
  /// packet per beat would misrepresent the arrival pattern the SDK's batch
  /// path is designed around.
  List<CardiacPacket> _drainPackets(int nowMs) {
    if (_pendingRr.isEmpty) return const <CardiacPacket>[];
    final packet = CardiacPacket(
      // The anchor is the arrival time of the notification, i.e. the last beat
      // in it. `push_rr_batch` reconstructs the earlier beats' timestamps by
      // walking backwards from here — which is the whole reason to send a
      // batch rather than a loop of single pushes sharing one arrival stamp.
      anchorTsMs: _lastBeatTsMs == 0 ? nowMs : _lastBeatTsMs,
      // Oldest first, matching `order: 0`.
      rrMs: List<double>.unmodifiable(_pendingRr),
      bpm: displayBpm ?? 60000.0 / _instantBpm,
      rmssdMs: rmssdMs,
      activityLabel: activityLabel,
    );
    _pendingRr.clear();
    return <CardiacPacket>[packet];
  }

  /// Box–Muller, standard normal.
  double _gaussian() {
    // nextDouble() can return exactly 0.0, and log(0) is -inf.
    final u1 = 1.0 - _rng.nextDouble();
    final u2 = _rng.nextDouble();
    return sqrt(-2.0 * log(u1)) * cos(2 * pi * u2);
  }
}

enum _Episode { rest, light, moderate, recovery }

/// One sensor notification's worth of beats.
///
/// Shaped after a BLE Heart Rate Measurement: several RR intervals sharing a
/// single arrival timestamp, plus the rate the monitor reports.
class CardiacPacket {
  const CardiacPacket({
    required this.anchorTsMs,
    required this.rrMs,
    required this.bpm,
    required this.activityLabel,
    this.rmssdMs,
  });

  /// Arrival time of the notification — the timestamp of its **last** beat.
  final int anchorTsMs;

  /// Intervals in ms, oldest first (`order: 0`).
  final List<double> rrMs;

  /// Rate averaged over recent beats, as a monitor would display it.
  final double bpm;

  /// RMSSD over the trailing window, or null before enough beats exist.
  final double? rmssdMs;

  /// Which activity episode produced this packet.
  final String activityLabel;
}
