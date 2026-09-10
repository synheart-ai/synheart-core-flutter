# Mobile host implementation guide (C ABI / SDK level)

> **This is the authoritative mobile host guide.** It is deliberately outside
> the book: the book documents the C ABI surface chapter by chapter, this
> documents *what a mobile SDK team has to build*, which is a project plan with a
> shelf life rather than a reference.
>
> For the per-symbol reference — ownership, return codes, worked Dart/Swift
> snippets — see the book's **Engine and HSI** section, starting at
> [`book/src/engine/overview.md`](../book/src/engine/overview.md). Where the two
> disagree, the book wins on symbol detail and this wins on sequencing and
> status.
>
> `synheart-engine-runtime`'s `book/src/getting-started/mobile-integration.md`
> covers the same ground at the **Rust/engine** level for engine integrators.
> Keep that one about `PipelineConfig`, `declare_rest_window`, `flush_pending`
> and `SensingProfile`; keep host/FFI/Dart specifics here.

**Audience:** the teams building `synheart-core-flutter`,
`synheart-behavior-flutter`, `synheart-wear-flutter`, and any Swift/Kotlin host
that links the core-runtime dylib directly.

**Engine baseline:** `synheart-engine` **0.16.0** (mobile-adoption cycle,
blockers B-0, B-2, B-3, B-5, B-6, B-12, B-12b).

**Legend** — ✅ available · ◐ partial or wrong · ❌ absent · ⛔ impossible on this
platform.

---

## 0. Layering — who owns which line of code

| Layer | Owns | Repo |
|---|---|---|
| Engine | `Pipeline`, heads, scores. Rust only, no FFI. | `synheart-engine-runtime` |
| Core runtime | The C ABI (`synheart_core_*`), config JSON, session lifecycle, storage, sync. | `synheart-core-runtime` |
| Platform SDK | Dart/Swift/Kotlin bindings over the C ABI. | `synheart-core-flutter`, `SDK/` |
| App | Sensor capture, permissions, scheduling, UI. | `synheart-life-mobile-app` + the `*-flutter` collectors |

Two distinct FFI families exist and they are **not** interchangeable:

- `synheart_core_*` — the full runtime handle (`SynheartHandle`): storage, sync,
  consent, sessions, plus the pipeline. This is what a product app uses.
- `synheart_core_edge_*` — a bare `EdgeHandle` around the engine only, no
  storage or sync. Used by the workbench and embedded/edge integrations.

**Every mobile item below is stated against the `synheart_core_*` family.** Where
an edge equivalent exists it is named `synheart_core_edge_<same suffix>`.

**String contract:** every `*mut c_char` returned by the ABI must be released with
`synheart_core_free_string` (edge family: `synheart_core_edge_free_string`).
Never `free()` it and never let a Dart `Finalizer` do it.

---

## 1. Binding gaps — what to fix first

The C ABI is complete. **The Dart binding layer is not**, and that is where the
mobile stack is losing data. Verified against the current `synheart_core_*`
export list:

| Capability | C ABI | Dart binding | App calls it |
|---|---|---|---|
| `synheart_core_push_rr` / `push_rr_batch` | ✅ | ✅ | ✅ |
| `synheart_core_push_hr` | ✅ | ✅ | ◐ only via `ingest_batch` |
| `synheart_core_push_vendor_hrv` / `push_vendor_vitals` | ✅ | ✅ | ✅ |
| `synheart_core_push_accel` | ✅ | ✅ | ❌ `emitRawMotionSamples` never enabled |
| `synheart_core_push_speed` | ✅ | ❌ | ❌ |
| `synheart_core_push_behavior` (legacy int) | ✅ | ✅ | ◐ code 2 only, from the IME |
| `synheart_core_push_behavior_event` (rich JSON) | ✅ | ❌ **bind this first** | ❌ |
| `synheart_core_push_context_event` | ✅ | ❌ | ❌ |
| `synheart_core_declare_rest_window` | ✅ | ❌ | ❌ |
| `synheart_core_flush_pending` | ✅ | ❌ | ❌ |
| `synheart_core_roll_day` | ✅ | ❌ | ❌ |
| `synheart_core_srm_push_wearable_daily` | ✅ | ✅ | ❌ never called |
| `synheart_core_export/load_srm_snapshot` | ✅ | ✅ | ❌ never called |
| `synheart_core_export/load_longitudinal_snapshot` | ✅ | ✅ | ❌ never called |
| `synheart_core_set_accel_placement` | ✅ | ✅ | ❌ |
| `synheart_core_tick` / `tick_all` | ✅ | ✅ | ◐ 1 s timer, keyboard sessions only |

