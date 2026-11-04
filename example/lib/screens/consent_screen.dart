import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../sdk/synheart_controller.dart';
import '../widgets/ui.dart';

/// Step 2 — consent, via the runtime's editable-form flow.
///
/// This is the canonical path:
///
///   consentGetEditableFormTyped()  → what the user edits
///   consentSubmitFormTyped(form:)  → persist offline-first, then reconcile
///   consentEffectiveStateTyped()   → what the runtime actually enforces
///
/// The distinction between the form and the effective state matters. The
/// runtime intersects the submitted choice with the cloud default profile, so
/// asking for a channel does not guarantee getting it. Always gate features on
/// the effective state, never on the form.
///
/// The older Dart-side helpers — `requestConsent`, `getAvailableConsentProfiles`,
/// `setConsentUIProvider`, `getConsentInfo` — are legacy and are not used here.
class ConsentScreen extends StatelessWidget {
  const ConsentScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SynheartController>();
    final form = c.consentForm;
    final state = c.consentState;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Consent'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Re-read from runtime',
            onPressed: c.refreshConsent,
          ),
        ],
      ),
      body: form == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No consent form available.\n\n'
                  'The runtime returns one only after initialize() succeeds.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (c.consentError != null) ErrorBanner(c.consentError!),

                SectionCard(
                  title: 'Collection',
                  subtitle:
                      'Category-level, matching what the runtime exposes. '
                      'Channel-level truth is kept inside the runtime.',
                  children: [
                    ConsentToggle(
                      title: 'Biosignals',
                      description:
                          'Heart rate and HRV. Without it the physiological '
                          'axes are withheld; HSI still arrives with any '
                          'other collection consent.',
                      value: form.biosignals,
                      enforced: state?.biosignals,
                      onChanged: (v) => c.editConsent(biosignals: v),
                    ),
                    ConsentToggle(
                      title: 'Phone context',
                      description: 'Motion, screen state, and app context.',
                      value: form.phoneContext,
                      enforced: state?.phoneContext,
                      onChanged: (v) => c.editConsent(phoneContext: v),
                    ),
                    ConsentToggle(
                      title: 'Behavior',
                      description:
                          'Taps, typing rhythm, gestures, and notifications.',
                      value: form.behavior,
                      enforced: state?.behavior,
                      onChanged: (v) => c.editConsent(behavior: v),
                    ),
                  ],
                ),

                SectionCard(
                  title: 'Sharing',
                  subtitle:
                      'This example ships without cloud credentials, so these '
                      'persist locally but no upload path exists. Wiring a '
                      'CloudConfig activates them — see SETUP.md.',
                  children: [
                    ConsentToggle(
                      title: 'Cloud upload',
                      description:
                          'Send derived HSI to the platform. Turning this on '
                          'makes submit attempt a cloud profile fetch and token '
                          'issue, which fails offline without losing the local '
                          'save.',
                      value: form.allowCloud,
                      enforced: state?.cloudUpload,
                      onChanged: (v) => c.editConsent(allowCloud: v),
                    ),
                    ConsentToggle(
                      title: 'Vendor sync',
                      description: 'Pull from Whoop, Garmin, Oura, or Fitbit.',
                      value: form.allowVendorSync,
                      enforced: state?.vendorSync,
                      onChanged: (v) => c.editConsent(allowVendorSync: v),
                    ),
                    ConsentToggle(
                      title: 'Research',
                      description:
                          'Permit export to research studies. Independent of '
                          'cloud upload.',
                      value: form.allowResearch,
                      enforced: state?.research,
                      onChanged: (v) => c.editConsent(allowResearch: v),
                    ),
                  ],
                ),

                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: c.isSubmittingConsent ? null : c.submitConsent,
                    icon: c.isSubmittingConsent
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check),
                    label: Text(
                      c.isSubmittingConsent ? 'Submitting…' : 'Submit consent',
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                SectionCard(
                  title: 'Effective state',
                  subtitle:
                      'What the runtime enforces right now. Gate your features '
                      'on this, not on the toggles above.',
                  children: state == null
                      ? [const Text('Not available.')]
                      : [
                          KeyValueRow('biosignals', '${state.biosignals}'),
                          KeyValueRow('phone_context', '${state.phoneContext}'),
                          KeyValueRow('behavior', '${state.behavior}'),
                          KeyValueRow('cloud_upload', '${state.cloudUpload}'),
                          KeyValueRow('vendor_sync', '${state.vendorSync}'),
                          KeyValueRow('research', '${state.research}'),
                          const Divider(height: 20),
                          KeyValueRow('profile_id', form.profileId),
                          KeyValueRow('tier', form.consentTier.name),
                          KeyValueRow('version', state.version),
                        ],
                ),
              ],
            ),
    );
  }
}
