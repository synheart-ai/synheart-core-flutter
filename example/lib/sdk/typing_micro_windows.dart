import 'dart:math';

import 'package:synheart_core/synheart_core.dart' show TypingSessionData;

/// Aggregates keystrokes into the 10-second micro-window summaries the engine's
/// `Typing` variant expects (mobile host guide §5.3).
///
/// ## Why a host has to do this at all
///
/// `TypingSessionData` is the richest input the engine takes, and there is no
/// call that accepts a raw keystroke into it. Desktop aggregates key events
/// into 10 s micro-windows and emits one `Typing` event per window stamped at
/// `window_start_ms`; this mirrors that shape so the two platforms produce
/// comparable features. Pushing a single keystroke as a `Typing` event instead
/// would land a session whose every field is null — an observation with no
/// evidence behind it, which is worse for the feature group than sending
/// nothing.
///
/// ## Absent stays absent
///
/// Only fields this host can actually measure from a Flutter text field are
/// populated. Everything else is left null, and that is a deliberate report
/// rather than an omission: the engine withholds a null and renormalises it
/// out of the feature set, whereas `0.0` is a *measured zero* that moves the
/// score. Reporting an unobservable `hold_time_mean` as `0.0` would fabricate
/// evidence that the person released every key instantly.
///
/// What is genuinely unavailable here, and why:
///
/// * `number_of_delete` — a soft keyboard reports a backspace and a forward
///   delete identically through `TextEditingValue`. Collapsing both into
///   `number_of_backspace` keeps `typing.correction_rate` correct (it reads
///   the sum) without asserting a split this host cannot see.
/// * `hold_time_mean`, `latency_variability` — need key-down/key-up pairs. A
///   text field reports committed value changes, not physical key events.
/// * `number_of_cut` / `paste` / `copy`, `shortcut_count` — no clipboard or
///   modifier visibility from inside a text field.
///
/// A host with a real keyboard extension or IME sees all of those and should
/// fill them in; a host reading a text field should not pretend to.
class TypingMicroWindowAggregator {
  TypingMicroWindowAggregator({this.windowMs = 10_000});

  /// Micro-window length. 10 s matches desktop; changing it makes this host's
  /// rate features incomparable with desktop's.
  final int windowMs;

  /// Start of the window currently accumulating, aligned to [windowMs] so
  /// windows tile the timeline rather than starting wherever the first
  /// keystroke landed.
  int? _windowStartMs;

  final List<int> _tapTimestamps = <int>[];
  int _backspaces = 0;
  int _charactersAdded = 0;

  /// Length of the previous text value, so a change can be classified as an
  /// insertion or a deletion.
  int _previousLength = 0;

  /// Whether anything is currently buffered. Useful for a UI that wants to
  /// show a window filling up.
  bool get hasPendingKeystrokes => _tapTimestamps.isNotEmpty;

  int get pendingTapCount => _tapTimestamps.length;

  /// Reset to a clean state, dropping whatever is buffered.
  ///
  /// Call when the text field is cleared or the session restarts. The buffer
  /// is dropped rather than flushed on purpose: a partial window flushed
  /// against a new session's clock would attribute one session's keystrokes to
  /// another.
  void reset() {
    _windowStartMs = null;
    _tapTimestamps.clear();
    _backspaces = 0;
    _charactersAdded = 0;
    _previousLength = 0;
  }

  /// Seed the length baseline without recording keystrokes.
  ///
  /// Needed when the field is pre-populated or programmatically set: without
  /// it the first real edit is measured against a length of 0 and a paste of
  /// 40 characters reads as 40 taps.
  void syncLength(int length) => _previousLength = length;

  /// The text length this aggregator last saw.
  ///
  /// Exposed so a caller can classify the *next* change as an insertion or a
  /// deletion before handing it over — which is what the context channel needs
  /// (`ContextEventInput.textChange`) and what this aggregator otherwise keeps
  /// to itself. Reading it after [onTextChanged] gives the post-change length,
  /// so read it first.
  int get currentLength => _previousLength;

  /// Record a text change. Returns a completed [TypingSessionData] with its
  /// window start when this change closed a window, otherwise null.
  ///
  /// [nowMs] is epoch ms, on the same clock as every `push_*` call.
  ({int windowStartMs, TypingSessionData session})? onTextChanged(
    String text,
    int nowMs,
  ) {
    final delta = text.length - _previousLength;
    _previousLength = text.length;

    // A change of zero length (autocorrect swapping one word for another of
    // the same length, say) is still an edit, but it is not a countable tap
    // and guessing which it was would corrupt the correction rate. Skipped.
    if (delta == 0) return null;

    final completed = _closeWindowIfElapsed(nowMs);

    _windowStartMs ??= nowMs - (nowMs % windowMs);
    _tapTimestamps.add(nowMs);
    if (delta < 0) {
      // One backspace per removed character. A held-down backspace deleting a
      // run arrives as several changes, each counted once.
      _backspaces += -delta;
    } else {
      _charactersAdded += delta;
    }

    return completed;
  }

