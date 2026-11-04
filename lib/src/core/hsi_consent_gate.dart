import '../modules/interfaces/consent_provider.dart';

/// Whether a completed HSI window may reach the host's streams.
///
/// A window is delivered when the person has granted any collection category
/// — biosignals, behavior, phone context — or research. Each axis in the frame
/// already comes only from inputs the SDK was allowed to collect, and the
/// runtime reports the rest as withheld, so a behavior-only app gets its
/// digital axes and an empty biosignal side. Gating on biosignals alone threw
/// away every window for an app with no wearable, the one case the digital
/// axes exist for.
///
/// [effective] is the runtime's `consentEffectiveState()` and [local] the
/// Dart-side snapshot; either granting is enough. The Dart snapshot has been
/// seen returning stale defaults after a native consent write, and the
/// runtime's view can be absent before it loads, so neither alone is trusted
/// to refuse.
bool hsiDeliveryAllowed({
  required Map<String, dynamic>? effective,
  required ConsentSnapshot? local,
}) {
  bool granted(String key) => effective?[key] == true;
  if (granted('biosignals') ||
      granted('behavior') ||
      granted('phone_context') ||
      granted('research')) {
    return true;
  }
  if (local == null) return false;
  return local.biosignals ||
      local.behavior ||
      local.phoneContext ||
      local.research;
}