Two consequences worth stating plainly:

- `push_behavior_event` carries the **typed payload**. The legacy
  `push_behavior(ts, code, value)` has none, so a notification pushed that way
  has `action: None` and a typing event has an all-`None` `TypingSessionData`.
  Section 5 is entirely blocked on this one binding.
- `PhoneModule` emits `Random()` for motion, screen state, app focus and
  notifications, and `startPhoneCollection()` is never called. Replace it or
  delete it — mock data reaching the engine is worse than no data, because
  withholding stops working.

---

## 2. Configuration — the four declarations that change output

Pass these in the config JSON handed to `synheart_core_new` /
`synheart_core_ensure_pipeline` (edge: `synheart_core_edge_create`).

```jsonc
{
  "platform": "android",              // or "ios" | "ipados" | "watchos"
  "window_ms": 60000,
  "step_ms": 60000,
  "behavior_enabled": true,           // false on watch

  "sensing": "auto",                  // or the object form, §2.2
  "device_class": "auto",             // "desktop"|"phone"|"tablet"|"watch"
  "mask_profile": "auto",             // "desktop"|"mobile"
  "cfi_structural_components": 4      // Android + mobile mask only
}
```

`"auto"` resolves through core-runtime's `engine::host_declarations` tables from
your `platform` string. **`"auto"` is the recommended setting for a new mobile
integration**; the tables are the maintained answer and you do not want to
re-derive them per app.

### 2.1 Why these are opt-in rather than derived from `platform`

Each one changes engine output for a host already in the field, so the default
is "undeclared" and reproduces pre-0.16.0 behaviour exactly:

| Declaration | What changes the moment you declare it |
|---|---|
| `device_class` | Folds into the SRM `config_hash`. **Every persisted baseline snapshot stops loading** (`ERR_SRM_CONFIG_MISMATCH`) and the person re-warms 30 observations across 3 distinct days. |
| `sensing` | Appended to `config_id`. `episodic` additionally **withholds Capacity and Mental Fatigue** from every frame. |
| `mask_profile: mobile` | Admits the hesitation bit in the `Communication` and `WritingEditing` context rows — moves Focus and Cognitive Load. |
| `cfi_structural_components: 4` | **Lowers** `conf_CFI` for identical evidence. It widens the coverage denominator; that direction surprises people. |

Declare them once at first launch and keep them stable. Changing `device_class`
mid-life is a baseline reset, not a config tweak.

### 2.2 The `sensing` object

```jsonc
"sensing": {
  "mode": "episodic",                 // REQUIRED: "continuous" | "episodic"
  "lateness_budget_ms": 120000,       // optional, default 0
  "streams": {                        // optional; omit to take the platform roster
    "cardiac": true,
    "accelerometer": true,
    "keystrokes": true,
    "pointer": false,
    "app_focus": false,
    "notification_arrivals": false,
    "notification_responses": false,
    "screen_state": true
  }
}
```

- `mode` may **not** be omitted. Continuous-vs-episodic is the whole claim, and
  guessing it is exactly what ruling B-0 forbids. An object with no valid `mode`
  is dropped entirely (with a log line), leaving you undeclared.
- The roster is a **closed, versioned set**. A stream you do not name is declared
  *unavailable*, not merely absent — that is what lets a consumer distinguish
  "iOS structurally cannot see notifications" from "this host predates the
  field". The roster id rides on the wire as
  `meta.synheart.sensing.roster_version`.
