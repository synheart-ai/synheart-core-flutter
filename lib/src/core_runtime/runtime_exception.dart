import 'runtime_compat.dart';

/// Why the native runtime could not be used.
enum SynheartRuntimeErrorKind {
  /// No runtime library was found for this platform.
  notInstalled,

  /// A library was found but was built for a different CPU architecture.
  wrongArchitecture,

  /// The runtime loaded, but its ABI or version does not fit this SDK.
  incompatible,

  /// The library exists but the loader rejected it: a damaged file, or (on
  /// Windows, which reports both the same way) one built for another CPU.
  loadFailed,
}

/// The native runtime is missing, unusable, or incompatible with this SDK.
///
/// `Synheart.initialize` throws it for
/// [SynheartRuntimeErrorKind.incompatible] only. The other kinds leave
/// initialisation degraded (no HSI) and are readable from
/// `Synheart.runtimeError`.
class SynheartRuntimeException implements Exception {
  final SynheartRuntimeErrorKind kind;

  /// One plain sentence naming the versions involved and the fix.
  final String message;

  /// Loaded runtime version, when one loaded and reported it.
  final String? runtimeVersion;

  /// Loaded runtime ABI (`MAJOR.MINOR`), when it reported one.
  final String? runtimeAbi;

  /// ABI this SDK requires (`MAJOR.MINOR`; the runtime must match MAJOR and
  /// be at least this MINOR).
  final String requiredAbi;

  /// Runtime release to install.
  final String recommendedVersion;

  /// Exact shell command that installs [recommendedVersion].
  final String installCommand;

  /// Raw loader text, for support. Not meant for end users.
  final String? cause;

  const SynheartRuntimeException({
    required this.kind,
    required this.message,
    required this.requiredAbi,
    required this.recommendedVersion,
    required this.installCommand,
    this.runtimeVersion,
    this.runtimeAbi,
    this.cause,
  });

  /// Build the exception for a runtime that failed to load.
  factory SynheartRuntimeException.loadFailure(
    SynheartRuntimeErrorKind kind, {
    String? cause,
  }) {
    const fix =
        'Install runtime ${RuntimeCompat.writtenAgainst}: '
        '${RuntimeCompat.installCommand}';
    final message = switch (kind) {
      SynheartRuntimeErrorKind.notInstalled =>
        'Core runtime not found. synheart_core needs runtime ABI '
            '${RuntimeCompat.requiredAbiMajor}.x. $fix',
      SynheartRuntimeErrorKind.wrongArchitecture =>
        'Core runtime was built for a different CPU architecture than this '
            'device. $fix',
      _ =>
        'Core runtime file is damaged or not built for this device. '
            'Reinstall it. $fix',
    };
    return SynheartRuntimeException(
      kind: kind,
      message: message,
      requiredAbi: RuntimeCompat.requiredAbi,
      recommendedVersion: RuntimeCompat.writtenAgainst,
      installCommand: RuntimeCompat.installCommand,
      cause: cause,
    );
  }

  /// Build the exception for a library that loaded but does not report its
  /// build info: not a Synheart Core runtime, or a build without its C ABI.
  factory SynheartRuntimeException.unidentified({String? cause}) =>
      SynheartRuntimeException(
        kind: SynheartRuntimeErrorKind.incompatible,
        message:
            'The Core runtime library does not report its version, so it is '
            'not a usable runtime build for synheart_core. Install runtime '
            '${RuntimeCompat.writtenAgainst}: ${RuntimeCompat.installCommand}',
        requiredAbi: RuntimeCompat.requiredAbi,
        recommendedVersion: RuntimeCompat.writtenAgainst,
        installCommand: RuntimeCompat.installCommand,
        cause: cause,
      );

  /// Build the exception for a loaded runtime that [compat] refused.
  factory SynheartRuntimeException.incompatible(RuntimeCompatResult compat) =>
      SynheartRuntimeException(
        kind: SynheartRuntimeErrorKind.incompatible,
        message: compat.message,
        runtimeVersion: compat.version,
        runtimeAbi: compat.abi,
        requiredAbi: RuntimeCompat.requiredAbi,
        recommendedVersion: RuntimeCompat.writtenAgainst,
        installCommand: RuntimeCompat.installCommand,
        cause: compat.version == null
            ? null
            : 'runtime ${compat.version}'
                  '${compat.abi == null ? '' : ' abi ${compat.abi}'}',
      );

  @override
  String toString() => 'SynheartRuntimeException(${kind.name}): $message';
}

/// Why a native library failed to load, as recorded by the loader.
class RuntimeLoadFailure {
  const RuntimeLoadFailure(this.kind, this.cause);

  final SynheartRuntimeErrorKind kind;

  /// Raw loader text.
  final String cause;

  SynheartRuntimeException toException() =>
      SynheartRuntimeException.loadFailure(kind, cause: cause);
}

// Loader wording differs per OS (dlopen on glibc, Apple, Bionic). Windows
// error 193 ("not a valid Win32 application") is deliberately absent: it is
// raised for a corrupt or truncated file as well as a foreign architecture,
// so it falls through to loadFailed, whose message covers both.
final _wrongArchitecture = RegExp(
  r'incompatible architecture|wrong ELF class|'
  r'mach-o, but wrong architecture|wrong architecture',
  caseSensitive: false,
);

final _notFound = RegExp(
  r'no such file|cannot open shared object|image not found|'
  r'library .* not found|\(error code: 126\)|'
  r'specified module could not be found',
  caseSensitive: false,
);

/// Map loader text to a [SynheartRuntimeErrorKind]. [fileMissing] is true when
/// the runtime file was known not to exist at the vendored location, which
/// makes any non-architecture failure a missing install.
SynheartRuntimeErrorKind classifyRuntimeLoadFailure(
  String loaderMessage, {
  bool fileMissing = false,
}) {
  if (_wrongArchitecture.hasMatch(loaderMessage)) {
    return SynheartRuntimeErrorKind.wrongArchitecture;
  }
  if (fileMissing || _notFound.hasMatch(loaderMessage)) {
    return SynheartRuntimeErrorKind.notInstalled;
  }
  return SynheartRuntimeErrorKind.loadFailed;
}
