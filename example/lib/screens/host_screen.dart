import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:synheart_core/synheart_core.dart' show AccelPlacement;

import '../sdk/synheart_controller.dart';
import '../widgets/ui.dart';

/// Step 5 — the host-driven half of the integration.
///
/// Everything on the other tabs is configuration: build a config, grant
/// consent, start a session. This tab is what a mobile host has to keep
/// *doing* once that is done, and it is the half that was missing. The section
/// headings map onto the mobile host implementation guide, because the point of
/// the screen is to make each item observable rather than described.
///
/// The first card is the one to read before the others. Every call below is
/// looked up optionally against the vendored runtime, which is a pinned
/// artifact that lags this SDK — so on any given device some of this file is
/// running and some of it is a logged no-op, and guessing which is not
/// possible from the outside.
class HostScreen extends StatelessWidget {
  const HostScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SynheartController>();
    final host = c.host;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mobile host'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: StatusPill(
                host.isRunning ? 'driving' : 'idle',
                tone: host.isRunning ? PillTone.good : PillTone.neutral,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (host.lastError != null) ErrorBanner(host.lastError!),

          const _AbiSupportCard(),
          const _TickLoopCard(),
          const _RestCard(),
          const _PlacementCard(),
          const _TypingProbeCard(),
          const _ContextCard(),
          const _SnapshotsCard(),
          const _DailyLoopCard(),
          const _NotWiredCard(),
        ],
      ),
    );
  }
}

/// §1 — what the loaded runtime can actually do.
class _AbiSupportCard extends StatelessWidget {
  const _AbiSupportCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.watch<SynheartController>();
    final host = c.host;
    final support = host.abiSupport;
    final missing = host.unsupportedCalls;