- Platform defaults: Android → `ANDROID` continuous; desktop → `DESKTOP`;
  watch → `WATCH`; **iOS → `IOS_EPISODIC`**.

**iOS `continuous` is a claim only you can make.** An iOS app holding a BLE
connection to a strap stays alive and streams all day; the same app without one
gets whatever foreground slices the user grants. `"auto"` picks `episodic`
because its failure mode is honest — it withholds the two stateful heads with a
reason rather than publishing torn session clocks as trajectories. If you *do*
hold a live peripheral connection, declare `{"mode":"continuous", …}` explicitly
and both heads come back.

### 2.3 Settings no host currently passes

`hr_max_bpm`, `subject_age_years`, `hr_rest_bpm` are `None` everywhere in the
stack, so heart-rate-reserve features run on fallbacks and daily `hr_load` is
withheld outright. Pass at least `subject_age_years` from the user profile.

`subject_id` must be `sub_…` and `session_id` `sess_…`; the engine returns an
error on a bad prefix and the ABI surfaces it. Handle it — do not unwrap.

### 2.4 Kinematic heads

Opt-in via `extra_heads`:
`["movement_regularity","postural_state","activity_state","locomotion_state"]`.
They withhold unless you also declare a placement (§4.3).

---

## 3. Cardiac

### 3.1 Use `push_rr_batch`, not a per-RR loop ◐

One BLE Heart Rate Measurement notification carries **several RR intervals under
a single arrival timestamp**. Pushing each one separately with that same arrival
time collapses every beat in the packet onto one instant;
`synheart_core_push_rr_batch(h, anchor_ts_ms, rr_ms[], len, order)` reconstructs
a per-beat cardiac clock from the anchor.

The binding already exists on the Dart facade — this is a call-site change.

### 3.2 Per source

| Source | Call | Notes |
|---|---|---|
| BLE HRM strap | `push_rr_batch` + `push_hr` | The only always-available true-RR path |
| Apple HealthKit `HKHeartbeatSeries` | `push_rr_batch` | Retrospective — see §6.3 |
| Garmin BBI | `push_rr_batch` | |
| Health Connect / Whoop / Fitbit / Oura | `push_vendor_hrv`, or the daily path (§8) | **No RR** — aggregates only |

**Do not send `0.0` for a missing field** in `push_vendor_hrv`. A measured zero
and an absent measurement are different things to every head that reads them.
Send only what you have.

### 3.3 `push_vendor_hrv` is the *windowed* path, not the backfill path

Vendor HRV is no longer gated on ordering at all (§6.3), so a rollup describing
a window minutes or hours in the past is accepted rather than rejected. But it is still read **by window range**, and windows
are emitted in non-decreasing start order and never re-emitted. A rollup stamped
before the current window cursor is accepted, buffered, pruned, and matched by no
window — silently.

A WHOOP or Garmin summary for 03:00 landing at 09:00 is not a lateness budget
case. **Send those through the day-indexed path** (`srm_push_wearable_daily`,
§8), which has no cursor to miss.

---

## 4. Motion

### 4.1 Fix the Android sample rate ◐ **bug**

`MotionSignalCollector.kt` uses `SENSOR_DELAY_NORMAL` (~5 Hz) while its own class
doc claims 50 Hz. iOS is genuinely 50 Hz (`accelerometerUpdateInterval = 0.02`).
The two platforms are an order of magnitude apart. Use `SENSOR_DELAY_GAME`, or an
explicit `samplingPeriodUs = 20000`.

### 4.2 Actually forward it ❌

`emitRawMotionSamples` defaults to `false` and the app never enables it, so the
accel subscription is never created and `push_accel` is never called.
Units: **m/s², gravity included**.

### 4.3 Declare the placement, or the kinematic axes stay dark ❌

