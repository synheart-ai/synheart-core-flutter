# Integration guide

The ordered path from an empty project to a device that collects HSI locally
and uploads it. Each part ends in something you can verify, so a failure is
attributable to the step that caused it rather than discovered three steps
later.

The SDK reference lives in [README.md](../README.md). This document is the
walkthrough: what to do, in what order, and what each step is for.

**Contents**

1. [Platform prerequisites](#1-platform-prerequisites)
2. [Install](#2-install)
3. [Configure](#3-configure)
4. [Consent](#4-consent)
5. [Collect](#5-collect)
6. [Upload](#6-upload)
7. [Device attestation](#7-device-attestation)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Platform prerequisites

Everything here happens at [platform.synheart.ai](https://platform.synheart.ai)
before you write any code. The SDK runs **local-only with none of it** — see
[Running without cloud credentials](../README.md#running-without-cloud-credentials)
— so skip to [Install](#2-install) if you only need on-device HSI. Cloud upload
needs all eight.

They are ordered because each depends on the one above it.

### 1.1 Create a platform account

Your login. Nothing in the SDK reads it.

### 1.2 Create an organization

The billing and ownership boundary. Yields an **`org_…` id**, which the SDK
takes as `CloudConfig.orgId`.

This id is load-bearing beyond identification: the runtime enables cloud ingest
only when `org_id` is non-empty, and **rejects the entire configuration** if
ingest is enabled without one. A missing org id therefore surfaces as a null
runtime handle rather than a targeted error.

### 1.3 Create a tenant

The data-isolation boundary within the organization — one tenant per
environment (development, staging, production) is the usual shape. Yields a
**`ten_…` id**.

The Flutter SDK does **not** consume the tenant id. The runtime configuration
carries `app_id` and `org_id` only. It appears in your credential file for use
by platform APIs the SDK does not call; setting it changes no SDK behavior.

### 1.4 Create a project

Groups the apps that belong to one product line inside the tenant. Yields a
**`prj_…` id**.

Like the tenant, the Flutter SDK does **not** consume it — the runtime
configuration carries `app_id` and `org_id` only. It is issued into the same
credential file for platform APIs outside this SDK.

### 1.5 Create an app

One per shipping application, per environment. Yields an **`app_…` id**, which
the SDK takes as `SynheartConfig.appId`.

This is the point at which the credentials become downloadable — the app is the
last of the four ids to be issued, so the file is complete only once it exists.
See [1.6](#16-download-the-credentials).

**Use a separate app id for development.** [Development mode](#73-development-builds-that-cannot-attest)
is enabled per app id, and it must never be enabled on the id your store build
uses.

> **`app_…` is not your bundle id.** `SynheartConfig.appId` is the
> platform-issued `app_…` identifier that an ingest scope resolves from.
> `DeviceAuthConfig.packageName` is the real installed bundle id
> (`com.example.my_app`), which Play Integrity and App Attest verify against.
> They are different values and are not interchangeable — passing the `app_…`
> id as the package name fails attestation.

### 1.6 Download the credentials

**Download the credentials from the platform** once the app exists — do not
transcribe the four ids by hand from separate screens. The platform emits them
together as a single JSON file:

```json
{
  "org_id":     "org_…",
  "tenant_id":  "ten_…",
  "project_id": "prj_…",
  "app_id":     "app_…"
}
```

All four are identifiers, not secrets — there is no API key or signing secret
among them. They are still organization-specific, so keep the downloaded file
out of version control ([3.3](#33-keep-populated-files-out-of-git)).

Of the four, the SDK reads **`app_id`** (as `SynheartConfig.appId`) and
**`org_id`** (as `CloudConfig.orgId`). `tenant_id` and `project_id` are carried
in the same file for platform APIs this SDK does not call; setting them changes
no SDK behavior.

Downloading the file rather than copying values individually is worth insisting
on: `org_…`, `ten_…`, `prj_…` and `app_…` differ only by prefix, and a pair
swapped between two environments produces authentication failures that look
like a broken SDK.

> **Repeat 1.5 through 1.8 per platform.** Android and iOS are separate apps
> with separate `app_…` ids, so each needs its own **app policy**, its own
> **consent profile**, and its own development-mode setting. Provisioning one
> platform does not carry over.
>
> The failure this causes is quiet: the provisioned platform uploads happily
> while the other reports its consent gate closed, which reads like a
> platform-specific SDK bug rather than a missing profile.

### 1.7 Create an app policy

Declares what this app is permitted to collect and upload. The runtime
intersects the user's consent against it, which is why the **effective** state
can grant less than the user asked for. See [Consent](#4-consent).

### 1.8 Create a consent profile

The default profile for the app id. **Cloud upload does not work without it**,
and the failure is easy to misread.

Once a cloud consent client is configured, the runtime holds every consent type
closed until the consent service issues a **token**, whatever the user chose.
No profile means no token, which means nothing uploads even though your consent
screen shows everything granted:

```
consent profile fetch deferred; keeping offline choice
  | GET …/consent/v1/sdk/{app_id}/consent-profile
    {"code":"PROFILE_NOT_FOUND","message":"Consent profile not found"}
```

Confirm it resolved before debugging anything else — the success line is:

```
default consent profile loaded | profile_id=…
consent token issued | expires_at_ms=… synced=true
```

---

## 2. Install

Two halves, and the order matters. The Dart package comes from pub; **the
native runtime does not** — it is proprietary and provisioned by the Synheart
CLI. Adding the dependency alone gives you a package that loads no runtime and
produces no HSI.

### 2.1 Add the package

```yaml
dependencies:
  synheart_core: ^0.11.0
```

```bash
flutter pub get
```

### 2.2 Install the CLI

Full instructions, including platform-specific notes and alternatives to the
install script: **<https://docs.synheart.ai/setup/install-cli>**

```bash
curl -fsSL https://synheart.sh/install | sh
synheart --version
```

### 2.3 Authenticate

```bash
synheart login
```

This opens a browser against the account from
[1.1](#11-create-a-platform-account). The CLI needs it because the runtime
artifacts are not public — an unauthenticated `install` cannot fetch them.

### 2.4 Provision the runtime

Run these **from the Flutter project root**, not from a subdirectory — paths in
the generated lockfile are resolved relative to the working directory:

```bash
synheart install runtime
synheart install syni      # see below — required on iOS regardless of use
```

`synheart install syni` is **not optional on iOS even if you never use Syni.**
`synheart_core` depends on the `syni` package, whose iOS pod links its own
vendored framework, and `pod install` fails outright without it.

This writes a `synheart.lock` recording the resolved versions and a SHA-256 per
artifact. Commit it: teammates and CI run `synheart sync` against it to get
byte-identical runtimes. A lockfile that describes fewer packages than before
has lost a pin — regenerate rather than committing it.

### 2.5 Verify before writing any integration code

```dart
final diag = Synheart.runtimeDiagnostics();
print(diag['isAvailable']);      // true once the FFI bridge loaded
print(diag['missingSymbols']);   // empty on a matching runtime
```

`isAvailable: false` means the native library was not bundled — the usual cause
is a build that predates `synheart install runtime`. Run `flutter clean` and
rebuild; a stale build directory will happily keep shipping the old artifacts.

A non-empty `missingSymbols` means the runtime loaded but is a different version
from the one this SDK expects. Features bound through the guarded path degrade
rather than crash, so this is worth checking explicitly instead of discovering
it as a missing feature later.

---

## 3. Configure

### 3.1 Identity

```dart
SynheartConfig(
  appId:     'app_…',                  // from 1.4
  subjectId: 'usr_stable_identifier',  // YOUR account id
  deviceId:  'stable-installation-uuid',
)
```

`subjectId` **must be stable across restarts.** The runtime scopes storage,
baselines, and device identity to it, so a value that changes per launch looks
like a new person every time and baselines never mature. Both `appId` and
`subjectId` are required; `validate()` rejects an empty value before any native
work happens.

### 3.2 Endpoints

Supply credentials and endpoints through a dart-defines file rather than
inline flags:

```bash
cp env/synheart.endpoints.example.json env/endpoints.dev.json
flutter run --dart-define-from-file=env/endpoints.dev.json
```

| Define | Effect |
| --- | --- |
| `SYNHEART_BASE_URL` | Platform origin. Every per-service URL falls back to it. |
| `SYNHEART_AUTH_BASE_URL` | Auth service only. Optional. |
| `SYNHEART_CONSENT_BASE_URL` | Consent service only. Optional. |
| `SYNHEART_INGEST_BASE_URL` | Ingest service only. Optional. |

> **Set `SYNHEART_BASE_URL`, not just a per-service override.** A per-service
> override moves one service; everything else keeps resolving through
> `SYNHEART_BASE_URL`, which defaults to the production origin. Overriding auth
> alone points attestation at one environment while consent and ingest stay on
> another — a split that produces authentication failures with no obvious cause.

Base URLs are origins. The runtime appends service paths.

### 3.3 Keep populated files out of git

A filled-in defines file carries your organization's identifiers. Check in the
template only:

```gitignore
env/*.json
!env/synheart.endpoints.example.json
```

Add the same rule to `.pubignore` if you publish a package —
**`.pubignore` replaces `.gitignore` for publishing**, so a path excluded only
by `.gitignore` still reaches the archive.

---

## 4. Consent

### 4.1 The canonical flow

Read the runtime's editable form, edit it, submit it:

```dart
final form = Synheart.consentGetEditableFormTyped();
await Synheart.consentSubmitFormTyped(
  form: form!.copyWith(biosignals: true, allowCloud: true),
);
final effective = Synheart.consentEffectiveStateTyped();
```

This is offline-first: the runtime persists the choice immediately, then
reconciles it against the app policy and cloud profile.

`ConsentConfig` is **required** for this flow — `consentSubmitFormTyped` needs a
non-empty `deviceId` and `platform` to stamp on the submission, and returns
`null` without them.

### 4.2 Gate on the effective state, never the form

The runtime may grant less than was asked for, because the app policy (1.5)
constrains it:

```dart
if (effective?.biosignals != true) {
  // Do not collect. The submitted form said yes; the policy said no.
}
```

### 4.3 `hasConsent()` answers a different question

```dart
final granted   = Synheart.consentEffectiveStateTyped()?.cloudUpload;  // user's choice
final actionable = await Synheart.hasConsent('cloudUpload');           // enforceable now
```

Once a cloud consent client is configured, `hasConsent` returns `false` for
**every** consent type until the consent service has issued a token — whatever
the user chose:

```rust
if cloud_configured && self.consent_status() != ConsentStatus::Granted {
    return false;
}
```

So a `false` here does not mean the user declined. Use
`consentEffectiveStateTyped()` to read the choice, and `hasConsent()` to gate an
action that must not proceed without cloud confirmation.

### 4.4 Enablement and consent are both required

A feature collects only when its config is declared **and** its consent is
granted. Declaring `wearConfig` while being granted only `behavior` collects
nothing: wear is enabled but not permitted, behavior is permitted but not
enabled. `startSession()` enforces this and throws rather than starting a
session that can never produce data.

`cloudUpload`, `vendorSync` and `research` govern what happens to data once
collected — none of them makes a sensor readable.

---

## 5. Collect

```dart
final session = await Synheart.startSession();
Synheart.onStateUpdate.listen((state) { /* HSIState per window */ });
```

**The runtime closes a window about every 60 seconds**, and does so whether or
not signal arrived — emitting each axis at `confidence: 0` when it has no basis.
A climbing window count is not evidence that anything is being measured.

### What grounds which axes

| Axis | Domain | Needs |
| --- | --- | --- |
| `focus`, `capacity` | `cognitive` | physiological signal |
| `arousal`, `stress` | `affective` | physiological signal |
| `sleep` | `physiological` | physiological signal |
| `focusQuality`, `interruptionPressure`, `interactionMode` | `digital` | **interaction only** |

The five headline axes are physiology-derived: with no heart rate or HRV they
stay at zero confidence no matter how long the session runs. A phone with no
wearable has no biosignal source at all — most phones have no heart-rate sensor,
and a health datastore is only as useful as whatever writes into it.

The **digital** axes need no biosignal. They are derived from taps, scrolls,
swipes, app switches and notifications, so they resolve on any device:

```dart
if (state.hsi.hasDigital) {
  print(state.hsi.focusQuality?.value);
  print(state.hsi.interruptionPressure?.value);  // lower_is_more
  print(state.hsi.interactionMode?.value);       // bidirectional
}
```

Two properties to respect: `interruptionPressure` is `lower_is_more`, so a low
score means *more* interruption; `interactionMode` is `bidirectional`, so
neither end is "good". Rendering either like a conventional 0→1 quality bar
inverts its meaning.

Digital readings **lag one window**: the runtime flushes a closed window's
interaction events and attaches the result to the *next* emission, so the first
window of a session never carries them.

### Behavior needs a wrapper

Declaring `behaviorConfig` and granting `behavior` consent is not enough — the
SDK cannot observe gestures it is not wrapped around:

```dart
Synheart.wrapWithBehaviorDetector(yourAppContent)
```

It returns the child unchanged until the SDK is initialized and behavior consent
is granted, so wrapping early is safe.

---

## 6. Upload

**The runtime uploads on its own.** It subscribes to the engine's HSI
broadcast, enqueues each window into a local queue, and POSTs on
`CloudConfig.uploadInterval`. No host code is required:

```
cloud HSI auto-enqueue: listening (engine HSI → ingest queue)
ingest POST succeeded | url=…/ingest/v1/hsi status_code=200
```

The enqueue is gated on cloud-upload consent, and buffers the windows that
arrive during the cold-start token race so the first minute is not lost.

`Synheart.ingestion.enqueueHsiWindows(...)` exists as a fallback for hosts whose
engine skips that channel. **Calling it per window on top of the automatic
bridge queues every window twice.**

To observe, or to force a flush early rather than waiting out the interval:

```dart
print(Synheart.uploadQueueLength);   // climbs on its own, drains on the interval
print(Synheart.lastUploadAt);
print(Synheart.lastUploadError);

await Synheart.ingestion.flushIfEligible();
```

Upload requires all of: a non-empty `orgId`, cloud-upload consent, an issued
consent token ([1.8](#18-create-a-consent-profile)), and a registered device —
the runtime signs every ingest request with the device key.

---

## 7. Device attestation

### 7.1 What triggers it

**Registration is triggered by cloud-upload consent, not by `initialize()`.**
Configuring `DeviceAuthConfig` only makes it possible. Granting the consent
starts a seven-step flow in the background — it can park the calling thread for
seconds, so the SDK deliberately does not await it.

```dart
deviceAuthConfig: DeviceAuthConfig(
  authBaseUrl: 'https://api.synheart.ai',
  packageName: 'com.example.my_app',   // the BUNDLE id — see 1.4
),
```

Attestation and upload are independent opt-ins. Attestation needs
`DeviceAuthConfig` and nothing else — every registration trigger keys off it,
and none consults the cloud config, so an org id is not required to test it.

### 7.2 Reading a failure

Registration failures carry a `reason` that says what to do:

```dart
try {
  await Synheart.ensureDeviceAuthRegistered();
} on SyncNativeException catch (e) {
  switch (e.reason) {
    case 'unsupported':    runLocalOnly();  // and stop asking, across relaunches
    case 'misconfigured':  log.severe('Attestation setup is wrong: ${e.detail}');
    default:
      if (e.retryable) {
        scheduleRetry(Duration(milliseconds: e.retryAfterMs ?? 5000));
      } else {
        runLocalOnly();
      }
  }
}
```

| `reason` | Meaning | Action |
| --- | --- | --- |
| `transient` | Network or upstream blip | Retry ~5s |
| `timeout` | No verdict in time | Retry ~15s |
| `quota` | Rate limited | Retry much later |
| `unsupported` | No Play Services, emulator, de-Googled ROM, iOS Simulator | Local-only, stop asking |
| `misconfigured` | Not linked in Play Console, wrong project number | A developer must fix it |
| `server_transient` | Server reported its own outage | Retry ~30s |
| `policy` | Server refused, permanently | Do not retry |
| absent | Runtime or bridge predates the field | Treat as not retryable |

`e.detail` is diagnostics only — log it, never branch on it.

### 7.3 Development builds that cannot attest

A debug build, an emulator, or a de-Googled ROM produces no attestation
material, so the runtime skips registration and stays local-only:

```
WARN device auth: no attestation material - device cannot attest;
     skipping registration (local-only)
```

To let those builds register:

```dart
DeviceAuthConfig(
  authBaseUrl: authBaseUrl,
  packageName: packageName,
  allowUnattestedDevRegistration: kDebugMode,
)
```

**Two switches, both required.** The flag stops the SDK giving up client-side;
development mode must also be enabled for that app id server-side. With the
server switch off, the registration is sent and refused — one round trip later,
not silently. Nothing fake is transmitted: the request carries
`attestation.format = "none"` with an empty blob.

- Gate it on `kDebugMode` or a dev flavor so a store build cannot ship it on.
- Use the development app id from [1.5](#15-create-an-app). Never enable
  server-side development mode for a production app id.
- A device admitted this way is recorded **`unattested`**. It holds a hardware
  key and signs every request; it simply carries no provenance claim. Ingest,
  consent and sync all work.

```dart
Synheart.coreDeviceAuthStatus();
// {'status': 'registered', 'attestation': 'attested' | 'unattested' | 'unknown', …}
```

Do not collapse `unattested` into "registered" in your own telemetry — the
distinction is the point of attestation.

---

## 8. Troubleshooting

Keyed on what you will actually see.

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Initialization complete` but `runtimeDiagnostics()['isAvailable']` is false | Native runtime not bundled | `synheart install runtime`, then `flutter clean` |
| `appId must not be empty` | `appId` / `subjectId` unset | Both are required; `validate()` rejects empty |
| `startSession()` throws about consent | No enabled feature has matching consent | Grant a consent that pairs with a declared module ([4.4](#44-enablement-and-consent-are-both-required)) |
| Windows arrive, all axes `confidence: 0` | No biosignal source | Expected on a bare phone. Read the digital axes, or attach a BLE strap |
| No digital axes in the first window | One-window lag by design | Wait for the next emission |
| `PROFILE_NOT_FOUND` on the consent profile | No consent profile for the app id | [1.8](#18-create-a-consent-profile) |
| "cloudUpload consent not granted" while the UI shows it granted | No consent token issued | Almost always `PROFILE_NOT_FOUND` above |
| `REGISTRATION_REJECTED`, `reason: policy` | Server refused this device | Check the app id is provisioned in this environment |
| `no attestation material - device cannot attest` | Debug build or emulator | [7.3](#73-development-builds-that-cannot-attest) |
| Authentication fails only on some services | Split endpoints | Set `SYNHEART_BASE_URL`, not one override ([3.2](#32-endpoints)) |
| HSI produced, nothing uploads | Cloud gate closed | Check `lastUploadError`; the runtime uploads on its own once the gate opens |
| `pod install` fails on iOS | `syni` pod's vendored framework missing | `synheart install syni` |

### Read the runtime's own explanation first

When a call returns `false`, `null` or a failure code, the runtime has already
said why. Read it right after the call:

```dart
final removed = Synheart.deleteVendorEventsForProvider('garmin');
final e = Synheart.lastNativeError;      // SynheartNativeError?
if (removed < 0 && e != null && e.op == 'synheart_core_delete_vendor_events_for_provider') {
  switch (e.recoveryKind) {
    case NativeErrorRecovery.grantConsent:  // e.reason names the consent
    case NativeErrorRecovery.retry:         // honour e.retryAfterMs
    case NativeErrorRecovery.reportBug:     // send e.errorId + e.report
    default:
  }
  log('${e.code} in ${e.op}: ${e.hint} [${e.errorId}]');
}
```

| Field | Use |
| --- | --- |
| `code` | Stable; branch on it (`CONSENT_REQUIRED`, `NO_ACTIVE_SESSION`, …) |
| `recoveryKind` / `recoveryCall` | What to do, and the exact native call that does it |
| `ownerKind` | Who can fix it: `app`, `user`, `environment`, `service`, `runtime` |
| `reason`, `argument` | The narrower cause: which consent, which argument and how it was wrong |
| `message` | End-user copy; show it |
| `hint` | One developer sentence; log it, never parse it |
| `errorId` | Matches the native log line; quote it in bug reports |

Sync calls still throw `SyncNativeException`, which is a
`SynheartNativeException` carrying the same `SynheartNativeError`, so one
`catch` handles both. `lastNativeError` is null on runtimes older than ABI 2.0.

### Checklist before filing a bug

```dart
Synheart.lastNativeError;               // code, recovery, errorId of the last failure
Synheart.runtimeDiagnostics();          // isAvailable, missingSymbols
Synheart.consentEffectiveStateTyped();  // what the user actually has
await Synheart.hasConsent('cloudUpload');  // whether it is enforceable
Synheart.coreDeviceAuthStatus();        // status + attestation claim
Synheart.uploadQueueLength;             // is anything queued
Synheart.lastUploadError;               // why the last attempt failed
```

---

## See also

- [README.md](../README.md) — full API reference
- [example/](../example) — a runnable app that walks this same sequence
- [example/SETUP.md](../example/SETUP.md) — credentials and attestation testing
