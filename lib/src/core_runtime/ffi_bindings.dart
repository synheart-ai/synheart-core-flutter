/// dart:ffi bindings to `synheart_core_runtime` C ABI.
///
/// Loads the native library and resolves `synheart_core_*` symbols.
/// Used by [CoreRuntimeBridge] — not called directly by app code.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../core/logger.dart';
import 'sdk_ffi.dart';

// ── C function typedefs (native + Dart) ─────────────────────────────────

// Handle lifecycle
typedef _NewC = Pointer<Void> Function(Pointer<Utf8> configJson);
typedef _NewDart = Pointer<Void> Function(Pointer<Utf8> configJson);
typedef _FreeC = Void Function(Pointer<Void> handle);
typedef _FreeDart = void Function(Pointer<Void> handle);
typedef _FreeStringC = Void Function(Pointer<Utf8> ptr);
typedef _FreeStringDart = void Function(Pointer<Utf8> ptr);

// Session
typedef _StartSessionC = Pointer<Utf8> Function(Pointer<Void> handle);
typedef _StartSessionDart = Pointer<Utf8> Function(Pointer<Void> handle);
typedef _StopSessionC = Int32 Function(Pointer<Void> handle);
typedef _StopSessionDart = int Function(Pointer<Void> handle);
typedef _CurrentSessionC = Pointer<Utf8> Function(Pointer<Void> handle);
typedef _CurrentSessionDart = Pointer<Utf8> Function(Pointer<Void> handle);
typedef _IsRunningC = Int32 Function(Pointer<Void> handle);
typedef _IsRunningDart = int Function(Pointer<Void> handle);

// Sensor push
typedef _PushRrC =
    Void Function(Pointer<Void> h, Int64 ts, Double rr, Pointer<Utf8> provider);
typedef _PushRrDart =
    void Function(Pointer<Void> h, int ts, double rr, Pointer<Utf8> provider);
// Batched RR push: `rr` points to `len` doubles (RR intervals in ms) that
// arrived together in one sensor notification; `order` is 0=oldest-first
// (BLE HRM), 1=newest-first. Maps `size_t` → `Size`.
typedef _PushRrBatchC =
    Void Function(
      Pointer<Void> h,
      Int64 anchorTs,
      Pointer<Double> rr,
      Size len,
      Int32 order,
      Pointer<Utf8> provider,
    );
typedef _PushRrBatchDart =
    void Function(
      Pointer<Void> h,
      int anchorTs,
      Pointer<Double> rr,
      int len,
      int order,
      Pointer<Utf8> provider,
    );
typedef _PushHrC = Void Function(Pointer<Void> h, Int64 ts, Double bpm);
typedef _PushHrDart = void Function(Pointer<Void> h, int ts, double bpm);
typedef _EnsurePipelineC = Void Function(Pointer<Void> h);
typedef _EnsurePipelineDart = void Function(Pointer<Void> h);
typedef _TickC = Pointer<Utf8> Function(Pointer<Void> h, Int64 nowMs);
typedef _TickDart = Pointer<Utf8> Function(Pointer<Void> h, int nowMs);
typedef _PushVendorHrvC =
    Void Function(
      Pointer<Void> h,
      Int64 ts,
      Double rmssd,
      Double sdnn,
      Double stress,
      Double recovery,
    );
typedef _PushVendorHrvDart =
    void Function(
      Pointer<Void> h,
      int ts,
      double rmssd,
      double sdnn,
      double stress,
      double recovery,
    );
typedef _PushVendorVitalsC =
    Void Function(Pointer<Void> h, Int64 ts, Double spo2, Double respiration);
typedef _PushVendorVitalsDart =
    void Function(Pointer<Void> h, int ts, double spo2, double respiration);
typedef _PushAccelC =
    Void Function(Pointer<Void> h, Int64 ts, Double x, Double y, Double z);
typedef _PushAccelDart =
    void Function(Pointer<Void> h, int ts, double x, double y, double z);
typedef _PushBehaviorC =
    Void Function(Pointer<Void> h, Int64 ts, Int32 t, Double v);
typedef _PushBehaviorDart =
    void Function(Pointer<Void> h, int ts, int t, double v);
typedef _PushSleepC = Void Function(Pointer<Void> h, Pointer<Utf8> json);
typedef _PushSleepDart = void Function(Pointer<Void> h, Pointer<Utf8> json);
// Rich behavior / context events: the typed payload goes over as JSON and the
// call reports acceptance as an int (0 = accepted). The legacy
// `push_behavior(ts, code, value)` above carries no payload at all, so a
// notification pushed that way has `action: None` and a typing event an
// all-`None` `TypingSessionData`.
typedef _PushJsonEventC =
    Int32 Function(Pointer<Void> h, Pointer<Utf8> eventJson);
typedef _PushJsonEventDart =
    int Function(Pointer<Void> h, Pointer<Utf8> eventJson);
typedef _PushSpeedC = Void Function(Pointer<Void> h, Int64 ts, Double speedMps);
typedef _PushSpeedDart =
    void Function(Pointer<Void> h, int ts, double speedMps);
typedef _SetAccelPlacementC = Void Function(Pointer<Void> h, Int32 placement);
typedef _SetAccelPlacementDart = void Function(Pointer<Void> h, int placement);
typedef _DeclareRestWindowC = Void Function(Pointer<Void> h, Int64 tsMs);
typedef _DeclareRestWindowDart = void Function(Pointer<Void> h, int tsMs);
typedef _RollDayC = Int32 Function(Pointer<Void> h, Int32 dayIndex);
typedef _RollDayDart = int Function(Pointer<Void> h, int dayIndex);
// `tick_all` and `flush_pending` both return a JSON *array* of HSI documents,
// oldest first — unlike `tick`, which returns at most one window.
typedef _DrainC = Pointer<Utf8> Function(Pointer<Void> h, Int64 nowMs);
typedef _DrainDart = Pointer<Utf8> Function(Pointer<Void> h, int nowMs);
typedef _ReadStringC = Pointer<Utf8> Function(Pointer<Void> h);
typedef _ReadStringDart = Pointer<Utf8> Function(Pointer<Void> h);
typedef _LoadStringC = Int32 Function(Pointer<Void> h, Pointer<Utf8> json);
typedef _LoadStringDart = int Function(Pointer<Void> h, Pointer<Utf8> json);
typedef _IngestBatchC =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> json, Int64 now);
typedef _IngestBatchDart =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> json, int now);

// Breathing compliance.
typedef _BreathingSetTargetBpmC = Void Function(Pointer<Void> h, Double bpm);
typedef _BreathingSetTargetBpmDart = void Function(Pointer<Void> h, double bpm);
typedef _BreathingSetWindowSecsC = Void Function(Pointer<Void> h, Int32 secs);
typedef _BreathingSetWindowSecsDart = void Function(Pointer<Void> h, int secs);
typedef _BreathingSetPopulationC =
    Void Function(Pointer<Void> h, Int32 profile);
typedef _BreathingSetPopulationDart =
    void Function(Pointer<Void> h, int profile);
typedef _BreathingEvaluateC = Pointer<Utf8> Function(Pointer<Void> h);
typedef _BreathingEvaluateDart = Pointer<Utf8> Function(Pointer<Void> h);
typedef _BreathingResetC = Void Function(Pointer<Void> h);
typedef _BreathingResetDart = void Function(Pointer<Void> h);

// Personalization task / workout APIs .
typedef _SetTaskTypeC = Void Function(Pointer<Void> h, Int32 kind);
typedef _SetTaskTypeDart = void Function(Pointer<Void> h, int kind);
typedef _PushWorkoutEventC =
    Void Function(
      Pointer<Void> h,
      Int64 startMs,
      Int64 endMs,
      Int32 workoutKind,
      Double vendorStrain,
      Double vendorRecovery,
    );
typedef _PushWorkoutEventDart =
    void Function(
      Pointer<Void> h,
      int startMs,
      int endMs,
      int workoutKind,
      double vendorStrain,
      double vendorRecovery,
    );
typedef _CurrentTaskTypeC = Int32 Function(Pointer<Void> h);
typedef _CurrentTaskTypeDart = int Function(Pointer<Void> h);
typedef _CurrentWorkoutKindC = Int32 Function(Pointer<Void> h);
typedef _CurrentWorkoutKindDart = int Function(Pointer<Void> h);
typedef _PersonalizationContextJsonC = Pointer<Utf8> Function(Pointer<Void> h);
typedef _PersonalizationContextJsonDart =
    Pointer<Utf8> Function(Pointer<Void> h);
// Daily Recovery Score attach.
typedef _AttachRecoveryScoreC = Int32 Function(Pointer<Void> h, Uint8 score);
typedef _AttachRecoveryScoreDart = int Function(Pointer<Void> h, int score);
typedef _SrmPushWearableDailyC =
    Void Function(
      Pointer<Void> h,
      Pointer<Utf8> dim,
      Int32 dayIndex,
      Double value,
      Double confidence,
      Int32 fidelity,
    );
typedef _SrmPushWearableDailyDart =
    void Function(
      Pointer<Void> h,
      Pointer<Utf8> dim,
      int dayIndex,
      double value,
      double confidence,
      int fidelity,
    );
typedef _SrmTriggerRecomputeC =
    Void Function(Pointer<Void> h, Int32 trigger, Int32 asOfDay);