    return SectionCard(
      title: 'Runtime ABI',
      subtitle:
          'Which mobile-host calls the vendored native runtime exports. A '
          'binding existing in the Dart SDK says nothing about whether the '
          'call does anything on this device.',
      trailing: StatusPill(
        support.isEmpty
            ? 'no runtime'
            : missing.isEmpty
            ? 'complete'
            : '${missing.length} missing',
        tone: support.isEmpty
            ? PillTone.bad
            : missing.isEmpty
            ? PillTone.good
            : PillTone.warn,
      ),
      children: [
        if (support.isEmpty)
          Text(
            'The native runtime is not loaded, so none of this tab does '
            'anything. Initialize on the Setup tab first.',
            style: theme.textTheme.bodySmall,
          )
        else ...[
          for (final entry in support.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Icon(
                    entry.value ? Icons.check_circle : Icons.cancel_outlined,
                    size: 16,
                    color: entry.value
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      entry.key,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 20),
          // Which cargo features the runtime was built with. Without
          // `app-context`, push_context_event is an inert stub that returns 1
          // — indistinguishable from a rejected payload unless this is read.
          Text('runtime build', style: theme.textTheme.labelMedium),
          const SizedBox(height: 6),
          if (c.buildInfo == null)
            Text('build_info unavailable', style: theme.textTheme.bodySmall)
          else
            for (final entry in c.buildInfo!.entries)
              KeyValueRow(entry.key, '${entry.value}'),
          if (missing.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'Each missing call degrades to a no-op, or to a null return for '
              'the ones that report status. That is deliberate — a hard '
              'symbol lookup would fail library load outright for a host that '
              'simply has not re-vendored — but it means the feature behind '
              'it is silently off. Run `synheart install runtime` to update '
              'the pinned artifact.\n\n'
              'push_context_event needs more than a recent artifact: without '
              'the `app-context` cargo feature it compiles to an inert stub '
              'that always returns 1.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ],
      ],
    );
  }
}

/// §6.1 / §6.4 — the tick loop.
class _TickLoopCard extends StatelessWidget {
  const _TickLoopCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.watch<SynheartController>();
    final host = c.host;
    final usingTickAll = host.abiSupport['tickAll'] == true;

    return SectionCard(
      title: 'Tick loop',
      subtitle:
          'The engine runs its own 1 Hz ticker from start_session — but with '
          'tick, not tick_all, so after any gap it drains one window and '
          'skips the rest. This loop calls tick_all so nothing is left behind.',
      trailing: StatusPill(
        host.isRunning ? '1 Hz' : 'stopped',
        tone: host.isRunning ? PillTone.good : PillTone.neutral,
      ),
      children: [
        KeyValueRow('ticks', '${host.ticks}'),
        // Undercounts by design: windows the engine's own loop drains never
        // pass through this counter. A low number is not evidence that
        // emission is broken — watch the Live HSI window count instead.
        KeyValueRow('windows drained here', '${host.windowsDrained}'),
        KeyValueRow('symbol', usingTickAll ? 'tick_all' : 'tick (fallback)'),
        KeyValueRow(
          'keep-alive',
          host.foregroundServiceUnsupported
              ? 'n/a — iOS uses a connected BLE peripheral'
              : host.foregroundServiceRunning
              ? 'dataSync foreground service running'
              : host.isRunning
              ? 'NOT running — collection stops on background'
              : 'stopped with the session',
        ),
        const SizedBox(height: 8),
        Text(
          host.foregroundServiceUnsupported
              ? 'On iOS what keeps the runtime alive is bluetooth-central '
                    'plus a CONNECTED peripheral — a strap holding the process '
                    'up. This example holds none, which is exactly why it '
                    'declares episodic sensing rather than pretending '
                    'otherwise.'
              : 'Without the foreground service the tick loop dies the moment '
                    'Android stops scheduling this process: the session emits '
                    'nothing from then on, silently, while the UI still says '
                    '"collecting". Bound to the session here rather than '
                    'started from an IME, so it covers the whole thing and '
                    'not just typing.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          usingTickAll
              ? 'tick_all drains every completed window, oldest first. After '
                    'a background gap tick would poll one window and silently '
                    'skip the rest, which is why the loop prefers this and '
                    'only falls back when the symbol is absent.'
              : 'This runtime has no tick_all, so the loop is falling back to '
                    'tick — one window per call. A gap longer than one window '
                    'loses the windows it spanned, and nothing counts them.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Ordering, per §6.4: the loop drains its own retroactive buffers '
          '(the typing aggregator below) BEFORE each tick. Reverse that and '
          'the window closes without the events belonging to it, and the '
          'window cursor drops them with no counter to show it — the one '
          'limit the per-modality ingest gates did not fix.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// §6.5 — rest declaration.
class _RestCard extends StatelessWidget {
  const _RestCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.watch<SynheartController>();
    final host = c.host;
    final supported = host.abiSupport['declareRestWindow'] == true;

    return SectionCard(
      title: 'Rest windows',
      subtitle:
          'Without a rest declaration Focus is never zeroed on a break and '
          'Capacity never takes the recovery path — break windows score as '
          'engaged. There is no context module on mobile to derive it.',
      trailing: StatusPill(
        '${host.restDeclarations} declared',
        tone: host.restDeclarations > 0 ? PillTone.good : PillTone.neutral,
      ),
      children: [
        KeyValueRow(
          'condition',
          host.rest.lastDeclineReason ?? 'satisfied / not evaluated',
        ),
        KeyValueRow(
          'engine accel_rms',
          host.latestAccelRms?.toStringAsFixed(3) ?? 'no reading',
        ),
        const SizedBox(height: 8),
        Text(
          'Composite: screen off ≥ 2 min AND no interaction AND low motion, '
          'with a wall-clock sleep window as an override. Screen off alone is '
          'wrong in both directions — someone watching a video is screen-on '
          'and resting, someone in a meeting is screen-off and working.\n\n'
          'A null motion reading is not treated as low motion: with no '
          'accelerometer forwarding the clause is unverifiable, and declaring '
          'on two of three conditions would call a walk with the phone '
          'pocketed a rest window.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: supported && c.isSessionRunning
                ? host.declareRestNow
                : null,
            icon: const Icon(Icons.bedtime_outlined),
            label: const Text('Declare rest for this window'),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          supported
              ? 'Manual, because the composite needs two minutes of '
                    'screen-off and nobody demos that. The call is one-shot '
                    'by design: a sticky flag a host forgot to clear would '
                    'pin Focus at exactly 0.0, stop Capacity depleting and '
                    'freeze Mental Fatigue’s engaged clock for the rest of '
                    'the session, silently. Call it once per rest WINDOW, not '
                    'once when a break begins.'
              : 'declare_rest_window is absent from this runtime, so every '
                    'break window on this device scores as engaged.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// §4.3 — accelerometer placement.
class _PlacementCard extends StatelessWidget {
  const _PlacementCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final host = context.watch<SynheartController>().host;
    final supported = host.abiSupport['setAccelPlacement'] == true;
    final placement = host.placement;

    return SectionCard(
      title: 'Accelerometer placement',
      subtitle:
          'The four kinematic heads are requested in the config, but they '
          'withhold until a body-worn mount is declared. Unknown — the '
          'default — withholds all of them.',
      trailing: StatusPill(
        placement.isValidatedEnvelope ? 'in envelope' : 'out of envelope',
        tone: placement.isValidatedEnvelope ? PillTone.good : PillTone.warn,
      ),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in AccelPlacement.values)
              ChoiceChip(
                label: Text(p.name),
                selected: placement == p,
                onSelected: supported ? (_) => host.setAccelPlacement(p) : null,
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Only pocket and waist are inside the validated envelope. Wrist and '
          'chest are body-worn but outside it; desk is not body-worn at all, '
          'and its suppression exists precisely so desk vibration does not '
          'read as physiology-relevant motion.\n\n'
          'The part you cannot design around: there is no hand-held '
          'placement, and during exactly the interaction the digital axes '
          'measure — typing, scrolling — the phone is in the hand. So '
          'placement is genuinely dynamic and the kinematic and behavioural '
          'axes are largely disjoint in time. A fixed compile-time pocket is '
          'wrong the moment the person picks the device up.\n\n'
          'Until a labelled 50 Hz dataset validates pocket geometry on '
          'phones, treat mobile kinematics as a validation target rather than '
          'a shipped capability.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        if (!supported)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'set_accel_placement is absent from this runtime — the '
              'kinematic heads stay dark whatever is selected above.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}

/// §5.3 — the typing micro-window probe.
class _TypingProbeCard extends StatefulWidget {
  const _TypingProbeCard();

  @override
  State<_TypingProbeCard> createState() => _TypingProbeCardState();
}

class _TypingProbeCardState extends State<_TypingProbeCard> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.watch<SynheartController>();
    final host = c.host;
    final supported = host.abiSupport['pushBehaviorEvent'] == true;

    return SectionCard(
      title: 'Typing micro-windows',
      subtitle:
          'The richest input the engine takes, and mobile produced none of '
          'it. Desktop aggregates key events into 10 s micro-windows and '
          'emits one Typing event per window at ts = window_start_ms; this '
          'mirrors that shape.',
      trailing: StatusPill(
        '${host.typingWindowsPushed} pushed',
        tone: host.typingWindowsPushed > 0 ? PillTone.good : PillTone.neutral,
      ),
      children: [
        TextField(
          controller: _controller,
          minLines: 2,
          maxLines: 4,
          enabled: supported && c.isSessionRunning,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: 'Type here for ten seconds',
            helperText: supported
                ? 'Backspaces count — they produce typing.correction_rate'
                : 'push_behavior_event is absent from this runtime',
          ),
          onChanged: host.onTypingChanged,
        ),
        const SizedBox(height: 12),
        KeyValueRow('buffered taps', '${host.typing.pendingTapCount}'),
        KeyValueRow('windows pushed', '${host.typingWindowsPushed}'),
        KeyValueRow('taps in those windows', '${host.typingTapsPushed}'),
        const SizedBox(height: 8),
        Text(
          'Only fields a Flutter text field can actually measure are '
          'populated — tap count, backspaces, the measured first→last span, '
          'speed, mean inter-tap interval, pauses over 500 ms, cadence '
          'stability and variability. Everything else is left null, and that '
          'is a report rather than an omission: the engine withholds a null '
          'and renormalises it out, whereas 0.0 is a MEASURED zero that moves '
          'the score. Reporting an unobservable hold_time_mean as 0.0 would '
          'assert the person released every key instantly.\n\n'
          'number_of_delete stays null because a soft keyboard reports '
          'backspace and forward-delete identically; both land in '
          'number_of_backspace, which keeps correction_rate correct without '
          'asserting a split this host cannot see.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Not double-counted: the raw keystrokes behind these summaries take '
          'the legacy int-coded path inside the SDK, and a failed rich push '
          'is deliberately NOT retried through it. Sending both a windowed '
          'summary and its raw events roughly doubles every rate feature.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () {
              _controller.clear();
              host.resetTypingProbe();
            },
            icon: const Icon(Icons.backspace_outlined, size: 18),
            label: const Text('Clear probe'),
          ),
        ),
      ],
    );
  }
}

/// §5.5 — foreground app context.
class _ContextCard extends StatelessWidget {
  const _ContextCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.watch<SynheartController>();
    final host = c.host;
    final supported = host.abiSupport['pushContextEvent'] == true;
    final richSupported = host.abiSupport['pushBehaviorEvent'] == true;

    return SectionCard(
      title: 'App context',
      subtitle:
          'Two separate channels. App identity types the window; context '
          'events supply the friction evidence CFI reads.',
      trailing: StatusPill(
        supported ? 'bound' : 'absent',
        tone: supported ? PillTone.neutral : PillTone.warn,
      ),
      children: [
        KeyValueRow('app_foreground pushes', '${host.appForegroundPushes}'),
        KeyValueRow('context accepted', '${host.contextEventsAccepted}'),
        KeyValueRow('context rejected', '${host.contextEventsRejected}'),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: richSupported && c.isSessionRunning
                ? host.declareSelfForeground
                : null,
            icon: const Icon(Icons.apps_outlined),
            label: const Text('Declare this app as foreground'),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'APP IDENTITY rides the behaviour channel as app_foreground, and it '
          'is what gives the engine an app to type each window against. With '
          'none, current_app stays None, None resolves to the UNKNOWN '
          'category, and UNKNOWN\'s interpretation-mask row is all zeros — so '
          'CFI / Cognitive Load, Stress B, Mental Fatigue B and Focus '
          'deviation terms all read 0 for someone who was working the whole '
          'time. The SDK now runs a 30 s heartbeat of this for the session; '
          'the button is here to make it observable.\n\n'
          'CONTEXT EVENTS are a different channel with a different consumer: '
          'privacy-preserving keyboard / pointer / shortcut events feeding the '
          'context window, which is the only source of context.deviation.* '
          'and so the only source of CFI. There is NO app-category variant on '
          'this channel — the {ts_ms, app_id, category} payload this example '
          'used to send never parsed. The SDK derives these from REAL native '
          'scroll and swipe gestures; the keyboard half comes from the typing '
          'probe, one event per real keystroke. There is no button to push a '
          'hand-made one: cardiac is the only thing this example simulates, '
          'and an invented Paste would be fabricated evidence. Type or scroll '
          'and watch "context accepted".\n\n'
          'Both are honest but limited here: this app reports ITSELF, true '
          'while the person is in it and wrong the moment they leave (which '
          'is why the SDK stops on background). A real Android host '
          'implements ForegroundAppSource over UsageStatsManager (permission '
          'PACKAGE_USAGE_STATS) and passes it as '
          'BehaviorConfig.foregroundAppSource; iOS has no API for this.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

/// §7 / §9.5 — the three snapshots and the comparability key.
class _SnapshotsCard extends StatelessWidget {
  const _SnapshotsCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.watch<SynheartController>();
    final host = c.host;
    final sizes = host.storedSnapshotSizes;

    return SectionCard(
      title: 'Persisted snapshots',
      subtitle:
          'Three, not one. The runtime’s own SQLite covers session state '
          'only; everything the engine accumulates about the person lives in '
          'snapshots the host exports and re-loads.',
      trailing: StatusPill(
        '${host.sessionStateSaves} state saves',
        tone: host.sessionStateSaves > 0 ? PillTone.good : PillTone.neutral,
      ),
      children: [
        for (final entry in sizes.entries)
          KeyValueRow(
            entry.key,
            entry.value == 0 ? 'not stored' : '${entry.value} bytes',
          ),
        const Divider(height: 24),
        KeyValueRow('config_id', host.configId ?? 'unavailable'),
        KeyValueRow('device_class key', c.hostDeviceClass),
        if (host.configIdChanged) ...[
          const SizedBox(height: 8),
          ErrorBanner(
            'config_id changed since the stored snapshots were written. Any '
            'score cached under the old key is not comparable to a new one — '
            'config_id moves whenever anything value-affecting changes, '
            'including the sensing and mask_profile declarations.',
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'session state carries Capacity, Mental Fatigue, Stress, Valence '
          'and the context engine, and is loaded at initialize() — before '
          'the first tick, because window 1 writes each head’s state slot and '
          'a later restore is overwritten by a cold window.\n\n'
          'SRM carries the personal baseline and is exported at session end. '
          'Without it the baselines report Warming forever across launches, '
          'however many sessions the person completes. It is keyed per '
          'device_class: a cross-class load is rejected with '
          'ERR_SRM_CONFIG_MISMATCH, which is the baseline partition working, '
          'and one shared file means a phone and a tablet take turns '
          'invalidating each other.\n\n'
          'longitudinal carries the wearable reference, the 7-night sleep '
          'ring and today’s partial daily accumulator, and is written after '
          'every recompute — without it a mid-day relaunch discards the '
          'morning’s cardiovascular load.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

/// §8 — the daily loop.
class _DailyLoopCard extends StatelessWidget {
  const _DailyLoopCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.watch<SynheartController>();
    final host = c.host;
    final supported = host.abiSupport['rollDay'] == true;

    return SectionCard(
      title: 'Daily loop',
      subtitle:
          'Recovery, Readiness, Strain and Sleep are DAILY scores with no '
          'live per-window head. Desktop implements none of this, so there is '
          'no reference to copy.',
      trailing: StatusPill(
        '${host.dailyPushes} dimensions',
        tone: host.dailyPushes > 0 ? PillTone.good : PillTone.neutral,
      ),
      children: [
        KeyValueRow('roll_day', supported ? 'bound' : 'absent'),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: c.isSessionRunning
                ? host.pushSimulatedDailyBaselines
                : null,
            icon: const Icon(Icons.calendar_today_outlined),
            label: const Text('Push a day of wearable baselines'),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'srm_push_wearable_daily is the ONLY baseline path for a phone with '
          'no live wearable session. It was bound and never called.\n\n'
          'The values here come from the simulator rather than HealthKit or '
          'Health Connect, because this example holds no health permission — '
          'a real host reads them from the platform store and sends '
          'fidelity: 1 for a provider summary. Note what is not sent: no '
          'dimension is padded to zero. A vendor reporting no deep-sleep '
          'figure means the value is absent, and a measured 0.0 there is a '
          'different claim to every head that reads it.\n\n'
          'roll_day runs at session start and at LOCAL midnight; skip it and '
          'the engine adopts a provisional UTC day, which is wrong for most '
          'of the world. The index must strictly advance, so the last one is '
          'persisted and checked rather than rolled blindly at each launch.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

/// What this example does not do, and why. Kept in the app rather than only in
/// a README because the honest list is short and a developer copying this file
/// needs it in front of them.
class _NotWiredCard extends StatelessWidget {
  const _NotWiredCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Still not wired',
      subtitle: 'Gaps this example does not close, and what each one needs.',
      children: [
        for (final item in const [
          (
            'subject_age_years / hr_max_bpm / hr_rest_bpm',
            'The engine’s PipelineConfig has these fields, but core-runtime '
                'never reads them out of the config JSON — so passing them '
                'from Dart changes nothing. Heart-rate-reserve features run '
                'on fallbacks and daily hr_load stays withheld until '
                'core-runtime plumbs them through.',
          ),
          (
            'UsageStatsManager → AppSwitch identity',
            'Android-native work in synheart-behavior-flutter, plus the '
                'PACKAGE_USAGE_STATS permission. Without it AppSwitch carries '
                'no app ids and Android has no context layer.',
          ),
          (
            'NotificationListenerService',
            'The collector is written in synheart-behavior-flutter and simply '
                'not registered. Declaring it is one manifest block — done in '
                'this example’s AndroidManifest, but the plugin release that '
                'carries the collector fix is not on pub.dev yet.',
          ),
          (
            'Scheduled daily job',
            'workmanager on Android, BGTaskScheduler on iOS. The midnight '
                'roll here is a Timer, so it only fires if the app is alive '
                'across midnight; otherwise the day rolls at the next '
                'session start.',
          ),
          (
            'Real GPS speed',
            'push_speed is bound and never called. It is the '
                'high-confidence input for locomotion_state, which therefore '
                'runs permanently on its low-confidence accel-only fallback. '
                'The only speed this example could supply is one the '
                'simulator invented, and cardiac is the only thing it is '
                'allowed to simulate — so a real host wires the platform’s '
                'location updates instead. A phone has GPS; this is the cheap '
                'win.',
          ),
          (
            'Foreground app context',
            'push_context_event is bound and never called. Without a '
                'UsageStatsManager binding this app cannot name the app '
                'actually in front — it could only report itself with a '
                'category it made up, and unlike a simulated heart rate, a '
                'fabricated context claim is indistinguishable from a real '
                'one downstream. On Android this means no context layer at '
                'all; iOS has no API for it.',
          ),
          (
            'PhoneModule’s collectors',
            'Not enabled here — buildConfig declares no phoneConfig. The four '
                'collectors are Random() generators for motion, screen state, '
                'app focus and notifications, which is why. They never '
                'reached the runtime either (no bridge reference), so they '
                'wrote to a cache with no reader. The module needs replacing '
                'with real platform collectors or deleting.',
          ),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.$1,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  item.$2,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
