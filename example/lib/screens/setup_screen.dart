import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../sdk/synheart_controller.dart';
import '../widgets/ui.dart';

/// Step 1 — build a config and initialize.
///
/// The two required fields are `appId` and `subjectId`. Everything else has a
/// working default. `SynheartConfig.validate()` runs before any native work, so
/// a bad config fails here with an actionable message rather than surfacing
/// later as an unexplained empty org_id or a mis-bound device.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _subjectController = TextEditingController();
  bool _seeded = false;

  @override
  void dispose() {
    _subjectController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SynheartController>();

    // Seed the field once the persisted subject id has loaded.
    if (!_seeded && c.subjectId != null) {
      _subjectController.text = c.subjectId!;
      _seeded = true;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Setup'),
        actions: [
          if (c.isInitialized)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: StatusPill('v${c.sdkVersion}', tone: PillTone.neutral),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (c.initError != null) ErrorBanner(c.initError!),

          SectionCard(
            title: c.isInitialized ? 'SDK initialized' : 'SDK not initialized',
            subtitle: c.isInitialized
                ? 'The native runtime is loaded. Grant consent next.'
                : 'Nothing is collected until you initialize and start a session.',
            trailing: StatusPill(
              c.isInitialized ? 'ready' : 'inactive',
              tone: c.isInitialized ? PillTone.good : PillTone.neutral,
            ),
            children: [
              SizedBox(
                width: double.infinity,
                child: c.isInitialized
                    ? OutlinedButton.icon(
                        onPressed: c.shutdown,
                        icon: const Icon(Icons.power_settings_new),
                        label: const Text('Dispose SDK'),
                      )
                    : FilledButton.icon(
                        onPressed: c.isInitializing ? null : c.initialize,
                        icon: c.isInitializing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.play_arrow),
                        label: Text(
                          c.isInitializing ? 'Initializing…' : 'Initialize SDK',
                        ),
                      ),
              ),
            ],
          ),

          SectionCard(
            title: 'Identity',
            subtitle:
                'subjectId must stay the same across restarts. The runtime '
                'scopes storage, baselines, and device identity to it — a value '
                'that changes per launch looks like a new person every time, so '
                'baselines never mature.',
            children: [
              TextField(
                controller: _subjectController,
                enabled: !c.isInitialized,
                decoration: const InputDecoration(
                  labelText: 'subjectId',
                  helperText: 'Your account id in a real app. Persisted here.',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: c.setSubjectId,
              ),
              const SizedBox(height: 8),
              if (!c.isInitialized)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => c.setSubjectId(_subjectController.text),
                    child: const Text('Save'),
                  ),
                ),
              KeyValueRow('appId', SynheartController.appId, selectable: true),
              KeyValueRow('deviceId', c.deviceId ?? '—', selectable: true),
            ],
          ),

          // §2 — the four declarations that change engine output. On this
          // screen rather than the Host tab because they are config, read
          // once at `synheart_core_new`: changing one after initialize()
          // does nothing until the SDK is torn down and rebuilt.
          SectionCard(
            title: 'Host declarations',
            subtitle:
                'Four declarations that change what the engine outputs. All '
                'opt-in rather than derived from platform, because each one '
                'changes the output of a host already in the field — the '
                'default, declaring nothing, reproduces pre-0.16.0 behaviour '
                'exactly.',
            trailing: StatusPill(
              c.host.declareHostProfile ? 'declared' : 'undeclared',
              tone: c.host.declareHostProfile
                  ? PillTone.good
                  : PillTone.neutral,
            ),
            children: [
              ConsentToggle(
                title: 'Declare host profile',
                description:
                    'Sends sensing, device_class, mask_profile and '
                    'cfi_structural_components: 4. '
                    'Declaring device_class folds into the SRM config_hash '
                    'and INVALIDATES every persisted baseline — the person '
                    're-warms 30 observations across 3 distinct days. Declare '
                    'it once at first launch and keep it stable; changing it '
                    'mid-life is a baseline reset, not a config tweak.',
                value: c.host.declareHostProfile,
                onChanged: c.isInitialized ? null : c.setDeclareHostProfile,
              ),
              ConsentToggle(
                title: 'Claim continuous sensing',
                description:
                    '"auto" resolves iOS to episodic, which withholds '
                    'Capacity and Mental Fatigue from every frame with reason '
                    'episodic_sensing. Continuous is a claim only the host can '
                    'make, and only truthfully — it needs a live BLE '
                    'peripheral holding the process alive. This example has '
                    'none, so this is a way to see the two heads come back, '
                    'not a way to earn them.',
                value: c.host.claimContinuousSensing,
                onChanged: c.isInitialized || !c.host.declareHostProfile
                    ? null
                    : c.setClaimContinuousSensing,
              ),
              const SizedBox(height: 8),
              Text(
                c.isInitialized
                    ? 'Locked while initialized — the config JSON is read '
                          'once at synheart_core_new. Shut down on this tab '
                          'to change them.'
                    : 'mask_profile: mobile admits the hesitation bit in the '
                          'Communication and WritingEditing context rows, '
                          'moving Focus and Cognitive Load. '
                          'cfi_structural_components: 4 LOWERS conf_CFI for '
                          'identical evidence by widening the coverage '
                          'denominator — that direction surprises people, and '
                          'it is correct.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
          ),

          SectionCard(
            title: 'Device attestation',
            subtitle: SynheartController.attestationConfigured
                ? 'Registration is triggered by CLOUD-UPLOAD CONSENT, not by '
                      'initialize(). Grant it on the Consent tab and watch the '
                      'status change here — the SDK runs the flow in the '
                      'background rather than blocking the consent screen.'
                : 'Not configured, so this build never attests. Pass '
                      '--dart-define=SYNHEART_AUTH_URL=... to enable it — an '
                      'org id is only needed for upload, not attestation. '
                      'See SETUP.md.',
            trailing: StatusPill(
              !SynheartController.attestationConfigured
                  ? 'off'
                  : c.attestationRegistered
                  ? 'registered'
                  : 'pending',
              tone: !SynheartController.attestationConfigured
                  ? PillTone.neutral
                  : c.attestationRegistered
                  ? PillTone.good
                  : PillTone.warn,
            ),
            children: [
              if (SynheartController.attestationConfigured) ...[
                KeyValueRow('auth url', SynheartController.authBaseUrl),
                KeyValueRow(
                  'upload',
                  SynheartController.uploadConfigured
                      ? 'enabled (org ${SynheartController.orgId})'
                      : 'off — no SYNHEART_ORG_ID',
                ),
                KeyValueRow('ABI available', '${c.attestationAvailable}'),
                KeyValueRow(
                  'status',
                  c.attestationStatus?['status']?.toString() ?? '—',
                ),
                KeyValueRow(
                  'device id',
                  c.attestationStatus?['device_id']?.toString() ?? '—',
                  selectable: true,
                ),
                // Shown separately from `status` on purpose. A device admitted
                // through development mode registers successfully and signs
                // every request with a real hardware key, but is recorded
                // `unattested` — it carries no provenance claim. Collapsing
                // that into "registered" is exactly the confusion worth
                // avoiding.
                KeyValueRow('attestation', c.attestationClaim),
                if (c.allowsUnattestedDevRegistration)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Debug build: allowUnattestedDevRegistration is ON, so a '
                      'device that cannot produce Play Integrity / App Attest '
                      'material still asks the server to admit it, carrying '
                      'format:"none" and an empty blob — nothing fake is sent.\n\n'
                      'The flag alone does nothing: development mode must also '
                      'be enabled for this app id server-side, and it must be a '
                      'development app id, never a production one. Release '
                      'builds disable this automatically.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: c.isInitialized ? c.registerDevice : null,
                      child: const Text('Register now'),
                    ),
                    OutlinedButton(
                      onPressed: c.isInitialized ? c.reattestDevice : null,
                      child: const Text('Re-attest'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Register now is idempotent — it no-ops when already '
                  'registered. Re-attest forces a fresh registration, for when '
                  'the server has lost or revoked the device record.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),

          SectionCard(
            title: 'Config being used',
            subtitle: SynheartController.attestationConfigured
                ? 'DeviceAuthConfig is set from dart-defines, so attestation '
                      'is active. Upload additionally needs SYNHEART_ORG_ID.'
                : 'Local-only: no CloudConfig and no DeviceAuthConfig, so '
                      'nothing leaves the device and no attestation is '
                      'attempted. See SETUP.md to enable cloud upload.',
            children: const [_ConfigListing()],
          ),
        ],
      ),
    );
  }
}

/// A literal listing of the config this example passes, so a developer can copy
/// it rather than reverse-engineer it from the controller.
class _ConfigListing extends StatelessWidget {
  const _ConfigListing();

  static const _code = '''
SynheartConfig(
  appId: 'ai.synheart.core.example',   // required
  subjectId: <persisted, stable>,      // required
  appVersion: '1.0.0',
  deviceId: <persisted>,
  mode: SynheartMode.personal,

  // Development only — production gates on a verified consent token.
  allowUnsignedCapabilities: true,

  // Declaring a module config activates that feature.
  wearConfig: WearConfig(),
  phoneConfig: PhoneConfig(),
  behaviorConfig: BehaviorConfig(),

  // Required for the runtime consent-form flow.
  consentConfig: ConsentConfig(
    deviceId: <persisted>,
    platform: 'flutter',
    userId: <subjectId>,
  ),
)''';

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const SelectableText(
        _code,
        style: TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.45),
      ),
    );
  }
}
