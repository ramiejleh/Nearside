package dev.nearside.phone

import dev.nearside.Desktop
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dev.nearside.link.HelperConnection
import org.json.JSONObject

/**
 * "Apps open on your Mac" while any phone app is shown in a Mac window, and "Camera in use by your
 * Mac" while it's a webcam, with a Stop button. Both work while the phone is locked, so this must
 * always be visible.
 */
object InUseNotification {
    private const val CHANNEL = "apps-on-mac"
    private const val ID = 0x41505053 // "APPS"

    fun update(context: Context, open: Int, camera: Boolean = false) {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (open <= 0 && !camera) return manager.cancel(ID)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Apps open on your ${Desktop.name(context)}", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while phone apps are open in windows on your ${Desktop.name(context)}"
            },
        )
        val stop = PendingIntent.getBroadcast(
            context, 0, Intent(context, StopReceiver::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(context, CHANNEL)
            .setSmallIcon(dev.nearside.R.drawable.ic_notification)
            .setContentTitle(when {
                open <= 0 -> "Camera in use by your ${Desktop.name(context)}"
                open == 1 -> "An app is open on your ${Desktop.name(context)}" + if (camera) ", and the camera" else ""
                else -> "$open apps are open on your ${Desktop.name(context)}" + if (camera) ", and the camera" else ""
            })
            .setContentText(if (open <= 0) "Your ${Desktop.name(context)} uses this phone's camera as its webcam."
                else "They can be used from your ${Desktop.name(context)} while this phone is locked.")
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
        manager.notify(ID, notification)
    }

    /** "Stop": every app window closes and its app comes back to the phone; the camera turns off. */
    class StopReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            HelperConnection.send(JSONObject().put("t", "apps-stop"))
        }
    }
}