typedef _SrmTriggerRecomputeDart =
    void Function(Pointer<Void> h, int trigger, int asOfDay);

// Consent
typedef _ConsentStrC = Int32 Function(Pointer<Void> h, Pointer<Utf8> ct);
typedef _ConsentStrDart = int Function(Pointer<Void> h, Pointer<Utf8> ct);
typedef _HasConsentC = Int32 Function(Pointer<Void> h, Pointer<Utf8> ct);
typedef _HasConsentDart = int Function(Pointer<Void> h, Pointer<Utf8> ct);
typedef _CurrentConsentC = Pointer<Utf8> Function(Pointer<Void> h);
typedef _CurrentConsentDart = Pointer<Utf8> Function(Pointer<Void> h);
typedef _ConsentConfigureCloudC =
    Int32 Function(Pointer<Void> h, Pointer<Utf8> baseUrl, Pointer<Utf8> appId);
typedef _ConsentConfigureCloudDart =
    int Function(Pointer<Void> h, Pointer<Utf8> baseUrl, Pointer<Utf8> appId);
typedef _ConsentSubmitFormC =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> deviceId,
      Pointer<Utf8> platform,
      Pointer<Utf8> userId,
      Pointer<Utf8> formJson,
    );
typedef _ConsentSubmitFormDart =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> deviceId,
      Pointer<Utf8> platform,
      Pointer<Utf8> userId,
      Pointer<Utf8> formJson,
    );
typedef _RecordStudyConsentC =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> payloadJson);
typedef _RecordStudyConsentDart =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> payloadJson);

// Research study
typedef _EnrolStudyC =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> accessCode,
      Pointer<Utf8> studyCode,
    );
typedef _EnrolStudyDart =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> accessCode,
      Pointer<Utf8> studyCode,
    );

// Study data deletion (request erasure of study-contributed data).
typedef _RequestStudyDeletionC =
    Pointer<Utf8> Function(Pointer<Void> h, Bool dryRun);
typedef _RequestStudyDeletionDart =
    Pointer<Utf8> Function(Pointer<Void> h, bool dryRun);

// Capability
typedef _LoadCapC =
    Int32 Function(Pointer<Void> h, Pointer<Utf8> tj, Pointer<Utf8> s);
typedef _LoadCapDart =
    int Function(Pointer<Void> h, Pointer<Utf8> tj, Pointer<Utf8> s);

// Queries
typedef _JsonReturnC = Pointer<Utf8> Function(Pointer<Void> h);
typedef _JsonReturnDart = Pointer<Utf8> Function(Pointer<Void> h);

// ── Batch sleep score ──
// compute: (handle, input_json) -> *char (handle reserved, may be null)
typedef _SleepScoreComputeC =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> inputJson);
typedef _SleepScoreComputeDart =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> inputJson);

// compute_traced: (handle, input_json, correlation_id) -> *char
typedef _SleepScoreComputeTracedC =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> inputJson,
      Pointer<Utf8> correlationId,
    );
typedef _SleepScoreComputeTracedDart =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> inputJson,
      Pointer<Utf8> correlationId,
    );

// hsi_history list: (handle, since_unix_ms, limit) -> char* (JSON array)
typedef _HsiHistoryListC =
    Pointer<Utf8> Function(Pointer<Void> h, Int64 sinceMs, Int64 limit);
typedef _HsiHistoryListDart =
    Pointer<Utf8> Function(Pointer<Void> h, int sinceMs, int limit);
// hsi_history count: (handle) -> int64 uses the existing _Int64Return* typedefs.
typedef _SessionIdC =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> sid);
typedef _SessionIdDart =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> sid);
typedef _HsiWindowsC =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> sid,
      Int64 s,
      Int64 e,
      Int32 l,
    );
typedef _HsiWindowsDart =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> sid,
      int s,
      int e,
      int l,
    );

// Syni service (device-signed cloud chat + sessions).
typedef _SyniChatC =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> requestJson);
typedef _SyniChatDart =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> requestJson);
typedef _SyniListSessionsC =
    Pointer<Utf8> Function(Pointer<Void> h, Int32 limit);
typedef _SyniListSessionsDart =
    Pointer<Utf8> Function(Pointer<Void> h, int limit);
typedef _SyniGetSessionC =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> sessionId);
typedef _SyniGetSessionDart =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> sessionId);
typedef _SyniGetSessionMessagesC =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> sessionId,
      Int32 limit,
    );
typedef _SyniGetSessionMessagesDart =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> sessionId, int limit);

// Metrics
typedef _RecordMetricC = Int32 Function(Pointer<Void> h, Pointer<Utf8> json);
typedef _RecordMetricDart = int Function(Pointer<Void> h, Pointer<Utf8> json);

// Deletion
typedef _DeleteSessionC = Int32 Function(Pointer<Void> h, Pointer<Utf8> sid);
typedef _DeleteSessionDart = int Function(Pointer<Void> h, Pointer<Utf8> sid);
typedef _WipeC = Int32 Function(Pointer<Void> h);
typedef _WipeDart = int Function(Pointer<Void> h);
typedef _RetentionC = Int64 Function(Pointer<Void> h, Int32 days);
typedef _RetentionDart = int Function(Pointer<Void> h, int days);

// Customer-facing GDPR data deletion (cloud-side).
typedef _RequestDataDeletionC =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> reason,
      Pointer<Utf8> contact,
      Bool dryRun,
    );
typedef _RequestDataDeletionDart =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> reason,
      Pointer<Utf8> contact,
      bool dryRun,
    );
typedef _GetDataDeletionC =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> requestId);
typedef _GetDataDeletionDart =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> requestId);
typedef _ListDataDeletionsC =
    Pointer<Utf8> Function(Pointer<Void> h, Int32 limit, Int32 offset);
typedef _ListDataDeletionsDart =
    Pointer<Utf8> Function(Pointer<Void> h, int limit, int offset);

// Baseline local hydrate (cross-device transport rides the sync engine).
typedef _BaselineHydrateLocalC = Pointer<Utf8> Function(Pointer<Void> h);
typedef _BaselineHydrateLocalDart = Pointer<Utf8> Function(Pointer<Void> h);

// Baseline offline export/import (.srm.synheart file share).
typedef _BaselineExportOfflineC =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> passphrase);
typedef _BaselineExportOfflineDart =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> passphrase);
typedef _BaselineImportOfflineC =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> passphrase,
      Pointer<Utf8> blobB64,
    );
typedef _BaselineImportOfflineDart =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> passphrase,
      Pointer<Utf8> blobB64,
    );

// Vendor events
typedef _IngestVendorEventC =
    Int32 Function(Pointer<Void> h, Pointer<Utf8> json);
typedef _IngestVendorEventDart =
    int Function(Pointer<Void> h, Pointer<Utf8> json);
typedef _QueryVendorEventsC =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> queryJson);
typedef _QueryVendorEventsDart =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> queryJson);
typedef _GetLatestVendorEventC =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> provider,
      Pointer<Utf8> eventType,
    );
typedef _GetLatestVendorEventDart =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> provider,
      Pointer<Utf8> eventType,
    );
typedef _DeleteVendorEventsC =
    Int64 Function(Pointer<Void> h, Pointer<Utf8> provider);
typedef _DeleteVendorEventsDart =
    int Function(Pointer<Void> h, Pointer<Utf8> provider);

// Sync
typedef _SetSyncC = Void Function(Pointer<Void> h, Int32 enabled);
typedef _SetSyncDart = void Function(Pointer<Void> h, int enabled);
typedef _SyncNowC = Pointer<Utf8> Function(Pointer<Void> h);
typedef _SyncNowDart = Pointer<Utf8> Function(Pointer<Void> h);
typedef _SyncCreateSpaceC =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> deviceName);
typedef _SyncCreateSpaceDart =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> deviceName);
typedef _SyncJoinSpaceC =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> pairingToken,
      Pointer<Utf8> deviceName,
    );
typedef _SyncJoinSpaceDart =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> pairingToken,
      Pointer<Utf8> deviceName,
    );
typedef _SyncGeneratePairingC = Pointer<Utf8> Function(Pointer<Void> h);
typedef _SyncGeneratePairingDart = Pointer<Utf8> Function(Pointer<Void> h);
typedef _SyncStatusC = Pointer<Utf8> Function(Pointer<Void> h);
typedef _SyncStatusDart = Pointer<Utf8> Function(Pointer<Void> h);
typedef _SyncRecoverSpaceC =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> recoveryKey,
      Pointer<Utf8> spaceId,
    );
typedef _SyncRecoverSpaceDart =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> recoveryKey,
      Pointer<Utf8> spaceId,
    );
typedef _SyncLeaveSpaceC = Pointer<Utf8> Function(Pointer<Void> h);
typedef _SyncLeaveSpaceDart = Pointer<Utf8> Function(Pointer<Void> h);
typedef _SyncListDevicesC = Pointer<Utf8> Function(Pointer<Void> h);
typedef _SyncListDevicesDart = Pointer<Utf8> Function(Pointer<Void> h);
typedef _SyncRevokeDeviceC =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> deviceId);
typedef _SyncRevokeDeviceDart =
    Pointer<Utf8> Function(Pointer<Void> h, Pointer<Utf8> deviceId);
