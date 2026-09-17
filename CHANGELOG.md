# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed — data correctness

- **Accelerometer samples were pushed in m/s² into an API that takes g**, so
  every sample reached the engine ~9.81x too large. `synheart_behavior`'s
  `MotionSample` is documented as m/s² with gravity included (Android's raw
  `TYPE_ACCELEROMETER`); the engine's `push_accel` takes **g** and multiplies by
  `9.80665` internally. A phone at rest reported ~9.81 and the engine stored
  ~96 m/s². It cleared the runtime's own ±50 sanity gate because that gate runs
  on the pre-multiply value, so nothing ever complained.

  The SDK now converts at the push boundary. What this was breaking:
  `activity_state` and `locomotion_state` (magnitude and jerk cut-points were
  all off by the same factor), the RulePack still-gate — which never saw
  stillness, so **no personal physiological baseline could accumulate at all**
  — and any host reading `meta.synheart.motion.accel_rms` back out for its own
  rest detection, which could never satisfy a low-motion clause. `postural_state`
  was unaffected (APE is an angle, and angles are scale-invariant).

### Added — the context evidence channel

- **`ContextEventInput`** — typed payloads for `push_context_event`, the channel
  that feeds the person-relative context window and so `context.deviation.*`.
  Those deviations are the only source of Cognitive Load's friction index
  (CFI), and before this the mobile stack pushed nothing onto this channel, so
  `pause_elevation`, `err_elevation` and `scroll_deviation` were structurally
  zero on every window regardless of how much the person interacted.

  It is a **second** channel, not an alternative to `pushBehaviorEvent`: the two
  write to different runtime buffers with different consumers, so one event on
  each per user action is correct and is not a double count.

- **BREAKING: `Synheart.pushContextEvent` now takes a `ContextEventInput`**
  instead of a `Map<String, dynamic>`. Existing call sites fail to compile
  rather than warn; that is deliberate, because the old map form documented
  a shape the runtime **never accepted**, so every such call site is a call
  site that was silently doing nothing. The shape it documented was
  `{ts_ms, app_id, category}`; the runtime instead
  deserializes this channel into an externally-tagged keyboard / pointer /
  shortcut enum with no app-category variant, so every such push was rejected.
  The failure was invisible: a rejected payload returns the same `1` as a
  runtime built without the `app-context` cargo feature. The raw escape hatch
  is now `Synheart.pushContextEventJson(Map)`.

  The wire shape is pinned against the runtime's documented form by
  `test/context_event_input_test.dart`, because getting it wrong is silent.

- The SDK **derives context events from native gestures automatically** —
  scroll to `Mouse`/`Scroll` with its direction, swipe to `Mouse`/`Move` with a
  distance. Native taps are deliberately **not** forwarded: Android's input
  collector reports every keystroke as a `tap`, so forwarding them would
  inflate `N_click` with typing while leaving `N_key` — the denominator of
  `err_rate = N_corr / N_key` — at zero. Keyboard evidence must come from the
  host's text layer via `ContextEventInput.textChange`, which is the only place
  an insertion can be told from a deletion. Send **both** directions.

### Added — foreground app identity

- **`BehaviorEventInput.appForeground(tsMs, app)`** and
  **`Synheart.pushAppForeground(app)`** — the foreground *resolve*, as opposed
  to the `appSwitch` *edge*. This kind had no Dart factory at all, which meant
  app identity could not reach the engine by any route: `app_switch` only fires
  on a transition, and the native collector reports both of its ids as null.

  With no identity the runtime's `current_app` stays `None`, `None` resolves to
  the `Unknown` app category, and `Unknown`'s interpretation-mask row is **all
  zeros** — so CFI / Cognitive Load, Stress `B`, Mental Fatigue `B` and Focus's
  deviation sub-terms all read `0` for a person who was working the whole time.

- **`ForegroundAppReporter`** runs the resolve for the life of a session: once
  at session start, then on a 30 s heartbeat (shorter than the default 60 s HSI
  window, so no window goes without an identity). It is gated on app lifecycle
  by an `AppLifecycleListener` the SDK owns: the heartbeat stops on
  `hidden` / `paused` / `detached` and resumes with an immediate resolve on
  `resumed`, because the default source names *this* app and continuing to
  assert it from the background is worse than silence — the engine would
  attribute another app's window to this one. `inactive` is deliberately not
  a stop: a call banner or the app switcher is not leaving. A headless host
  with no bound `WidgetsBinding` logs once and runs ungated, which is correct
  there since it has no foreground to leave. Repeats are safe — the
  engine treats an unchanged app as a steady-state observation and does not bump
  the switch count, so a heartbeat cannot fabricate fragmentation.

- **`BehaviorConfig.reportForegroundApp`** (default `true`),
  **`foregroundAppId`**, and **`foregroundAppSource`**. The default source
  reports the host's own application id, resolved from `foregroundAppId`, else
  `DeviceAuthConfig.packageName`, else `SynheartConfig.appId` when it looks like
  a package name rather than a Synheart-issued `app_…` id. Implement
  `ForegroundAppSource` over Android's `UsageStatsManager` (permission
  `PACKAGE_USAGE_STATS`) to report what is *actually* in front; iOS exposes no
  equivalent API, so the self-report is the ceiling there.

### Added — the daily loop

- **`Synheart.attachStrainScore()`**, binding
  `synheart_core_attach_strain_score_json`. This symbol had no Dart binding, and
  `rollDay` does not score for you — it validates the index and folds the day
  into the longitudinal baselines, and that fold **clears the values Strain is
  computed from**. So a host that rolled without attaching first got no Strain
  score, ever, while the load itself still reached the baselines: nothing looked
  broken except a score that was always absent. Call it **before** `rollDay`.

### Changed

