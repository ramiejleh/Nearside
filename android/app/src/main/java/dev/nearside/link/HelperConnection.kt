package dev.nearside.link

import android.os.Binder
import android.os.RemoteException
import dev.nearside.NotificationMirror
import dev.nearside.Status
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
        }
    }

    internal fun attached(h: IHelper) {
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
        when (msg.optString("t")) {
            // Health check for the whole Mac → helper → app → helper → Mac path.
            "ping" -> send(JSONObject().put("t", "pong").put("id", msg.opt("id")))
            "notif-dismiss" -> NotificationMirror.instance?.dismiss(msg.optString("key"))
        }
    }
}
