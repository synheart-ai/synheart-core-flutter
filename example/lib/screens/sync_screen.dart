import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../sdk/synheart_controller.dart';
import '../sdk/sync_runner.dart';
import '../widgets/ui.dart';

/// Cross-device sync, end to end, for testing on two devices.
///
/// Device A: Create space → Generate code. Device B: paste the code → Join.
/// Device A's pairing card should flip from `waiting` to `joined` on its own,
/// within one poll, naming device B. That flip is the thing worth watching:
/// before pairing status existed the device showing the code could not tell.
///
/// Every gate is shown separately rather than as one "sync ready" flag,
/// because the useful question is never "is sync ready" but "which
/// prerequisite is missing for this operation".
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  final _joinToken = TextEditingController();
  final _recoverKey = TextEditingController();
  final _recoverSpace = TextEditingController();

  /// Re-renders the pairing countdown between polls.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && context.read<SynheartController>().sync.isPolling) {
        setState(() {});
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<SynheartController>().sync.refresh();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _joinToken.dispose();
    _recoverKey.dispose();
    _recoverSpace.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SynheartController>();
    final s = c.sync;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Re-read readiness and status',
            onPressed: s.busy == null ? s.refresh : null,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _Notice(
            'Sync is a paid-plan feature. The SDK does not check the plan: '
            'the host app does, before offering sync. This example has no '
            'account sign-in, so a server that enforces the plan refuses it. '
            'Today that refusal shows up as a retryable SERVER error.',
          ),
          if (!SynheartController.attestationConfigured)
            const _Notice(
              'Sync needs an attested device, and this build has no '
              'SYNHEART_AUTH_URL. Run with the credentials file (see SETUP.md), '
              'then grant Cloud upload on the Consent tab.',
            ),
          if (s.busy != null) ...[
            LinearProgressIndicator(semanticsLabel: 'Running ${s.busy}'),
            const SizedBox(height: 12),
          ],
          if (s.lastError != null) ErrorBanner(s.lastError!),
          if (s.lastResult != null && s.lastError == null)
            _Notice(s.lastResult!, good: true),
          _ReadinessCard(runner: s),
          _StatusCard(runner: s),
          _SpaceCard(
            runner: s,
            joinToken: _joinToken,
            recoverKey: _recoverKey,
            recoverSpace: _recoverSpace,
          ),
          _PairingCard(runner: s),
          _DevicesCard(runner: s),
        ],
      ),
    );
  }
}

class _ReadinessCard extends StatelessWidget {
  const _ReadinessCard({required this.runner});

  final SyncRunner runner;

  @override
  Widget build(BuildContext context) {
    final native = runner.readiness.values
        .map((r) => r.nativeState)
        .firstWhere((v) => v != null, orElse: () => null);
    return SectionCard(
      title: 'Readiness',
      subtitle:
          'Per operation. Create, join and recover need no space; pairing and '
          'sync also need the space key unlocked.',
      trailing: StatusPill(native ?? 'no runtime state'),
      children: [
        for (final op in SyncRunner.operations)
          _ReadinessRow(
            op.name,
            ready: runner.readiness[op]?.isReady,
            code: runner.readiness[op]?.code.name,
          ),
      ],
    );
  }
}

class _ReadinessRow extends StatelessWidget {
  const _ReadinessRow(this.label, {required this.ready, required this.code});

  final String label;

