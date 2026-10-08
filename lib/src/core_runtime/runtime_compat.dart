import '../version.dart';

/// Runtime-version compatibility for the hand-written C ABI bindings.
///
/// The runtime's C surface is additive and stable — a binding written against
/// one version still *links* against a much newer one — so nothing fails
/// loudly when the two drift apart. What moves between versions is semantics,
/// JSON shapes, error-code vocabulary and which symbols a build exports, none
/// of which a linker checks. This is the one place the SDK states which
/// runtime its bindings assume and compares it to what actually loaded.
class RuntimeCompat {
  RuntimeCompat._();

  /// The newest runtime release these bindings were verified against, and the
  /// release every install hint recommends. Bump it when the bindings adopt a
  /// new symbol or a moved shape, or once they are verified on a newer
  /// release.
  static const String writtenAgainst = '0.36.0';

  /// Oldest runtime the bindings are known to load and behave on. Below this
  /// the SDK refuses to initialise rather than run with entrypoints that no
  /// longer mean what the code assumes. `0.20.0` is the baseline of the
  /// runtime's `SDK-CONTRACT-CHANGES.md`.
  static const String minimum = '0.20.0';

  /// The C ABI this SDK requires, as `MAJOR.MINOR`. The runtime bumps MAJOR on
  /// any removal, rename or signature change and MINOR on additions only, so a
  /// runtime is compatible when its MAJOR equals [requiredAbiMajor] and its
  /// MINOR is at least [requiredAbiMinor]. This, not the release version, is
  /// the contract; the version checks only grade runtimes that satisfy it.
  static const String requiredAbi = '1.0';
  static const int requiredAbiMajor = 1;
  static const int requiredAbiMinor = 0;

  /// Newest ABI major the bindings also accept. ABI 2.0 only removed symbols
  /// these bindings never call, and its one addition
  /// (`synheart_core_last_error_json`) is looked up as optional, so runtimes on
  /// either major load. Raise it only after checking a new major's removals
  /// against the bindings.
  static const int maxAbiMajor = 2;

  /// The accepted ABI range, for messages.
  static String get abiRange => maxAbiMajor == requiredAbiMajor
      ? '$requiredAbiMajor.x'
      : '$requiredAbi to $maxAbiMajor.x';

  /// Whether a runtime reporting [abi] can be used.
  static bool acceptsAbi(({int major, int minor}) abi) {
    if (abi.major < requiredAbiMajor || abi.major > maxAbiMajor) return false;
    return abi.major > requiredAbiMajor || abi.minor >= requiredAbiMinor;
  }

  /// Installs the release the bindings were written against.
  static const String installCommand =
      'synheart install runtime --version $writtenAgainst';

  static const String _fix = 'Install runtime $writtenAgainst: $installCommand';

  /// Parse `MAJOR.MINOR` (extra components ignored); null if malformed.
  static ({int major, int minor})? parseAbi(String abi) {
    final m = RegExp(r'^(\d+)\.(\d+)').firstMatch(abi.trim());
    if (m == null) return null;
    return (major: int.parse(m.group(1)!), minor: int.parse(m.group(2)!));
  }

  /// Compare two dotted numeric versions (`0.31.1`). Non-numeric suffixes are
  /// ignored; a missing component reads as `0`. Negative when [a] < [b].
  static int compare(String a, String b) {
    List<int> parse(String v) => v
        .split('.')
        .map((p) => int.tryParse(RegExp(r'^\d+').stringMatch(p) ?? '') ?? 0)
        .toList();
    final pa = parse(a);
    final pb = parse(b);
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  /// Evaluate the loaded runtime's `build_info`: its ABI against
  /// [requiredAbi] when it reports one (runtime 0.33.0+), otherwise its
  /// version against [minimum]; then against [writtenAgainst] for status.
  static RuntimeCompatResult check(Map<String, dynamic>? buildInfo) {
    final raw = buildInfo?['core_runtime'];
    final version = raw is String && raw.isNotEmpty ? raw : null;
    final rawAbi = buildInfo?['abi'];
    final parsedAbi = rawAbi is String ? parseAbi(rawAbi) : null;
    final abi = parsedAbi == null ? null : (rawAbi as String);
    if (parsedAbi != null && !acceptsAbi(parsedAbi)) {
      return RuntimeCompatResult(
        version: version,
        abi: abi,
        status: RuntimeCompatStatus.incompatibleAbi,
        message:
            'Core runtime ${version ?? '(unknown version)'} (ABI $abi) is '
            'incompatible with synheart_core $synheartCoreVersion (needs ABI '
            '$abiRange). $_fix',
      );
    }
    if (version == null) {
      return RuntimeCompatResult(
        version: null,
        abi: abi,
        status: RuntimeCompatStatus.unknown,
        message:
            '[Synheart] runtime version unknown — build_info carried no '
            'core_runtime; bindings assume $writtenAgainst. Expect silent '
            'divergence if the vendored library is older.',
      );
    }
    if (compare(version, minimum) < 0) {
      return RuntimeCompatResult(
        version: version,
        abi: abi,
        status: RuntimeCompatStatus.tooOld,
        message:
            'Core runtime $version is incompatible with synheart_core '
            '$synheartCoreVersion (needs runtime $minimum or newer). $_fix',
      );
    }
    if (compare(version, writtenAgainst) < 0) {
      return RuntimeCompatResult(
        version: version,
        abi: abi,
        status: RuntimeCompatStatus.older,
        message:
            '[Synheart] runtime $version is older than $writtenAgainst, which '
            'these bindings were verified against. Symbols added since then '
            'fall back, and behaviour documented for $writtenAgainst may not '
            'hold. Update '
            'the vendored runtime with `synheart install runtime`.',
      );
    }
    return RuntimeCompatResult(
      version: version,
      abi: abi,
      status: RuntimeCompatStatus.ok,
      message: '[Synheart] runtime $version (bindings: $writtenAgainst)',
    );
  }
}

enum RuntimeCompatStatus {
  /// At or above [RuntimeCompat.writtenAgainst].
  ok,

  /// Loads and works, but predates the version the bindings assume.
  older,

  /// Below [RuntimeCompat.minimum] on a runtime that reports no ABI;
  /// initialisation is refused.
  tooOld,

  /// The runtime's ABI is outside [RuntimeCompat.abiRange]; initialisation is
  /// refused.
  incompatibleAbi,

  /// `build_info` did not report a version.
  unknown,
}

class RuntimeCompatResult {
  const RuntimeCompatResult({
    required this.version,
    this.abi,
    required this.status,
    required this.message,
  });

  final String? version;

  /// The runtime's ABI (`MAJOR.MINOR`); null for runtimes before 0.33.0.
  final String? abi;
  final RuntimeCompatStatus status;
  final String message;

  bool get isAcceptable =>
      status != RuntimeCompatStatus.tooOld &&
      status != RuntimeCompatStatus.incompatibleAbi;
}