typedef _SyncDeleteSpaceC = Pointer<Utf8> Function(Pointer<Void> h);
typedef _SyncDeleteSpaceDart = Pointer<Utf8> Function(Pointer<Void> h);

typedef _SyncClearLocalSpaceC = Pointer<Utf8> Function(Pointer<Void> h);
typedef _SyncClearLocalSpaceDart = Pointer<Utf8> Function(Pointer<Void> h);

// Generic `(handle) -> int32` shape — used by ambient-capture get,
// and any future read-only flag accessor. Kept here rather than
// inlined at the lookup site so the binding block stays terse.
typedef _GetIntC = Int32 Function(Pointer<Void> h);
typedef _GetIntDart = int Function(Pointer<Void> h);

// SRM
typedef _LoadSnapshotC = Int32 Function(Pointer<Void> h, Pointer<Utf8> json);
typedef _LoadSnapshotDart = int Function(Pointer<Void> h, Pointer<Utf8> json);

// Cloud
typedef _EnqueueC =
    Void Function(Pointer<Void> h, Pointer<Utf8> json, Int64 ts);
typedef _EnqueueDart =
    void Function(Pointer<Void> h, Pointer<Utf8> json, int ts);
typedef _IntReturnC = Int32 Function(Pointer<Void> h);
typedef _IntReturnDart = int Function(Pointer<Void> h);

// Subject rebind: (handle, subject_id, invalidate_token) -> int32
// (1 = re-mint required, 0 = valid token loaded, -1 = error).
typedef _RebindSubjectC =
    Int32 Function(Pointer<Void> h, Pointer<Utf8> subjectId, Int32 invalidate);
typedef _RebindSubjectDart =
    int Function(Pointer<Void> h, Pointer<Utf8> subjectId, int invalidate);

// Account
typedef _AccountActionC = Int32 Function(Pointer<Void> h);
typedef _AccountActionDart = int Function(Pointer<Void> h);

// Lab
//
// `synheart_core_lab_start` returns `c_int` — 0 on success, non-zero on
// failure (e.g. 1 = "Lab session already active"). Earlier the Dart
// typedef declared the return as `Pointer<Utf8>`, which caused Dart to
// read the integer return as a pointer: a non-zero error code (e.g. 1)
// became `Pointer<Utf8>` at address `0x1`, and the bridge's
// `_readAndFree` then tried to walk bytes from `0x1` looking for a null
// terminator — guaranteed EXC_BAD_ACCESS at address=0x1. Mirror crash
// 2026-04-28 traced to this when "Add Another Entry" reused an active
// lab session and the runtime correctly returned err=1.
typedef _LabStartC =
    Int32 Function(
      Pointer<Void> h,
      Pointer<Utf8> protocolJson,
      Int64 startedAtMs,
    );
typedef _LabStartDart =
    int Function(Pointer<Void> h, Pointer<Utf8> protocolJson, int startedAtMs);
typedef _LabReenqueueC =
    Int32 Function(Pointer<Void> h, Pointer<Utf8> sessionJson);
typedef _LabReenqueueDart =
    int Function(Pointer<Void> h, Pointer<Utf8> sessionJson);
typedef _LabOpenWindowC =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> parentId,
      Pointer<Utf8> windowType,
      Pointer<Utf8> label,
      Int64 startedAtMs,
    );
typedef _LabOpenWindowDart =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> parentId,
      Pointer<Utf8> windowType,
      Pointer<Utf8> label,
      int startedAtMs,
    );
typedef _LabCloseWindowC =
    Int32 Function(Pointer<Void> h, Pointer<Utf8> windowId, Int64 endedAtMs);
typedef _LabCloseWindowDart =
    int Function(Pointer<Void> h, Pointer<Utf8> windowId, int endedAtMs);
typedef _LabSetWindowValuesC =
    Int32 Function(
      Pointer<Void> h,
      Pointer<Utf8> windowId,
      Pointer<Utf8> valuesJson,
    );
typedef _LabSetWindowValuesDart =
    int Function(
      Pointer<Void> h,
      Pointer<Utf8> windowId,
      Pointer<Utf8> valuesJson,
    );
// Same ABI-mismatch class as _LabStart was — the runtime returns `c_int`
// (0 = OK, non-zero = error code). Earlier this was declared as
// Pointer<Utf8>, so a non-zero error code was read as a pointer and
// the bridge crashed walking bytes from a tiny address.
typedef _LabMergeExtraDataC =
    Int32 Function(Pointer<Void> h, Pointer<Utf8> patchJson);
typedef _LabMergeExtraDataDart =
    int Function(Pointer<Void> h, Pointer<Utf8> patchJson);
typedef _LabSetStateOverridesC =
    Int32 Function(
      Pointer<Void> h,
      Pointer<Utf8> windowId,
      Pointer<Utf8> overridesJson,
    );
typedef _LabSetStateOverridesDart =
    int Function(
      Pointer<Void> h,
      Pointer<Utf8> windowId,
      Pointer<Utf8> overridesJson,
    );
typedef _LabFinalizeC =
    Pointer<Utf8> Function(Pointer<Void> h, Int64 endedAtMs);
typedef _LabFinalizeDart =
    Pointer<Utf8> Function(Pointer<Void> h, int endedAtMs);
typedef _LabAvailableC = Int32 Function(Pointer<Void> h);
typedef _LabAvailableDart = int Function(Pointer<Void> h);

// Lab metadata
typedef _LabEnsureMetadataC =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> deviceId,
      Pointer<Utf8> platform,
      Pointer<Utf8> osVersion,
      Pointer<Utf8> userInfoJson,
      Pointer<Utf8> deviceExtraJson,
    );
typedef _LabEnsureMetadataDart =
    Pointer<Utf8> Function(
      Pointer<Void> h,
      Pointer<Utf8> deviceId,
      Pointer<Utf8> platform,
      Pointer<Utf8> osVersion,
      Pointer<Utf8> userInfoJson,
      Pointer<Utf8> deviceExtraJson,
    );
typedef _LabMarkMetadataDirtyC =
    Int32 Function(Pointer<Void> h, Pointer<Utf8> reason);
typedef _LabMarkMetadataDirtyDart =
    int Function(Pointer<Void> h, Pointer<Utf8> reason);

// Diagnostics
typedef _VersionC = Pointer<Utf8> Function();
typedef _VersionDart = Pointer<Utf8> Function();
typedef _Int64ReturnC = Int64 Function(Pointer<Void> h);
typedef _Int64ReturnDart = int Function(Pointer<Void> h);

// ── Multi-source priority resolver ──────────────────────────────────
// Process-global (no handle), JSON in/out for resolve.
typedef _PrioritySetProviderC =
    Int32 Function(Pointer<Utf8> provider, Int32 rank);
typedef _PrioritySetProviderDart =
    int Function(Pointer<Utf8> provider, int rank);
typedef _PrioritySetMetricOverrideC =
    Int32 Function(
      Pointer<Utf8> metric,
      Pointer<Utf8> provider,
      Int32 present,
      Int32 rank,
    );
typedef _PrioritySetMetricOverrideDart =
    int Function(
      Pointer<Utf8> metric,
      Pointer<Utf8> provider,
      int present,
      int rank,
    );
typedef _PriorityEffectiveRankC =
    Int32 Function(Pointer<Utf8> metric, Pointer<Utf8> provider);
typedef _PriorityEffectiveRankDart =
    int Function(Pointer<Utf8> metric, Pointer<Utf8> provider);
typedef _PriorityResolveC =
    Pointer<Utf8> Function(Pointer<Utf8> metric, Pointer<Utf8> samplesJson);
typedef _PriorityResolveDart =
    Pointer<Utf8> Function(Pointer<Utf8> metric, Pointer<Utf8> samplesJson);

// ── HRV-CV resilience score ─────────────────────────────────────────
// Stateless. Three JSON inputs, one JSON output.
typedef _ResilienceComputeC =
    Pointer<Utf8> Function(
      Pointer<Utf8> samplesJson,
      Pointer<Utf8> windowsJson,
      Pointer<Utf8> configJson,
    );
typedef _ResilienceComputeDart =
    Pointer<Utf8> Function(
      Pointer<Utf8> samplesJson,
      Pointer<Utf8> windowsJson,
      Pointer<Utf8> configJson,
    );

// ── Apple Health XML backfill ───────────────────────────────────────
// Stateful per-import via runtime registry keyed by import_id.
typedef _BackfillOpenC =
    Int32 Function(Pointer<Utf8> dbPath, Pointer<Utf8> importId);
typedef _BackfillOpenDart =
    int Function(Pointer<Utf8> dbPath, Pointer<Utf8> importId);
typedef _BackfillInsertBatchC =
    Pointer<Utf8> Function(Pointer<Utf8> importId, Pointer<Utf8> samplesJson);
typedef _BackfillInsertBatchDart =
    Pointer<Utf8> Function(Pointer<Utf8> importId, Pointer<Utf8> samplesJson);
typedef _BackfillFinalizeC = Pointer<Utf8> Function(Pointer<Utf8> importId);
typedef _BackfillFinalizeDart = Pointer<Utf8> Function(Pointer<Utf8> importId);

// ── Library loader ──────────────────────────────────────────────────────