  /// Null until the first read.
  final bool? ready;
  final String? code;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          StatusPill(
            switch (ready) {
              null => 'unread',
              true => 'ready',
              false => code ?? 'blocked',
            },
            tone: switch (ready) {
              null => PillTone.neutral,
              true => PillTone.good,
              false => PillTone.warn,
            },
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.runner});

  final SyncRunner runner;

  /// Null is "the runtime did not report it", not zero or false — an older
  /// runtime never sends these fields, and painting them as 0 would claim a
  /// measurement nobody made.
  static String _v(Object? v) => v == null ? 'not reported' : '$v';

  @override
  Widget build(BuildContext context) {
    final st = runner.status;
    final last = st?.lastSuccessMs;
    return SectionCard(
      title: 'Local status',
      subtitle:
          'Synheart.syncStatus(): local, no network. No device count here — '
          'the roster lives on the server (Devices below).',
      trailing: StatusPill(
        st == null ? 'unknown' : (st.enabled ? 'engine on' : 'engine off'),
        tone: st == null
            ? PillTone.neutral
            : (st.enabled ? PillTone.good : PillTone.warn),
      ),
      children: [
        KeyValueRow('space', st?.syncSpaceId ?? '—', selectable: true),
        KeyValueRow('pending uploads', _v(st?.pendingCount)),
        KeyValueRow(
          'last success',
          last == null
              ? 'none since engine start'
              : DateTime.fromMillisecondsSinceEpoch(last).toLocal().toString(),
        ),
        KeyValueRow('space key ready', _v(st?.srkReady)),
        KeyValueRow('account owned', _v(st?.accountOwned)),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: runner.busy == null ? runner.syncNow : null,
            icon: const Icon(Icons.sync),
            label: const Text('Sync now'),
          ),
        ),
      ],
    );
  }
}

class _SpaceCard extends StatelessWidget {
  const _SpaceCard({
    required this.runner,
    required this.joinToken,
    required this.recoverKey,
    required this.recoverSpace,
  });

  final SyncRunner runner;
  final TextEditingController joinToken;
  final TextEditingController recoverKey;
  final TextEditingController recoverSpace;