- `TypingSessionData`'s documentation no longer claims `number_of_backspace` /
  `number_of_delete` feed CFI. They feed `TypingFluency`; CFI's correction
  sub-component reads `context.deviation.err_elevation`, which comes from the
  context channel. The advice to send them was right, the reason was wrong, and
  it would have sent someone hunting in the wrong place.

### Example app

- The `push_context_event` demo sent the payload shape that never parsed. It is
  now two buttons for the two real channels — declare foreground app, push a
  context event — with the counters separated.
- The typing probe now pushes a keyboard context event per change alongside its
  windowed summary, so CFI has a correction rate with a real denominator.
- `_rollDayIfNeeded` attaches the Strain score before rolling.
- A **lateness budget is now declared unconditionally** when the host profile is
  declared. It is not optional for this host: the engine's HSI window is aligned
  to the first signal rather than to a fixed grid, so a host aggregating into
  its own fixed-grid micro-windows has one micro-window straddle every HSI
  boundary — stamped before it, flushed after it, accepted by the ingest gate
  and then read by no window. That is ~1/6 of the typing evidence lost every
  window with no counter to show it. Declaring a budget requires declaring a
  sensing *mode* too, because `parse_sensing` accepts `"auto"` only as a
  top-level string; the mode now defaults to continuous on Android and episodic
  on iOS, matching what the toggle already asserts.

## [0.13.0] - 2026-09-04

### Changed — BREAKING

- Potentially blocking Device Sync APIs now return
  `Future<Map<String, dynamic>?>` and execute their native FFI work on a
  tracked background isolate:
  `syncCreateSpace`, `syncGeneratePairing`, `syncJoinSpace`,
  `syncRecoverSpace`, `syncLeaveSpace`, `syncListDevices`,
  `syncRevokeDevice`, `syncDeleteSpace`, and `syncClearLocalSpace`. Callers
  must `await` these methods. Sync operations are serialized per runtime
  handle so lifecycle mutations, roster reads, and `syncNow` cannot race.
  Fast local status and readiness snapshots remain synchronous.

### Added

- Core v0.24 device identity lifecycle support: `Synheart.reattestDeviceAuth()`
  refreshes attestation without rotating the installed device identity, and
  `Synheart.logoutDeviceAuth()` clears that identity and its sync membership.
  Instance-based hosts can use `reattestDevice()` and `logoutDevice()`.
  The new native operations require Core v0.24 ABI support.
- `Synheart.ensureDeviceAuthRegisteredOrThrow()` preserves typed native
  failures, including account mismatch, so hosts can route recovery correctly.

### Changed

- `Synheart.logout()` now awaits native device logout before wiping local SDK
  data and revoking consent. Hosts must await it before removing their own
  account credentials. Older runtimes retain the legacy local-wipe fallback.
- `reregisterDeviceAuth()` is deprecated in favor of `reattestDeviceAuth()`.
  Registration is for first-time setup; repair preserves the existing identity.

### Fixed

- Coalesce concurrent device-auth initialization and serialize native
  registration, re-attestation, logout, and sync operations per runtime handle.
- Compare restored and configured canonical subjects to avoid treating a
  restored identity as a different account and registering it again.
- Preserve typed native identity errors instead of masking them with the
  unsigned development fallback; surface device-auth worker failures explicitly.
- Keep native handles alive until tracked background FFI calls finish during
  disposal, preventing use-after-free while sync work is in flight.

## [0.12.0] - 2026-08-24

### Added

- Device-signed, non-streaming Syni chat and session APIs under
  `Synheart.syni?.service`: chat, list/get sessions, list messages, and close.
- Typed Syni service responses/errors, sticky session continuity, serialized
  chat turns, and delivery-unknown signaling for safe reconciliation. The
  service requires a native Core runtime that exports the
  `synheart_core_syni_*` ABI (runtime 0.21.0 or newer); older runtimes remain
  usable and report the service as unavailable.

## [0.11.1] - 2026-08-20

### Fixed

- Android `compileSdk` raised from 34 to 36. The package sat below the
  compileSdk of the plugins it ships alongside and below Flutter's own default,
  which made it the odd one out in any consumer's build graph.

  This does **not** change the minimum supported Android version: `minSdk`
  stays at 24. `compileSdk` is what the module is built against, not what it
  requires at runtime.

  **If your build fails with `requires libraries and applications that depend on
  it to compile against version 36 or later`, upgrading this package alone will
  not fix it.** That check runs per consuming module, and the artifacts naming
  it are transitive AndroidX dependencies (`androidx.health.connect`,
  `androidx.browser`, `androidx.core`) pulled in by the sibling plugins. Your
  app module needs the newer compileSdk:

  ```kotlin
  // android/app/build.gradle.kts
  compileSdk = flutter.compileSdkVersion   // 36 on current Flutter
  ```

## [0.11.0] - 2026-08-14

### Changed — BREAKING

- The SDK no longer carries a built-in API host. `ApiEndpoints.defaultBaseUrl`
  was `https://api.synheart.ai`; it now defaults to empty and comes from
  `SYNHEART_BASE_URL`. Publishing a company host inside every copy of the
  package made it the destination for any build that forgot to name one,
  including forks and self-hosted deployments.

  **Action:** set `SYNHEART_BASE_URL` (dart-define, or
  `--dart-define-from-file`) on any build that talks to the cloud. Apps that
  already set it are unaffected.

  With nothing configured, `api_base_url` is now **omitted** from the runtime
  config rather than sent empty, and the native runtime applies its own
  default. `apiBaseUrlConfigured(config)` reports whether an explicit origin was
  supplied.

### Added

- `HSIAxes.focusQuality`, `interruptionPressure`, `interactionMode` and
  `hasDigital`, parsed from `axes.digital[]`. These are derived from interaction
  rather than physiology, so they resolve on hardware with no biosignal source.
  Previously the whole domain was discarded at the parse boundary.
