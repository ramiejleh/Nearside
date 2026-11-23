package dev.nearside

import android.app.DownloadManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent

/**
 * "Received <file> from your Mac" (tapping it opens Downloads), and screenshots both ways:
 * "Screenshot from your Mac" (opens it) and "Screenshot sent to your Mac".
 */
object FileNotifications {
    private const val CHANNEL = "files"
    private const val SCREENSHOTS = "screenshots"

    /** A Mac screenshot landed in Pictures/Nearside. */
    fun screenshotReceived(context: Context, name: String) = Thread {
        // The Mac's media scan runs just before this; give it a moment to list the file.
        var uri: android.net.Uri? = null
        for (attempt in 0 until 4) {
            uri = findScreenshot(context, name)
            if (uri != null) break
            Thread.sleep(500)
        }
        val open = uri?.let {
            PendingIntent.getActivity(
                context, name.hashCode(),
                Intent(Intent.ACTION_VIEW).setDataAndType(it, "image/*")
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION),
                PendingIntent.FLAG_IMMUTABLE,
            )
        }
        notifyScreenshot(context, "Screenshot from your Mac", "$name · in Pictures/Nearside", open, name)
    }.start()

    /** A phone screenshot was copied to the Mac's Downloads. */
    fun screenshotSent(context: Context, name: String) =
        notifyScreenshot(context, "Screenshot sent to your Mac", "$name · in Downloads on your Mac", null, "sent:$name")

    private fun notifyScreenshot(context: Context, title: String, text: String, open: PendingIntent?, tag: String) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(SCREENSHOTS, "Screenshots shared with your Mac", NotificationManager.IMPORTANCE_DEFAULT),
        )
        val notification = Notification.Builder(context, SCREENSHOTS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .apply { open?.let(::setContentIntent) }
            .setAutoCancel(true)
            .build()
        manager.notify(tag.hashCode(), notification)
    }

    /** Its MediaStore entry, if the app may read photos (else the notification just informs). */
    private fun findScreenshot(context: Context, name: String): android.net.Uri? = runCatching {
        val collection = android.provider.MediaStore.Images.Media.getContentUri(android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY)
        context.contentResolver.query(
            collection, arrayOf(android.provider.MediaStore.Images.Media._ID),
            "${android.provider.MediaStore.Images.Media.DISPLAY_NAME} = ? AND ${android.provider.MediaStore.Images.Media.RELATIVE_PATH} = ?",
            arrayOf(name, "Pictures/Nearside/"), null,
        )?.use { c -> if (c.moveToFirst()) android.content.ContentUris.withAppendedId(collection, c.getLong(0)) else null }
    }.getOrNull()

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
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Received from your Mac")
            .setContentText("$name · in Downloads/Nearside")
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        manager.notify(name.hashCode(), notification)
    }
}
