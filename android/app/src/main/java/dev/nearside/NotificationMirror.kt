package dev.nearside

import android.app.Notification
import android.app.PendingIntent
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
 *   ← {"t":"notif-open","key"}             notification clicked on the Mac: open it here
 *   ← {"t":"notif-open","key","display"}   … or in a Mac window (that window's display, via the helper)
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
        // Buttons are part of the version: the Mac's button index must match the phone's list.
        val fingerprint = "$title\u0000$text\u0000" + usableActions(n).joinToString("\u0001") { it.title.toString() }
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
            .onSuccess { android.util.Log.i("Nearside", "dismissed on the phone") }
            .onFailure { android.util.Log.w("Nearside", "dismiss failed: $it") }
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
                fire(action.actionIntent, fill)
            } else {
                fire(action.actionIntent, null)
            }
            Status.lastEvent = "ran \"${action.title}\" from the Mac"
        }.onFailure { Status.lastEvent = "action failed: ${it.message}" }
    }

    /**
     * Google Messages keeps its own read state and ignores the SMS store, so after marking a
     * conversation read we also press "Mark as read" on its notification, if it still has one.
     * Matched by conversation title (contact name or number); the button by its semantic
     * action, so it works in any language.
     */
    fun markConversationRead(name: String?, address: String) = main.post {
        val digits = address.filter(Char::isDigit).takeLast(8)
        val notifications = runCatching { activeNotifications }.getOrNull() ?: return@post
        for (sbn in notifications) {
            if (sbn.packageName != "com.google.android.apps.messaging") continue
            val extras = sbn.notification.extras
            val title = (extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)
                ?: extras.getCharSequence(Notification.EXTRA_TITLE))?.toString() ?: continue
            val matches = (name != null && title.equals(name, ignoreCase = true)) ||
                (digits.length >= 6 && title.filter(Char::isDigit).takeLast(8) == digits) || title == address
            val actions = sbn.notification.actions.orEmpty()
            // Prefer the semantic tag (any language); some apps don't set it, so fall back to the label.
            val action = actions.firstOrNull { it.semanticAction == Notification.Action.SEMANTIC_ACTION_MARK_AS_READ }
                ?: actions.firstOrNull { it.title?.toString().equals("Mark as read", ignoreCase = true) }
            android.util.Log.i("Nearside", "Google Messages notification: title match=$matches (have name=${name != null}), " +
                "semantic actions=${actions.map { it.semanticAction }}, mark-read button=${action != null}")
            if (!matches || action == null) continue
            runCatching { fire(action.actionIntent, null) }
                .onSuccess { android.util.Log.i("Nearside", "pressed Mark as read in Google Messages") }
        }
    }

    /** Opens the notification's target on the phone (or on [display], a Mac window's), as tapping it would. */
    fun open(key: String, display: Int = -1) = main.post {
        val n = active[key] ?: return@post
        val target = n.contentIntent ?: return@post
        runCatching {
            if (display >= 0) {
                if (HelperConnection.helper?.sendIntentOnDisplay(target, display) != true) error("the helper couldn't open it there")
            } else {
                fire(target, null)
            }
        }.onFailure { Status.lastEvent = "open failed: ${it.message}" }
        // Tapping an auto-cancel notification removes it; do the same.
        if (n.flags and Notification.FLAG_AUTO_CANCEL != 0) {
            delivered.remove(key) // the Mac already removed its copy
            runCatching { cancelNotification(key) }
        }
    }

    /** Through the helper when linked (it may open activities from the background); else directly. */
    private fun fire(intent: PendingIntent, fillIn: Intent?) {
        val viaHelper = runCatching { HelperConnection.helper?.sendIntent(intent, fillIn) == true }.getOrDefault(false)
        if (!viaHelper) intent.send(this, 0, fillIn)
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