/// Resolved FFI bindings for `synheart_core_runtime`.
class SynheartCoreFFI {
  SynheartCoreFFI._(this._lib) : sdkFfi = SynheartSdkFfi.tryBind(_lib);

  final DynamicLibrary _lib;

  /// Optional `synheart_core_sdk_*` device-auth symbols (null fields if absent).
  final SynheartSdkFfi sdkFfi;

  static SynheartCoreFFI? _instance;

  /// Optional `synheart_core_*` symbols the loaded library does not export,
  /// recorded the first time each is probed.
  ///
  /// Bindings resolve lazily, so a name lands here when the feature behind it is
  /// first used. Surfaced through
  /// `Synheart.runtimeDiagnostics()['missingSymbols']`; a non-empty set means
  /// the vendored runtime predates this SDK release and those features return
  /// `null` / `-1` / `const []` rather than working.
  static final Set<String> _missingSymbols = <String>{};

  /// Unmodifiable view of [_missingSymbols].
  static Set<String> get missingSymbols =>
      Set<String>.unmodifiable(_missingSymbols);

  /// Every optional symbol probed so far, resolved or not.
  static final Set<String> _probedSymbols = <String>{};

  /// How many optional symbols have been probed. Zero means nothing has been
  /// checked yet — which is NOT the same as "everything is fine", and is why
  /// [probeOptionalSymbols] exists.
  static int get probedSymbolCount => _probedSymbols.length;

  /// Force-resolve every optional symbol so [missingSymbols] reflects a real
  /// audit rather than whatever happened to be used.
  ///
  /// Without this, a host that never touches a given feature never learns its
  /// symbol is absent, and an empty [missingSymbols] looks healthy while
  /// nothing has been checked. Intended for diagnostics surfaces rather than
  /// the hot path; idempotent, since the lookups cache.
  void probeOptionalSymbols() {
    // Referencing each field forces its initializer to run.
    coreLastError;
    recordStudyConsent;
    baselineHydrateLocal;
    baselineExportOffline;
    baselineImportOffline;
    labReenqueueSession;
    labEnsureMetadata;
    labMarkMetadataDirty;
    labCurrentMetadataId;
    version;
    prioritySetProvider;
    prioritySetMetricOverride;
    priorityEffectiveRank;
    priorityResolve;
    resilienceComputeV1;
    backfillOpen;
    backfillInsertBatch;
    backfillFinalize;
    syniChat;
    syniListSessions;
    syniGetSession;
    syniGetSessionMessages;
    syniCloseSession;
  }

  /// Wrap an OPTIONAL symbol lookup so a miss is recorded and logged once
  /// rather than silently swallowed — a runtime that predates this SDK release
  /// would otherwise disable whole feature areas with nothing in the logs.
  ///
  /// [lookup] must perform the `_lib.lookupFunction<NativeT, DartT>(symbol)`
  /// call itself: dart:ffi requires the native type to be concrete at the call
  /// site, so it cannot be passed through a type variable.
  static T? _optional<T extends Function>(String symbol, T Function() lookup) {
    _probedSymbols.add(symbol);
    try {
      return lookup();
    } catch (_) {
      if (_missingSymbols.add(symbol)) {
        SynheartLogger.log(
          '[Synheart] native symbol "$symbol" not found in the loaded runtime '
          '— the feature it backs is disabled. Update the vendored runtime '
          'with `synheart install runtime` if you expect it to be available.',
        );
      }
      return null;
    }
  }

  /// Load the native library. Returns null if not found.
  ///
  /// Desktop (macOS/Linux/Windows) lookup order:
  /// 1. `<cwd>/synheart/vendor/runtime/<platform>/<libname>` (installed by
  /// `synheart install runtime` or `synheart runtime install --from`)
  /// 2. bare `<libname>` (system loader path — DYLD/LD_LIBRARY_PATH, PATH)
  ///
  /// iOS loads `SynheartCoreRuntime.framework` (embedded by the
  /// vendored xcframework via the synheart_core podspec). Android
  /// loads via jniLibs/ auto-discovery by the Android loader.
  static SynheartCoreFFI? load() {
    if (_instance != null) return _instance;

    DynamicLibrary? lib;
    try {
      if (Platform.isIOS) {
        // iOS embeds SynheartCoreRuntime.framework into Runner.app/Frameworks/
        // and the dynamic loader maps it at app start. Its symbols are
        // therefore already in the process by the time Dart FFI runs, so
        // DynamicLibrary.process() resolves them without needing a path.
        // dlopen() with the literal relative string "SynheartCoreRuntime.
        // framework/SynheartCoreRuntime" fails because dlopen wants an
        // absolute path or @rpath-prefixed install name — and we don't
        // want to hardcode either.
        lib = DynamicLibrary.process();
      } else if (Platform.isAndroid) {
        lib = DynamicLibrary.open('libsynheart_core_runtime.so');
      } else if (Platform.isMacOS) {
        lib = _openDesktop('macos', 'libsynheart_core_runtime.dylib');
      } else if (Platform.isLinux) {
        lib = _openDesktop('linux', 'libsynheart_core_runtime.so');
      } else if (Platform.isWindows) {
        lib = _openDesktop('windows', 'synheart_core_runtime.dll');
      }
    } catch (e, st) {
      // Surface instead of swallowing — silent failures were why an iOS
      // misconfiguration (missing framework, bad install_name) used to
      // bubble up as a generic "core runtime bridge unavailable" with no
      // clue what actually went wrong.
      SynheartLogger.log(
        '[Synheart FFI] DynamicLibrary load failed: $e',
        name: 'synheart.ffi',
        error: e,
        stackTrace: st,
      );
      return null;
    }

    if (lib == null) return null;
    _instance = SynheartCoreFFI._(lib);
    return _instance;
  }

  /// Try `synheart/vendor/runtime/<platform>/<libname>` relative to the
  /// current working directory, then fall back to the bare filename so the
  /// OS loader can resolve it from standard library search paths.
  static DynamicLibrary? _openDesktop(String platform, String libname) {
    final vendored =
        '${Directory.current.path}'
        '${Platform.pathSeparator}synheart'
        '${Platform.pathSeparator}vendor'
        '${Platform.pathSeparator}runtime'
        '${Platform.pathSeparator}$platform'
        '${Platform.pathSeparator}$libname';
    if (File(vendored).existsSync()) {
      try {
        return DynamicLibrary.open(vendored);
      } catch (_) {
        // fall through to bare lookup
      }
    }
    try {
      return DynamicLibrary.open(libname);
    } catch (_) {
      return null;
    }
  }

  // ── Resolved symbols ────────────────────────────────────────────────

  late final initLogging = _lib
      .lookupFunction<
        Int32 Function(
          Pointer<Utf8>,
          Pointer<NativeFunction<Void Function(Pointer<Utf8>, Pointer<Void>)>>?,
          Pointer<Void>,
        ),
        int Function(
          Pointer<Utf8>,
          Pointer<NativeFunction<Void Function(Pointer<Utf8>, Pointer<Void>)>>?,
          Pointer<Void>,
        )
      >('synheart_core_init_logging');

  // Logging lifecycle FFI (runtime ≥ 5.2.1). Required: every shipped
  // runtime artifact exports these alongside `synheart_core_init_logging`.
  late final setLogCallback = _lib
      .lookupFunction<
        Int32 Function(
          Pointer<NativeFunction<Void Function(Pointer<Utf8>, Pointer<Void>)>>?,
          Pointer<Void>,
        ),
        int Function(
          Pointer<NativeFunction<Void Function(Pointer<Utf8>, Pointer<Void>)>>?,
          Pointer<Void>,
        )
      >('synheart_core_set_log_callback');

  late final shutdownLogging = _lib
      .lookupFunction<Int32 Function(), int Function()>(
        'synheart_core_shutdown_logging',
      );

  // Buffered (pull-based) logging FFI (runtime ≥ 0.19). Crash-safe for
  // Flutter hot restart: no NativeCallable trampoline crosses the FFI
  // boundary, so a freed Dart isolate can't leave the runtime holding a
  // dangling function pointer. These symbols are OPTIONAL — an older
  // vendored runtime won't export them, so callers must tolerate the
  // lookup throwing (see CoreRuntimeBridge.initRuntimeLogging fallback).
  late final initLoggingBuffered = _lib
      .lookupFunction<
        Int32 Function(Pointer<Utf8>),
        int Function(Pointer<Utf8>)
      >('synheart_core_init_logging_buffered');