- `SyncNativeError.reason`, `retryAfterMs` and `detail`, with
  `isUnsupported` / `isMisconfigured` / `isPolicyRefusal`. `reason` now appears
  in `toString()`.
- `doc/INTEGRATION.md` — ordered walkthrough from platform prerequisites to
  first upload.

### Fixed

- `startSession()` reported success when the native runtime failed to open a
  session. A null native result fell through to the Dart-only path, minting a
  `core_<millis>` handle — so the host saw a session id and a `collecting`
  state for a session the runtime never opened, with no HSI and no error. It now
  throws a `StateError`; the Dart-only path is reached only when no native
  runtime is present.
- `flushIfEligible` reported "cloudUpload consent not granted" whenever
  `hasConsent` returned false. Once cloud is configured the runtime denies every
  consent type until a consent token is issued, so the message blamed a consent
  screen that was already correct. It now names the real cause.
- `hasConsent` accepts either consent-key spelling; the Dart fallback path only
  understood camelCase.
- The Syni cloud origin resolved through a hard-coded literal instead of
  `ApiEndpoints`, overriding `SYNHEART_BASE_URL` for that one caller.


Hardening release from a full-repo review. No new features.

Released as a MINOR, not a patch: this removes and changes public API, and
`^0.10.1` would have resolved a patch automatically into apps that use it.

**Headline:** the SDK could not initialise at all without cloud credentials.
`initialize()` returned a null native runtime — no HSI, no consent store, no
storage — and then logged "Initialization complete". Local-only operation, a
documented configuration, has never worked in this line until now.

### Fixed

- **Local-only initialization was completely broken.** `_configure` hardcoded
  `ingest: {enabled: true, ...}`, so a host with no `CloudConfig` failed inside
  `synheart_core_new` with `ERR_NOT_CONFIGURED: cloud connector org_id must not
  be empty when HSI ingest is enabled`. The handle came back null and the SDK
  continued as if nothing were wrong. `device_auth.enabled` was hardcoded the
  same way, making the runtime reject crypto-callback registration with a
  misleading ERROR for every local-only host. Both are now gated on being
  configured. Hosts that supply a `CloudConfig` with an `orgId`, or a
  `DeviceAuthConfig`, are unaffected — the gates evaluate to the previous
  values.
- **A dev build with no dart-defines silently talked to production.**
  `SyncConfig.baseUrl` defaults to `ApiEndpoints.defaultAuthBaseUrl`, a const
  alias for the `SYNHEART_AUTH_BASE_URL` define, which is empty unless set. The
  empty value made the runtime fall back to its own hardcoded production URL.
  `api_base_url` is now resolved explicitly through `resolvedAuthBaseUrl`. Same
  endpoint, no longer by accident.
- **Packaging: the published archive was 70 MB and contained the proprietary
  native runtime.** `.pubignore` replaces `.gitignore` for publishing, so the
  `.gitignore` rules covering `ios/SynheartCoreRuntime.xcframework` (a symlink
  the podspec creates into the consumer app — pub follows it) and
  `example/synheart/vendor/` did not apply. The archive carried both framework
  slices plus their dSYM DWARF blobs. Now ~610 KB, with a CI check that fails
  the publish job if native artifacts or an oversized archive reappear.
- **`flushUploads` blocked the UI isolate.** The native call performs its HTTP
  round-trip under `block_on`; it now runs on a background isolate like every
  other network-touching FFI call in the bridge.
- **A failed `initialize()` could never be retried.** The init completer was
  left in place after an error, so every subsequent call received the same
  failed future — a transient cause was permanent short of `dispose()`.
- **HSI reached only the `onHsi` callback, never `onHSIUpdate` /
  `onStateUpdate`,** for hosts pushing through `pushWearHr` /
  `pushVendorHrv`. Both producers now share one consent-gated delivery path.
  (The long-standing claim that the native callback "doesn't fire on iOS" no
  longer holds against runtime 0.19.2 — verified on device — which is why that
  path needs the duplicate suppression below.)
- **Duplicate HSI delivery.** `ingest_batch_json` BOTH broadcasts on the
  runtime's `state_tx` — which drives `setHsiCallback` — and returns the same
  payload to Dart. With both producers wired to one delivery path, every window
  completed by a per-event push arrived twice: double `onHSIUpdate` /
  `onStateUpdate`, double session-buffer entries, double downstream counters.
  Now suppressed by `HsiDeliveryDeduper` on `meta.ids.hsi_id`
  (RFC-IDENTITY-0001), the same key the runtime's own ingest connector dedupes
  on. It keeps a bounded set of recent ids rather than a single last-id slot,
  because the producers do not always interleave as `A, A` — the sync return
  and the async callback can be separated by a background-tick window, giving
  `A, B, A`. A payload without an id is delivered rather than dropped: losing a
  window is worse than repeating one.
- **A session could start with nothing able to collect.** The runtime path of
  `startSession()` performed none of the checks the Dart fallback path did.
  `startSession()` now requires at least one enabled feature whose matching
  consent is granted — both halves of a pair. Consent alone is not enough:
  enabling only `wearConfig` while granting only `behavior` leaves wear
  permitted-but-not-enabled and behavior enabled-but-not-permitted, so nothing
  collects. Cloud upload, vendor sync, research and syni never qualify; they
  govern what happens to data once gathered.
- **Session buffers grew without bound.** `getSessionHsiWindows()` and
  `getSessionWearSamples()` retained every entry for the session's life (24h by
  default) and cleared only on the next `startSession()`. Both are now capped
  ring buffers — see `maxSessionHsiWindows` / `maxSessionWearSamples`.
