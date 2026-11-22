package dev.nearside

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.telephony.SignalStrength
import android.telephony.TelephonyCallback
import android.telephony.TelephonyDisplayInfo
import android.telephony.TelephonyManager
import dev.nearside.link.HelperConnection
import org.json.JSONObject

/**
 * The phone's battery, signal and network, for the Mac's menu bar:
 *   {"t":"phone-status","battery":82,"charging":false,"signal":3,"network":"5G","wifi":true}
 * (`signal` 0–4 bars, absent without a SIM; `network` absent when unknown).
 *
 * Listens only while a Mac is connected, and sends only when something the Mac shows changes:
 * a battery percent at most every 30 s, anything else at once. Nothing runs while no Mac is there.
 */
object PhoneStatus {
    private const val LEVEL_INTERVAL_MS = 30_000L

    private data class Snapshot(
        val battery: Int = -1,
        val charging: Boolean = false,
        val signal: Int? = null,
        val network: String? = null,
        val wifi: Boolean = false,
    )

    private val main = Handler(Looper.getMainLooper())
    private var context: Context? = null // main thread only, like everything here
    private var listening = false
    private var current = Snapshot()
    private var sent: Snapshot? = null
    private var sentAt = 0L
    private var displayNetwork: String? = null
    private var telephonyCallback: TelephonyCallback? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    /** Called whenever the Mac connects or disconnects (any thread). */
    fun macConnectionChanged(appContext: Context, connected: Boolean) = main.post {
        context = appContext
        if (connected) start(appContext) else stop(appContext)
    }

    private fun start(ctx: Context) {
        if (listening) { sent = null; publish(); return } // a new Mac session: send it all again
        listening = true
        sent = null
        ctx.registerReceiver(battery, IntentFilter(Intent.ACTION_BATTERY_CHANGED))?.let(::readBattery)

        val telephony = ctx.getSystemService(TelephonyManager::class.java)
        if (telephony != null) {
            // The network type (5G, LTE) needs READ_PHONE_STATE, which the Mac grants at setup;
            // without it only the bars are shown.
            telephonyCallback = registerTelephony(telephony, withDisplayInfo = true)
                ?: registerTelephony(telephony, withDisplayInfo = false)
        }
        val connectivity = ctx.getSystemService(ConnectivityManager::class.java)
        networkCallback = object : ConnectivityManager.NetworkCallback() {
            // Registered with the main handler, so these already run on the main thread.
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                update(current.copy(wifi = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)))
            }

            override fun onLost(network: Network) {
                update(current.copy(wifi = false))
            }
        }.also { cb -> runCatching { connectivity?.registerDefaultNetworkCallback(cb, main) } }
        publish()
    }

    private fun stop(ctx: Context) {
        if (!listening) return
        listening = false
        main.removeCallbacks(delayedPublish)
        runCatching { ctx.unregisterReceiver(battery) }
        telephonyCallback?.let { cb -> runCatching { ctx.getSystemService(TelephonyManager::class.java)?.unregisterTelephonyCallback(cb) } }
        networkCallback?.let { cb -> runCatching { ctx.getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(cb) } }
        telephonyCallback = null
        networkCallback = null
        sent = null
    }

    private val battery = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = readBattery(intent)
    }

    private fun readBattery(intent: Intent) {
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val percent = if (level >= 0 && scale > 0) level * 100 / scale else -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
        update(current.copy(battery = percent, charging = charging))
    }

    private fun registerTelephony(telephony: TelephonyManager, withDisplayInfo: Boolean): TelephonyCallback? {
        val callback: TelephonyCallback = if (withDisplayInfo) {
            object : TelephonyCallback(), TelephonyCallback.SignalStrengthsListener, TelephonyCallback.DisplayInfoListener {
                override fun onSignalStrengthsChanged(strength: SignalStrength) = signalChanged(strength)
                override fun onDisplayInfoChanged(info: TelephonyDisplayInfo) = displayInfoChanged(info)
            }
        } else {
            object : TelephonyCallback(), TelephonyCallback.SignalStrengthsListener {
                override fun onSignalStrengthsChanged(strength: SignalStrength) = signalChanged(strength)
            }
        }
        return runCatching { telephony.registerTelephonyCallback(main::post, callback); callback }
            .onFailure { android.util.Log.i("Nearside", "phone status: no ${if (withDisplayInfo) "network type" else "signal"} ($it)") }
            .getOrNull()
    }

    private fun signalChanged(strength: SignalStrength) {
        val simReady = context?.getSystemService(TelephonyManager::class.java)?.simState == TelephonyManager.SIM_STATE_READY
        update(current.copy(signal = if (simReady) strength.level.coerceIn(0, 4) else null))
    }

    private fun displayInfoChanged(info: TelephonyDisplayInfo) {
        displayNetwork = networkName(info)
        update(current.copy(network = displayNetwork))
    }

    /** What the phone's status bar would call this network. */
    private fun networkName(info: TelephonyDisplayInfo): String? = when (info.overrideNetworkType) {
        TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_NSA,
        TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_ADVANCED -> "5G"
        TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_LTE_ADVANCED_PRO,
        TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_LTE_CA -> "LTE"
        else -> when (info.networkType) {
            TelephonyManager.NETWORK_TYPE_NR -> "5G"
            TelephonyManager.NETWORK_TYPE_LTE, TelephonyManager.NETWORK_TYPE_IWLAN -> "LTE"
            TelephonyManager.NETWORK_TYPE_HSPAP, TelephonyManager.NETWORK_TYPE_HSPA, TelephonyManager.NETWORK_TYPE_HSDPA,
            TelephonyManager.NETWORK_TYPE_HSUPA, TelephonyManager.NETWORK_TYPE_UMTS, TelephonyManager.NETWORK_TYPE_TD_SCDMA -> "3G"
            TelephonyManager.NETWORK_TYPE_EDGE, TelephonyManager.NETWORK_TYPE_GPRS, TelephonyManager.NETWORK_TYPE_GSM -> "2G"
            else -> null
        }
    }

    private fun update(next: Snapshot) {
        if (next == current) return
        current = next
        publish()
    }

    private val delayedPublish = Runnable { publish() }

    private fun publish() {
        if (!listening || current.battery < 0) return
        val last = sent
        if (last == current) return
        // Only the percent moved: at most every 30 s (the rest goes out at once).
        val onlyLevel = last != null && last.copy(battery = current.battery) == current
        val wait = sentAt + LEVEL_INTERVAL_MS - SystemClock.uptimeMillis()
        if (onlyLevel && wait > 0) {
            main.removeCallbacks(delayedPublish)
            main.postDelayed(delayedPublish, wait)
            return
        }
        main.removeCallbacks(delayedPublish)
        val msg = JSONObject().put("t", "phone-status")
            .put("battery", current.battery).put("charging", current.charging).put("wifi", current.wifi)
        current.signal?.let { msg.put("signal", it) }
        current.network?.let { msg.put("network", it) }
        if (HelperConnection.send(msg)) {
            sent = current
            sentAt = SystemClock.uptimeMillis()
        }
    }
}