`synheart_core_set_accel_placement(h, placement)`. The validated envelope is
**`Pocket` and `Waist` only**. `Wrist` and `Chest` are body-worn but out of
envelope; `Unknown` — the default — withholds all four kinematic heads.

**The part you cannot design around:** there is no hand-held placement. During
exactly the interaction the digital axes measure — typing, scrolling — the phone
is in the hand, which is not declarable. Placement must therefore be **dynamic**,
re-declared as it changes, and the kinematic and behavioural axes will be largely
disjoint in time. A fixed compile-time `Pocket` is wrong: a phone on a desk is not
body-worn, and the suppression exists precisely to stop desk vibration reading as
physiology-relevant motion.

Until a labelled 50 Hz dataset validates pocket geometry, treat mobile kinematics
as a **validation target, not a shipped capability**.

### 4.4 GPS speed ❌

`synheart_core_push_speed(h, ts_ms, speed_mps)` — **no Dart binding today**.
Unwired on desktop too, which is why `locomotion_state` runs permanently on its
low-confidence accel-only fallback. A phone has GPS; this is a cheap win.

Speed is the one **wholly ungated** channel: it is drained by window range and
reduced to a median, so ordering does not matter and out-of-order GPS is never
dropped.

---

## 5. Interaction — the biggest gap

### 5.1 Bind `push_behavior_event` ❌ **blocking**

`synheart_core_push_behavior_event(h, event_json)` takes the typed event as JSON
and returns an `int` status. Everything in this section depends on it.

### 5.2 What to emit, and from where

| Event | Populate | Android | iOS |
|---|---|---|---|
| `Touch { duration_ms, long_press }` | both | ✅ global via `Window.Callback` | ✅ tap + long-press recognisers |
| `Scroll { velocity, direction, direction_reversal }` | **all three** | ◐ captured, direction and velocity dropped before the engine | ◐ same |
| `Swipe { direction, velocity }` | both | ✅ | ✅ |
| `AppSwitch { from_app_id, to_app_id }` | **both ids** | ❌ carries only a duration — needs `UsageStatsManager` | ⛔ no API |
| `NotificationReceived { action, source_app_id }` | both | ◐ `NotificationListenerService` written and reports `REASON_CLICK`, **but the manifest never declares it** | ⛔ `action` always `None` |
| `Typing { TypingSessionData }` | §5.3 | ◐ `TextWatcher` sees only native `EditText` | ◐ keyboard extension only |
| `TaskSuccess` / `Failure` / `Return` / `Abandonment` | — | your own workflows | your own workflows |

**Three fixes, in value order:**

1. **Declare the notification listener in the app manifest.** The collector
   already works — it is simply not registered. One manifest block.
2. **Add `UsageStatsManager`** (permission `PACKAGE_USAGE_STATS`). Without it
   there is no `AppSwitch` identity, no app category, and **no context layer at
   all** on Android.
3. **Forward scroll direction and velocity** — captured and then discarded.

### 5.3 `TypingSessionData` — emit a 10 s micro-window summary ❌

The richest input the engine takes, and mobile produces none of it. Desktop
aggregates raw key events into 10 s micro-windows and emits one `Typing` event
per window at `ts_ms = window_start_ms`. Mirror that shape.

Highest-value fields: `typing_tap_count`; `number_of_backspace` /
`number_of_delete` (**these produce `typing.correction_rate`, which Focus and CFI
both read — without them the friction index has nothing**); `typing_speed_cpm`,
`duration_sec` (measured first→last span, not the window length);
`mean_inter_tap_interval_ms`, `typing_cadence_stability`,
`typing_cadence_variability`, `pause_count` (gaps > 500 ms); then the burstiness
/ shortcut / hold-time family.

Set only what you can measure and leave the rest `null` — a `null` is withheld
and renormalised out, a `0.0` is a measured zero.

### 5.4 Do not double-count

Desktop feeds raw events to the context buffer **and** the translator, but sends
only the translator's summary to the engine. Push both raw keystrokes and a
windowed summary and every rate feature roughly doubles.