- **`isSessionRunning` ignored the runtime.** It returned the Dart module flag;
  the runtime's own `is_running` was never read anywhere in the SDK. A session
  ending natively left hosts reporting "collecting" indefinitely. It now
  prefers the runtime, falling back to the Dart flag when the bridge is absent.
- **Configuration errors named a field but not a fix.** `validate()` threw bare
  assertions like "appId must not be empty". The messages now say what to set,
  what a good value looks like, and why — including that passing `userId:` to
  `initialize()` does **not** populate `config.subjectId`, which is the most
  common way to hit the error. Failures are also logged before the throw, since
  hosts commonly catch and render a short toast that discards the detail.
- **One failing module killed the whole session, and orphaned a native one.**
  `ModuleManager.startAll()` awaited `module.start()` unguarded, so the first
  throw ended the loop and every later module was skipped —
  `initializeAll()` and `stopAll()` were already per-module resilient.
  Modules start wear-first, so on an iOS build without the HealthKit
  entitlement *nothing* started rather than everything-but-biosignals.
  Separately, `startSession()` opened the native session before starting
  modules, so a throw escaped leaving a session the host did not know about;
  the next call then got `SessionActive`, returned null, and fell through to
  the Dart-only path with a `core_<ts>` handle for a session the runtime never
  opened. `startAll()` is now resilient and reports `moduleId -> error`, and
  `startSession()` rolls the native session back on failure.
- `runtimeDiagnostics()['lastQuality']` always reported `0.0`; it read a native
  symbol the runtime has never exported outside the edge variant. Removed.

### Added

- **`runtimeDiagnostics()['missingSymbols']`** — optional native symbols the
  loaded runtime does not export. ~20 lookups previously failed silently, so a
  runtime one release behind disabled recovery scores, readiness, breathing,
  backfill, priority resolution, data deletion, research enrolment, sync-space
  management and cloud HSI fetch with nothing in the logs. Each miss now logs
  once, naming the symbol.
- **`runtimeDiagnostics(probeAll: true)`** and `probedSymbols`. Optional
  bindings resolve lazily, so a diagnostics screen reading `missingSymbols`
  before anything used those features reports an empty list and looks healthy
  while having checked nothing. `probeAll` forces a full audit. Note the list
  covers only the guarded bindings: most lab ABI calls are bound eagerly and
  throw on first access when absent — check `isLabAvailable` before using them.
- `HSIState.parseError` / `hasParseError` — a parse failure previously returned
  empty axes, indistinguishable from a window the engine had not populated.
- `buildRuntimeConfigMap` (internal) — one source of truth for the JSON handed
  to `synheart_core_new`, replacing three drifting copies, and unit-testable
  without a native runtime.

### Changed

- **BREAKING (direct `CoreRuntimeBridge` users only):**
  `CoreRuntimeBridge.flushUploads()` returns `Future<Map<String, dynamic>?>`.
  Add `await`. `Synheart.ingestion` callers are unaffected.
- `Synheart.deleteCloudData()` now throws `UnsupportedError`. It never deleted
  anything — it logged twice and returned — so a host could have wired it to a
  "delete my cloud data" control and shipped a promise the SDK did not keep.
  Use `requestDataDeletion()` and `wipeLocalData()`.
- `getSyncStatus()` reflects real engine/config state instead of a hardcoded
  `false`.
- `WearModule(useSynheartWear: false)` now yields no sources instead of a mock.
- Error messages and doc comments no longer cite "native runtime 5.4.0+"; that
  scheme does not match the runtime's actual `0.x` versioning. They name the
  remedy (`synheart install runtime`) instead.

### Deprecated

The native runtime removed bundle-secret configuration as a security fix, and
these were never forwarded to it. All are scheduled for removal in 0.12.0.

- `SynheartConfig.capabilityToken`, `SynheartConfig.capabilitySecret`
- `CloudConfig.apiKey`, `ConsentConfig.appApiKey`
- `Synheart.deleteCloudData()`, `Synheart.getSyncStatus()`
- `Synheart.runtimeBaselineSummary` (duplicate of `runtimeBaselinesJson`)
- `WearModule(useSynheartWear:)`

### Removed

- **`MockWearSourceHandler`.** It synthesised heart rate, HRV, RR intervals and
  sleep stages from `Random()`. Those samples were indistinguishable from real
  ones downstream and fed the runtime's longitudinal baselines, so a host
  passing `useSynheartWear: false` silently corrupted the user's on-device
  reference ranges with invented numbers. `WearModule(sources:)` already
  accepts an injected handler, which is the supported way to supply a fake.
- `HsiWindowArtifact`, `TombstoneArtifact`, `CapabilityTokenFetcher` — no
  producers, consumers, or implementations.
- `ios/Runner/` (host-app scaffolding in a plugin package) and
  `ios/synheart_ffi_symbols.txt` (an ld64 keep-list referenced by nothing and
  68 symbols stale — obsolete since the runtime became a dynamic framework).
- A no-op `loadCapabilityToken('{}', secret)` call that could never load a
  capability.

### Example app

Rebuilt as a lean reference: 6,555 lines across 17 files and three competing
entry points, down to ~1,600 across 8.

- Consent now uses the canonical runtime editable-form flow
  (`consentGetEditableFormTyped` → `consentSubmitFormTyped` →
  `consentEffectiveStateTyped`). The old app drove the legacy Dart-side helpers
  that `SDK_CONSENT_FLOW.md` §7-G lists as superseded.
- No longer reaches into `package:synheart_core/src/`.
- Local-only by default — runs with no credentials.
- Never fabricates biosignals, and distinguishes sources that feed the runtime
  (wear, behavior) from ones that only collect locally (phone context).
- `example.dart`, the snippet pub.dev renders, previously omitted the required
  `appId`/`subjectId` and could not run.

## [0.10.1] - 2026-07-31

