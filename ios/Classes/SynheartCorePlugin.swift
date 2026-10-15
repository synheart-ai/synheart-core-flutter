import Flutter

/// Flutter plugin that triggers CocoaPods linking of the native runtime static
/// library via the podspec's vendored_frameworks + force_load.
///
/// Runtime calls go through Dart's DynamicLibrary.process(). The one channel,
/// `ai.synheart.core/platform`, covers what Dart cannot do itself: marking the
/// runtime's data directory excluded from backup.
public class SynheartCorePlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "ai.synheart.core/platform",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(SynheartCorePlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "excludeFromBackup":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String, !path.isEmpty else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "path is required", details: nil))
                return
            }
            result(Self.excludeFromBackup(path: path))
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Sets `isExcludedFromBackup` on the directory, which covers everything
    /// inside it. Its contents are sealed with keys in Keychain items that
    /// never leave this device, so a restored copy cannot be decrypted, and
    /// the runtime's restored `.smk-provisioned-*` markers would then block it
    /// from minting a new storage master key on the new device.
    static func excludeFromBackup(path: String) -> Bool {
        var url = URL(fileURLWithPath: path, isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
            return true
        } catch {
            NSLog("[SynheartCore] could not exclude %@ from backup: %@", path, "\(error)")
            return false
        }
    }
}
