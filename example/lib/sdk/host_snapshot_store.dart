import 'package:shared_preferences/shared_preferences.dart';

/// Persistence for the three runtime snapshots a mobile host owns (mobile host
/// guide §7), plus the two scalars that go with them.
///
/// ## Three, not one
///
/// The runtime's own SQLite covers session *state* only. Everything the engine
/// accumulates about the person lives in snapshots the host has to export and
/// re-load, and each one loses something different if you skip it:
///
/// | Snapshot | Carries | Cost of skipping |
/// |---|---|---|
/// | session state | Capacity, Mental Fatigue, Stress, Valence, context engine | every relaunch starts the stateful heads cold |
/// | SRM | the personal baseline | baselines report `Warming` forever across launches |
/// | longitudinal | wearable reference, 7-night sleep ring, today's partial daily accumulator | a mid-day relaunch discards the morning's cardiovascular load |
///
/// ## One SRM file per device class
///
/// The SRM key includes the declared `device_class`, because a cross-class load
/// is rejected with `ERR_SRM_CONFIG_MISMATCH` — the baseline partition working
/// as designed, not a bug. Storing one file for all classes means a phone and a
/// tablet take turns invalidating each other's baseline and neither ever
/// matures. A rejected load needs no handling beyond a log line; the engine
/// starts cold.
///
/// ## `SharedPreferences` is the wrong backing store for a real app
///
/// It is used here because the example already depends on it and the point is
/// the call sequence, not the storage. These payloads are JSON blobs that grow
/// with history — a production host writes them to files under the app's
/// support directory, where a partial write can be made atomic with a
/// write-and-rename and a corrupt blob can be replaced without taking the rest
/// of the preferences file with it.
class HostSnapshotStore {
  HostSnapshotStore(this._prefs, {required this.subjectId});

  static Future<HostSnapshotStore> open({required String subjectId}) async =>
      HostSnapshotStore(
        await SharedPreferences.getInstance(),
        subjectId: subjectId,
      );

  final SharedPreferences _prefs;

  /// Every key is subject-scoped. The runtime scopes storage, baselines and
  /// device identity to the subject, so a snapshot restored under a different
  /// one would attribute one person's baseline to another.
  final String subjectId;

  String get _sessionStateKey => 'host.session_state.$subjectId';
  String _srmKey(String deviceClass) => 'host.srm.$subjectId.$deviceClass';
  String get _longitudinalKey => 'host.longitudinal.$subjectId';
  String get _configIdKey => 'host.config_id.$subjectId';
  String get _dayIndexKey => 'host.day_index.$subjectId';

  // ── Session state ─────────────────────────────────────────────────────

  String? readSessionState() => _prefs.getString(_sessionStateKey);

  Future<void> writeSessionState(String json) =>
      _prefs.setString(_sessionStateKey, json);

  // ── SRM ───────────────────────────────────────────────────────────────

  String? readSrm(String deviceClass) => _prefs.getString(_srmKey(deviceClass));

  Future<void> writeSrm(String deviceClass, String json) =>
      _prefs.setString(_srmKey(deviceClass), json);

  // ── Longitudinal ──────────────────────────────────────────────────────

  String? readLongitudinal() => _prefs.getString(_longitudinalKey);

  Future<void> writeLongitudinal(String json) =>
      _prefs.setString(_longitudinalKey, json);

  // ── The comparability key (§9.5) ──────────────────────────────────────

  /// The `config_id` the stored snapshots were produced under.
  ///
  /// Persisted beside them because a score computed under a different
  /// `config_id` is not comparable to a new one, and `config_id` changes
  /// whenever anything value-affecting changes — including the `sensing` and
  /// `mask_profile` declarations. Without this a host silently compares
  /// yesterday's numbers against today's different configuration.
  String? readConfigId() => _prefs.getString(_configIdKey);

  Future<void> writeConfigId(String id) => _prefs.setString(_configIdKey, id);

  // ── Daily accumulator cursor (§8) ─────────────────────────────────────

  /// The last `day_index` handed to `roll_day`.
  ///
  /// Kept because the index must **strictly advance** — a repeat or a negative
  /// returns `ERR_DAILY_DAY_NOT_ADVANCING` — and after a relaunch the host has
  /// no other way to know whether today has already been rolled.
  int? readLastDayIndex() => _prefs.getInt(_dayIndexKey);

  Future<void> writeLastDayIndex(int dayIndex) =>
      _prefs.setInt(_dayIndexKey, dayIndex);

  // ── Teardown ──────────────────────────────────────────────────────────

  /// Drop everything for this subject.
  ///
  /// [deviceClasses] must name every class whose SRM file might exist —
  /// they are separate keys by design, so clearing only the current one leaves
  /// the others behind for a future launch to load.
  Future<void> clear({
    Iterable<String> deviceClasses = const ['phone', 'tablet', 'watch'],
  }) async {
    await _prefs.remove(_sessionStateKey);
    await _prefs.remove(_longitudinalKey);
    await _prefs.remove(_configIdKey);
    await _prefs.remove(_dayIndexKey);
    for (final c in deviceClasses) {
      await _prefs.remove(_srmKey(c));
    }
  }

  /// Which snapshots are on disk, for a UI that has to show whether
  /// persistence is actually working.
  ///
  /// Worth rendering: all three of these calls fail quietly, and a host that
  /// exports every window and reloads nothing on launch looks identical to one
  /// that is persisting correctly right up until the baselines never mature.
  Map<String, int> storedSizes(String deviceClass) => <String, int>{
    'session_state': readSessionState()?.length ?? 0,
    'srm ($deviceClass)': readSrm(deviceClass)?.length ?? 0,
    'longitudinal': readLongitudinal()?.length ?? 0,
  };
}
