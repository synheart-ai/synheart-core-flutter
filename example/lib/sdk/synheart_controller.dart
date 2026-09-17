import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synheart_core/synheart_core.dart';

import 'mobile_host_runner.dart';

/// The one place in this example that talks to the Synheart SDK.
///
/// Every screen reads state from here and calls methods here — no screen
/// imports `package:synheart_core` directly. That keeps the SDK integration
/// readable as a single file you can skim top-to-bottom, and makes it obvious
/// what a host app actually has to implement.
///
/// The lifecycle it models is the one the SDK documents:
///
///   1. [initialize]      — validate config, load the native runtime
///   2. [submitConsent]   — write the user's choices through the runtime form
///   3. [startSession]    — begin collection; HSI starts arriving
///   4. [stopSession]     — end collection
///   5. [dispose]         — tear down
///
/// Consent uses the runtime's editable-form flow
/// (`consentGetEditableFormTyped` → `consentSubmitFormTyped` →
/// `consentEffectiveStateTyped`). That is the canonical path: the runtime
/// persists the choice offline-first, then reconciles with the cloud profile
/// when cloud is enabled. The older Dart-side helpers (`requestConsent`,
/// `getAvailableConsentProfiles`, `setConsentUIProvider`) are legacy and are
/// deliberately not used here.
class SynheartController extends ChangeNotifier {
  // ── Build-time configuration ───────────────────────────────────────────
  //
  // This example is LOCAL-ONLY by default: no CloudConfig, no
  // DeviceAuthConfig. Everything it demonstrates runs offline on any device
  // with no credentials.
  //
  // Values come from a dart-defines file rather than a wall of --dart-define
  // flags, matching how the other Synheart apps are built:
  //
  //   flutter run --dart-define-from-file=env/defines.dev.json
  //
  // `env/defines.example.json` is the checked-in template; a populated file is
  // gitignored, because it carries real organization identifiers. See SETUP.md.

  /// Platform-issued application identifier, per platform.
  ///
  /// Android and iOS are separate apps on the platform and carry separate
  /// `app_…` ids, because attestation is per-store: Play Integrity verifies the
  /// Android package, App Attest the iOS bundle. One shared id could not be
  /// bound to both.
  static const String androidAppId = String.fromEnvironment(
    'SYNHEART_ANDROID_APP_ID',
  );
  static const String iosAppId = String.fromEnvironment('SYNHEART_IOS_APP_ID');

  /// Single-platform fallback, for a build that names one id for both.
  static const String sharedAppId = String.fromEnvironment('SYNHEART_APP_ID');

  /// The id this build reports, resolved for the running platform.
  ///
  /// Resolution order is per-platform id → shared id → bundle id. The bundle id
  /// last resort keeps a credential-free run working, since
  /// `SynheartConfig.validate()` rejects an empty `appId`.
  ///
  /// Uses [defaultTargetPlatform] rather than `dart:io`'s `Platform`, so this
  /// stays resolvable in tests and on web.
  static String get appId {
    final perPlatform = switch (defaultTargetPlatform) {
      TargetPlatform.android => androidAppId,
      TargetPlatform.iOS => iosAppId,
      _ => '',
    };
    if (perPlatform.isNotEmpty) return perPlatform;
    if (sharedAppId.isNotEmpty) return sharedAppId;
    return 'ai.synheart.core.example';
  }

  static const String authBaseUrl = String.fromEnvironment('SYNHEART_AUTH_URL');

  /// Organization id, required only for HSI upload — cloud ingest stays
  /// disabled without one. Independent of attestation.
  ///
  /// `SYNHEART_CLOUD_ORG_ID` is the name the platform's credential download
  /// uses; `SYNHEART_ORG_ID` is accepted too so an existing defines file keeps
  /// working.
  static const String _cloudOrgId = String.fromEnvironment(
    'SYNHEART_CLOUD_ORG_ID',
  );
  static const String _plainOrgId = String.fromEnvironment('SYNHEART_ORG_ID');
  static String get orgId => _cloudOrgId.isNotEmpty ? _cloudOrgId : _plainOrgId;

  /// Platform package name, sent with the attestation request.
  ///
  /// Distinct from [appId] and NOT interchangeable: Play Integrity and App
  /// Attest verify the real installed package (`ai.synheart.core.example`),
  /// while [appId] is a platform-issued `app_…` identifier once credentials
  /// are supplied. Passing the latter as the package name fails attestation.
  static const String packageName = String.fromEnvironment(
    'SYNHEART_PACKAGE_NAME',
    defaultValue: 'ai.synheart.core.example',
  );

