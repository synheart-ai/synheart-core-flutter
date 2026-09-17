import 'package:flutter_test/flutter_test.dart';

import 'package:example/sdk/typing_micro_windows.dart';

/// The assertions that matter here are about what is *absent*. A field this
/// host cannot observe must come out null, because the engine withholds a null
/// and renormalises it out whereas `0.0` is a measured zero that moves the
/// score — so a test that only checked the populated fields would pass while
/// the summary quietly fabricated evidence.
void main() {
  const t0 = 1_700_000_000_000;

  group('window boundaries', () {
    test('nothing is emitted before the window elapses', () {
      final agg = TypingMicroWindowAggregator();
      expect(agg.onTextChanged('a', t0), isNull);
      expect(agg.onTextChanged('ab', t0 + 200), isNull);
      expect(agg.onTextChanged('abc', t0 + 9_000), isNull);
      expect(agg.hasPendingKeystrokes, isTrue);
    });

    test('the window closes on the first keystroke past its end', () {
      final agg = TypingMicroWindowAggregator();
      // t0 is a multiple of 1000 but the aggregator aligns to windowMs, so
      // take the alignment from the aggregator rather than assuming.
      agg.onTextChanged('a', t0);
      final completed = agg.onTextChanged('ab', t0 + 11_000);
      expect(completed, isNotNull);
      expect(completed!.session.typingTapCount, 1);
      // The keystroke that closed the window belongs to the NEXT one.
      expect(agg.pendingTapCount, 1);
    });

    test('a stalled typist is drained by the tick loop, not left buffered', () {
      // The reason flushIfElapsed exists: someone who stops typing mid-window
      // would otherwise leave it buffered until their next keystroke, and it
      // would be emitted long after the interaction it describes.
      final agg = TypingMicroWindowAggregator();
      agg.onTextChanged('a', t0);
      agg.onTextChanged('ab', t0 + 500);

      expect(agg.flushIfElapsed(t0 + 5_000), isNull);
      final completed = agg.flushIfElapsed(t0 + 30_000);
      expect(completed, isNotNull);
      expect(completed!.session.typingTapCount, 2);
      expect(agg.hasPendingKeystrokes, isFalse);
    });

    test('an elapsed but empty window is dropped, not emitted as zeros', () {
      // Silence and "measured zero typing" are different claims. An all-zero
      // session would land in the typing feature group as an observation.
      final agg = TypingMicroWindowAggregator();
      agg.onTextChanged('a', t0);
      agg.flushIfElapsed(t0 + 15_000); // closes the window with the one tap
      expect(agg.flushIfElapsed(t0 + 40_000), isNull);
    });

    test('the stamp is the window start, not the emission time', () {
      final agg = TypingMicroWindowAggregator(windowMs: 10_000);
      agg.onTextChanged('a', t0 + 1_500);
      final completed = agg.onTextChanged('ab', t0 + 25_000);
      expect(completed, isNotNull);
      // Aligned to the window grid containing the first keystroke — matching
      // desktop. Stamping at emission would place a summary of past typing in
      // a later window.
      expect(completed!.windowStartMs, (t0 + 1_500) - ((t0 + 1_500) % 10_000));
      expect(completed.windowStartMs, lessThan(t0 + 25_000));
    });

    test('flushNow emits a partial window for session end', () {
      final agg = TypingMicroWindowAggregator();
      agg.onTextChanged('a', t0);
      agg.onTextChanged('ab', t0 + 300);
      final completed = agg.flushNow();
      expect(completed, isNotNull);
      expect(completed!.session.typingTapCount, 2);
      expect(agg.flushNow(), isNull, reason: 'nothing left to flush');
    });
  });

  group('measured fields', () {
    ({int windowStartMs, dynamic session}) typeThen(
      TypingMicroWindowAggregator agg,
      List<(String, int)> edits,
    ) {
      for (final (text, offset) in edits) {
        agg.onTextChanged(text, t0 + offset);
      }
      final completed = agg.flushNow();
      expect(completed, isNotNull);
      return (
        windowStartMs: completed!.windowStartMs,
        session: completed.session,
      );
    }

    test('duration is the measured span, not the window length', () {
      final agg = TypingMicroWindowAggregator();
      final r = typeThen(agg, [('a', 0), ('ab', 600), ('abc', 1_200)]);
      // 1.2 s, not 10.0. Reporting the window length would make every rate
      // wrong by the ratio of the two.
      expect(r.session.durationSec, closeTo(1.2, 0.001));
    });

    test('pauses count gaps over 500 ms only', () {
      final agg = TypingMicroWindowAggregator();
      final r = typeThen(agg, [
        ('a', 0),
        ('ab', 200), // 200 ms — not a pause
        ('abc', 1_000), // 800 ms — a pause
        ('abcd', 1_100), // 100 ms — not a pause
        ('abcde', 2_000), // 900 ms — a pause
      ]);
      expect(r.session.pauseCount, 2);
    });

    test('backspaces are counted per removed character', () {
      final agg = TypingMicroWindowAggregator();
      final r = typeThen(agg, [
        ('hello', 0),
        ('hell', 200),
        ('hel', 400),
        ('help', 600),
      ]);
      // Two deletions, and the count is what produces
      // typing.correction_rate — the input Focus and CFI both read.
      expect(r.session.numberOfBackspace, 2);
      expect(r.session.typingTapCount, 4);
    });

    test('a held backspace deleting a run counts every character', () {
      final agg = TypingMicroWindowAggregator();
      final r = typeThen(agg, [('abcdefgh', 0), ('abc', 300)]);
      expect(r.session.numberOfBackspace, 5);
    });

    test('cadence stability is the complement of variability', () {
      final agg = TypingMicroWindowAggregator();
      final r = typeThen(agg, [
        ('a', 0),
        ('ab', 200),
        ('abc', 400),
        ('abcd', 900),
      ]);
      final cv = r.session.typingCadenceVariability as double;
      expect(cv, greaterThan(0));
      expect(
        r.session.typingCadenceStability,
        closeTo((1.0 - cv).clamp(0.0, 1.0), 1e-9),
      );
    });

    test('speed counts inserted characters over the measured span', () {
      final agg = TypingMicroWindowAggregator();
      // 6 characters inserted across 3 s → 120 cpm.
      final r = typeThen(agg, [('ab', 0), ('abcd', 1_500), ('abcdef', 3_000)]);
      expect(r.session.typingSpeedCpm, closeTo(120.0, 1.0));
    });
  });

  group('unobservable fields stay null', () {
    test('a single-tap window reports no span-derived field', () {
      final agg = TypingMicroWindowAggregator();
      agg.onTextChanged('a', t0);
      final session = agg.flushNow()!.session;

      expect(session.typingTapCount, 1);
      // 0.0 here would be a measured zero duration, which is not what
      // happened — there was one tap and therefore no measurable span.
      expect(session.durationSec, isNull);
      expect(session.typingSpeedCpm, isNull);
      expect(session.meanInterTapIntervalMs, isNull);
      expect(session.pauseCount, isNull);
      expect(session.typingCadenceVariability, isNull);
    });

    test('fields a text field cannot see are absent from the wire', () {
      final agg = TypingMicroWindowAggregator();
      agg.onTextChanged('a', t0);
      agg.onTextChanged('ab', t0 + 300);
      final json = agg.flushNow()!.session.toJson();

      // Not present at all, rather than present-and-zero. The engine
      // renormalises an absent field out; a zero asserts a measurement.
      for (final key in const [
        'hold_time_mean',
        'latency_variability',
        'number_of_cut',
        'number_of_paste',
        'number_of_copy',
        'shortcut_count',
        'shortcut_rate',
        'typing_efficiency',
        'keyboard_scroll_rate',
        'typing_gap_count',
        'typing_gap_ratio',
        'typing_burstiness',
        'deep_typing',
        // A soft keyboard reports backspace and forward-delete identically,
        // so the split is not asserted — both land in number_of_backspace.
        'number_of_delete',
      ]) {
        expect(json.containsKey(key), isFalse, reason: key);
      }

      expect(json['typing_tap_count'], 2);
      expect(json['number_of_backspace'], 0);
    });

    test('a zero-length change is not counted as a tap', () {
      // Autocorrect swapping one word for another of the same length is an
      // edit but not a countable keystroke, and guessing which it was would
      // corrupt the correction rate.
      final agg = TypingMicroWindowAggregator();
      agg.onTextChanged('cat', t0);
      expect(agg.onTextChanged('dog', t0 + 200), isNull);
      expect(agg.pendingTapCount, 1);
    });
  });

  group('length baseline', () {
    test('syncLength stops a prefilled field reading as a burst of taps', () {
      final agg = TypingMicroWindowAggregator();
      agg.syncLength(40);
      agg.onTextChanged('${'x' * 40}y', t0);
      expect(agg.flushNow()!.session.typingTapCount, 1);
    });

    test('reset clears the baseline with everything else', () {
      final agg = TypingMicroWindowAggregator();
      agg.onTextChanged('hello', t0);
      agg.reset();
      expect(agg.hasPendingKeystrokes, isFalse);
      // Length baseline back to 0, so 'hi' is a 2-character insertion.
      agg.onTextChanged('hi', t0 + 1_000);
      expect(agg.flushNow()!.session.numberOfBackspace, 0);
    });
  });
}
