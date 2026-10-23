/// Lets the native runtime have a say in which channels a module collects.
///
/// A module checks its consent snapshot first. When a runtime is attached it
/// also asks the runtime, which accepts a channel only when the user consented
/// to it and the app declared it as one of its data inputs. Collecting a
/// channel the runtime would refuse spends battery and permissions on data
/// that is thrown away, so a module skips it instead.
mixin RuntimeChannelGate {
  bool Function(String channel)? _runtimeAllowsChannel;

  /// The runtime's per-channel decision (`biosignals.vitals`, ...). `null`, the
  /// default, leaves the decision to the consent snapshot alone.
  set runtimeAllowsChannel(bool Function(String channel)? gate) =>
      _runtimeAllowsChannel = gate;

  /// Whether the runtime accepts [channel]; always true with no runtime gate.
  bool runtimeAllows(String channel) =>
      _runtimeAllowsChannel?.call(channel) ?? true;
}