  /// Tenant and project identifiers, read so a credentials file can be dropped
  /// in whole and the Setup screen can show what was supplied.
  ///
  /// The Core SDK does NOT consume either one. `buildRuntimeConfigMap` sends
  /// `app_id` and `org_id` and nothing else, and `CloudConfig` has no field for
  /// them — they are scoped to platform APIs that this SDK does not call.
  /// Setting them changes no behavior here.
  static const String _cloudTenantId = String.fromEnvironment(
    'SYNHEART_CLOUD_TENANT_ID',
  );
  static const String _plainTenantId = String.fromEnvironment(
    'SYNHEART_TENANT_ID',
  );
  static String get tenantId =>
      _cloudTenantId.isNotEmpty ? _cloudTenantId : _plainTenantId;
  static const String projectId = String.fromEnvironment('SYNHEART_PROJECT_ID');

  /// Attestation is possible. Every registration trigger in the SDK keys off
  /// `DeviceAuthConfig`; none of them consults the cloud config.
  static bool get attestationConfigured => authBaseUrl.isNotEmpty;

  /// Upload is possible. Needs an org id AND an attested identity, since the
  /// runtime signs every ingest request with the device key.
  static bool get uploadConfigured => orgId.isNotEmpty && attestationConfigured;

  static const _kSubjectId = 'example.subject_id';
  static const _kDeviceId = 'example.device_id';

  // ── State the UI renders ───────────────────────────────────────────────

  String? _subjectId;
  String? _deviceId;
  bool _isInitializing = false;
  bool _isInitialized = false;
  String? _initError;

  ConsentForm? _consentForm;
  ConsentEffectiveState? _consentState;
  bool _isSubmittingConsent = false;
  String? _consentError;

  bool _isSessionRunning = false;
  SessionHandle? _session;
  String? _sessionError;

  HSIState? _latestState;
  int _hsiWindowCount = 0;
  StreamSubscription<HSIState>? _hsiSub;

  /// The host-driven half of the mobile integration — the tick loop, rest
  /// declaration, the three snapshots, the daily loop, and the simulated
  /// cardiac stream.
  ///
  /// Split out rather than inlined here because it is *driving* rather than
  /// configuring: this class ends at `startSession()`, and everything in
  /// `MobileHostRunner` is what has to keep happening afterwards. Both halves
  /// are still the only code in the example that touches the SDK, and this one
  /// forwards the runner's notifications so a screen has a single listenable.
  late final MobileHostRunner host = MobileHostRunner(
    onChanged: notifyListeners,
  );

  /// Backgrounding is where §6 gets specific: `flush_pending` on the way out,
  /// or up to one lateness budget's worth of completed windows is stranded
  /// forever, and `drain then tick` on the way back in.
  ///
  /// Registered for the life of the controller rather than only while a
  /// session runs, because the transition that matters most — the one where
  /// iOS is about to stop scheduling this process — can arrive at any point.
  AppLifecycleListener? _lifecycleListener;

  String? get subjectId => _subjectId;
  String? get deviceId => _deviceId;
  bool get isInitializing => _isInitializing;
  bool get isInitialized => _isInitialized;
  String? get initError => _initError;

  ConsentForm? get consentForm => _consentForm;
  ConsentEffectiveState? get consentState => _consentState;
  bool get isSubmittingConsent => _isSubmittingConsent;
  String? get consentError => _consentError;

  bool get isSessionRunning => _isSessionRunning;
  SessionHandle? get session => _session;
  String? get sessionError => _sessionError;

  HSIState? get latestState => _latestState;
  int get hsiWindowCount => _hsiWindowCount;

  /// True when an enabled feature ALSO has its matching consent granted.
  ///
  /// Both halves are required. An app that enables only `wearConfig` and is
  /// granted only `behavior` has no working pair: wear is enabled but not
  /// permitted, behavior is permitted but not enabled. Nothing would collect.
  ///
  /// This example enables wear and behavior, so either of those two consents
  /// pairs with something. Phone context is a live demonstration of the
  /// unpaired case: the consent exists and can be granted, but [buildConfig]
  /// declares no `phoneConfig`, so granting it alone still collects nothing.
  /// The phone clause below is kept rather than deleted for exactly that
  /// reason — it is the half of the pair that is present.
  ///
  /// Deliberately NOT `hasAnyGrant`, which also counts cloudUpload, vendorSync,
  /// research and syni. Those govern what happens to data once collected; none
  /// makes a sensor readable. `Synheart.startSession()` enforces the same rule.
  bool get hasCollectionConsent {
    final c = _consentState;
    if (c == null) return false;
    final cfg = buildConfig();
    return (cfg.wearConfig != null && c.biosignals) ||
        (cfg.behaviorConfig != null && c.behavior) ||
        (cfg.phoneConfig != null && c.phoneContext);
  }

