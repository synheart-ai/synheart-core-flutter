/// Synheart Core SDK — Flutter
///
/// The Synheart Core SDK is the unified integration point for collecting
/// HSI-compatible data, computing human state on-device via the Synheart
/// Runtime, and uploading derived state snapshots (HSI 1.3) with explicit
/// user consent.
///
/// Modules:
/// - Device Auth — hardware-backed ECDSA device identity
/// - Capabilities — server-signed feature gating
/// - Consent — user permission management
/// - Wear — biosignal collection
/// - Phone — device motion / context
/// - Behavior — user interaction patterns
/// - HSI Runtime — signal fusion and state computation
/// - Cloud Connector — device-signed HSI snapshot uploads
library synheart_core;

// Core SDK Entry Point (PRD-compliant Architecture)
export 'src/synheart.dart';

// Secondary runtime instances (e.g. a research instance alongside the personal
// `Synheart.shared`) — see `SynheartInstance`.
export 'src/synheart_instance.dart';

// SDK version constant (string literal kept in sync with pubspec.yaml)
export 'src/version.dart';

// Domain-tagged logger for consumer apps.
export 'src/core/logger.dart' show SynheartLogger;

// Configuration
export 'src/config/api_endpoints.dart';
// Host declarations that change engine output — sensing profile, device class,
// interpretation-mask profile, CFI coverage denominator, kinematic heads.
export 'src/config/host_declarations.dart';
export 'src/config/synheart_config.dart';
export 'src/config/synheart_feature.dart';
export 'src/config/synheart_mode.dart';
export 'src/config/synheart_errors.dart';

// Cross-device synchronization readiness.
export 'src/sync/sync_readiness.dart';

// Artifacts (Tier A)
//
// Note: the legacy 4-axis BaselineSnapshotArtifact (previously at
// `src/artifacts/baseline_snapshot.dart`) was never deployed. The
// replacement is the typed envelope below.
//
// The native runtime owns Tier-A artifact production; the SDK exposes only the
// header and session-summary types.
export 'src/artifacts/artifact_header.dart';
export 'src/artifacts/session_summary.dart';

// Baseline-snapshot typed envelope. Typed builders + per-kind
// extractors, no `Map<String, dynamic>` round-tripping. The
// host-facing read facade lives on `Synheart.baselineSnapshots`.
export 'src/baseline/baseline_kind.dart';
export 'src/baseline/baseline_payloads.dart';
export 'src/baseline/baseline_envelope.dart';
export 'src/baseline/baseline_snapshots.dart';

// Session model
export 'src/models/session_handle.dart';

// Customer-facing GDPR Article 17 (right-to-erasure) types.
export 'src/models/data_deletion.dart';

// Typed state and metrics
export 'src/models/hsi_state.dart';
export 'src/models/metric_event.dart';

// Rich behavior events (the typed payload path) + accelerometer placement.
export 'src/models/behavior_event_input.dart';
export 'src/models/context_event_input.dart';
export 'src/modules/behavior/foreground_app_reporter.dart'
    show ForegroundAppSource, SelfForegroundAppSource;
export 'src/models/accel_placement.dart';

// Personalization task tags .
export 'src/models/task_type.dart';
export 'src/models/focus_kind.dart';

// WorkoutEvent / WorkoutKind contract — re-exported from synheart_wear
// so consumers don't need a separate import for personalization-aware
// workout integration.
export 'package:synheart_wear/synheart_wear.dart'
    show WorkoutEvent, WorkoutKind, WorkoutAdapter;

// Wearable Events
export 'src/models/canonical_wearable_event.dart';

// Sleep Score — typed input/result and
// wearable reference view for the batch sleep scorer.
export 'src/models/sleep_score.dart';
export 'src/models/sleep_questionnaire.dart';

// Recovery Score — typed input/result for
// the daily three-stage recovery scorer.
export 'src/models/recovery_score.dart';

// Readiness Score — typed input/result for
// the daily readiness scorer (Recovery + load + fatigue + history).
export 'src/models/readiness_score.dart';

// Baselines facade — host-facing API for vendor-sleep ingestion,
// cached reference/score, and a live snapshot stream.
export 'src/modules/baselines/baselines.dart';
export 'src/modules/baselines/baselines_snapshot.dart';

// Cloud vendor providers — moved to synheart_wear (link flows belong with
// the source layer; Stream service in Core consumes handles from Wear).
// Re-exported here for backwards compatibility; new code should import from
// synheart_wear directly.
export 'package:synheart_wear/synheart_wear.dart'
    show WhoopProvider, GarminProvider;

// Data Models
export 'src/models/behavior.dart';
export 'src/models/context.dart';
export 'src/models/hsi_axes.dart';
export 'src/models/hsi_export.dart';
export 'src/models/behavior_session_results.dart';

// Module Base
export 'src/modules/base/synheart_module.dart';
export 'src/modules/base/module_manager.dart';

// Module Interfaces
export 'src/modules/interfaces/capability_provider.dart';
export 'src/modules/interfaces/auth_provider.dart';
export 'src/modules/interfaces/consent_provider.dart';
// `SleepStage` from the legacy feature-provider interface collides with
// the richer enum in `models/sleep_score.dart`. The sleep_score one is
// the public contract going forward; hide the legacy one here.
export 'src/modules/interfaces/feature_providers.dart' hide SleepStage;