  @override
  Widget build(BuildContext context) {
    final idle = runner.busy == null;
    return SectionCard(
      title: 'Space',
      subtitle: 'First device creates; the others join with a code.',
      children: [
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: idle
                ? () => runner.createSpace(deviceName: 'Core example')
                : null,
            icon: const Icon(Icons.add),
            label: const Text('Create space (device A)'),
          ),
        ),
        if (runner.recoveryKey != null) ...[
          const SizedBox(height: 8),
          KeyValueRow(
            'space id',
            runner.createdSpaceId ?? '—',
            selectable: true,
          ),
          KeyValueRow('recovery key', runner.recoveryKey!, selectable: true),
          Text(
            'Shown once. A real app makes the person save it: it is the only '
            'way back in if every device is lost.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const Divider(height: 28),
        TextField(
          controller: joinToken,
          decoration: InputDecoration(
            labelText: 'Pairing code from device A',
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: IconButton(
              icon: const Icon(Icons.content_paste),
              tooltip: 'Paste',
              onPressed: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data?.text != null) joinToken.text = data!.text!.trim();
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: idle
                ? () {
                    if (joinToken.text.trim().isEmpty) return;
                    runner.joinSpace(
                      joinToken.text,
                      deviceName: 'Core example',
                    );
                  }
                : null,
            icon: const Icon(Icons.login),
            label: const Text('Join space (device B)'),
          ),
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Recover, leave, delete'),
          children: [
            TextField(
              controller: recoverKey,
              decoration: const InputDecoration(
                labelText: 'Recovery key',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: recoverSpace,
              decoration: const InputDecoration(
                labelText: 'Space id',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: idle
                    ? () => runner.recoverSpace(
                        recoverKey.text,
                        recoverSpace.text,
                      )
                    : null,
                child: const Text('Recover space'),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: idle ? runner.leaveSpace : null,
                  child: const Text('Leave'),
                ),
                OutlinedButton(
                  onPressed: idle ? runner.clearLocalSpace : null,
                  child: const Text('Clear local'),
                ),
                OutlinedButton(
                  onPressed: idle ? () => _confirmDelete(context) : null,
                  child: const Text('Delete space'),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Delete the space?'),
        content: const Text(
          'Removes the space on the server for every device in it. This '
          'cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await runner.deleteSpace();
  }
}

class _PairingCard extends StatelessWidget {
  const _PairingCard({required this.runner});

  final SyncRunner runner;

  @override
  Widget build(BuildContext context) {
    final token = runner.pairingToken;
    final st = runner.pairingStatus;
    final expiry = st?.expiresAt?.toLocal() ?? runner.pairingLocalExpiry;
    final left = expiry?.difference(DateTime.now());

    // `unknown` is a state the server sent that this SDK does not know. It is
    // still pending — never shown as success or failure.
    final (String pill, PillTone tone) = switch (st?.state.name) {
      _ when token == null => ('no code', PillTone.neutral),
      null when !runner.pairingStatusAvailable => (
        'status unsupported',
        PillTone.warn,
      ),
      null => ('checking…', PillTone.neutral),
      'joined' => ('joined', PillTone.good),
      'expired' => ('expired', PillTone.bad),
      'waiting' => ('waiting', PillTone.neutral),
      final other => (other, PillTone.warn),
    };

    return SectionCard(
      title: 'Pairing (device A)',
      subtitle: runner.pairingStatusAvailable
          ? 'Polls Synheart.syncPairingStatus every '
                '${SyncRunner.pollInterval.inSeconds} s until joined or expired.'
          : 'This runtime has no synheart_core_sync_pairing_status, so the '
                'join cannot be observed here.',
      trailing: StatusPill(pill, tone: tone),
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: runner.busy == null ? runner.generatePairing : null,
            icon: const Icon(Icons.qr_code_2),
            label: Text(token == null ? 'Generate code' : 'New code'),
          ),
        ),
        if (token != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    token,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copy',
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: token)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          KeyValueRow(
            'expires',
            expiry == null
                ? 'not reported'
                : left == null || left.isNegative
                ? 'passed'
                : 'in ${left.inMinutes}m ${left.inSeconds % 60}s',
          ),
          KeyValueRow('space', st?.syncSpaceId ?? '—', selectable: true),
          KeyValueRow(
            'joined by',
            st?.joinedDevice == null
                ? '—'
                : '${st!.joinedDevice!.deviceName ?? '(no name)'} · '
                      '${st.joinedDevice!.deviceId}',
            selectable: true,
          ),
          if (st?.joinedAt != null)
            KeyValueRow('joined at', st!.joinedAt!.toLocal().toString()),
          KeyValueRow(
            'polls',
            '${runner.pairingPolls}'
                '${runner.pairingCheckedAt == null ? '' : ' · last ${TimeOfDay.fromDateTime(runner.pairingCheckedAt!).format(context)}'}',
          ),
          KeyValueRow(
            'polling',
            runner.isPolling
                ? 'on'
                : 'stopped — ${runner.pairingStopReason ?? 'by hand'}',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: runner.pairingStatusAvailable
                    ? runner.pollPairing
                    : null,
                child: const Text('Check now'),
              ),
              if (runner.isPolling)
                OutlinedButton(
                  onPressed: runner.stopPolling,
                  child: const Text('Stop polling'),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _DevicesCard extends StatelessWidget {
  const _DevicesCard({required this.runner});

  final SyncRunner runner;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Devices',
      subtitle: 'Synheart.syncListDevices(): the server roster.',
      trailing: StatusPill(
        runner.devicesLoaded ? '${runner.devices.length}' : 'not loaded',
      ),
      children: [
        for (final d in runner.devices)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text('${d['device_name'] ?? '(no name)'}'),
            subtitle: SelectableText(
              d.entries
                  .where((e) => e.key != 'device_name')
                  .map((e) => '${e.key}: ${e.value}')
                  .join('\n'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
            trailing: d['device_id'] is String
                ? IconButton(
                    icon: const Icon(Icons.link_off),
                    tooltip: 'Revoke',
                    onPressed: runner.busy == null
                        ? () => runner.revokeDevice(d['device_id'] as String)
                        : null,
                  )
                : null,
          ),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: runner.busy == null ? runner.listDevices : null,
            icon: const Icon(Icons.devices),
            label: const Text('List devices'),
          ),
        ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.text, {this.good = false});

  final String text;
  final bool good;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: good ? const Color(0xFFD7F0DC) : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SelectableText(text, style: const TextStyle(fontSize: 13)),
    );
  }
}
