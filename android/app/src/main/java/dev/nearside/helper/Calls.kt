package dev.nearside.helper

import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.telecom.TelecomManager
import android.telephony.PhoneStateListener
import android.telephony.TelephonyManager
import org.json.JSONObject

/**
 * Phone calls, the parts only the shell may do (the call screen's buttons come from its
 * notification, through the app):
 *   us  → {"t":"call-number","number","dialer"}  a phone call is ringing: who (null when it stops)
 *   Mac → {"t":"call-place","number"}            call this number from the phone
 *   Mac → {"t":"call-mute","on"}                 mute the phone's microphone (any call)
 *   us  → {"t":"call-muted","on"}                on connecting: whether it still is
 */
object Calls {
    /** Set by Main. */
    lateinit var toMac: (JSONObject) -> Boolean

    private val telephony by lazy {
        // A bare app_process hasn't set up the telephony framework (apps get it at startup).
        runCatching {
            val manager = Class.forName("android.os.TelephonyServiceManager").getConstructor().newInstance()
            Class.forName("android.telephony.TelephonyFrameworkInitializer")
                .getMethod("setTelephonyServiceManager", manager.javaClass).invoke(null, manager)
        }.onFailure { Log.d("telephony setup: ${it.cause ?: it}") }
        shellOwned(TelephonyManager::class.java)
    }
    private val telecom by lazy { shellOwned(TelecomManager::class.java) }
    private val audio by lazy { shellOwned(android.media.AudioManager::class.java) }
    /** We muted the microphone: kept through a Mac dropping off mid-call, undone when the call ends. */
    @Volatile private var mutedByMac = false

    /** Made with our context: the system's own (what getSystemService gives) fails the package check. */
    private fun <T> shellOwned(type: Class<T>): T? = runCatching {
        type.getDeclaredConstructor(android.content.Context::class.java).apply { isAccessible = true }.newInstance(FakeContext.instance)
    }.onFailure { Log.d("${type.simpleName}: ${it.cause ?: it}") }.getOrNull()
    private var ringing: String? = null // main looper only

    @Suppress("DEPRECATION") // the replacement (TelephonyCallback) doesn't say who is calling
    private val listener by lazy {
        object : PhoneStateListener(Looper.getMainLooper().let { java.util.concurrent.Executor { r -> Handler(it).post(r) } }) {
            override fun onCallStateChanged(state: Int, number: String?) {
                val now = if (state == TelephonyManager.CALL_STATE_RINGING) number?.takeIf { it.isNotBlank() } else null
                if (now == ringing) return
                ringing = now
                toMac(JSONObject().put("t", "call-number").put("number", now ?: JSONObject.NULL)
                    .put("dialer", runCatching { telecom?.defaultDialerPackage }.getOrNull() ?: JSONObject.NULL))
            }
        }
    }

    /** While a Mac is connected only. */
    fun macConnectionChanged(connected: Boolean) = Handler(Looper.getMainLooper()).post {
        runCatching {
            @Suppress("DEPRECATION")
            telephony?.listen(listener, if (connected) PhoneStateListener.LISTEN_CALL_STATE else PhoneStateListener.LISTEN_NONE)
            if (!connected) ringing = null
            if (connected) toMac(JSONObject().put("t", "call-muted").put("on", mutedByMac))
            if (!connected && mutedByMac) unmuteWhenIdle()
        }.onFailure { Log.d("call state unavailable: ${it.cause ?: it}") }
    }

    /**
     * The Mac went away with the call muted: unmuting now would let the other side hear you
     * without warning. Keep it until nothing on the phone is in a call (cellular or VoIP).
     */
    private fun unmuteWhenIdle() {
        val main = Handler(Looper.getMainLooper())
        main.postDelayed(object : Runnable {
            override fun run() {
                if (!mutedByMac || macConnected()) return // undone, or a Mac is back to decide
                @Suppress("DEPRECATION")
                val idle = runCatching { telephony?.callState == TelephonyManager.CALL_STATE_IDLE }.getOrDefault(true) &&
                    runCatching { audio?.mode == android.media.AudioManager.MODE_NORMAL }.getOrDefault(true)
                if (idle) mute(false) else main.postDelayed(this, 2000)
            }
        }, 2000)
    }

    /** Set by Main. */
    lateinit var macConnected: () -> Boolean

    private fun mute(on: Boolean) {
        runCatching { audio!!.isMicrophoneMute = on }
            .onSuccess { mutedByMac = on; Log.d("microphone ${if (on) "muted" else "unmuted"} from the Mac") }
            .onFailure { Log.d("mute failed: ${it.cause ?: it}") }
    }

    fun handle(msg: JSONObject) {
        if (msg.optString("t") == "call-mute") return mute(msg.optBoolean("on"))
        if (msg.optString("t") != "call-place") return
        val number = dialable(msg.optString("number")) ?: return Log.d("call-place: not a phone number")
        runCatching { telecom!!.placeCall(Uri.fromParts("tel", number, null), Bundle()) }
            .onSuccess { Log.d("placing a call from the Mac") }
            .onFailure { Log.d("placing a call failed: ${it.cause ?: it}") }
    }

    /**
     * A phone number: digits with an optional leading +, spaces and dashes dropped; else null.
     * Never * or #: those make service codes (call forwarding, …) that change the phone's settings.
     */
    fun dialable(text: String): String? {
        val kept = text.filterNot { it == ' ' || it == '-' || it == '(' || it == ')' || it == '.' || it == '\u00a0' }
        if (kept.length !in 3..20) return null
        if (!kept.withIndex().all { (i, c) -> c in '0'..'9' || (c == '+' && i == 0) }) return null
        return kept.takeIf { it.any { c -> c in '0'..'9' } }
    }
}
