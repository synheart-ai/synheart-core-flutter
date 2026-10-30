package ai.synheart.core.example

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * Forwards the raw samples a paired Wear OS watch app streams in STREAM mode
 * (`/synheart/session/bio_sample`: bpm, beat-to-beat intervals when the watch
 * detects beats, the sample time) to Dart as their JSON bodies.
 *
 * The session plugin relays only session events, not samples, so without this
 * a watch's heart rate never reaches the phone's runtime. The Data Layer only
 * delivers between apps with the same package and signing key, so the watch
 * app must be installed as `ai.synheart.core.example`.
 */
class WatchSampleBridge(private val context: Context) : EventChannel.StreamHandler {

    private companion object {
        const val CHANNEL = "ai.synheart.core.example/watch_samples"
        const val BIO_SAMPLE_PATH = "/synheart/session/bio_sample"
    }

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    private val listener = MessageClient.OnMessageReceivedListener { event: MessageEvent ->
        if (event.path != BIO_SAMPLE_PATH) return@OnMessageReceivedListener
        val body = String(event.data, Charsets.UTF_8)
        main.post { sink?.success(body) }
    }

    fun register(messenger: BinaryMessenger) {
        EventChannel(messenger, CHANNEL).setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        Wearable.getMessageClient(context).addListener(listener)
    }

    override fun onCancel(arguments: Any?) {
        Wearable.getMessageClient(context).removeListener(listener)
        sink = null
    }
}
