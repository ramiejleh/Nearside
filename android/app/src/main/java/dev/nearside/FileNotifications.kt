package dev.nearside

import android.app.DownloadManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent

/** "Received <file> from your Mac"; tapping it opens Downloads. */
object FileNotifications {
    private const val CHANNEL = "files"

    fun received(context: Context, name: String) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Files from your Mac", NotificationManager.IMPORTANCE_DEFAULT),
        )
        val open = PendingIntent.getActivity(
            context, 0,
            Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Received from your Mac")
            .setContentText("$name · in Downloads/Nearside")
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        manager.notify(name.hashCode(), notification)
    }
}
