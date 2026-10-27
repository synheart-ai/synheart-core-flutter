import 'package:shared_preferences/shared_preferences.dart';

/// Persistence for the one runtime snapshot a mobile host still owns (mobile
/// host guide §7), plus the two scalars that go with it.
///
/// ## One, not three
///
/// | Snapshot | Carries | Who persists it |
/// |---|---|---|
/// | session state | Capacity, Mental Fatigue, Stress, Valence, context engine | **the host** — skip it and every relaunch starts the stateful heads cold |
/// | personal baselines | every per-window reference, the daily values, the 7-night sleep ring | **the runtime** (0.42+): it seals one snapshot to its own data directory at session end, after every reference refresh and every 15 minutes while windows close, and restores it at startup |
///
/// A host that keeps the runtime's data directory, as this one does, needs no
/// baseline snapshot calls at all. `Synheart.exportBaselineSnapshot` /
/// `loadBaselineSnapshot` exist for a host that persists somewhere else.
///
/// ## `SharedPreferences` is the wrong backing store for a real app
///
/// It is used here because the example already depends on it and the point is
/// the call sequence, not the storage. A production host writes the session
/// state to a file under the app's support directory, where a partial write
/// can be made atomic with a write-and-rename.
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
  /// one would attribute one person's state to another.
  final String subjectId;

  String get _sessionStateKey => 'host.session_state.$subjectId';
  String get _configIdKey => 'host.config_id.$subjectId';
  String get _strainDateKey => 'host.closed_day_strain.$subjectId';

  // ── Session state ─────────────────────────────────────────────────────

  String? readSessionState() => _prefs.getString(_sessionStateKey);

  Future<void> writeSessionState(String json) =>
      _prefs.setString(_sessionStateKey, json);

  // ── The comparability key (§9.5) ──────────────────────────────────────

  /// The `config_id` the stored snapshot was produced under.
  ///
  /// Persisted beside it because a score computed under a different
  /// `config_id` is not comparable to a new one, and `config_id` changes
  /// whenever anything value-affecting changes — including the `sensing` and
  /// `mask_profile` declarations. Without this a host silently compares
  /// yesterday's numbers against today's different configuration.
  String? readConfigId() => _prefs.getString(_configIdKey);

  Future<void> writeConfigId(String id) => _prefs.setString(_configIdKey, id);

  // ── Closed-day strain cursor (§8) ─────────────────────────────────────

  /// The local date (`YYYY-MM-DD`) whose closed-day Strain was last attached.
  ///
  /// The engine closes each local day itself and keeps the closed day until
  /// the next one closes, across a restart too, so attaching it at every
  /// launch would send the same day's Strain again. This cursor makes it once
  /// per date.
  String? readLastStrainDate() => _prefs.getString(_strainDateKey);

  Future<void> writeLastStrainDate(String date) =>
      _prefs.setString(_strainDateKey, date);

  // ── Teardown ──────────────────────────────────────────────────────────

  /// Drop everything for this subject.
  Future<void> clear() async {
    await _prefs.remove(_sessionStateKey);
    await _prefs.remove(_configIdKey);
    await _prefs.remove(_strainDateKey);
  }

  /// What is on disk, for a UI that has to show whether persistence is
  /// actually working: a host that exports every window and reloads nothing
  /// on launch looks identical to one that persists correctly until the
  /// stateful heads never warm.
  Map<String, int> storedSizes() => <String, int>{
    'session_state': readSessionState()?.length ?? 0,
  };
}
