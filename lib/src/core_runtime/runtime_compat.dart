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

  /// The runtime release these bindings were written and tested against.
  /// Bump it in the same change that adopts a new symbol or a moved shape.
  static const String writtenAgainst = '0.31.1';

  /// Oldest runtime the bindings are known to load and behave on. Below this
  /// the SDK refuses to initialise rather than run with entrypoints that no
  /// longer mean what the code assumes. `0.20.0` is the baseline of the
  /// runtime's `SDK-CONTRACT-CHANGES.md`.
  static const String minimum = '0.20.0';

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

  /// Evaluate the loaded runtime's `build_info` against [minimum] and
  /// [writtenAgainst].
  static RuntimeCompatResult check(Map<String, dynamic>? buildInfo) {
    final raw = buildInfo?['core_runtime'];
    final version = raw is String && raw.isNotEmpty ? raw : null;
    if (version == null) {
      return const RuntimeCompatResult(
        version: null,
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
        status: RuntimeCompatStatus.tooOld,
        message:
            '[Synheart] runtime $version is below the minimum $minimum these '
            'bindings support — refusing to initialise. Update the vendored '
            'runtime with `synheart install runtime`.',
      );
    }
    if (compare(version, writtenAgainst) < 0) {
      return RuntimeCompatResult(
        version: version,
        status: RuntimeCompatStatus.older,
        message:
            '[Synheart] runtime $version is older than $writtenAgainst, which '
            'these bindings were written against. Newer symbols fall back '
            '(buffered HSI, context fan-in, secure-storage marker …) and '
            'behaviour documented for $writtenAgainst may not hold. Update '
            'the vendored runtime with `synheart install runtime`.',
      );
    }
    return RuntimeCompatResult(
      version: version,
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

  /// Below [RuntimeCompat.minimum]; initialisation is refused.
  tooOld,

  /// `build_info` did not report a version.
  unknown,
}

class RuntimeCompatResult {
  const RuntimeCompatResult({
    required this.version,
    required this.status,
    required this.message,
  });

  final String? version;
  final RuntimeCompatStatus status;
  final String message;

  bool get isAcceptable => status != RuntimeCompatStatus.tooOld;
}
