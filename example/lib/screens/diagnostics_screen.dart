import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../sdk/synheart_controller.dart';
import '../widgets/ui.dart';

/// Step 4 — native runtime health.
///
/// The field worth understanding is `missingSymbols`. Optional native symbols
/// are resolved lazily and a miss degrades gracefully: the feature behind it
/// returns null, -1, or an empty list rather than throwing. That is good for
/// robustness and terrible for debugging, because a runtime one release behind
/// silently disables whole feature areas.
///
/// An empty list is the healthy state. Anything in it means the vendored
/// runtime predates this SDK release — run `synheart install runtime`.
class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SynheartController>();
    final diag = c.diagnostics;

    final available = diag['isAvailable'] == true;
    final version = diag['version'] as String?;
    final frameCount = diag['frameCount'] as int? ?? 0;
    final missing =
        (diag['missingSymbols'] as List?)?.cast<String>() ?? const <String>[];
    final probed = diag['probedSymbols'] as int? ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Runtime'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Re-read diagnostics',
            onPressed: c.refreshConsent,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            title: 'Native runtime',
            subtitle: available
                ? 'The FFI bridge loaded and the runtime is answering.'
                : 'Not loaded. Run `synheart install runtime`, then rebuild.',
            trailing: StatusPill(
              available ? 'loaded' : 'missing',
              tone: available ? PillTone.good : PillTone.bad,
            ),
            children: [
              KeyValueRow('runtime version', version ?? '—', selectable: true),
              KeyValueRow('sdk version', c.sdkVersion),
              KeyValueRow('frames this session', '$frameCount'),
              KeyValueRow('buffered windows', '${c.sessionWindows.length}'),
              KeyValueRow('lab ABI', c.isLabAvailable ? 'available' : 'absent'),
            ],
          ),

          SectionCard(
            title: 'Native symbols',
            subtitle: missing.isEmpty
                ? 'All $probed optional symbols resolved against this runtime.'
                : '${missing.length} of $probed optional symbols are absent, so '
                      'the features behind them are disabled. Run '
                      '`synheart install runtime` to update the runtime.',
            trailing: StatusPill(
              missing.isEmpty ? 'all $probed ok' : '${missing.length} missing',
              tone: missing.isEmpty ? PillTone.good : PillTone.warn,
            ),
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  'Covers the $probed symbols bound through the guarded path. '
                  'Some ABIs — the lab session calls in particular — are bound '
                  'eagerly and are not counted here: an absent one throws on '
                  'first access rather than degrading. Check "lab ABI" above '
                  'before calling any lab API.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (missing.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SelectableText(
                    missing.join('\n'),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
            ],
          ),

          _NativeErrorCard(controller: c),

          SectionCard(
            title: 'Local data',
            subtitle:
                'Everything this example stores lives on the device: the '
                'runtime SQLite store, the SRM snapshot, and consent records.',
            children: [
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _confirmWipe(context, c),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Wipe local data'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmWipe(BuildContext context, SynheartController c) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Wipe local data?'),
        content: const Text(
          'Deletes the runtime SQLite store, the SRM snapshot, and cached '
          'consent records for this subject. Baselines restart from cold. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Wipe'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await c.wipeLocalData();
    messenger.showSnackBar(const SnackBar(content: Text('Local data wiped.')));
  }
}

/// The runtime's structured error for the most recent failed call.
///
/// Every field a host needs to act is here without reading a log: `code` to
/// branch on, `owner` and `recovery` to decide who does what, `recovery_call`
/// for the exact native fix, and `error_id` to quote in a bug report.
class _NativeErrorCard extends StatelessWidget {
  const _NativeErrorCard({required this.controller});

  final SynheartController controller;

  @override
  Widget build(BuildContext context) {
    final e = controller.lastNativeError;
    return SectionCard(
      title: 'Last native error',
      subtitle: e == null
          ? 'No runtime call has failed yet (or the runtime predates ABI 2.0).'
          : e.message,
      trailing: StatusPill(
        e?.code ?? 'none',
        tone: e == null ? PillTone.good : PillTone.warn,
      ),
      children: [
        if (e != null) ...[
          KeyValueRow('code', e.code, selectable: true),
          KeyValueRow('owner', e.owner ?? '—'),
          KeyValueRow('recovery', e.recovery ?? '—'),
          KeyValueRow('recovery call', e.recoveryCall ?? '—', selectable: true),
          if (e.reason != null) KeyValueRow('reason', e.reason!),
          if (e.argument != null) KeyValueRow('argument', e.argument!),
          KeyValueRow('op', e.op ?? '—', selectable: true),
          KeyValueRow('error id', e.errorId ?? '—', selectable: true),
          KeyValueRow('retryable', '${e.retryable}'),
          if (e.hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: SelectableText(
                e.hint!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: controller.probeNativeError,
            icon: const Icon(Icons.bug_report_outlined),
            label: const Text('Probe: stop a session that is not running'),
          ),
        ),
      ],
    );
  }
}