  late final drainLogs = _lib
      .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
        'synheart_core_drain_logs',
      );

  late final droppedLogLines = _lib
      .lookupFunction<Uint64 Function(), int Function()>(
        'synheart_core_dropped_log_lines',
      );

  late final buildInfo = _lib
      .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
        'synheart_core_build_info',
      );

  late final coreNew = _lib.lookupFunction<_NewC, _NewDart>(
    'synheart_core_new',
  );
  late final coreFree = _lib.lookupFunction<_FreeC, _FreeDart>(
    'synheart_core_free',
  );
  late final coreFreeString = _lib
      .lookupFunction<_FreeStringC, _FreeStringDart>(
        'synheart_core_free_string',
      );

  /// Returns null when the symbol isn't exported (older runtime build).
  /// Caller MUST free the returned pointer via [coreFreeString].
  late final coreLastError = _optional(
    'synheart_core_last_error',
    () =>
        _lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
          'synheart_core_last_error',
        ),
  );

  late final startSession = _lib
      .lookupFunction<_StartSessionC, _StartSessionDart>(
        'synheart_core_start_session',
      );
  late final stopSession = _lib.lookupFunction<_StopSessionC, _StopSessionDart>(
    'synheart_core_stop_session',
  );
  late final currentSession = _lib
      .lookupFunction<_CurrentSessionC, _CurrentSessionDart>(
        'synheart_core_current_session',
      );
  late final isRunning = _lib.lookupFunction<_IsRunningC, _IsRunningDart>(
    'synheart_core_is_running',
  );

  late final pushRr = _lib.lookupFunction<_PushRrC, _PushRrDart>(
    'synheart_core_push_rr',
  );
  late final pushRrBatch = _lib.lookupFunction<_PushRrBatchC, _PushRrBatchDart>(
    'synheart_core_push_rr_batch',
  );
  late final pushHr = _lib.lookupFunction<_PushHrC, _PushHrDart>(
    'synheart_core_push_hr',
  );

  // Breathing compliance.
  late final breathingSetTargetBpm = _lib
      .lookupFunction<_BreathingSetTargetBpmC, _BreathingSetTargetBpmDart>(
        'synheart_core_breathing_set_target_bpm',
      );
  late final breathingSetWindowSecs = _lib
      .lookupFunction<_BreathingSetWindowSecsC, _BreathingSetWindowSecsDart>(
        'synheart_core_breathing_set_window_secs',
      );
  late final breathingSetPopulation = _lib
      .lookupFunction<_BreathingSetPopulationC, _BreathingSetPopulationDart>(
        'synheart_core_breathing_set_population',
      );
  late final breathingEvaluate = _lib
      .lookupFunction<_BreathingEvaluateC, _BreathingEvaluateDart>(
        'synheart_core_breathing_evaluate',
      );
  late final breathingReset = _lib
      .lookupFunction<_BreathingResetC, _BreathingResetDart>(
        'synheart_core_breathing_reset',
      );
  late final ensurePipeline = _lib
      .lookupFunction<_EnsurePipelineC, _EnsurePipelineDart>(
        'synheart_core_ensure_pipeline',
      );
  late final tick = _lib.lookupFunction<_TickC, _TickDart>(
    'synheart_core_tick',
  );
  late final pushVendorHrv = _lib
      .lookupFunction<_PushVendorHrvC, _PushVendorHrvDart>(
        'synheart_core_push_vendor_hrv',
      );
  late final pushVendorVitals = _lib
      .lookupFunction<_PushVendorVitalsC, _PushVendorVitalsDart>(
        'synheart_core_push_vendor_vitals',
      );
  late final pushAccel = _lib.lookupFunction<_PushAccelC, _PushAccelDart>(
    'synheart_core_push_accel',
  );
  late final pushBehavior = _lib
      .lookupFunction<_PushBehaviorC, _PushBehaviorDart>(
        'synheart_core_push_behavior',
      );
  // ── Mobile host surface (engine 0.16.0 / core-runtime 0.26.0) ────────
  //
  // Every symbol below is looked up optionally. The vendored runtimes in the
  // field span several releases — the iOS xcframework and the Android .so a
  // host ships are pinned artifacts, not the source tree — so a hard lookup
  // here would fail library load outright for a host that simply has not
  // re-vendored yet. Optional means the binding is present and correct the
  // moment the artifact catches up, and a logged no-op until then.
  //
  // `push_context_event` needs more than a recent artifact: it is compiled to
  // an inert stub (always returns 1) unless the runtime was built with the
  // `app-context` cargo feature.

  late final int Function(Pointer<Void>, Pointer<Utf8>)? pushBehaviorEvent =
      _optional(
        'synheart_core_push_behavior_event',
        () => _lib.lookupFunction<_PushJsonEventC, _PushJsonEventDart>(
          'synheart_core_push_behavior_event',
        ),
      );
  late final int Function(Pointer<Void>, Pointer<Utf8>)? pushContextEvent =
      _optional(
        'synheart_core_push_context_event',
        () => _lib.lookupFunction<_PushJsonEventC, _PushJsonEventDart>(
          'synheart_core_push_context_event',
        ),
      );
  late final void Function(Pointer<Void>, int, double)? pushSpeed = _optional(
    'synheart_core_push_speed',
    () => _lib.lookupFunction<_PushSpeedC, _PushSpeedDart>(
      'synheart_core_push_speed',
    ),
  );
  late final void Function(Pointer<Void>, int)? setAccelPlacement = _optional(
    'synheart_core_set_accel_placement',
    () => _lib.lookupFunction<_SetAccelPlacementC, _SetAccelPlacementDart>(
      'synheart_core_set_accel_placement',
    ),
  );
  late final void Function(Pointer<Void>, int)? declareRestWindow = _optional(
    'synheart_core_declare_rest_window',
    () => _lib.lookupFunction<_DeclareRestWindowC, _DeclareRestWindowDart>(
      'synheart_core_declare_rest_window',
    ),
  );
  late final Pointer<Utf8> Function(Pointer<Void>, int)? tickAll = _optional(
    'synheart_core_tick_all',
    () => _lib.lookupFunction<_DrainC, _DrainDart>('synheart_core_tick_all'),
  );
  late final Pointer<Utf8> Function(Pointer<Void>, int)? flushPending =
      _optional(
        'synheart_core_flush_pending',
        () => _lib.lookupFunction<_DrainC, _DrainDart>(
          'synheart_core_flush_pending',
        ),
      );
  late final int Function(Pointer<Void>, int)? rollDay = _optional(
    'synheart_core_roll_day',
    () =>
        _lib.lookupFunction<_RollDayC, _RollDayDart>('synheart_core_roll_day'),
  );
  late final Pointer<Utf8> Function(Pointer<Void>)? exportSessionState =
      _optional(
        'synheart_core_export_session_state',
        () => _lib.lookupFunction<_ReadStringC, _ReadStringDart>(
          'synheart_core_export_session_state',
        ),
      );
  late final int Function(Pointer<Void>, Pointer<Utf8>)? loadSessionState =
      _optional(
        'synheart_core_load_session_state',
        () => _lib.lookupFunction<_LoadStringC, _LoadStringDart>(
          'synheart_core_load_session_state',
        ),
      );
  late final Pointer<Utf8> Function(Pointer<Void>)? configId = _optional(
    'synheart_core_config_id',
    () => _lib.lookupFunction<_ReadStringC, _ReadStringDart>(
      'synheart_core_config_id',
    ),
  );
  late final Pointer<Utf8> Function(Pointer<Void>)? lastHsv = _optional(
    'synheart_core_last_hsv',
    () => _lib.lookupFunction<_ReadStringC, _ReadStringDart>(
      'synheart_core_last_hsv',
    ),
  );
  late final Pointer<Utf8> Function(Pointer<Void>)? attachStrainScoreJson =
      _optional(
        'synheart_core_attach_strain_score_json',
        () => _lib.lookupFunction<_ReadStringC, _ReadStringDart>(
          'synheart_core_attach_strain_score_json',
        ),
      );

  late final pushSleepStages = _lib.lookupFunction<_PushSleepC, _PushSleepDart>(
    'synheart_core_push_sleep_stages',
  );
  late final ingestBatch = _lib.lookupFunction<_IngestBatchC, _IngestBatchDart>(
    'synheart_core_ingest_batch',
  );

  // Personalization task / workout APIs .
  late final setTaskType = _lib.lookupFunction<_SetTaskTypeC, _SetTaskTypeDart>(
    'synheart_core_set_task_type',
  );
  late final pushWorkoutEvent = _lib
      .lookupFunction<_PushWorkoutEventC, _PushWorkoutEventDart>(
        'synheart_core_push_workout_event',
      );
  late final currentTaskType = _lib
      .lookupFunction<_CurrentTaskTypeC, _CurrentTaskTypeDart>(
        'synheart_core_current_task_type',
      );
  late final currentWorkoutKind = _lib
      .lookupFunction<_CurrentWorkoutKindC, _CurrentWorkoutKindDart>(
        'synheart_core_current_workout_kind',
      );
  late final setFocusKind = _lib
      .lookupFunction<_SetTaskTypeC, _SetTaskTypeDart>(
        'synheart_core_set_focus_kind',
      );
  late final currentFocusKind = _lib
      .lookupFunction<_CurrentTaskTypeC, _CurrentTaskTypeDart>(
        'synheart_core_current_focus_kind',
      );
  late final personalizationContextJson = _lib
      .lookupFunction<
        _PersonalizationContextJsonC,
        _PersonalizationContextJsonDart
      >('synheart_core_personalization_context_json');
  late final srmPushWearableDaily = _lib
      .lookupFunction<_SrmPushWearableDailyC, _SrmPushWearableDailyDart>(
        'synheart_core_srm_push_wearable_daily',
      );
  late final srmTriggerWearableRecompute = _lib
      .lookupFunction<_SrmTriggerRecomputeC, _SrmTriggerRecomputeDart>(
        'synheart_core_srm_trigger_wearable_recompute',
      );

  late final grantConsent = _lib.lookupFunction<_ConsentStrC, _ConsentStrDart>(
    'synheart_core_grant_consent',
  );
  late final revokeConsent = _lib.lookupFunction<_ConsentStrC, _ConsentStrDart>(
    'synheart_core_revoke_consent',
  );
  late final hasConsent = _lib.lookupFunction<_HasConsentC, _HasConsentDart>(
    'synheart_core_has_consent',
  );
  late final currentConsent = _lib
      .lookupFunction<_CurrentConsentC, _CurrentConsentDart>(
        'synheart_core_current_consent',
      );
  late final consentConfigureCloud = _lib
      .lookupFunction<_ConsentConfigureCloudC, _ConsentConfigureCloudDart>(
        'synheart_core_consent_configure_cloud',
      );
  late final consentGetEditableForm = _lib
      .lookupFunction<_CurrentConsentC, _CurrentConsentDart>(
        'synheart_core_consent_get_editable_form',
      );
  late final consentSubmitForm = _lib
      .lookupFunction<_ConsentSubmitFormC, _ConsentSubmitFormDart>(
        'synheart_core_consent_submit_form',
      );
  // Nullable: older native runtimes predate this symbol. The lookup throws when
  // the symbol is absent, so guard it and let the high-level API degrade to a
  // no-op (returns null) instead of crashing at load.
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)?
  recordStudyConsent = _optional(
    'synheart_core_record_study_consent',
    () => _lib.lookupFunction<_RecordStudyConsentC, _RecordStudyConsentDart>(
      'synheart_core_record_study_consent',
    ),
  );
  late final enrolStudy = _lib.lookupFunction<_EnrolStudyC, _EnrolStudyDart>(
    'synheart_core_enrol_study',
  );
  late final validateStudyCodes = _lib
      .lookupFunction<_EnrolStudyC, _EnrolStudyDart>(
        'synheart_core_validate_study_codes',
      );
  late final withdrawStudy = _lib
      .lookupFunction<_CurrentConsentC, _CurrentConsentDart>(
        'synheart_core_withdraw_study',
      );
  late final requestStudyDataDeletion = _lib
      .lookupFunction<_RequestStudyDeletionC, _RequestStudyDeletionDart>(
        'synheart_core_request_study_data_deletion',
      );
  late final researchStudyStatus = _lib
      .lookupFunction<_CurrentConsentC, _CurrentConsentDart>(
        'synheart_core_research_study_status',
      );
  late final consentClearStored = _lib
      .lookupFunction<_IntReturnC, _IntReturnDart>(
        'synheart_core_consent_clear_stored',
      );
  late final consentStatus = _lib
      .lookupFunction<_CurrentConsentC, _CurrentConsentDart>(
        'synheart_core_consent_status',
      );
  late final consentEffectiveState = _lib
      .lookupFunction<_CurrentConsentC, _CurrentConsentDart>(
        'synheart_core_consent_effective_state',
      );
  late final consentNeedsTokenRefresh = _lib
      .lookupFunction<_IntReturnC, _IntReturnDart>(
        'synheart_core_consent_needs_token_refresh',
      );

  late final loadCapabilityToken = _lib.lookupFunction<_LoadCapC, _LoadCapDart>(
    'synheart_core_load_capability_token',
  );

  late final listSessions = _lib.lookupFunction<_JsonReturnC, _JsonReturnDart>(
    'synheart_core_list_sessions',
  );
  late final getSessionSummary = _lib
      .lookupFunction<_SessionIdC, _SessionIdDart>(
        'synheart_core_get_session_summary',
      );
  late final getHsiWindows = _lib.lookupFunction<_HsiWindowsC, _HsiWindowsDart>(
    'synheart_core_get_hsi_windows',
  );

  // Device-signed Syni service API (runtime >= 0.21.0). Every symbol is
  // optional so linking an older runtime keeps the rest of Core usable; the
  // public Syni service client reports a typed unsupported error on access.
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)? syniChat =
      _optional(
        'synheart_core_syni_chat',
        () => _lib.lookupFunction<_SyniChatC, _SyniChatDart>(
          'synheart_core_syni_chat',
        ),
      );
  late final Pointer<Utf8> Function(Pointer<Void>, int)? syniListSessions =
      _optional(
        'synheart_core_syni_list_sessions',
        () => _lib.lookupFunction<_SyniListSessionsC, _SyniListSessionsDart>(
          'synheart_core_syni_list_sessions',
        ),
      );
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)?
  syniGetSession = _optional(
    'synheart_core_syni_get_session',
    () => _lib.lookupFunction<_SyniGetSessionC, _SyniGetSessionDart>(
      'synheart_core_syni_get_session',
    ),
  );
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, int)?
  syniGetSessionMessages = _optional(
    'synheart_core_syni_get_session_messages',
    () => _lib
        .lookupFunction<_SyniGetSessionMessagesC, _SyniGetSessionMessagesDart>(
          'synheart_core_syni_get_session_messages',
        ),
  );
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)?
  syniCloseSession = _optional(
    'synheart_core_syni_close_session',
    () => _lib.lookupFunction<_SyniGetSessionC, _SyniGetSessionDart>(
      'synheart_core_syni_close_session',
    ),
  );

  late final getStorageUsage = _lib
      .lookupFunction<_JsonReturnC, _JsonReturnDart>(
        'synheart_core_get_storage_usage',
      );

  late final recordMetric = _lib
      .lookupFunction<_RecordMetricC, _RecordMetricDart>(
        'synheart_core_record_metric',
      );

  late final deleteSession = _lib
      .lookupFunction<_DeleteSessionC, _DeleteSessionDart>(
        'synheart_core_delete_session',
      );
  late final closeOrphanSession = _lib
      .lookupFunction<_DeleteSessionC, _DeleteSessionDart>(
        'synheart_core_close_orphan_session',
      );
  late final wipeLocalData = _lib.lookupFunction<_WipeC, _WipeDart>(
    'synheart_core_wipe_local_data',
  );

  /// `POST /v1/customer/data-deletions` — request cloud-side deletion of every
  /// byte the platform holds for the currently-bound subject (the value
  /// derived from the `client_id` you passed to [registerDevice]). Returns
  /// the persisted request row as JSON; poll [getDataDeletion] for completion.
  late final requestDataDeletion = _lib
      .lookupFunction<_RequestDataDeletionC, _RequestDataDeletionDart>(
        'synheart_core_request_data_deletion',
      );
  late final getDataDeletion = _lib
      .lookupFunction<_GetDataDeletionC, _GetDataDeletionDart>(
        'synheart_core_get_data_deletion',
      );
  late final listDataDeletions = _lib
      .lookupFunction<_ListDataDeletionsC, _ListDataDeletionsDart>(
        'synheart_core_list_data_deletions',
      );

  /// Read the latest locally-persisted baseline envelope per kind for
  /// the configured subject. Returns `{snapshots: [...]}`. No network —
  /// pure on-device SQLite + decryption. Used by the
  /// auto-hydrate-on-init path so the typed baseline cache survives
  /// app cold starts.
  ///
  /// Optional symbol — null on older runtime binaries that don't
  /// export it. Bridge callers branch on null.
  ///
  /// Cross-device baseline transport rides the existing sync engine;
  /// there's no separate cloud-baseline FFI surface here.
  late final Pointer<Utf8> Function(Pointer<Void>)? baselineHydrateLocal =
      _optional(
        'synheart_core_baseline_hydrate_local',
        () => _lib
            .lookupFunction<_BaselineHydrateLocalC, _BaselineHydrateLocalDart>(
              'synheart_core_baseline_hydrate_local',
            ),
      );

  /// Encrypt every cached baseline envelope into an offline-export
  /// blob keyed by passphrase. Optional symbol — null on older
  /// runtime binaries without the offline export FFI.
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)?
  baselineExportOffline = _optional(
    'synheart_core_baseline_export_offline',
    () => _lib
        .lookupFunction<_BaselineExportOfflineC, _BaselineExportOfflineDart>(
          'synheart_core_baseline_export_offline',
        ),
  );

  /// Decrypt a `.srm.synheart` blob and import its envelopes.
  /// Optional symbol — null on older runtime binaries.
  late final Pointer<Utf8> Function(
    Pointer<Void>,
    Pointer<Utf8>,
    Pointer<Utf8>,
  )?
  baselineImportOffline = _optional(
    'synheart_core_baseline_import_offline',
    () => _lib
        .lookupFunction<_BaselineImportOfflineC, _BaselineImportOfflineDart>(
          'synheart_core_baseline_import_offline',
        ),
  );

  late final setRetentionDays = _lib
      .lookupFunction<_RetentionC, _RetentionDart>(
        'synheart_core_set_retention_days',
      );

  late final ingestVendorEvent = _lib
      .lookupFunction<_IngestVendorEventC, _IngestVendorEventDart>(
        'synheart_core_ingest_vendor_event',
      );
  late final queryVendorEvents = _lib
      .lookupFunction<_QueryVendorEventsC, _QueryVendorEventsDart>(
        'synheart_core_query_vendor_events',
      );
  late final getLatestVendorEvent = _lib
      .lookupFunction<_GetLatestVendorEventC, _GetLatestVendorEventDart>(
        'synheart_core_get_latest_vendor_event',
      );
  late final deleteVendorEventsForProvider = _lib
      .lookupFunction<_DeleteVendorEventsC, _DeleteVendorEventsDart>(
        'synheart_core_delete_vendor_events_for_provider',
      );

  late final setSyncEnabled = _lib.lookupFunction<_SetSyncC, _SetSyncDart>(
    'synheart_core_set_sync_enabled',
  );

  // Ambient capture gate. Drives whether the runtime forwards
  // out-of-session HSI windows to the host's hsi callback. Default off
  // — a host that never calls `setAmbientCapture` continues to behave
  // like the legacy session-only build. Returns `1` for on, `0` for
  // off; reuses `_SetSync*` typedefs because the wire shape is the
  // same `(handle, c_int)` pair.
  late final setAmbientCapture = _lib.lookupFunction<_SetSyncC, _SetSyncDart>(
    'synheart_core_set_ambient_capture',
  );
  late final getAmbientCapture = _lib.lookupFunction<_GetIntC, _GetIntDart>(
    'synheart_core_get_ambient_capture',
  );
  late final syncNow = _lib.lookupFunction<_SyncNowC, _SyncNowDart>(
    'synheart_core_sync_now',
  );
  late final syncCreateSpace = _lib
      .lookupFunction<_SyncCreateSpaceC, _SyncCreateSpaceDart>(
        'synheart_core_sync_create_space',
      );
  late final syncJoinSpace = _lib
      .lookupFunction<_SyncJoinSpaceC, _SyncJoinSpaceDart>(
        'synheart_core_sync_join_space',
      );
  late final syncGeneratePairing = _lib
      .lookupFunction<_SyncGeneratePairingC, _SyncGeneratePairingDart>(
        'synheart_core_sync_generate_pairing',
      );
  late final syncStatus = _lib.lookupFunction<_SyncStatusC, _SyncStatusDart>(
    'synheart_core_sync_status',
  );
  // Same C ABI as sync_status: `Pointer<Utf8> Function(Pointer<Void> h)`.
  late final syncReadiness = _lib.lookupFunction<_SyncStatusC, _SyncStatusDart>(
    'synheart_core_sync_readiness',
  );
  late final syncRecoverSpace = _lib
      .lookupFunction<_SyncRecoverSpaceC, _SyncRecoverSpaceDart>(
        'synheart_core_sync_recover_space',
      );
  late final syncLeaveSpace = _lib
      .lookupFunction<_SyncLeaveSpaceC, _SyncLeaveSpaceDart>(
        'synheart_core_sync_leave_space',
      );
  late final syncListDevices = _lib
      .lookupFunction<_SyncListDevicesC, _SyncListDevicesDart>(
        'synheart_core_sync_list_devices',
      );
  late final syncRevokeDevice = _lib
      .lookupFunction<_SyncRevokeDeviceC, _SyncRevokeDeviceDart>(
        'synheart_core_sync_revoke_device',
      );
  late final syncDeleteSpace = _lib
      .lookupFunction<_SyncDeleteSpaceC, _SyncDeleteSpaceDart>(
        'synheart_core_sync_delete_space',
      );

  late final syncClearLocalSpace = _lib
      .lookupFunction<_SyncClearLocalSpaceC, _SyncClearLocalSpaceDart>(
        'synheart_core_sync_clear_local_space',
      );

  late final baselinesJson = _lib.lookupFunction<_JsonReturnC, _JsonReturnDart>(
    'synheart_core_baselines_json',
  );
  late final exportSrmSnapshot = _lib
      .lookupFunction<_JsonReturnC, _JsonReturnDart>(
        'synheart_core_export_srm_snapshot',
      );
  late final loadSrmSnapshot = _lib
      .lookupFunction<_LoadSnapshotC, _LoadSnapshotDart>(
        'synheart_core_load_srm_snapshot',
      );

  // ── Batch nightly sleep score ──
  late final sleepScoreComputeJson = _lib
      .lookupFunction<_SleepScoreComputeC, _SleepScoreComputeDart>(
        'synheart_core_sleep_score_compute_json',
      );
  late final sleepScoreComputeJsonTraced = _lib
      .lookupFunction<_SleepScoreComputeTracedC, _SleepScoreComputeTracedDart>(
        'synheart_core_sleep_score_compute_json_traced',
      );

  // ── Daily recovery score ──
  // Same `(handle, input_json)` shape as sleep-score; reuse typedefs.
  late final recoveryScoreComputeJson = _lib
      .lookupFunction<_SleepScoreComputeC, _SleepScoreComputeDart>(
        'synheart_core_recovery_score_compute_json',
      );
  late final recoveryScoreComputeJsonTraced = _lib
      .lookupFunction<_SleepScoreComputeTracedC, _SleepScoreComputeTracedDart>(
        'synheart_core_recovery_score_compute_json_traced',
      );

  // ── Daily readiness score ──
  // Same `(handle, input_json)` shape; reuse typedefs.
  late final readinessScoreComputeJson = _lib
      .lookupFunction<_SleepScoreComputeC, _SleepScoreComputeDart>(
        'synheart_core_readiness_score_compute_json',
      );
  late final readinessScoreComputeJsonTraced = _lib
      .lookupFunction<_SleepScoreComputeTracedC, _SleepScoreComputeTracedDart>(
        'synheart_core_readiness_score_compute_json_traced',
      );
  late final attachSleepScoreJson = _lib
      .lookupFunction<_LoadSnapshotC, _LoadSnapshotDart>(
        'synheart_core_attach_sleep_score_json',
      );
  late final attachRecoveryScoreToday = _lib
      .lookupFunction<_AttachRecoveryScoreC, _AttachRecoveryScoreDart>(
        'synheart_core_attach_recovery_score_today',
      );
  late final clearRecoveryScoreToday = _lib
      .lookupFunction<_IntReturnC, _IntReturnDart>(
        'synheart_core_clear_recovery_score_today',
      );
  late final lastSleepScoreJson = _lib
      .lookupFunction<_JsonReturnC, _JsonReturnDart>(
        'synheart_core_last_sleep_score_json',
      );
  late final exportLongitudinalSnapshot = _lib
      .lookupFunction<_JsonReturnC, _JsonReturnDart>(
        'synheart_core_export_longitudinal_snapshot',
      );
  late final loadLongitudinalSnapshot = _lib
      .lookupFunction<_LoadSnapshotC, _LoadSnapshotDart>(
        'synheart_core_load_longitudinal_snapshot',
      );
  late final wearableReferenceJson = _lib
      .lookupFunction<_JsonReturnC, _JsonReturnDart>(
        'synheart_core_wearable_reference_json',
      );
  late final srmOverallStatus = _lib
      .lookupFunction<_JsonReturnC, _JsonReturnDart>(
        'synheart_core_srm_overall_status',
      );

  late final enqueueHsi = _lib.lookupFunction<_EnqueueC, _EnqueueDart>(
    'synheart_core_enqueue_hsi',
  );
  late final uploadQueueLength = _lib
      .lookupFunction<_IntReturnC, _IntReturnDart>(
        'synheart_core_upload_queue_length',
      );
  late final lastIngestSuccessAtMs = _lib
      .lookupFunction<_Int64ReturnC, _Int64ReturnDart>(
        'synheart_core_last_ingest_success_at_ms',
      );
  late final flushUploads = _lib.lookupFunction<_JsonReturnC, _JsonReturnDart>(
    'synheart_core_flush_uploads',
  );

  // Subject identity. `getSubjectId` returns the canonical RFC-0008 subject
  // (heap char* — free via coreFreeString). `rebindSubjectId` atomically
  // re-points consent + the cloud connector to a new subject mid-session.
  late final getSubjectId = _lib.lookupFunction<_JsonReturnC, _JsonReturnDart>(
    'synheart_core_get_subject_id',
  );
  late final rebindSubjectId = _lib
      .lookupFunction<_RebindSubjectC, _RebindSubjectDart>(
        'synheart_core_rebind_subject_id',
      );

  // hsi_history: on-device mirror of successfully uploaded HSI payloads.
  // Populated automatically by the ingest connector on HTTP 200; pruned
  // by age (default 30 days).
  late final hsiHistoryList = _lib
      .lookupFunction<_HsiHistoryListC, _HsiHistoryListDart>(
        'synheart_core_hsi_history_list',
      );

  // Cloud HSI fetch: (handle, from_unix_ms, to_unix_ms) -> char* (JSON array of
  // normalized HSIState records). Same C signature as hsi_history list, so it
  // reuses the _HsiHistoryList* typedefs.
  late final fetchCloudHsi = _lib
      .lookupFunction<_HsiHistoryListC, _HsiHistoryListDart>(
        'synheart_core_fetch_cloud_hsi',
      );
  late final hsiHistoryCount = _lib
      .lookupFunction<_Int64ReturnC, _Int64ReturnDart>(
        'synheart_core_hsi_history_count',
      );
  late final hsiHistoryClear = _lib.lookupFunction<_IntReturnC, _IntReturnDart>(
    'synheart_core_hsi_history_clear',
  );
  late final uploadMetadata = _lib
      .lookupFunction<_JsonReturnC, _JsonReturnDart>(
        'synheart_core_upload_metadata',
      );

  late final wellnessJson = _lib.lookupFunction<_JsonReturnC, _JsonReturnDart>(
    'synheart_core_wellness_json',
  );

  late final lastFeatures = _lib.lookupFunction<_JsonReturnC, _JsonReturnDart>(
    'synheart_core_last_features',
  );
  late final diagnostics = _lib.lookupFunction<_JsonReturnC, _JsonReturnDart>(
    'synheart_core_diagnostics',
  );
  late final lastErrorCode = _lib.lookupFunction<_IntReturnC, _IntReturnDart>(
    'synheart_core_last_error_code',
  );
  late final isRuntimeAvailable = _lib
      .lookupFunction<_IntReturnC, _IntReturnDart>(
        'synheart_core_is_runtime_available',
      );
  late final isNetworkReachable = _lib
      .lookupFunction<_IntReturnC, _IntReturnDart>(
        'synheart_core_is_network_reachable',
      );

  late final requestAccountDeletion = _lib
      .lookupFunction<_AccountActionC, _AccountActionDart>(
        'synheart_core_request_account_deletion',
      );
  late final cancelAccountDeletion = _lib
      .lookupFunction<_AccountActionC, _AccountActionDart>(
        'synheart_core_cancel_account_deletion',
      );

  // HSI callback
  late final setHsiCallback = _lib
      .lookupFunction<
        Void Function(
          Pointer<Void>,
          Pointer<NativeFunction<Void Function(Pointer<Utf8>, Pointer<Void>)>>,
          Pointer<Void>,
        ),
        void Function(
          Pointer<Void>,
          Pointer<NativeFunction<Void Function(Pointer<Utf8>, Pointer<Void>)>>,
          Pointer<Void>,
        )
      >('synheart_core_set_hsi_callback');

  late final clearHsiCallback = _lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('synheart_core_clear_hsi_callback');

  // Stream (RAMEN vendor sync)
  late final streamStart = _lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf8>),
        int Function(Pointer<Void>, Pointer<Utf8>)
      >('synheart_core_stream_start');

  late final streamStop = _lib
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('synheart_core_stream_stop');

  late final setStreamCallback = _lib
      .lookupFunction<
        Void Function(
          Pointer<Void>,
          Pointer<NativeFunction<Void Function(Pointer<Utf8>, Pointer<Void>)>>,
          Pointer<Void>,
        ),
        void Function(
          Pointer<Void>,
          Pointer<NativeFunction<Void Function(Pointer<Utf8>, Pointer<Void>)>>,
          Pointer<Void>,
        )
      >('synheart_core_set_stream_callback');

  late final streamState = _lib
      .lookupFunction<
        Pointer<Utf8> Function(Pointer<Void>),
        Pointer<Utf8> Function(Pointer<Void>)
      >('synheart_core_stream_state');

  // Lab
  late final labStart = _lib.lookupFunction<_LabStartC, _LabStartDart>(
    'synheart_core_lab_start',
  );
  late final labOpenWindow = _lib
      .lookupFunction<_LabOpenWindowC, _LabOpenWindowDart>(
        'synheart_core_lab_open_window',
      );
  late final labCloseWindow = _lib
      .lookupFunction<_LabCloseWindowC, _LabCloseWindowDart>(
        'synheart_core_lab_close_window',
      );
  late final labSetWindowValues = _lib
      .lookupFunction<_LabSetWindowValuesC, _LabSetWindowValuesDart>(
        'synheart_core_lab_set_window_values',
      );
  late final labMergeExtraData = _lib
      .lookupFunction<_LabMergeExtraDataC, _LabMergeExtraDataDart>(
        'synheart_core_lab_merge_extra_data',
      );
  late final labSetStateOverrides = _lib
      .lookupFunction<_LabSetStateOverridesC, _LabSetStateOverridesDart>(
        'synheart_core_lab_set_state_overrides',
      );
  late final labFinalize = _lib.lookupFunction<_LabFinalizeC, _LabFinalizeDart>(
    'synheart_core_lab_finalize',
  );
  late final labAvailable = _lib
      .lookupFunction<_LabAvailableC, _LabAvailableDart>(
        'synheart_core_is_lab_available',
      );
  late final labExportJson = _lib.lookupFunction<_JsonReturnC, _JsonReturnDart>(
    'synheart_core_lab_export_json',
  );
  // Re-enqueue a previously-finalized lab session for upload (engine
  // v0.8.1+). Optional lookup so older runtime binaries that don't
  // export the symbol don't break the bridge — caller checks for null
  // before invoking.
  late final int Function(Pointer<Void>, Pointer<Utf8>)? labReenqueueSession =
      _optional(
        'synheart_core_reenqueue_lab_session',
        () => _lib.lookupFunction<_LabReenqueueC, _LabReenqueueDart>(
          'synheart_core_reenqueue_lab_session',
        ),
      );
  // Lab metadata. Optional: older runtimes may not export these, in which case
  // the lookup throws and the field stays null.
  late final Pointer<Utf8> Function(
    Pointer<Void>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
  )?
  labEnsureMetadata = _optional(
    'synheart_core_lab_ensure_metadata',
    () => _lib.lookupFunction<_LabEnsureMetadataC, _LabEnsureMetadataDart>(
      'synheart_core_lab_ensure_metadata',
    ),
  );
  late final int Function(Pointer<Void>, Pointer<Utf8>)? labMarkMetadataDirty =
      _optional(
        'synheart_core_lab_mark_metadata_dirty',
        () => _lib
            .lookupFunction<_LabMarkMetadataDirtyC, _LabMarkMetadataDirtyDart>(
              'synheart_core_lab_mark_metadata_dirty',
            ),
      );
  late final Pointer<Utf8> Function(Pointer<Void>)? labCurrentMetadataId =
      _optional(
        'synheart_core_lab_current_metadata_id',
        () => _lib.lookupFunction<_JsonReturnC, _JsonReturnDart>(
          'synheart_core_lab_current_metadata_id',
        ),
      );

  // Version / frame diagnostics
  late final Pointer<Utf8> Function()? version = _optional(
    'synheart_core_version',
    () => _lib.lookupFunction<_VersionC, _VersionDart>('synheart_core_version'),
  );
  late final frameCount = _lib.lookupFunction<_Int64ReturnC, _Int64ReturnDart>(
    'synheart_core_frame_count',
  );
  // NOTE: there is deliberately no `lastQuality` binding. The runtime exports
  // `synheart_core_edge_last_quality` (edge/watch variant only) and has never
  // exported a non-edge `synheart_core_last_quality`, so the lookup always
  // fell into its `catch (_) => null` and every caller read a hardcoded 0.0.
  // Removed in 0.10.2 along with the `runtimeDiagnostics()['lastQuality']`
  // key. Re-add both together if the symbol is ever exported non-edge.

  // ── Multi-source priority resolver ────────────────────────────────
  // All four symbols are nullable because they ship in the native runtime
  // in newer runtimes only; older ones resolve to null and the Dart API
  // falls back to a pure-Dart in-memory store.

  late final int Function(Pointer<Utf8>, int)? prioritySetProvider = _optional(
    'synheart_core_priority_set_provider',
    () => _lib.lookupFunction<_PrioritySetProviderC, _PrioritySetProviderDart>(
      'synheart_core_priority_set_provider',
    ),
  );

  late final int Function(Pointer<Utf8>, Pointer<Utf8>, int, int)?
  prioritySetMetricOverride = _optional(
    'synheart_core_priority_set_metric_override',
    () =>
        _lib.lookupFunction<
          _PrioritySetMetricOverrideC,
          _PrioritySetMetricOverrideDart
        >('synheart_core_priority_set_metric_override'),
  );

  late final int Function(Pointer<Utf8>, Pointer<Utf8>)? priorityEffectiveRank =
      _optional(
        'synheart_core_priority_effective_rank',
        () =>
            _lib.lookupFunction<
              _PriorityEffectiveRankC,
              _PriorityEffectiveRankDart
            >('synheart_core_priority_effective_rank'),
      );

  late final Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)?
  priorityResolve = _optional(
    'synheart_core_priority_resolve',
    () => _lib.lookupFunction<_PriorityResolveC, _PriorityResolveDart>(
      'synheart_core_priority_resolve',
    ),
  );

  // ── HRV-CV resilience score ───────────────────────────────────────
  // Stateless. Nullable for graceful version fallback.

  late final Pointer<Utf8> Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
  )?
  resilienceComputeV1 = _optional(
    'synheart_core_resilience_compute_v1',
    () => _lib.lookupFunction<_ResilienceComputeC, _ResilienceComputeDart>(
      'synheart_core_resilience_compute_v1',
    ),
  );

  // ── Apple Health XML backfill ─────────────────────────────────────
  // Same nullable pattern.

  late final int Function(Pointer<Utf8>, Pointer<Utf8>)? backfillOpen =
      _optional(
        'synheart_core_backfill_open',
        () => _lib.lookupFunction<_BackfillOpenC, _BackfillOpenDart>(
          'synheart_core_backfill_open',
        ),
      );

  late final Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)?
  backfillInsertBatch = _optional(
    'synheart_core_backfill_insert_batch',
    () => _lib.lookupFunction<_BackfillInsertBatchC, _BackfillInsertBatchDart>(
      'synheart_core_backfill_insert_batch',
    ),
  );

  late final Pointer<Utf8> Function(Pointer<Utf8>)? backfillFinalize =
      _optional(
        'synheart_core_backfill_finalize',
        () => _lib.lookupFunction<_BackfillFinalizeC, _BackfillFinalizeDart>(
          'synheart_core_backfill_finalize',
        ),
      );
}