### Added
- `Synheart.pushRrBatch(...)` — push a batch of RR intervals anchored to a single
  timestamp, instead of one call per interval.
- Buffered runtime logging (`synheart_core_init_logging_buffered` + log drain) so
  runtime diagnostics survive a crash. Falls back gracefully when the vendored
  runtime does not export the symbols.

## [0.10.0] - 2026-07-29

### Changed
- Reorganized and updated the SDK documentation to match the current public API,
  configuration, native runtime layout, platform requirements, and examples.

## [0.9.0] - 2026-07-21

### Added
- `Synheart.recordStudyConsent(...)` — record a durable study-consent record via the core runtime (new `synheart_core_record_study_consent` FFI). Includes a matching `studyConsentPath` endpoint constant.

## [0.8.2] - 2026-07-07

### Fixed
- Sync the `synheartCoreVersion` constant with the package version; 0.8.1
  inadvertently shipped it as `0.8.0`.

## [0.8.1] - 2026-07-07

### Changed
- Widen the `synheart_wear` constraint to `>=0.4.0 <0.6.0` so the 0.5.x line
  resolves. `synheart_wear` 0.5.0 is additive and backward compatible (adds an
  optional per-request auth-header signer for the cloud providers), so the
  re-exported workout and provider surface is unchanged and no code updates are
  required.

## [0.8.0] - 2026-06-29

### Added
- **`Synheart.rebindSubjectId(subject)`** — rebind the subject when the signed-in
  identity changes: the native runtime atomically re-points consent and the cloud
  connector, then the SDK syncs its subject and re-mints cloud consent if needed —
  without a full dispose/reinit.

### Changed
- The native runtime is now the source of truth for the canonical subject id.
  `Synheart.subjectId` prefers the runtime's value (captured after init) over the
  configured one, and `consentTokenSubjectStale` compares against it.
- Subject FFI degrades softly: on a runtime build that predates the new symbols,
  subject sync/rebind fall back to the configured value instead of failing init.

## [0.7.3] - 2026-06-28

### Changed
- Bump `synheart_auth` to `^0.1.7`. This adds a 30-second timeout to Android
  Play Integrity device attestation (and pulls in the matching native-SDK
  timeouts). A stalled attestation — e.g. an `IntegrityService` bind that never
  resolves on a device without Play Store — now fails fast and falls through to
  the existing unsigned-capabilities path instead of leaving device
  registration hung.

## [0.7.2] - 2026-06-28

### Fixed
- **Cloud consent token is kept scoped to the current subject.** A consent token
  is issued for a specific `subjectId`; reusing one issued for a previous subject
  (e.g. a different signed-in account, or a token minted before the account was
  known) would attribute uploads to the wrong subject. `ensureCloudConsentReady`
  now treats a token whose `user_id` claim differs from the current `subjectId`
  as not-ready and reissues it for the current subject, and on (re)init the SDK
  self-heals by reissuing under the current subject so uploads resume immediately
  rather than waiting for the next consent change. Best-effort and idempotent —
  no behavior change for a stable, matching subject. Adds
  `Synheart.consentTokenSubjectStale()`.

## [0.7.1] - 2026-06-25

### Fixed
- **`syncNow` now runs on a background isolate.** It previously executed the
  blocking native sync (a network round-trip) inline on the calling isolate, so
  a slow or stalled sync froze that isolate until it completed or timed out.
  Routed through the same `Isolate.run` offload the other network-bound calls
  use; the public `Synheart.syncNow()` already returned a `Future`, so this is
  not an API change.

## [0.7.0] - 2026-06-17

### Added
- **`HSIAxes.stress`** — typed accessor for the engine's multimodal stress
  reading (engine v0.10.0; HSI 1.3 `axes.affective[].stress`). Hosts get a named
  field instead of digging through `rawJson`. Resolves to `null` on the legacy
  1.2 path that never carried it. Parity with the Kotlin/Swift bindings.
- **`EdgeIngest`** — canonical phone-side consumer of the Synheart edge wire
  contract (watch → phone).
  Pure Dart (no Flutter import), unit-tests under `dart test` / `flutter test`.
  Parses `hr_sample` / `bio_sample` / `hsi_artifact` / session events and, for
  artifacts, dedupes by `artifact_id`, verifies `payload_hash_sha256` ==
  sha256(`payload_json`), validates the inner `hsi_version` against the supported
  set, and produces the `artifact_ack` body. Public surface:
  - Sealed `EdgeEvent` family (`HrEvent | BioEvent | ArtifactEvent |
    SessionEventWrap`) plus the typed models (`HrSample`, `BioSample`,
    `HsiArtifact`, `Accel`) and the `EdgeOutcome` result family.
  - Reactive `events` broadcast `Stream<EdgeEvent>`, emitting in lock-step with
    the optional `EdgeIngestListener` callbacks (parity with the Kotlin
    `SharedFlow` and Swift `events` publisher).
  - ACK helpers `drainPendingAcks()` / `buildAckBody(...)` / `drainAckBody()`.
  - `dispose()` — Flutter-only lifecycle that closes the broadcast
    `StreamController` (idempotent). The Kotlin/Swift hot streams have no
    equivalent. Hosts using `EdgeIngest.events` must call `dispose()` when done.
  - The Kotlin-only `onUnsupportedHsiVersion` / `onHashMismatch` hooks are folded
    into the `EdgeOutcome` return value (`ArtifactHashMismatch`) and logging, plus
    the optional poison-pill / dead-letter hook
    `EdgeIngestListener.onPoisonPill(artifactId, expected, actual, attempts)`.
  - Delivery hardening (the watch outbox is delete-on-ACK):
    - **Duplicate re-ack** — a duplicate `artifact_id` is not re-surfaced
      (`ArtifactDuplicate`) but is re-queued for ACK, so a lost ACK no longer
      makes the watch resend forever.
    - **Bounded dedupe set** — the seen-artifact set is a bounded LRU
      (`seenLruCapacity`), keeping memory flat over a long-lived process.
    - **Poison-pill dead-letter** — an artifact that fails hash verification
      `poisonPillThreshold` (3) times for the same id is dead-lettered
      (`ArtifactDeadLettered`, the `onPoisonPill` hook, and ack-to-discard) so a
      deterministically-corrupt artifact stops blocking the outbox.

