package dev.nearside

import android.app.Notification
import android.graphics.Bitmap
import android.graphics.Canvas
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import dev.nearside.link.HelperConnection
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * Mirrors the phone's notifications to the Mac through the helper link.
 *   → {"t":"notif","key","pkg","app","title","text","when","icon":<base64 png>}
 *   → {"t":"notif-removed","key"}       (dismissed or opened on the phone)
 *   ← {"t":"notif-dismiss","key"}       (dismissed on the Mac)
 * Access is granted by the Mac over adb (`cmd notification allow_listener`), so there's no
 * settings screen to visit, and turning mirroring off on the Mac revokes it again.
 */
class NotificationMirror : NotificationListenerService() {
    companion object {
        @Volatile var instance: NotificationMirror? = null
            private set
        private const val MAX_TEXT = 2000
    }

    /** What we last sent per key, so progress ticks and silent re-posts aren't re-sent. */
    private val sent = HashMap<String, String>()
    private val icons = HashMap<String, String>()

    override fun onListenerConnected() {
        instance = this
        Status.lastEvent = "notification mirroring on"
    }

    override fun onListenerDisconnected() {
        if (instance === this) instance = null
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val n = sbn.notification
        if (sbn.packageName == packageName) return
        // Ongoing (music, navigation, foreground services) and group summaries aren't alerts.
        if (sbn.isOngoing || n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val extras = n.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))
            ?.toString().orEmpty().take(MAX_TEXT)
        if (title.isBlank() && text.isBlank()) return

        val fingerprint = "$title\u0000$text"
        synchronized(sent) {
            if (sent[sbn.key] == fingerprint) return
            sent[sbn.key] = fingerprint
        }
        val msg = JSONObject()
            .put("t", "notif")
            .put("key", sbn.key)
            .put("pkg", sbn.packageName)
            .put("app", appLabel(sbn.packageName))
            .put("title", title)
            .put("text", text)
            .put("when", sbn.postTime)
        icon(sbn.packageName)?.let { msg.put("icon", it) }
        HelperConnection.send(msg)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        val known = synchronized(sent) { sent.remove(sbn.key) != null }
        if (known) HelperConnection.send(JSONObject().put("t", "notif-removed").put("key", sbn.key))
    }

    /** Dismiss on the phone because it was dismissed on the Mac. */
    fun dismiss(key: String) {
        synchronized(sent) { sent.remove(key) } // don't echo a removal back
        runCatching { cancelNotification(key) }
    }

    private fun appLabel(pkg: String): String = runCatching {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    }.getOrDefault(pkg)

    /** The posting app's icon as a 96 px PNG, cached per package. */
    private fun icon(pkg: String): String? = icons[pkg] ?: runCatching {
        val drawable = packageManager.getApplicationIcon(pkg)
        val size = 96
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(Canvas(bitmap))
        val png = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        Base64.encodeToString(png.toByteArray(), Base64.NO_WRAP)
    }.getOrNull()?.also { icons[pkg] = it }
}
