package dev.nearside.link

import android.content.Context
import android.os.Binder
import android.os.RemoteException
import dev.nearside.FileNotifications
import dev.nearside.NotificationMirror
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
        }
    }

    internal fun attached(h: IHelper, appContext: Context) {
        context = appContext
        helper = h
        Status.lastEvent = "linked to helper"
        runCatching {
            h.asBinder().linkToDeath({
                if (helper === h) {
                    helper = null
                    macConnected = false
                    Status.lastEvent = "helper stopped"
                }
            }, 0)
        }.onFailure { helper = null } // already dead
        macConnected = runCatching { h.isMacConnected }.getOrDefault(false)
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
            "sms-threads", "sms-thread", "sms-send", "sms-read" -> context?.let { SmsBridge.handle(it, msg) }
            "notif-open" -> NotificationMirror.instance?.open(msg.optString("key"))
            "display-state" -> context?.let { InUseNotification.update(it, msg.optInt("open")) }
            "notif-action" -> NotificationMirror.instance?.runAction(
                msg.optString("key"),
                msg.optInt("i", -1),
                if (msg.has("text")) msg.optString("text") else null,
            )
        }
    }
}
