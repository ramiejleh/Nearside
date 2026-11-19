package dev.nearside

import android.app.Notification
import android.app.RemoteInput
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import dev.nearside.link.HelperConnection
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * Mirrors the phone's notifications to the Mac through the helper link.
 *   → {"t":"notif","key","pkg","app","title","text","when","icon":<base64 png>,
 *      "actions":[{"title","reply":bool}],"quiet":bool}
 *   → {"t":"notif-removed","key"}          dismissed or opened on the phone
 *   → {"t":"notif-active","keys":[…]}      after catch-up: what's still showing
 *   ← {"t":"notif-dismiss","key"}          dismissed on the Mac
 *   ← {"t":"notif-action","key","i","text"?}  button (or reply with text) clicked on the Mac
 * Access is granted by the Mac over adb (`cmd notification allow_listener`), so there's no
 * settings screen to visit, and turning mirroring off on the Mac revokes it again.
 * All state is touched on the main thread only.
 */
class NotificationMirror : NotificationListenerService() {
    companion object {
        @Volatile var instance: NotificationMirror? = null
            private set
        private const val MAX_TEXT = 2000
        private const val MAX_ACTIONS = 3
        /** Catch-up shows this many newest as banners; older ones go quietly to the list. */
        private const val CATCH_UP_BANNERS = 3
        /** After a reply from the Mac, the app re-posts with our reply added: don't re-alert. */
        private const val QUIET_AFTER_ACTION_MS = 8_000L

        /** Called (on any thread) when the Mac connects: send what it missed. */
        fun macConnected() {
            val mirror = instance ?: return
            mirror.main.post { mirror.catchUp() }
        }
    }

    private val main = Handler(Looper.getMainLooper())
    /** What the Mac has, per key: so unchanged re-posts (progress ticks…) aren't re-sent. */
    private val delivered = HashMap<String, String>()
    /** Current notification per key, to run its actions when the Mac asks. */
    private val active = HashMap<String, Notification>()
    private val quietUntil = HashMap<String, Long>()
    private val icons = HashMap<String, String>()

    override fun onListenerConnected() {
        instance = this
        Status.lastEvent = "notification mirroring on"
        if (HelperConnection.macConnected) catchUp()
    }

    override fun onListenerDisconnected() {
        if (instance === this) instance = null
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        mirror(sbn, quiet = false)
    }


    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        active.remove(sbn.key)
        quietUntil.remove(sbn.key)
        if (delivered.remove(sbn.key) != null) {
            HelperConnection.send(JSONObject().put("t", "notif-removed").put("key", sbn.key))
        }
    }

    /**
     * Sends one notification unless it's filtered or the Mac already has this version.
     * Returns whether it was sent.
     */
    private fun mirror(sbn: StatusBarNotification, quiet: Boolean): Boolean {
        val n = sbn.notification
        if (sbn.packageName == packageName) return false
        // Ongoing (music, navigation, foreground services) and group summaries aren't alerts.
        if (sbn.isOngoing || n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return false
        val extras = n.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))
            ?.toString().orEmpty().take(MAX_TEXT)
        if (title.isBlank() && text.isBlank()) return false

        active[sbn.key] = n
        val fingerprint = "$title\u0000$text"
        if (delivered[sbn.key] == fingerprint) return false

        val actions = JSONArray()
        usableActions(n).forEach { action ->
            actions.put(JSONObject().put("title", action.title.toString()).put("reply", replyInputs(action).isNotEmpty()))
        }
        val msg = JSONObject()
            .put("t", "notif")
            .put("key", sbn.key)
            .put("pkg", sbn.packageName)
            .put("app", appLabel(sbn.packageName))
            .put("title", title)
            .put("text", text)
            .put("when", sbn.postTime)
            .put("actions", actions)
            .put("quiet", quiet || SystemClock.uptimeMillis() < (quietUntil[sbn.key] ?: 0))
        icon(sbn.packageName)?.let { msg.put("icon", it) }
        // Only remember it as delivered if it actually reached the Mac; otherwise catch-up sends it.
        if (!HelperConnection.send(msg)) return false
        delivered[sbn.key] = fingerprint
        return true
    }

    /** Everything still showing that the Mac doesn't have yet; the newest few as banners. */
    private fun catchUp() {
        val showing = runCatching { activeNotifications }.getOrNull() ?: return
        val sorted = showing.sortedByDescending { it.postTime }
        var banners = 0
        for (sbn in sorted) {
            if (mirror(sbn, quiet = banners >= CATCH_UP_BANNERS)) banners++
        }
        val keys = JSONArray().apply { sorted.forEach { put(it.key) } }
        HelperConnection.send(JSONObject().put("t", "notif-active").put("keys", keys))
    }

    /** Dismiss on the phone because it was dismissed on the Mac. */
    fun dismiss(key: String) = main.post {
        delivered.remove(key) // don't echo a removal back
        runCatching { cancelNotification(key) }
    }

    /** Runs action [index] of notification [key]; [text] fills its reply field, if any. */
    fun runAction(key: String, index: Int, text: String?) = main.post {
        val n = active[key] ?: return@post
        val action = usableActions(n).getOrNull(index) ?: return@post
        val inputs = replyInputs(action)
        runCatching {
            if (text != null && inputs.isNotEmpty()) {
                val fill = Intent().addFlags(Intent.FLAG_RECEIVER_FOREGROUND)
                RemoteInput.addResultsToIntent(inputs.toTypedArray(), fill, Bundle().apply {
                    inputs.forEach { putCharSequence(it.resultKey, text) }
                })
                quietUntil[key] = SystemClock.uptimeMillis() + QUIET_AFTER_ACTION_MS
                action.actionIntent.send(this, 0, fill)
            } else {
                action.actionIntent.send()
            }
            Status.lastEvent = "ran \"${action.title}\" from the Mac"
        }.onFailure { Status.lastEvent = "action failed: ${it.message}" }
    }

    private fun usableActions(n: Notification): List<Notification.Action> =
        n.actions.orEmpty().filter { it.actionIntent != null && !it.title.isNullOrBlank() }.take(MAX_ACTIONS)

    private fun replyInputs(action: Notification.Action): List<RemoteInput> =
        action.remoteInputs.orEmpty().filter { it.allowFreeFormInput }

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