### 5.5 Android app context

With `UsageStatsManager` in place, feed the foreground app through
`synheart_core_push_context_event`. **Send the app *category*, never a context
label.** The engine derives the 12-class `ContextLabel` (AP/CD/WE/RR/BR/…)
itself; two-letter app codes collide with live label codes (`BR` is
`BreakRecovery`, not "browsing/reading").

Android keys are **package names** (`com.google.android.gm`); the lookup is
case-insensitive. An unmapped package resolves to `UNKNOWN`, whose
interpretation-mask row is all zeros — a missing table row silently blinds every
behavioural stream while that app is in front, so file additions upstream rather
than shipping a local map.

---

## 6. Tick and lifecycle

### 6.1 Tick every second, for the whole session ◐

There is no internal ticker. `ingest_batch` advances the clock but `push_behavior`
does not, so a typing-only session emits **zero HSI windows** without an explicit
tick. The app's 1 s timer exists but runs only during keyboard sessions.

After any gap call `synheart_core_tick_all(h, now_ms)` rather than `tick`, so no
completed window is skipped. `tick` polls one window; `tick_all` drains them all.

### 6.2 Keep the process alive

| Platform | Mechanism | Status |
|---|---|---|
| Android | Foreground service, `dataSync` | ◐ the service exists but is started **from the IME**, so it only covers typing. Start it for the whole sensing session. |
| iOS | `bluetooth-central` + a connected peripheral | ✅ declared. **This is what keeps the runtime alive on iOS.** No strap ⇒ foreground-only ⇒ declare `episodic`. |

### 6.3 Ingest is now per-modality — and what that does *not* fix

0.16.0 split the single monotonic ingest gate into five independent watermarks:
`rr`, `hr`, `vendor_hrv`, `accel`, `behavior`. The fastest stream no longer
starves the slower ones — pushing a whole accel block and *then* the window's RR
is fine, where it used to drop almost everything. The per-channel rejection counts
are in `synheart_core_diagnostics` under
`out_of_order_by_channel.{rr,hr,vendor_hrv,accel,behavior}`.

**Only cardiac and motion require ordering.** `rr`, `hr` and `accel` still
reject a backwards timestamp — their maths accumulates forward, and a backdated
sample corrupts HRV and the dropout count. `behavior` and `vendor_hrv` are
**counted but accepted**: both are sorted before use downstream, and rejecting
them defeated the exact cases they exist for. So you may push a
keyboard-extension backlog stamped in the past *after* live screen-on and
app-switch events, and a WHOOP/Garmin HRV rollup describing a window from an hour
ago, and both land.

`out_of_order_by_channel` still counts them, so the counter stays an honest
description of your feed rather than only of its rejections — a non-zero
`behavior` count is information, not an error.

**One limit survives, and it bites on mobile:** the window cursor still loses
late data. A sample older than the current window is accepted by the gate and
then read by no window, without tripping any counter. The sensing lateness budget
is how you widen that horizon; §6.4 is how you work inside it.

### 6.4 Draining a retroactive source

**Rule: drain the shared container before the `tick` that closes the window those
events belong to.** On wake: drain first, then tick.

If your flush cadence is longer than one window, declare a lateness budget
(§2.2). The engine then holds every completed window for that long and emits it
**once, complete, just later** — the frame's content is unchanged, only its
emission tick moves. The hold is pipeline-wide, not per-channel, because Capacity
and Mental Fatigue integrate a trajectory and cannot tolerate a cardiac-only
window overtaking a deferred one.

Call `synheart_core_flush_pending(h, now_ms)` on backgrounding and at session end,
or up to one budget's worth of windows is stranded forever. It returns the same
JSON array `tick_all` does; free it with `synheart_core_free_string`.

### 6.5 Declare rest ❌

```c
synheart_core_declare_rest_window(h, ts_ms);
```

Without this, **Focus is never zeroed on a break and Capacity never takes the
recovery path** — there is no context module on mobile to derive it, so break
windows currently score as engaged.

