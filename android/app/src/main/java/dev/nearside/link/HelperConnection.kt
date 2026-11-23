package dev.nearside.link

import android.content.Context
import android.os.Binder
import android.os.RemoteException
import dev.nearside.FileNotifications
import dev.nearside.NotificationMirror
import dev.nearside.PhoneStatus
import dev.nearside.PhotoFeed
import dev.nearside.SmsBridge
import dev.nearside.Status
import dev.nearside.phone.InUseNotification
import org.json.JSONObject

/**
 * The app's side of the link: talk to the Mac through the helper, which relays over the
 * adb tunnel. App features (notifications, SMS, …) send with [send] and receive in [handle].
 */
object HelperConnection {
    const val SHELL_UID = 2000

    @Volatile var helper: IHelper? = null
        private set
    @Volatile var macConnected = false
        private set
    @Volatile private var context: Context? = null

    internal val callback = object : IAppCallback.Stub() {
        override fun onMessage(json: String) {
            if (Binder.getCallingUid() != SHELL_UID) return
            val msg = runCatching { JSONObject(json) }.getOrNull() ?: return
            handle(msg)
        }

        override fun onMacConnectionChanged(connected: Boolean) {
            if (Binder.getCallingUid() != SHELL_UID) return
            macConnected = connected
            Status.lastEvent = if (connected) "Mac connected" else "Mac disconnected"
            if (connected) NotificationMirror.macConnected()
            context?.let { PhoneStatus.macConnectionChanged(it, connected) }
            if (!connected) context?.let { PhotoFeed.macDisconnected(it) }
        }
    }

    internal fun attached(h: IHelper, appContext: Context) {
        context = appContext
        helper = h
        dev.nearside.phone.DroppedFiles.prepare(appContext)
        Status.lastEvent = "linked to helper"
        runCatching {
            h.asBinder().linkToDeath({
                if (helper === h) {
                    helper = null
                    macConnected = false
                    PhoneStatus.macConnectionChanged(appContext, false)
                    Status.lastEvent = "helper stopped"
                }
            }, 0)
        }.onFailure { helper = null } // already dead
        macConnected = runCatching { h.isMacConnected }.getOrDefault(false)
        PhoneStatus.macConnectionChanged(appContext, macConnected)
    }

    /** True when the message reached a connected Mac. */
    fun send(msg: JSONObject): Boolean = try {
        helper?.sendToMac(msg.toString()) == true
    } catch (_: RemoteException) {
        false
    }

    private fun handle(msg: JSONObject) {
        android.util.Log.i("Nearside", "from Mac: ${msg.optString("t")} (mirror ${if (NotificationMirror.instance != null) "on" else "off"})")
        when (msg.optString("t")) {
            // Health check for the whole Mac → helper → app → helper → Mac path.
            "ping" -> send(JSONObject().put("t", "pong").put("id", msg.opt("id")))
            "notif-dismiss" -> NotificationMirror.instance?.dismiss(msg.optString("key"))
            "file-received" -> context?.let { FileNotifications.received(it, msg.optString("name")) }
            "screenshot-received" -> context?.let { FileNotifications.screenshotReceived(it, msg.optString("name")) }
            "screenshot-sent" -> context?.let { FileNotifications.screenshotSent(it, msg.optString("name")) }
            "sms-threads", "sms-thread", "sms-send", "sms-read" -> context?.let { SmsBridge.handle(it, msg) }
            "notif-open" -> NotificationMirror.instance?.open(msg.optString("key"), msg.optInt("display", -1))
            "share-into" -> context?.let { c ->
                val names = msg.optJSONArray("names")?.let { a -> (0 until a.length()).map { a.optString(it) } }.orEmpty()
                Thread { dev.nearside.phone.DroppedFiles.share(c, names, msg.optString("pkg"), msg.optInt("display", -1)) }.start()
            }
            "photos-watch", "photos-thumbs" -> context?.let { PhotoFeed.handle(it, msg) }
            "call-action" -> NotificationMirror.instance?.callAction(msg.optString("key"), msg.optString("do"))
            "display-state" -> context?.let { InUseNotification.update(it, msg.optInt("open")) }
            "notif-action" -> NotificationMirror.instance?.runAction(
                msg.optString("key"),
                msg.optInt("i", -1),
                if (msg.has("text")) msg.optString("text") else null,
            )
        }
    }
}
