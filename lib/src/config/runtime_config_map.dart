import 'api_endpoints.dart';
import 'synheart_config.dart';

/// Builds the JSON config handed to `synheart_core_new`.
///
/// Pure and side-effect free, so it can be unit-tested without a native
/// runtime, and single-sourced so the facade and secondary instances cannot
/// drift apart.
///
/// Both gates below are load-bearing:
///
/// - `ingest.*` requires a non-empty `org_id`. Enabling it without one makes
///   the runtime reject the entire configuration, which surfaces as a null
///   handle rather than a targeted error — so ingest is enabled only when a
///   [CloudConfig] supplies an org id, leaving local-only hosts working.
/// - `device_auth.enabled` requires a [DeviceAuthConfig]. Enabling it without
///   one makes crypto-callback registration fail.
/// The platform origin this config will use, or empty when none was supplied.
///
/// `SyncConfig.baseUrl` wins; otherwise the `SYNHEART_BASE_URL` dart-define via
/// [ApiEndpoints]. Both empty means the host named no environment and the
/// runtime will fall back to its own default.
String _resolveApiBaseUrl(SynheartConfig config) =>
    config.sync.baseUrl.isNotEmpty
    ? config.sync.baseUrl
    : ApiEndpoints.resolvedAuthBaseUrl;

/// Whether an explicit platform origin was configured.
///
/// Worth checking before enabling anything cloud-bound: without one the runtime
/// silently uses its own default, so a build intended for a non-default
/// environment would talk to the wrong host with no error to explain it.
bool apiBaseUrlConfigured(SynheartConfig config) =>
    _resolveApiBaseUrl(config).isNotEmpty;

Map<String, dynamic> buildRuntimeConfigMap(
  SynheartConfig config, {
  String? dataDir,
}) {
  final orgId = config.cloudConfig?.orgId ?? '';

  /// Cloud ingest is only legal with a non-empty org id.
  final cloudReady = orgId.isNotEmpty;

  final deviceAuthEnabled = config.deviceAuthConfig != null;

  return <String, dynamic>{
    'app_id': config.appId,
    'org_id': orgId,
    'subject_id': config.subjectId,
    // The runtime derives the device identity's subject from client_id, and
    // rejects the config when device_auth is enabled without one.
    'client_id': config.subjectId,
    // API gateway origin for consent / ingest / platform calls.
    //
    // Omitted rather than sent empty when no origin was configured. The SDK no
    // longer carries a built-in host, so there is nothing to resolve to when
    // `SyncConfig.baseUrl` and `SYNHEART_BASE_URL` are both unset, and sending
    // `""` would assert an origin the host never chose.
    //
    // With the key absent the runtime applies its own default. That is fine for
    // a local-only build, which makes no network calls at all — but it means a
    // CLOUD build that forgets to set an origin inherits the runtime's default
    // rather than failing. Set `SYNHEART_BASE_URL` explicitly for anything that
    // talks to a non-default environment; see `apiBaseUrlConfigured` below.
    if (_resolveApiBaseUrl(config).isNotEmpty)
      'api_base_url': _resolveApiBaseUrl(config),
    'mode': config.mode.name,
    'device_id': config.deviceId,
    'app_version': config.appVersion,
    'platform': config.platform,
    if (dataDir != null) 'data_dir': dataDir,
    'storage': {'enabled': config.storage.enabled},
    'ingest': {'enabled': cloudReady, 'hsi': cloudReady, 'lab': cloudReady},
    'device_auth': {
      'enabled': deviceAuthEnabled,
      'auth_base_url': config.deviceAuthConfig?.authBaseUrl ?? '',
      'package_name': config.deviceAuthConfig?.packageName ?? '',
      'allow_unattested_dev_registration':
          config.deviceAuthConfig?.allowUnattestedDevRegistration ?? false,
    },
    'sync': {'enabled': config.sync.enabled, 'base_url': config.sync.baseUrl},
    'privacy': {'allow_research': config.privacy.allowResearch},
    if (config.windowMs != null && config.windowMs! > 0)
      'window_ms': config.windowMs,
    if (config.extraHeads.isNotEmpty)
      'extra_heads': config.extraHeads.map((h) => h.wire).toList(),
    // Host declarations are spread rather than nested: the runtime reads
    // `sensing` / `device_class` / `mask_profile` / `cfi_structural_components`
    // as top-level keys. An absent key means *undeclared*, which is a distinct
    // state from a declared default — so nothing is emitted for a null field.
    ...config.hostDeclarations.toJson(),
  };
}
