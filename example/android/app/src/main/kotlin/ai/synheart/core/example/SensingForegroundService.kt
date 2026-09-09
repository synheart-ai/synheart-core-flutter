package ai.synheart.core.example

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Keeps the process alive for the whole sensing session (mobile host guide §6.2).
 *
 * ## Why a host needs this at all
 *
 * The runtime has no internal ticker: the Dart side drives `tick_all` once a
 * second, and the engine only closes a window when it is ticked. Android is
 * free to stop scheduling a backgrounded process at any point, so without a
 * foreground service the tick loop simply stops and the session emits nothing
 * from the moment the person leaves the app — silently, with the session still
 * reading as "collecting" when they come back.
 *
 * The guide's note on the existing implementation is that a foreground service
 * exists in the field but is started *from the IME*, so it only ever covers
 * typing. This one is bound to the sensing session itself, which is the scope
 * that actually matters.
 *
 * ## `dataSync`, and the Android 15 limit
 *
 * The type is `dataSync` because that is what "keep streaming and processing
 * sensor data" is. On Android 15+ `dataSync` services are capped at roughly six
 * hours per day, after which the system stops them; a host that needs to sense
 * across a full day has to either move to a different service type that fits
 * its actual use, or accept the gap and rely on `flush_pending` plus the three
 * snapshots to make the resumption lossless. This example accepts the gap — it
 * is a reference for the call sequence, not a 24-hour collector.
 *
 * ## The notification is not optional
 *
 * A foreground service must post one, and that is the correct trade: a process
 * observing a person's physiology in the background should be visibly doing so.
 * Tapping it returns to the app rather than dismissing anything.
 */
class SensingForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "synheart_sensing"
        private const val NOTIFICATION_ID = 4201

        fun start(context: Context) {
            val intent = Intent(context, SensingForegroundService::class.java)
            // startForegroundService requires the service to call
            // startForeground() within a few seconds or the system kills the
            // app with a ForegroundServiceDidNotStartInTimeException — which is
            // why onStartCommand does it first, before anything else.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, SensingForegroundService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // Android 14+ requires the type to be declared at the call site as
            // well as in the manifest, and requires the matching typed
            // permission (FOREGROUND_SERVICE_DATA_SYNC). Passing the untyped
            // overload on 14+ throws MissingForegroundServiceTypeException.
            startForeground(
                NOTIFICATION_ID,
                buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, buildNotification())
        }

        // Deliberately not sticky. If the system kills us, the Dart side is
        // gone too, so a restarted service would hold a notification over a
        // process with no tick loop behind it — a foreground service claiming
        // to sense while nothing senses is worse than being stopped.
        return START_NOT_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Sensing session",
                // LOW: it must be visible, but an ongoing status notification
                // should not make a sound every time the service restarts.
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown while a Synheart sensing session is running."
                setShowBadge(false)
            },
        )
    }

    private fun buildNotification(): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Synheart session running")
            .setContentText("Collecting and processing signal on this device.")
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
}