  /// Close the current window if [nowMs] has passed its end.
  ///
  /// Exposed separately so the host can call it from its own tick loop: a
  /// person who stops typing mid-window would otherwise leave that window
  /// buffered until their next keystroke, and it would then be stamped and
  /// emitted long after the interaction it describes. §6.4's rule — drain
  /// before the tick that closes the window the events belong to — applies to
  /// this buffer as much as to a platform one.
  ({int windowStartMs, TypingSessionData session})? flushIfElapsed(int nowMs) =>
      _closeWindowIfElapsed(nowMs);

  /// Force the buffered window out regardless of elapsed time.
  ///
  /// For session end and backgrounding, where the alternative is losing the
  /// partial window entirely.
  ({int windowStartMs, TypingSessionData session})? flushNow() {
    final start = _windowStartMs;
    if (start == null || _tapTimestamps.isEmpty) return null;
    final session = _buildSession();
    _startFreshWindow(null);
    return (windowStartMs: start, session: session);
  }

  ({int windowStartMs, TypingSessionData session})? _closeWindowIfElapsed(
    int nowMs,
  ) {
    final start = _windowStartMs;
    if (start == null) return null;
    if (nowMs < start + windowMs) return null;
    if (_tapTimestamps.isEmpty) {
      // An empty elapsed window carries no evidence, so it is dropped rather
      // than emitted as an all-zero session. Silence and "measured zero
      // typing" are different claims.
      _startFreshWindow(nowMs);
      return null;
    }
    final session = _buildSession();
    _startFreshWindow(nowMs);
    return (windowStartMs: start, session: session);
  }

  void _startFreshWindow(int? nowMs) {
    _windowStartMs = nowMs == null ? null : nowMs - (nowMs % windowMs);
    _tapTimestamps.clear();
    _backspaces = 0;
    _charactersAdded = 0;
  }

  TypingSessionData _buildSession() {
    final taps = _tapTimestamps.length;

    // Measured first-tap → last-tap span, NOT the window length. A window
    // holding two taps 1.2 s apart has durationSec 1.2; reporting 10.0 would
    // make every derived rate wrong by the ratio of the two.
    final spanMs = _tapTimestamps.last - _tapTimestamps.first;
    final durationSec = spanMs / 1000.0;

    final intervals = <double>[];
    for (var i = 1; i < _tapTimestamps.length; i++) {
      intervals.add((_tapTimestamps[i] - _tapTimestamps[i - 1]).toDouble());
    }

    double? meanIti;
    double? cv;
    if (intervals.isNotEmpty) {
      final mean = intervals.reduce((a, b) => a + b) / intervals.length;
      meanIti = mean;
      if (intervals.length > 1 && mean > 0) {
        final variance =
            intervals
                .map((x) => (x - mean) * (x - mean))
                .reduce((a, b) => a + b) /
            (intervals.length - 1);
        cv = sqrt(variance) / mean;
      }
    }

    // Gaps longer than 500 ms, per the field's definition.
    final pauseCount = intervals.where((i) => i > 500).length;

    return TypingSessionData(
      typingTapCount: taps,
      // A single-tap window has no measurable span; 0.0 there would be a
      // measured zero duration, which is not what happened.
      durationSec: spanMs > 0 ? durationSec : null,
      // Characters per minute over the measured span. Needs a real span —
      // dividing by a zero duration is the other half of the same problem.
      typingSpeedCpm: spanMs > 0
          ? _charactersAdded / (durationSec / 60.0)
          : null,
      meanInterTapIntervalMs: meanIti,
      pauseCount: intervals.isEmpty ? null : pauseCount,
      typingCadenceVariability: cv,
      // Stability as the complement of variability, clamped. Sent alongside
      // the CV because the engine reads both, and derived from the same
      // measurement rather than invented independently.
      typingCadenceStability: cv == null ? null : (1.0 - cv).clamp(0.0, 1.0),
      // The correction-rate input. Focus and CFI both read it, and without it
      // the friction index has nothing — so this is the one count worth
      // reporting even when it is genuinely zero: a window with taps and no
      // backspaces is a *measured* zero correction rate, which is real
      // evidence of fluent typing.
      numberOfBackspace: _backspaces,
    );
  }
}