Composite definition: screen off ≥ 2 min **and** no interaction **and** low
motion, with a wall-clock sleep window as an override. Screen-off alone is not
rest — someone watching a video is screen-on and resting; someone in a meeting is
screen-off and working.

Semantics, in the order they bite:

- `ts_ms` is epoch ms on the same clock as every `push_*`. The declaration is
  applied to the window whose bounds **contain** that timestamp — not to
  whichever window happens to emerge next. Those differ whenever a lateness
  budget is deferring emission.
- It is **one-shot**, deliberately. A sticky flag a host forgot to clear would
  pin Focus at exactly `0.0`, stop Capacity depleting and freeze Mental Fatigue's
  engaged clock for the rest of the session, silently. Call it once **per rest
  window**, not once when a break begins.
- A declaration whose window has already been emitted is discarded, not applied
  to a later one.
- It is echoed on `meta.synheart.sensing.rest_declared` — but only if you also
  declared a `sensing` profile, since that is the block it rides on. Without one
  the gating still works and the `focus = 0.0` is correct, but nothing on the
  wire explains it.

---

## 7. Persist three snapshots, not one ❌

The app persists none of these; it relies on runtime-side SQLite, which covers
session state only.

| Snapshot | Carries | Persist when |
|---|---|---|
| `synheart_core_export_session_state` | Capacity, Mental Fatigue, Stress, Valence + the context engine | once per emitted window, and on background/terminate. **Load before the first `tick`.** |
| `synheart_core_export_srm_snapshot` | the personal SRM baseline | session end. Without it the baselines report `Warming` forever across launches. |
| `synheart_core_export_longitudinal_snapshot` | wearable reference, 7-night sleep ring, **today's partial daily accumulator** | after every `srm_trigger_wearable_recompute` and every sleep-score attach. Without it a mid-day relaunch discards the morning's cardiovascular load. |

**Keep one SRM file per `device_class`.** A cross-class load is rejected with
`ERR_SRM_CONFIG_MISMATCH` — that rejection is the B-6 baseline partition working,
not a bug. A rejected snapshot needs no handling beyond logging; the engine starts
cold.

`load_session_state` must run **before the first `tick`**: window 1 writes each
head's state slot, so a later restore is overwritten by a cold window and the
context baseline has already counted one window against the wrong history.

---

## 8. The daily loop — nobody has built this ❌

Desktop implements none of it, so there is no reference to copy. Mobile needs it,
because Recovery, Readiness, Strain and Sleep are **daily** scores with no live
per-window head.

1. `synheart_core_roll_day(h, day_index)` at session start and at the user's
   **local** midnight. Skip it and the engine adopts a provisional **UTC** day,
   which is wrong for most of the world. `day_index` is days since epoch in the
   host's zone; it must strictly advance (a repeat or a negative returns
   `ERR_DAILY_DAY_NOT_ADVANCING`). **No Dart binding — add one.**
2. `synheart_core_srm_push_wearable_daily(h, dimension, day_index, value,
   confidence, fidelity)` from HealthKit / Health Connect. Dimensions:
   `sleep_need`, `sleep_regularity`, `hrv_rmssd`, `hrv_sdnn`, `resting_hr`,
   `recovery_score`, `deep_sleep_min`, `rem_sleep_min`, `daily_strain`.
   `fidelity`: `0` raw, `1` provider summary. **This is the only baseline path
   for a phone with no live wearable session** — bound already, never called.
3. `synheart_core_srm_trigger_wearable_recompute(h, 0, as_of_day)`, then persist
   the longitudinal snapshot.
4. Compute and attach the daily scores, then call
   `synheart_core_attach_recovery_score_today` — a **different call** from the
   display attach (`attach_recovery_score_json`). A host that wants both must
   make both.

This needs a scheduled job (`workmanager` / `BGTaskScheduler`). There is none.

---

## 9. Rendering rules — non-negotiable

### 9.1 Handle withheld readings