### Notes
- **Requires the Synheart Runtime.** This package is a thin Flutter wrapper; the
  on-device logic lives in the Synheart Runtime native binary, which is installed
  separately via the Synheart CLI (`synheart install runtime`). See the README's
  "Native Runtime Setup".

## [0.6.3] - 2026-06-07

### Added
- `Synheart.requestStudyDataDeletion({bool dryRun})`: request erasure of the data
  the participant contributed to their study for this app — the deletion the
  consent copy promises alongside withdrawal. No identifiers are passed; the
  participant and app come from the device's signed cloud credential. `dryRun`
  returns an inventory preview without deleting; a real request is accepted
  asynchronously and carries a `request_id`. Idempotent.

## [0.6.2] - 2026-06-07

### Added
- Research-study enrolment API: `Synheart.enrolResearchStudy(...)`,
  `Synheart.validateResearchStudyCodes(...)`, and `Synheart.withdrawResearchStudy()`.
  Enrolment rides the device's signed cloud credential — no tokens are handled by
  the app. Withdrawal is idempotent.
- `DeviceAuthConfig.packageName`: the app's package / bundle id, passed through so
  device registration can be bound to the app. Optional (defaults to empty).

## [0.6.1] - 2026-05-24

### Added
- **Consent surface for Syni.** `ConsentForm.syni`, the parameter
  `Synheart.grantConsent(..., syni: bool)`, and `ConsentSnapshot.syni`
  are now exposed end-to-end so hosts can track and persist the user's
  consent for on-device or cloud LLM processing alongside the other
  channels. Backward compatible — `syni` defaults to `false` everywhere
  so existing callers compile unchanged.
- **Canonical channel iteration.** New `ConsentTypeMeta` extension on
  `ConsentType` exposes `wireKey`, `displayName`, `valueOn` (typed
  accessor for `ConsentEffectiveState`), and `valueOnForm` (typed
  accessor for `ConsentForm`). Plus `ConsentEffectiveState.toChannelMap()`
  / `ConsentForm.toChannelMap()` and `ConsentForm.fromChannelMap(...)`.
  Hosts can now iterate `ConsentType.values` rather than hardcoding each
  channel — adding a new channel becomes a single change in the SDK
  enum plus its metadata; consumers pick it up automatically.
- **`Synheart.consentChanges`** — public broadcast stream of
  `ConsentSnapshot`s. Emits on any grant or revoke so hosts that render
  consent in multiple places (e.g. a profile counter alongside a
  consent screen) can stay in sync without polling
  `consentEffectiveStateTyped` or re-dispatching reads.
- **`Synheart.syni.bindPersona(SyniPersona)`** (passthrough to
  `package:syni`'s new `SyniAgent.bindPersona`). Cloud chat needs only
  a persona plus a configured cloud client; hosts that pick
  `SyniExecutionMode.cloudOnly` can call this once instead of running
  `install()` purely to attach a persona. Requires `syni: ^0.3.2`.

### Changed
- `syni` dependency bumped to `^0.3.2` (carries `bindPersona` + the
  fix that lets `cloudOnly` chat run without a local install).
- `ConsentEffectiveState.hasAnyGrant` now includes `syni` — previously
  the flag was tracked through the rest of the state but missing from
  this convenience getter.

### Fixed
- `consentSubmitFormTyped` now propagates the form's `syni` value to
  the runtime via the per-type grant/revoke FFI when the runtime's
  form parser doesn't carry the key directly. Without this a host
  setting `syni` on the typed form would see the other channels update
  but `syni` stay at its previous value.

## [0.6.0] - 2026-05-23

### Added
- `Synheart.configure()` now wires Syni's hybrid router to the cloud — it
  builds the `SyniCloudConfig` and authenticates Syni cloud-chat requests as
  device-attested cloud requests. `Synheart.syni` cloud chat needs no extra
  host-app setup.
- `DeviceAuthProvider.signUrl` — device-attests an absolute URL (no base-URL
  prefixing); `signRequest` now delegates to it.

### Changed
- Bumped the `syni` dependency to `^0.3.0`, whose `SyniCloudConfig`
  replaced the static `authToken` with the request-aware `authHeaders`.
  Consumers building a `SyniCloudConfig` directly need to update to the
  new shape; consumers using `Synheart.configure()` are unaffected.
- The SDK-side default `SyniCloudConfig.authHeaders` closure lazily
  device-attests each request — works whether device auth resolves through
  the Dart `DeviceAuthProvider` or the native runtime.

## [0.5.3] - 2026-05-21

### Fixed
- **iOS: the native runtime can now start on the ONNX-backed tiers.**
  The podspec force-loads ONNX Runtime into the host app binary. The
  runtime framework resolves `OrtGetApiBase` at load time, and
  `onnxruntime-c` ships ONNX as a static archive — nothing in the host
  app references it directly, so the linker dead-stripped the whole
  archive and the runtime crashed on first use. Consumers no longer
  need any per-app linker configuration; depending on `synheart_core`
  is enough. iOS build configuration only — no Dart API change.

## [0.5.2] - 2026-05-20

### Changed
- Bumped the `synheart_behavior` dependency to `^0.4.0`. The behavior
  SDK is now an event producer — a session summary may arrive with no
  `behavioralMetrics`. `BehaviorSessionResults.fromSummary` already
  treats those metrics as optional and defaults each to 0 when absent.

## [0.5.1] - 2026-05-19

### Changed
- Scrubbed internal references from the public package surface — dartdoc
  comments, section header dividers, and barrel-file comments no longer
  cite internal identifiers or internal documentation paths. Comments
  and doc strings only; no code or API changes.

## [0.5.0] - 2026-05-19

### Added
- **Cross-device baseline sync.** `Synheart.syncCreateSpace`,
  `syncJoinSpace`, `syncGeneratePairing`, `syncStatus` — pair two devices
  and replicate baselines in either direction with end-to-end encryption.
- **Offline export / import.** `Synheart.baselineExportOffline(passphrase)`
  produces an encrypted `.srm.synheart` bundle (6-word passphrase, never
  sent to any server). `baselineImportOffline(passphrase, bytes)` returns
  `{imported, skipped, errors}`. Lets users move baselines across
  devices without the cloud.
- **`BaselineLocalHydrator` facade** — `wireLocalHydrator(...)` is the
  new entry point for hydrating baselines into the SDK from
  device-local sources.

### Fixed
- **iOS native runtime loading.** Replaced the relative-path framework
  open with `DynamicLibrary.process()`, which resolves symbols from the
  auto-loaded embedded framework. The previous form silently failed and
  surfaced only as a generic "Native runtime not loaded" warning.
- **Runtime initialization failures are now visible.** When the native
  runtime rejects a configuration on iOS, the host now sees the actual
  reason instead of a silent fallback.

### Changed (breaking)
- **`wireCloud(...)` removed.** Migrate to `wireLocalHydrator(...)`. The
  separate baseline cloud uploader is retired; baselines now ride the
  cross-device sync path.
- **iOS install model.** Podspec moves to a vendored dynamic framework
  installed via the synheart CLI (`synheart install runtime`), rather
  than a static library bundled with the package. Consumer Podfile gets
  a `prepare_command` symlink pointing at the CLI-installed vendor dir.

### Other
- Logging hygiene: consent change events emit one structured line
  instead of an 8-line block; native bridge startup is silent on the
  happy path and warns only on real failures; baseline scoring no
  longer dumps the full engine input JSON.

### Requires
- The matching Synheart native runtime release (v0.10.0).

## [0.4.0] - 2026-05-16

### Added
- `Synheart.syni` — gated Syni client surface with install lifecycle +
  chat + chatStream, delegating to `package:syni`'s `SyniAgent`.
- `SyniContextBuilder` — projects this SDK's HSI (live state + stored
  session history) into the runtime's conditioning contract.
  HSI-version-agnostic; iterates whatever axes the runtime emitted.
