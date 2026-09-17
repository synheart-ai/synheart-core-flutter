package ai.synheart.core.example

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Must extend FlutterFragmentActivity (not FlutterActivity) so the health package
// can register the Health Connect permission launcher on Android.
class MainActivity : FlutterFragmentActivity() {

    private companion object {
        const val CHANNEL = "ai.synheart.core.example/sensing_service"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Start/stop the sensing foreground service from Dart, so its lifetime
        // matches the session rather than the activity. See
        // SensingForegroundService for why the session needs it: the runtime
        // has no internal ticker, so a backgrounded process that stops being
        // scheduled stops emitting windows entirely.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        SensingForegroundService.start(applicationContext)
                        result.success(true)
                    }
                    "stop" -> {
                        SensingForegroundService.stop(applicationContext)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