  // ── 1. Identity + initialization ───────────────────────────────────────

  /// Load (or mint) the identifiers this install is bound to.
  ///
  /// `subjectId` MUST be stable across restarts — the runtime scopes storage,
  /// baselines, and device identity to it, so a value that changes per launch
  /// makes every session look like a new person and baselines never mature.
  /// A real app uses its own account id; this example generates one once and
  /// persists it.
  Future<void> loadIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    _subjectId = prefs.getString(_kSubjectId);
    if (_subjectId == null || _subjectId!.isEmpty) {
      _subjectId = 'demo_${DateTime.now().millisecondsSinceEpoch}';
      await prefs.setString(_kSubjectId, _subjectId!);
    }
    _deviceId = prefs.getString(_kDeviceId);
    if (_deviceId == null || _deviceId!.isEmpty) {
      _deviceId = 'dev_${DateTime.now().microsecondsSinceEpoch}';
      await prefs.setString(_kDeviceId, _deviceId!);
    }
    notifyListeners();
  }

  /// Replace the subject id and persist it. Clears SDK state, because the
  /// runtime binds storage to the subject — carrying state across a change
  /// would attribute one person's data to another.
  Future<void> setSubjectId(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == _subjectId) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSubjectId, trimmed);
    _subjectId = trimmed;
    if (_isInitialized) await shutdown();
    notifyListeners();
  }

  /// The config this example initializes with. Kept as a getter so the setup
  /// screen can show developers exactly what is being passed.
  SynheartConfig buildConfig() {
    return SynheartConfig(
      // Both are REQUIRED — validate() rejects an empty value.
      appId: appId,
      subjectId: _subjectId ?? '',
      appVersion: '1.0.0',
      appName: 'Synheart Core Example',
      deviceId: _deviceId ?? '',
      mode: SynheartMode.personal,

      // Development only. In production the capability lattice is driven by a
      // verified consent token; running unsigned means "allow everything".
      allowUnsignedCapabilities: true,

      // Declaring a module config both activates the feature and tells the SDK
      // which collectors to wire. Omit one and that module never starts.
      wearConfig: const WearConfig(),

      // phoneConfig is deliberately NOT declared.
      //
      // Declaring it starts PhoneModule, whose four collectors are `Random()`
      // generators: motion at 10 Hz, a 30% chance of flipping screen state
      // every 30 s, a 40% chance of switching to a mock app every 15 s, and a
      // 30% chance of inventing a notification every 20 s
      // (`lib/src/modules/phone/phone_collectors.dart`). Cardiac is the only
      // thing this example is allowed to simulate, and those four are not
      // cardiac.
      //
      // It also contradicted the sensing roster: `MobileHostRunner` declares
      // `screen_state: false` and `app_focus: false` because nothing real
      // observes them, while the phone module was busy inventing exactly
      // those two.
      //
      // The data never reached the runtime — `phone_module.dart` holds no
      // bridge reference, so it wrote to an in-memory cache nothing reads —
      // so nothing of value is lost by leaving it off. The module needs
      // replacing with real platform collectors or deleting; until then, off
      // is the honest setting.
      behaviorConfig: const BehaviorConfig(
        // §4.2 — without this the accel subscription is never created and
        // `push_accel` is never called, so the kinematic modality has no
        // input at all. It defaulted to false and no host was enabling it,
        // which is why mobile motion was reaching nothing.
        //
        // It is necessary but not sufficient: the four kinematic heads also
        // need a body-worn placement declared (§4.3, `setAccelPlacement`),
        // and `unknown` — the default — withholds all of them.
        emitRawMotionSamples: true,
      ),

      // §2 — the four declarations that change engine output. Off unless the
      // Setup screen turns them on, because declaring `device_class`
      // invalidates every persisted SRM baseline. See
      // `MobileHostRunner.declareHostProfile`.
      hostDeclarations: host.buildHostDeclarations(),

      // §2.4 — the kinematic heads are opt-in and withhold until a placement
      // is declared. Requested here so the Host screen can show them moving
      // from "not requested" to "withheld, no placement" to a real reading,
      // which are three different states a host has to be able to tell apart.
      extraHeads: const [
        ExtraHead.movementRegularity,
        ExtraHead.posturalState,
        ExtraHead.activityState,
        ExtraHead.locomotionState,
      ],

      // Left at the runtime default (60 000). Stated explicitly because the
      // rest detector's one-shot bookkeeping counts on the same grid — see
      // `RestWindowDetector.windowMs`.
      windowMs: 60000,

      // Required for the runtime consent-form flow: consentSubmitFormTyped
      // needs a non-empty deviceId + platform to stamp on the submission.
      // Without a ConsentConfig the submit call returns null and consent can
      // never be written.
      consentConfig: ConsentConfig(
        deviceId: _deviceId,
        platform: 'flutter',
        userId: _subjectId,
      ),

      // Both opt-in and independent: SYNHEART_AUTH_URL alone enables
      // attestation, SYNHEART_ORG_ID adds upload on top. With neither, the
      // example is local-only. Granting cloud-upload consent is what actually
      // triggers registration. See SETUP.md.
      deviceAuthConfig: attestationConfigured
          ? DeviceAuthConfig(
              authBaseUrl: authBaseUrl,
              packageName: packageName,
              // A debug build, an emulator, or a de-Googled ROM cannot produce
              // a Play Integrity token, so the runtime skips registration and
              // stays local-only:
              //
              //   WARN device auth: no attestation material - device cannot
              //   attest; skipping registration (local-only)
              //
              // This stops the SDK giving up client-side: it sends the
              // registration carrying `format:"none"` and an empty blob, and
              // the server decides. Nothing fake is transmitted.
              //
              // It is NOT a bypass, and the flag alone does nothing. Server-side
              // development mode must also be on for this app id, and it must be
              // a DEVELOPMENT app id — never enable that on a production one. A
              // device admitted this way is recorded `unattested`: it still holds
              // a hardware key and signs every request, it just carries no
              // provenance claim.
              //
              // Gated on kDebugMode so a store build can never ship it enabled.
              allowUnattestedDevRegistration: kDebugMode,
            )
          : null,
      cloudConfig: uploadConfigured
          ? CloudConfig(
              subjectId: _subjectId ?? '',
              instanceId: _deviceId ?? '',
              orgId: orgId,
            )
          : null,
    );
  }

  /// Turn the §2 host declarations on or off.
  ///
  /// Only meaningful before [initialize]: the config JSON is read once at
  /// `synheart_core_new`, so flipping this afterwards changes nothing until
  /// the SDK is shut down and rebuilt. The UI locks the toggle for exactly
  /// that reason rather than letting it look effective and do nothing.
  void setDeclareHostProfile(bool value) {
    if (_isInitialized || host.declareHostProfile == value) return;
    host.declareHostProfile = value;
    notifyListeners();
  }

  /// Claim continuous sensing rather than letting `"auto"` resolve it.
  void setClaimContinuousSensing(bool value) {
    if (_isInitialized || host.claimContinuousSensing == value) return;
    host.claimContinuousSensing = value;
    notifyListeners();
  }

  /// The `device_class` this host stores its SRM snapshot under.
  ///
  /// Kept separate from the declaration itself, because the two answer
  /// different questions. The runtime resolves `"auto"` to a class through its
  /// own tables and rejects a cross-class SRM load with
  /// `ERR_SRM_CONFIG_MISMATCH` — so the host needs a stable file key even
  /// while it declares `"auto"`, and a phone and a tablet must not share one
  /// or they take turns invalidating each other's baseline.
  String get hostDeviceClass => switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.android => 'phone',
    _ => 'desktop',
  };

  /// Validate the config and load the native runtime.
  ///
  /// `autoStart: false` is deliberate — initializing must not begin collecting.
  /// Collection starts at [startSession], after consent.
  Future<void> initialize() async {
    if (_isInitialized || _isInitializing) return;
    _isInitializing = true;
    _initError = null;
    notifyListeners();

    try {
      if (_subjectId == null) await loadIdentity();
      await Synheart.initialize(config: buildConfig(), autoStart: false);
      _isInitialized = true;

      // §7 — restore the three snapshots now, while there is still no
      // Pipeline and therefore no window 1. `load_session_state` MUST run
      // before the first tick: window 1 writes each head's state slot, so a
      // restore attempted later is overwritten by a cold window and the
      // context baseline has already counted a window against the wrong
      // history. Doing it at initialize() rather than at startSession() is
      // what makes that ordering unconditional.
      await host.restore(
        subjectId: _subjectId ?? '',
        deviceClass: hostDeviceClass,
      );

      _lifecycleListener ??= AppLifecycleListener(
        onPause: () => host.onBackgrounded(),
        onRestart: host.onForegrounded,
        // Last call before the process may be killed. `flush_pending` and the
        // snapshot writes are best-effort here by nature — there is no
        // guarantee of being scheduled again — which is exactly why the same
        // work also runs on every pause and once per emitted window.
        onDetach: () => host.onBackgrounded(),
      );

      await refreshConsent();
    } on SynheartError catch (e) {
      // Configuration was rejected. The message names the field and the fix.
      _initError = '${e.code}\n\n${e.message}';
    } catch (e) {
      _initError = '$e';
    } finally {
      _isInitializing = false;
      notifyListeners();
    }
  }

  // ── 2. Consent (runtime editable-form flow) ────────────────────────────

  /// Read the runtime's current form and effective state.
  ///
  /// The form is what the user edits; the effective state is what the runtime
  /// actually enforces after intersecting the choice with the cloud profile.
  /// They can differ — always gate features on the effective state.
  Future<void> refreshConsent() async {
    if (!_isInitialized) return;
    _consentForm = Synheart.consentGetEditableFormTyped();
    _consentState = Synheart.consentEffectiveStateTyped();
    notifyListeners();
  }

  /// Apply a local edit to the pending form without submitting it, so toggles
  /// feel immediate. Nothing is enforced until [submitConsent].
  void editConsent({
    bool? biosignals,
    bool? phoneContext,
    bool? behavior,
    bool? allowCloud,
    bool? allowResearch,
    bool? allowVendorSync,
  }) {
    final form = _consentForm;
    if (form == null) return;
    _consentForm = form.copyWith(
      biosignals: biosignals,
      phoneContext: phoneContext,
      behavior: behavior,
      allowCloud: allowCloud,
      allowResearch: allowResearch,
      allowVendorSync: allowVendorSync,
    );
    notifyListeners();
  }

  /// Submit the edited form to the runtime.
  ///
  /// Offline-first: the runtime persists the choice immediately and succeeds
  /// even with no network. When `allowCloud` is set it additionally fetches the
  /// cloud default profile, intersects it with the choice, and issues a consent
  /// token — a step that legitimately fails offline without invalidating the
  /// local save.
  Future<void> submitConsent() async {
    final form = _consentForm;
    if (form == null || !_isInitialized) return;
    _isSubmittingConsent = true;
    _consentError = null;
    notifyListeners();

    try {
      final result = await Synheart.consentSubmitFormTyped(form: form);
      if (result == null) {
        _consentError =
            'Submit returned null — the runtime bridge or ConsentConfig is '
            'missing. Check that SynheartConfig.consentConfig is set with a '
            'non-empty deviceId and platform.';
      } else if (result['error'] != null) {
        _consentError = '${result['error']}';
      }
      await refreshConsent();
    } catch (e) {
      _consentError = '$e';
    } finally {
      _isSubmittingConsent = false;
      notifyListeners();
    }
  }

  // ── 3. Session + HSI ───────────────────────────────────────────────────

  /// Start collecting. HSI windows begin arriving on [latestState] once the
  /// runtime closes a window, which it does on a fixed ~60s cadence.
  Future<void> startSession() async {
    if (!_isInitialized || _isSessionRunning) return;
    _sessionError = null;
    try {
      _hsiWindowCount = 0;
      _latestState = null;
      _wearSampleCount = 0;
      _wearDataSampleCount = 0;
      _lastWearSample = null;
      _behaviorEventCount = 0;
      _behaviorCounts.clear();
      _lastBehaviorEvent = null;

      // Subscribe BEFORE starting so the first completed window is not missed.
      // onStateUpdate parses each window once and shares it across listeners.
      _hsiSub ??= Synheart.onStateUpdate.listen((state) {
        _latestState = state;
        _hsiWindowCount++;
        // §7 — export session state once per emitted window. Doing it only on
        // background loses everything since the last one whenever the process
        // is killed without a pause callback, which on Android is routine.
        host.persistSessionState();
        notifyListeners();
      });

      // Raw samples as the wear module produces them. Consent-gated by the SDK:
      // nothing is emitted unless biosignals are granted.
      _wearSub ??= Synheart.wearSampleStream.listen((sample) {
        _wearSampleCount++;
        if (_carriesBiosignal(sample)) {
          // Keep the last sample that actually held a reading, so the UI shows
          // the most recent real value rather than the most recent empty tick.
          _lastWearSample = sample;
          _wearDataSampleCount++;
        }
        notifyListeners();
      });

      // Behavior events as the gesture detector captures them. This is the one
      // source that needs no sensor and no wearable, so on a phone with neither
      // it is the only proof the collection path is alive. Counting by type
      // also shows which gestures the detector actually resolves — a scroll and
      // a swipe are distinct events, not one "touch".
      _behaviorSub ??= Synheart.behaviorEventStream.listen((event) {
        _behaviorEventCount++;
        _lastBehaviorEvent = event;
        _behaviorCounts.update(event.type, (n) => n + 1, ifAbsent: () => 1);
        notifyListeners();
      });

      _session = await Synheart.startSession();
      _isSessionRunning = Synheart.isSessionRunning;

      // §6.1 — start the tick loop for the WHOLE session. `ingest_batch`
      // advances the pipeline clock but `push_behavior` does not, so a
      // session carrying interaction and no cardiac input emits zero HSI
      // windows without this. Started after startSession() so the pipeline
      // exists for the first tick to advance.
      if (_isSessionRunning) host.start();
    } catch (e) {
      _sessionError = '$e';
    }
    notifyListeners();
  }

  Future<void> stopSession() async {
    if (!_isSessionRunning) return;
    // Before `stopSession`, not after: `flush_pending` and the snapshot
    // exports need a live handle, and the SRM export at session end is the
    // one that stops baselines reporting `Warming` forever across launches.
    await host.stop();
    try {
      await Synheart.stopSession();
    } catch (e) {
      _sessionError = '$e';
    }
    await _hsiSub?.cancel();
    _hsiSub = null;
    await _wearSub?.cancel();
    _wearSub = null;
    await _behaviorSub?.cancel();
    _behaviorSub = null;
    _session = null;
    _isSessionRunning = Synheart.isSessionRunning;
    notifyListeners();
  }

  // ── Signal sources ─────────────────────────────────────────────────────
  //
  // Real signal arrives from the modules the config activated:
  //   wear      — HealthKit / Health Connect / BLE strap / watch companion
  //   phone     — device motion and context
  //   behavior  — taps and typing rhythm, via the gesture detector wrapper
  //
  // The SDK pushes those into the runtime itself. `Synheart.pushWearHr`,
  // `pushRr`, and `pushRrBatch` exist for hosts that own a source the SDK does
  // not adapt — a proprietary strap, say.
  //
  // ── And a simulated one, behind a button ───────────────────────────────
  //
  // `host.startCardiacStream()` streams fabricated beats through that same
  // path, because on a bare phone with no strap and no health permission it is
  // the only way to see the cardiac ingest path work at all — and five axes
  // sitting at zero confidence forever teaches a developer nothing about
  // whether their integration is correct.
  //
  // Two things keep that from being a lie rather than a demo:
  //
  //  * It is tagged `default_sensor`, Tier-3, not `ble_hrm`. A synthetic
  //    source does not get the Tier-1 routing a real chest strap earns.
  //  * It is never automatic. The host has to ask, every session.
  //
  // The cost is real and unavoidable: those samples reach the SRM, which
  // builds this person's longitudinal reference ranges on this device. So run
  // it under a throwaway `subject_id` and use [wipeLocalData] afterwards. The
  // Session screen says so where the button is, not in a comment nobody
  // reading the UI will see.

  /// Live raw samples from the wear module, so the UI can show what is actually
  /// arriving rather than asserting that something is.
  WearSample? _lastWearSample;
  int _wearSampleCount = 0;
  int _wearDataSampleCount = 0;
  StreamSubscription<WearSample>? _wearSub;

  WearSample? get lastWearSample => _lastWearSample;

  /// Every sample the wear module emitted, including empty ones.
  int get wearSampleCount => _wearSampleCount;

  /// Samples that actually carried a biosignal.
  ///
  /// Tracked separately because the wear source emits a [WearSample] on every
  /// poll tick whether or not a metric resolved. With no wearable paired and no
  /// health data available, that is one all-null envelope per second — so a
  /// raw sample count climbing steadily says nothing about whether biosignals
  /// are arriving, and reporting it as "receiving" would be false.
  int get wearDataSampleCount => _wearDataSampleCount;

  static bool _carriesBiosignal(WearSample s) =>
      s.hr != null ||
      s.hrvRmssd != null ||
      (s.rrIntervals?.isNotEmpty ?? false);

  // ── Behavior signal ────────────────────────────────────────────────────
  //
  // Taps, scrolls and swipes need no sensor, so behavior is the one source
  // that works on any phone. The SDK forwards each event into the runtime
  // (`pushBehaviorToRuntime` → `synheart_core_push_behavior`), where it feeds
  // the DIGITAL modality.
  //
  // Worth being precise about, because it is the most common source of "the
  // SDK looks broken": digital signal does not populate focus, capacity,
  // arousal or stress. Those are physiology-derived and stay at zero
  // confidence until heart rate or HRV arrives. Behavior's contribution shows
  // up as `modalities.digital`, which is why the Session screen renders it.

  int _behaviorEventCount = 0;
  BehaviorEvent? _lastBehaviorEvent;
  final Map<BehaviorEventType, int> _behaviorCounts = {};
  StreamSubscription<BehaviorEvent>? _behaviorSub;

  /// Behavior events captured since the session started.
  int get behaviorEventCount => _behaviorEventCount;

  BehaviorEvent? get lastBehaviorEvent => _lastBehaviorEvent;

  /// Per-type tallies, most frequent first.
  List<MapEntry<BehaviorEventType, int>> get behaviorBreakdown {
    final entries = _behaviorCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries;
  }

  bool get isWearCollecting => Synheart.isWearCollecting;
  bool get isPhoneCollecting => Synheart.isPhoneCollecting;
  bool get isBehaviorCollecting => Synheart.isBehaviorCollecting;

  /// True once a sample carrying an actual biosignal has arrived — not merely
  /// once the stream is ticking. Until then the runtime has no heart-rate or
  /// HRV input, so the physiological axes stay empty no matter how long the
  /// session runs.
  bool get hasBiosignalSource => _wearDataSampleCount > 0;

  /// The wear source is emitting, but every sample so far has been empty. This
  /// is the normal state on a phone with no wearable paired or with health
  /// permissions not yet granted, and it is worth naming: it looks identical
  /// to "working" if you only watch the sample counter.
  bool get wearEmittingButEmpty =>
      _wearSampleCount > 0 && _wearDataSampleCount == 0;

  // ── Behavior capture ───────────────────────────────────────────────────

  /// Wrap the app in the SDK's gesture detector so taps and typing rhythm feed
  /// the behavior module.
  ///
  /// Required for behavior collection — declaring `behaviorConfig` and granting
  /// behavior consent is not enough on its own, because the SDK has no way to
  /// observe your widget tree otherwise. Safe to call unconditionally: it
  /// returns [child] unchanged when the SDK is not initialized or behavior
  /// consent is not granted.
  Widget wrapWithBehaviorDetector(Widget child) =>
      Synheart.wrapWithBehaviorDetector(child);

  // ── 4. Diagnostics ─────────────────────────────────────────────────────

  /// Native runtime health, with a FULL symbol audit.
  ///
  /// `probeAll: true` matters here. Optional bindings resolve lazily, so a
  /// diagnostics screen that just reads `missingSymbols` reports an empty list
  /// — and looks healthy — while having checked nothing. This example never
  /// calls the lab, resilience, priority, or backfill APIs, so without the
  /// probe every one of those symbols would go unexamined.
  Map<String, dynamic> get diagnostics =>
      Synheart.runtimeDiagnostics(probeAll: true);

  /// Compile-time facts about the vendored runtime — crate versions, profile,
  /// and the cargo features it was built with.
  ///
  /// The features list is the one to read when a context event is rejected:
  /// without `app-context`, push_context_event is compiled as an inert stub
  /// that returns 1, which is byte-identical to a rejected payload.
  Map<String, dynamic>? get buildInfo => Synheart.buildInfo;

  /// SDK version constant, kept in sync with pubspec.
  String get sdkVersion => synheartCoreVersion;

  // ── Device attestation ─────────────────────────────────────────────────
  //
  // Registration is triggered by CLOUD-UPLOAD CONSENT, not by initialize().
  // Granting it starts the flow in the background (it can park the calling
  // thread for seconds, so the SDK deliberately does not await it) — poll
  // [attestationStatus] to watch it progress.

  /// Whether the loaded runtime exports the device-auth ABI at all.
  bool get attestationAvailable => Synheart.coreSdkDeviceAuthAvailable;

  /// Runtime attestation snapshot: `{status, device_id, ...}`, or null when
  /// device auth is not configured or the ABI is absent.
  Map<String, dynamic>? get attestationStatus =>
      Synheart.coreDeviceAuthStatus();

  /// True once this process has completed a registration.
  bool get attestationRegistered => Synheart.deviceAuthUsedCoreRuntime;

  /// Whether this build asks the server to admit a device that produced no
  /// attestation material. True only in debug — see [buildConfig].
  bool get allowsUnattestedDevRegistration => kDebugMode;

  // ── Cloud ingest ───────────────────────────────────────────────────────
  //
  // The host does NOT drive uploading. The runtime owns the whole pipeline:
  // it subscribes to the engine's HSI broadcast, enqueues each window into a
  // SQLite upload queue (gated on cloud-upload consent, buffering the windows
  // that arrive during the cold-start token race), and POSTs the queue on
  // `CloudConfig.uploadInterval`.
  //
  //   cloud HSI auto-enqueue: listening (engine HSI → ingest queue)
  //   ingest POST succeeded | url=…/ingest/v1/hsi status_code=200
  //
  // So `Synheart.ingestion.enqueueHsiWindows(...)` is NOT part of the normal
  // path — the runtime's own log calls it the fallback for "if engine skips
  // this channel". Calling it per window on top of the automatic bridge queues
  // every window twice.
  //
  // What is worth having is visibility, and a way to force a flush rather than
  // waiting out the interval. That is all this section does.

  int _uploadedCount = 0;
  String? _uploadError;
  DateTime? _lastFlushAt;
  bool _isFlushing = false;

  int get uploadedCount => _uploadedCount;
  String? get uploadError => _uploadError;
  DateTime? get lastFlushAt => _lastFlushAt;
  bool get isFlushing => _isFlushing;

  /// Windows the runtime has queued but not yet POSTed. Climbs on its own as
  /// windows close, and drains on the runtime's own upload interval.
  int get uploadQueueLength => Synheart.uploadQueueLength;

  /// POST whatever is queued now, instead of waiting for the runtime's own
  /// interval. Safe to call when the queue is empty.
  Future<void> flushUploads() async {
    if (!uploadConfigured || _isFlushing) return;
    _isFlushing = true;
    notifyListeners();
    try {
      final result = await Synheart.ingestion.flushIfEligible();
      _lastFlushAt = DateTime.now();
      if (result.success) {
        _uploadedCount += result.uploaded;
        _uploadError = null;
      } else {
        // Surfaced rather than swallowed: the common failures here are a
        // missing cloud-upload consent and an unregistered device, and both
        // look identical to "nothing happened" if the message is dropped.
        _uploadError = result.errorMessage ?? 'flush failed';
      }
    } catch (e) {
      _uploadError = '$e';
    } finally {
      _isFlushing = false;
      notifyListeners();
    }
  }

  /// The provenance claim on the registered device: `attested`, `unattested`,
  /// or `unknown`.
  ///
  /// Worth surfacing rather than collapsing into "registered": a device
  /// admitted through development mode signs every request with a real
  /// hardware key and can ingest normally, but carries no provenance claim.
  /// Treating it as equivalent to an attested device is the mistake this
  /// distinction exists to prevent.
  String get attestationClaim {
    final raw = attestationStatus?['attestation'];
    return raw is String && raw.isNotEmpty ? raw : 'unknown';
  }

  /// Force a registration attempt without waiting for a consent change.
  /// Returns false when device auth is not configured.
  Future<bool> registerDevice() async {
    final ok = await Synheart.ensureDeviceAuthRegistered();
    notifyListeners();
    return ok;
  }

  /// Refresh the current identity's server attestation without rotating it.
  Future<bool> reattestDevice() async {
    final ok = await Synheart.reattestDeviceAuth();
    notifyListeners();
    return ok;
  }

  /// Whether the loaded runtime exposes the lab session ABI.
  ///
  /// Worth surfacing next to `missingSymbols`, because that list does NOT cover
  /// it. Most lab operations (`lab_start`, `lab_open_window`, `lab_finalize`, …)
  /// are bound eagerly rather than through the guarded optional path, so an
  /// absent one throws on first access instead of being recorded as missing.
  /// `is_lab_available` is the SDK's documented gate — check it before calling
  /// any lab API.
  bool get isLabAvailable => Synheart.isLabAvailable;

  /// HSI windows buffered during the session, capped by the SDK.
  List<String> get sessionWindows => Synheart.getSessionHsiWindows();

  // ── 5. Teardown ────────────────────────────────────────────────────────

  /// Stop and release everything, returning to the pre-initialize state.
  Future<void> shutdown() async {
    await stopSession();
    try {
      await Synheart.dispose();
    } catch (_) {
      // Dispose is best-effort; nothing useful to do if teardown throws.
    }
    _isInitialized = false;
    _consentForm = null;
    _consentState = null;
    _latestState = null;
    _hsiWindowCount = 0;
    _session = null;
    notifyListeners();
  }

  /// Erase every byte the SDK holds on this device.
  Future<void> wipeLocalData() async {
    await Synheart.wipeLocalData();
    // The host's own snapshots are NOT runtime storage — they live in this
    // app's preferences, so `Synheart.wipeLocalData()` does not touch them.
    // Leaving them behind would restore the wiped baselines on the next
    // launch, which makes the erasure look like it silently failed.
    await host.clearSnapshots();
    _latestState = null;
    _hsiWindowCount = 0;
    await refreshConsent();
  }

  @override
  void dispose() {
    _hsiSub?.cancel();
    _wearSub?.cancel();
    _behaviorSub?.cancel();
    _lifecycleListener?.dispose();
    host.dispose();
    super.dispose();
  }
}