- Trivial-message context skip — for greetings / acks, ship only the
  persona prefix instead of full HSI + history (~30–50% prefill
  reduction on short messages).
- `SyniSpecPersona` re-exported from `package:syni` so consumers can
  `SyniSpecPersona.load('focus.coach.v1')` for canonical prompts.
- `Synheart.{closeOrphanSession, sweepOrphanSessions}` — host-side
  orphan cleanup. Sweep on app start closes `state='active'` sessions
  older than 6h that the runtime never finalized (force-kill, OS
  reclaim, sudden reboot).
- `Synheart.configureSyniCloud(...)` — injects cloud client config;
  `Synheart.syni.hasCloud` + per-call `SyniExecutionMode` routes
  between local and cloud.
- Cold-start restore — `SyniAgent.restoreInstallIfReady` checks disk
  before download flow; consumers don't re-prompt for an install when
  the model is already cached.

### Changed
- `syni` dependency switched from `path: ../syni-flutter` to
  `^0.1.0` (now published on pub.dev).
- `SessionSummaryArtifact` parser rewritten to match the runtime's
  actual wire format (nested `header` block, `started_at_ms` /
  `ended_at_ms` keys, nullable per-axis aggregates, structured
  `SessionAggregates` keyed by axis name).
- `SessionRecord` now reads `started_at_ms` from the FFI (was missing —
  surfaced as 1970-01-01 timestamps in downstream digests). `state`
  and `endedAtUtc` exposed for the sweep's filter.

## [0.3.0] - 2026-05-14

### Added
- `Synheart.labReenqueueSession(String sessionJson)` — replay a
  previously-finalized lab session payload through the cloud
  connector. Useful when the initial upload was dropped on a 4xx
  (typically a cloud schema mismatch — the runtime removes those
  rows from the in-memory upload queue). Host reads the
  persisted JSON from app-side storage and passes it back.
- `Synheart.isLabReenqueueAvailable` — feature-detect whether the
  linked runtime binary exports the symbol (engine v0.8.1+).
- `LabReenqueueResult` enum — mirrors the FFI return codes
  (`queued`, `researchNotAllowed`, `cloudNotConfigured`,
  `parseError`, `invalidArgument`, `unsupported`).
- `CoreRuntimeBridge.labReenqueueSession` instance method + companion
  `isLabReenqueueAvailable` getter; new `_LabReenqueueC` / `_LabReenqueueDart`
  typedefs in `ffi_bindings.dart`. Lookup is optional so older
  runtime binaries (pre-v0.8.1) keep loading without errors.
- Customer-facing data deletion API (`requestDataDeletion`,
  `getDataDeletion`, `listDataDeletions`) and `DataDeletion*` models
  for GDPR Article 17.

### Runtime compatibility
- Requires the Synheart native runtime v0.8.1+ for `labReenqueueSession`
  to actually invoke the FFI. Older binaries return
  `LabReenqueueResult.unsupported`.

## [0.2.0] - 2026-05-09

