package dev.nearside.phone

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
 * "Apps open on your Mac" while any phone app is shown in a Mac window, with a Stop button. Phone
 * apps can be used from the Mac even while the phone is locked, so this must always be visible.
 */
object InUseNotification {
    private const val CHANNEL = "apps-on-mac"
    private const val ID = 0x41505053 // "APPS"

    fun update(context: Context, open: Int) {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (open <= 0) return manager.cancel(ID)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Apps open on your Mac", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while phone apps are open in windows on your Mac"
            },
        )
        val stop = PendingIntent.getBroadcast(
            context, 0, Intent(context, StopReceiver::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(context, CHANNEL)
            .setSmallIcon(dev.nearside.R.drawable.ic_notification)
            .setContentTitle(if (open == 1) "An app is open on your Mac" else "$open apps are open on your Mac")
            .setContentText("They can be used from your Mac while this phone is locked.")
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
        manager.notify(ID, notification)
    }

    /** "Stop": every app window closes and its app comes back to the phone. */
    class StopReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            HelperConnection.send(JSONObject().put("t", "apps-stop"))
        }
    }
}
