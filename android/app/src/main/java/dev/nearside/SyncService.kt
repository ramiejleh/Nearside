package dev.nearside

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.IBinder

/** Live state shown by [MainActivity]. PoC only: plain volatile fields. */
object Status {
    @Volatile var serviceRunning = false
    @Volatile var lastEvent = "—"
}

/**
 * PoC role: stay alive as a foreground service and try to keep wireless debugging on, so the
 * Mac can (re)start the helper. Clipboard traffic goes Mac ⇄ helper over the adb tunnel; the
 * app can't talk to the helper directly (SELinux blocks untrusted_app → shell sockets; the real
 * app will use a Binder handed over Shizuku-style). Tier-1 features will live here later.
 */
class SyncService : Service() {
    companion object {
        private const val CHANNEL = "sync"

        fun start(context: Context) {
            context.startForegroundService(Intent(context, SyncService::class.java))
        }
    }

    @Volatile private var running = false
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(1, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        if (!running) {
            running = true
            Status.serviceRunning = true
            AdbWifi.ensureEnabled(this)
            watchWifi()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        Status.serviceRunning = false
        networkCallback?.let { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) }
        super.onDestroy()
    }

    private fun watchWifi() {
        val cm = getSystemService(ConnectivityManager::class.java)
        val callback = object : ConnectivityManager.NetworkCallback() {
            // Android switches wireless debugging off when Wi-Fi changes; try to turn it back on.
            override fun onAvailable(network: Network) {
                AdbWifi.ensureEnabled(this@SyncService)
            }
        }
        networkCallback = callback
        cm.registerNetworkCallback(
            NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(),
            callback,
        )
    }

    private fun notification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, "Connection", NotificationManager.IMPORTANCE_MIN),
        )
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("Nearside is running")
            .setOngoing(true)
            .build()
    }
}