### Added
- HSI 1.3 envelope parsing in `HSIState` and `HSIPayload`. Producers
  emit the closed 5-axis domain set (`physiological`, `kinematic`,
  `digital`, `cognitive`, `affective`) with deterministic UUIDv5
  `hsi_id`. The SDK now parses the new shape and exposes the digital
  readings (`focus_quality`, `interruption_pressure`,
  `interaction_mode`) alongside the existing physiological / cognitive
  / affective fields. The 1.2 wire shape is still accepted as a
  fallback; consumers should not rely on that path long-term.

### Fixed
- `BehaviorModule._convertSynheartEvent` now forwards
  `BehaviorEventType.app_switch` to the runtime instead of dropping it
  via the default-arm. The runtime needs `app_switch` to detect
  notification responses (an app switch shortly after a notification)
  and to anchor session boundaries between foreground events of
  different apps. Without this forward, the digital readings on the
  HSI 1.3 envelope (`axes.digital[]` — `focus_quality`,
  `interruption_pressure`, `interaction_mode`) were silent on iOS and
  Android.

## [0.1.1] - 2026-05-08

### Changed
- Bumped `synheart_auth` dep to `^0.1.2`. Picks up the Maven Central
  `ai.synheart:synheart-auth:0.1.1` upgrade (clock-skew auto-apply,
  register/rotate race fix, HTTP timeouts, audit-log PII redaction).

## [0.1.0] - 2026-05-08

First public open-source release on pub.dev. The SDK is now a thin
FFI shell over the native Synheart Runtime — storage, crypto, sync,
consent, the artifact pipeline, the cloud connector, and SRM live in
the runtime, and this package exposes them through a Dart surface.

The native runtime is installed via the
[Synheart CLI](https://docs.synheart.ai/synheart-cli)
(`synheart install runtime`); see the README.

This release consolidates the OSS-launch refactors plus the
breaking change to `processVendorEvent`.

### Breaking
- `Synheart.processVendorEvent(...)` and
  `WearModule.processVendorEvent(...)` now return
  `Future<CanonicalWearableEvent?>` instead of `Future<void>`. The
  previous void return discarded the canonical event the vendor payload
  was mapped to. Mirrors the Swift and Kotlin counterparts.
- Removed `CloudConfig.tenantId`. Drop the argument — `app_id` is the
  only identifier the SDK sends.
- Removed `CloudConfig.hmacSecret`. Request signing uses the device key;
  `authProvider` is now optional.
- Removed `InvalidTenantError`.
- `ConsentForm` shape is flat (`profile_id`, `biosignals`,
  `phone_context`, `behavior`, `consent_tier`, `allow_cloud`,
  `allow_research`, `allow_vendor_sync`) to mirror the runtime. Hosts
  that previously built `categories[] → channels[]` structures must
  migrate to the flat form.
- Consent type strings are snake_case at the runtime boundary
  (`phone_context` / `cloud_upload` / `vendor_sync`). Flutter still
  accepts camelCase on its public API.
- Removed `ConsentCategory` and `ConsentChannel` types — channel-level
  truth is owned by the runtime.

### Added
- `Synheart.rawRamenEvents` — broadcast `Stream<RamenEvent>` re-exported
  from `synheart_wear`, surfacing every RAMEN event with its
  capability-flavored `deliveryHint`. `app_id` / `user_id` from the
  active `startVendorSync` config are stamped onto each event so
  `RamenEventDispatcher` can drive REST pulls without extra plumbing.
- Offline-first consent FFI surface: `consentConfigureCloud`,
  `consentGetEditableForm`, `consentSubmitForm`, `consentEffectiveState`,
  `consentStatus`, `consentNeedsTokenRefresh`, `consentClearStored`.
  Local choice is persisted immediately; cloud sync is best-effort.
- Typed consent form accessors: `consentGetEditableFormTyped()` and
  `consentSubmitFormTyped({ required ConsentForm form, … })`.
- Consent coverage for `vendorSync` and `research` through
  `hasConsent()` / `getConsentStatusMap()` and the granular grant API.
- Durable `data_dir` for the native runtime via `path_provider`. Fixes
  SRM snapshots and the artifact SQLite landing in
  `std::env::temp_dir()` (cleaned up by the OS), which broke baseline
  persistence across app restarts.

### Changed
- `setStreamCallback` auto-route now skips `delivery_hint == "ping"`
  events. Their inline `payload_json` is empty by design (Garmin / Oura
  / Fitbit only send a notification), so apps must subscribe to
  `rawRamenEvents` and use `RamenEventDispatcher` to fetch the full
  record before re-feeding the canonical pipeline.
- README rewritten to match the actual public API.
- Dependencies on sibling Synheart SDKs are now hosted on pub.dev
  (`synheart_wear ^0.4.0`, `synheart_session ^0.2.0`,
  `synheart_behavior ^0.3.0`, `synheart_auth ^0.1.1`) instead of git
  refs.

[Unreleased]: https://github.com/synheart-ai/synheart-core-flutter/compare/v0.12.0...HEAD
[0.12.0]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.12.0
[0.11.1]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.11.1
[0.11.0]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.11.0
[0.10.1]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.10.1
[0.10.0]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.10.0
[0.9.0]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.9.0
[0.8.2]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.8.2
[0.8.1]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.8.1
[0.8.0]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.8.0
[0.7.3]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.7.3
[0.7.2]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.7.2
[0.7.1]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.7.1
[0.7.0]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.7.0
[0.6.3]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.6.3
[0.6.2]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.6.2
[0.6.1]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.6.1
[0.6.0]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.6.0
[0.5.3]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.5.3
[0.5.2]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.5.2
[0.5.1]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.5.1
[0.5.0]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.5.0
[0.4.0]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.4.0
[0.3.0]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.3.0
[0.2.0]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.2.0
[0.1.1]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.1.1
[0.1.0]: https://github.com/synheart-ai/synheart-core-flutter/releases/tag/v0.1.0