// Modules
export 'src/modules/capabilities/capability_module.dart';
export 'src/modules/capabilities/capability_token.dart';
export 'src/modules/consent/consent_module.dart';
export 'src/modules/consent/consent_effective_state.dart';
export 'src/modules/consent/consent_form.dart';
export 'src/modules/consent/consent_type_meta.dart';
export 'src/modules/consent/consent_profile.dart';
export 'src/modules/consent/consent_token.dart';
export 'src/modules/consent/consent_ui.dart';
export 'src/modules/wear/wear_module.dart';
export 'src/modules/wear/wear_module_status.dart';
export 'src/modules/wear/wear_source_handler.dart' show WearSample;
export 'src/modules/phone/phone_module.dart';
export 'src/modules/behavior/behavior_module.dart';
export 'src/modules/behavior/behavior_code.dart';
export 'src/modules/behavior/behavior_events.dart';
export 'src/modules/breathing/breathing_module.dart';
export 'src/modules/breathing/breathing_compliance_result.dart';
export 'src/modules/breathing/breathing_guidance_copy.dart';

// Syni — adaptive AI agent (gated feature).
// SyniModule is the thin host-SDK facade (gate + HSI context builder);
// the orchestration types are re-exported from package:syni's agent layer
// so app code gets the full surface via `package:synheart_core`.
export 'src/modules/syni/syni_module.dart';
export 'src/modules/syni/syni_service_client.dart';
export 'src/modules/syni/syni_service_models.dart';
export 'package:syni/agent.dart'
    show
        SyniPersona,
        SyniSpecPersona,
        SyniSpecPersonaException,
        SyniModelSpec,
        SyniModels,
        SyniInstallState,
        SyniNotInstalled,
        SyniInstalling,
        SyniInstalled,
        SyniInstallFailed,
        SyniInstallStage,
        SyniChatResponse,
        SyniResponseKind,
        SyniChatEvent,
        SyniChatDelta,
        SyniChatFinal,
        SyniInstallException,
        // Hybrid local/cloud execution
        SyniExecutionMode,
        SyniCloudConfig,
        SyniCloudException,
        // Model catalog (local + cloud peers)
        SyniModelOption,
        SyniLocalModel,
        SyniCloudModel,
        SyniModelCatalog;

export 'src/modules/cloud/upload_models.dart';
export 'src/modules/cloud/cloud_exceptions.dart';

// Core Runtime Bridge — surface that loads the on-device runtime.
// Most apps shouldn't reach for this directly; subscribe to
// `Synheart.onHSIUpdate` / `onStateUpdate` instead.
export 'src/core_runtime/core_runtime_bridge.dart';

// FFI loader — needed by apps that wire optional engines (e.g.
// `SynheartResilience(ffi: SynheartCoreFFI.load())`).
export 'src/core_runtime/ffi_bindings.dart' show SynheartCoreFFI;

// Watch Session (adapter around synheart_session for watch relay)
export 'src/modules/session/watch_session_module.dart';

// Device Auth
export 'src/modules/cloud/device_auth_provider.dart';

// Device Auth (re-exported from synheart_auth, hiding name collisions)
export 'package:synheart_auth/synheart_auth.dart' hide NetworkError;

// Session lifecycle (re-exported from synheart_session)
export 'package:synheart_session/synheart_session.dart';

// BLE Heart Rate Monitor (re-exported from synheart_wear)
export 'package:synheart_wear/src/adapters/ble_hrm_models.dart';
export 'package:synheart_wear/src/adapters/ble_hrm_bridge.dart';

// Multi-source priority resolver. Requires the native priority symbols;
// falls back to an in-memory Dart store when the loaded runtime lacks them
// (check `runtimeDiagnostics()['missingSymbols']`).
// In-memory fallback when the runtime doesn't expose the symbols.
export 'src/priority/priority_metric.dart';
export 'src/priority/synheart_priority.dart';

// Apple Health XML backfill sink. Requires the native backfill symbols.
// Bridges the synheart-wear orchestrator's `AppleXmlIngestSink` to the
// runtime's backfill SQLite ingest.
export 'src/backfill/apple_xml_backfill_sink.dart';
// High-level Apple Health import sink. Aggregates samples per day and
// replays them via `Synheart.srmPushWearableDaily` so an imported
// `export.zip` actually populates the user's runtime baselines —
// without it, the FFI backfill path only stores idempotency keys
// and the values are dropped on the floor.
export 'src/backfill/apple_health_runtime_sink.dart';
// Android-side parallel: pulls the last N days of sleep + overnight
// HR/HRV from Health Connect and feeds them into the same runtime
// SRM plumbing. Bounded by Health Connect's per-record-type
// retention (typically ~30 days for HR, longer for sleep), but
// closes the gap that Android users had no historical-import gesture.
export 'src/backfill/health_connect_runtime_sink.dart';

// HRV-CV resilience score. Requires the native resilience symbol.
// Stateless multi-day score derived from sleep-window-filtered HRV.
export 'src/resilience/synheart_resilience.dart';
export 'src/resilience/resilience_data.dart';

// Edge ingest — pure-Dart, transport-independent phone-side consumer of the
// watch→phone edge wire contract. Dart member of the cross-platform EdgeIngest
// matrix (parity with Kotlin/Swift). The native WCSession/Wearable→EventChannel
// transport bridge is a separate follow-up.
export 'src/edge/edge_ingest.dart';
export 'src/edge/edge_models.dart';