A reading with no contributing modality is **omitted**, with its reason in
`meta.synheart.state_withheld`. On mobile that is the common case:

| Situation | Result |
|---|---|
| No wearable | `arousal` absent — it is cardiac-only |
| No task events | `valence` absent |
| `sensing.mode = "episodic"` | `capacity` and `mental_fatigue` absent, reason `episodic_sensing` |
| iOS | the Interruption Pressure axis absent entirely |

Never index `axes.*` by position, never assume a fixed member set, and **never
paint a default**. A card showing a neutral 50 where a value was withheld is
exactly the "Stress pinned at 100 / Recovery pinned at 50" failure that
withholding exists to prevent.

A canonical member is complete over `axes.<domain>` ∪
`meta.synheart.state_withheld` — check both before concluding a member is
unsupported.

> **Episodic suppression is applied at the source.** The engine stores the
> already-suppressed set, so `synheart_core_last_hsv` and the HSI frame agree:
> on an episodic host neither will show `capacity` or `mental_fatigue`. (Through
> an earlier 0.16.0 build `last_hsv` returned the raw set and leaked both values
> past the withholding — if you are pinned to a build before that fix, render
> from the HSI frame.)

### 9.2 Valence

**Valence does not report on mobile at launch.** The phone task-event vocabulary
is too inferred to meet its own standard. Remove the card rather than defaulting
it; log candidate events for research.

### 9.3 Daily scores are not per-window

`recovery`, `readiness`, `strain`, `sleep_score` are daily attaches consumed by
exactly one emitted HSI. A UI showing them every window has no engine source.

### 9.4 New notes to handle

- Capacity may carry `cold_start_confidence_exhausted` — a real reading at
  confidence `0`, produced when the additive cold-start penalty consumes the whole
  multiplicative confidence chain. Render it as unavailable, not as a score.
- `meta.synheart.sensing` is present only when you declared a profile. Consumers
  comparing across platforms should **stratify on this block rather than pooling**:
  an iOS Cognitive Load built without notification observation and without a
  context layer is measuring a structurally thinner subset of the same construct.

### 9.5 `config_id` is your comparability key

`synheart_core_config_id` changes whenever anything value-affecting changes,
including the `sensing` and `mask_profile` declarations. Persist it beside any
cached score; a score computed under a different `config_id` is not comparable to
a new one.

---

## 10. Priority order

1. Bind `push_behavior_event` — all of §5 is blocked on it.
2. Declare the notification listener in the app manifest (one block; the collector
   is already written).
3. Fix the Android accel rate, enable `emitRawMotionSamples`, declare placement.
4. Tick for the whole session, not just keyboard sessions.
5. Bind and call `declare_rest_window` — break windows currently score as engaged.
6. The three snapshots, one SRM file per `device_class`.
7. `sensing` + `device_class` + `mask_profile` + `cfi_structural_components`
   (`"auto"` everywhere is a valid first cut).
8. `UsageStatsManager` → app identity → `push_context_event` (Android only).
9. Bind `roll_day` + `flush_pending` + `push_speed`; build the daily loop and its
   scheduled job.
10. Replace `PhoneModule`'s mock collectors, or delete them.

---

## Related

- `synheart-core-runtime` — `crates/core-runtime/src/engine/host_declarations.rs`
  (the `"auto"` resolution tables), `src/ffi/session_io.rs`, `src/edge_ffi.rs`
- `synheart-engine-runtime/docs/rule-pack/MOBILE-ADOPTION-BLOCKERS-2026-09-03.md`
  — B-0 … B-12b as raised
- `synheart-engine-runtime/docs/rule-pack/MOBILE-ADOPTION-IMPLEMENTATION-2026-09-04.md`
  — what shipped and why
- `synheart-engine-runtime/book/src/pipeline/signals.md` — ingest gating and the
  lateness budget, at the Rust level
- `synheart-engine-runtime/book/src/getting-started/state-and-persistence.md` —
  the three snapshots, at the Rust level
