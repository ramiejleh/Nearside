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
 *   ← {"t":"notif-filter","muted":[pkg…]}  apps the computer doesn't want (never sent to it; calls still are)
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
        /** ...and only ones posted this recently (a link that dropped for a moment); older ones
         *  were already seen on the phone, or are simply still there: quiet. */
        private const val CATCH_UP_RECENT_MS = 2 * 60_000L
        /** After a reply from the Mac, the app re-posts with our reply added: don't re-alert. */
        private const val QUIET_AFTER_ACTION_MS = 8_000L
        /** CallStyle's extras (hidden constants; their values are stable across releases). */
        private const val EXTRA_CALL_TYPE = "android.callType"
        private val CALL_INTENTS = listOf(
            "answer" to "android.answerIntent",
            "decline" to "android.declineIntent",
            "hangup" to "android.hangUpIntent",
        )

        /**
         * Apps whose notifications the computer doesn't want: they aren't sent at all (calls still
         * are). Kept across connections; each computer sends its own list right after connecting.
         */
        @Volatile private var muted: Set<String> = emptySet()

        /** A new list from the computer: what's now muted is taken back, what's unmuted is sent. */
        fun setMuted(packages: Set<String>) {
            val mirror = instance
            if (mirror == null) { muted = packages; return }
            mirror.main.post { mirror.applyMuted(packages) }
        }

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
    /** Packages whose icon this Mac connection has: the Mac keeps icons per package. */
    private val iconsSent = HashSet<String>()

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
        if (calls.remove(sbn.key) != null) {
            HelperConnection.send(JSONObject().put("t", "call-ended").put("key", sbn.key))
            return
        }
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
        if (isCall(n)) return mirrorCall(sbn)
        if (sbn.packageName in muted) return false
        // Ongoing (music, navigation, foreground services) and group summaries aren't alerts.
        if (sbn.isOngoing || n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return false
        val extras = n.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))
            ?.toString().orEmpty().take(MAX_TEXT)
        if (title.isBlank() && text.isBlank()) return false

        active[sbn.key] = n
        // No Mac: nothing to build (catch-up sends it when one connects).
        if (!HelperConnection.macConnected) return false
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
        if (sbn.packageName !in iconsSent) icon(sbn.packageName)?.let { msg.put("icon", it) }
        // Only remember it as delivered if it actually reached the Mac; otherwise catch-up sends it.
        if (!HelperConnection.send(msg)) return false
        delivered[sbn.key] = fingerprint
        iconsSent += sbn.packageName
        return true
    }

    /**
     * Everything still showing, sent again to a computer that (re)connected: what it never had and
     * arrived in the last two minutes, the newest few as banners; the rest quietly (what was sent
     * before: a link that died unnoticed may have swallowed it; the computer replaces it by key,
     * without alerting).
     */
    private fun catchUp() {
        val showing = runCatching { activeNotifications }.getOrNull() ?: return
        val sorted = showing.sortedByDescending { it.postTime }
        val sentBefore = delivered.keys.toSet()
        delivered.clear()
        calls.clear()
        iconsSent.clear() // a new connection: maybe another Mac, without our icons
        var banners = 0
        val now = System.currentTimeMillis()
        for (sbn in sorted) {
            val alert = sbn.key !in sentBefore && now - sbn.postTime < CATCH_UP_RECENT_MS && banners < CATCH_UP_BANNERS
            if (mirror(sbn, quiet = !alert) && alert) banners++
        }
        val keys = JSONArray().apply { sorted.forEach { put(it.key) } }
        HelperConnection.send(JSONObject().put("t", "notif-active").put("keys", keys))
    }

    private fun applyMuted(packages: Set<String>) {
        val before = muted
        muted = packages
        if (packages == before) return
        val showing = runCatching { activeNotifications }.getOrNull().orEmpty()
        // Newly muted: gone from the computer.
        for (sbn in showing) {
            if (sbn.packageName in packages && sbn.packageName !in before && delivered.remove(sbn.key) != null) {
                HelperConnection.send(JSONObject().put("t", "notif-removed").put("key", sbn.key))
            }
        }
        // Unmuted: what they have showing now goes over, quietly.
        if (HelperConnection.macConnected) {
            for (sbn in showing) {
                if (sbn.packageName in before && sbn.packageName !in packages) mirror(sbn, quiet = true)
            }
        }
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
            Status.lastEvent = "ran \"${action.title}\" from your ${Desktop.name(this@NotificationMirror)}"
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
        val n = active[key] ?: runCatching { getActiveNotifications(arrayOf(key)) }.getOrNull()?.firstOrNull()?.notification
            ?: run { // already gone here: the Mac's copy is stale, drop it
            android.util.Log.i("Nearside", "notification to open is no longer showing")
            HelperConnection.send(JSONObject().put("t", "notif-removed").put("key", key))
            return@post
        }
        val target = n.contentIntent ?: run {
            android.util.Log.i("Nearside", "notification to open has nothing to open")
            return@post
        }
        runCatching {
            if (display >= 0) {
                if (HelperConnection.helper?.sendIntentOnDisplay(target, display) != true) error("the helper couldn't open it there")
            } else {
                fire(target, null)
            }
        }.onSuccess { android.util.Log.i("Nearside", "opened a notification${if (display >= 0) " on display $display" else ""}") }
            .onFailure { Status.lastEvent = "open failed: ${it.message}"; android.util.Log.i("Nearside", "notification open failed: ${it.message}") }
        // Tapping an auto-cancel notification removes it; do the same.
        // The removal is reported back as usual: the Mac's banner went, but its notification list keeps it until then.
        if (n.flags and Notification.FLAG_AUTO_CANCEL != 0) {
            runCatching { cancelNotification(key) }
        }
    }

    // MARK: Calls

    /** Call notifications the Mac has, by key: what it was sent (so unchanged re-posts aren't re-sent). */
    private val calls = HashMap<String, String>()

    /** A call screen's notification (CallStyle): the Phone app's and VoIP apps' alike. */
    private fun isCall(n: Notification) =
        n.extras.getString(Notification.EXTRA_TEMPLATE) == "android.app.Notification\$CallStyle"

    /**
     *   → {"t":"call","key","pkg","app","state":"incoming"|"ongoing"|"screening","name","photo"?,
     *      "since"?,"can":["answer","decline","hangup"]}
     *   → {"t":"call-ended","key"}
     *   ← {"t":"call-action","key","do":"answer"|"decline"|"hangup"}
     * The phone keeps its own call screen; these are its buttons, pressed from the Mac.
     */
    private fun mirrorCall(sbn: StatusBarNotification): Boolean {
        val n = sbn.notification
        active[sbn.key] = n
        if (!HelperConnection.macConnected) return false
        val extras = n.extras
        val state = when (extras.getInt(EXTRA_CALL_TYPE)) {
            1 -> "incoming"
            2 -> "ongoing"
            3 -> "screening"
            else -> return false
        }
        @Suppress("DEPRECATION") val person = extras.getParcelable<android.app.Person>("android.callPerson")
        val name = (person?.name ?: extras.getCharSequence(Notification.EXTRA_TITLE))?.toString().orEmpty().take(100)
        val can = JSONArray()
        CALL_INTENTS.forEach { (action, extra) -> if (callIntent(n, extra) != null) can.put(action) }
        val since = if (extras.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER)) n.`when` else 0L
        val fingerprint = "$state\u0000$name\u0000$can\u0000$since"
        if (calls[sbn.key] == fingerprint) return false
        val msg = JSONObject().put("t", "call").put("key", sbn.key).put("pkg", sbn.packageName)
            .put("app", appLabel(sbn.packageName)).put("state", state).put("name", name).put("can", can)
        if (since > 0) msg.put("since", since)
        if (sbn.key !in calls) callPhoto(person)?.let { msg.put("photo", it) }
        android.util.Log.i("Nearside", "call notification: $state, buttons $can")
        if (!HelperConnection.send(msg)) return false
        calls[sbn.key] = fingerprint
        return true
    }

    /** Answer, decline or hang up from the Mac: the call notification's own button. */
    fun callAction(key: String, action: String) = main.post {
        val n = active[key]?.takeIf { isCall(it) } ?: return@post
        val extra = CALL_INTENTS.firstOrNull { it.first == action }?.second ?: return@post
        val intent = callIntent(n, extra) ?: return@post
        runCatching { fire(intent, null) }
            .onSuccess { android.util.Log.i("Nearside", "call: $action from the Mac") }
            .onFailure { android.util.Log.i("Nearside", "call: $action failed: $it") }
    }

    private fun callIntent(n: Notification, extra: String): PendingIntent? =
        @Suppress("DEPRECATION") n.extras.getParcelable<PendingIntent>(extra)

    /** The caller's picture, if the call has one: a small JPEG. */
    private fun callPhoto(person: android.app.Person?): String? = runCatching {
        val drawable = person?.icon?.loadDrawable(this) ?: return null
        val size = 160
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(Canvas(bitmap))
        val jpeg = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it) }
        Base64.encodeToString(jpeg.toByteArray(), Base64.NO_WRAP)
    }.getOrNull()

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
