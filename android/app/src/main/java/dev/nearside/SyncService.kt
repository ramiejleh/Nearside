package dev.nearside

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import org.json.JSONObject
import java.io.IOException
import java.io.Writer
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors

/** Live state shown by [MainActivity]. PoC only: plain volatile fields. */
object Status {
    @Volatile var serviceRunning = false
    @Volatile var helperConnected = false
    @Volatile var macConnected = false
    @Volatile var lastEvent = "—"
}

/**
 * Bridges the Mac (TCP on the LAN, advertised as `_nearside._tcp`) and the privileged
 * helper (abstract unix socket). Messages are newline-delimited JSON, see helper/Main.kt.
 * No encryption or pairing: this is a throwaway LAN-only proof of concept.
 */
class SyncService : Service() {
    companion object {
        const val PORT = 47800
        private const val CHANNEL = "sync"

        fun start(context: Context) {
            context.startForegroundService(Intent(context, SyncService::class.java))
        }
    }

    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var mac: Writer? = null
    @Volatile private var macSocket: Socket? = null
    @Volatile private var helper: Writer? = null
    @Volatile private var running = false
    private var serverSocket: ServerSocket? = null
    private var nsdListener: NsdManager.RegistrationListener? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(1, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        if (!running) {
            running = true
            Status.serviceRunning = true
            AdbWifi.ensureEnabled(this)
            Thread(::macLoop, "mac").start()
            Thread(::helperLoop, "helper").start()
            watchWifi()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        Status.serviceRunning = false
        runCatching { serverSocket?.close() }
        nsdListener?.let { runCatching { getSystemService(NsdManager::class.java).unregisterService(it) } }
        networkCallback?.let { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) }
        super.onDestroy()
    }

    // --- Mac side -------------------------------------------------------------------------

    private fun macLoop() {
        val server = try {
            ServerSocket(PORT).also { serverSocket = it }
        } catch (e: IOException) {
            event("cannot listen on $PORT: $e")
            return
        }
        advertise()
        while (running) {
            val socket = try { server.accept() } catch (e: IOException) { continue }
            socket.tcpNoDelay = true
            socket.keepAlive = true
            Thread({ serveMac(socket) }, "mac-client").start()
        }
    }

    private fun serveMac(socket: Socket) {
        val reader = socket.getInputStream().bufferedReader()
        // The first line must authenticate; nothing is relayed to or from an unknown peer.
        val authed = try {
            socket.soTimeout = 5000
            val first = JSONObject(reader.readLine() ?: "")
            socket.soTimeout = 0
            first.optString("t") == "auth" && Auth.isValid(this, first.optString("token"))
        } catch (_: Exception) {
            false
        }
        if (!authed) {
            event("rejected unauthenticated client ${socket.inetAddress.hostAddress}")
            runCatching { socket.close() }
            return
        }
        // One Mac at a time; an authenticated connection replaces the old one.
        runCatching { macSocket?.close() }
        macSocket = socket
        val writer = socket.getOutputStream().bufferedWriter()
        mac = writer
        Status.macConnected = true
        event("Mac connected from ${socket.inetAddress.hostAddress}")
        sendStatus()
        try {
            reader.forEachLine { line ->
                val msg = runCatching { JSONObject(line) }.getOrNull() ?: return@forEachLine
                if (msg.optString("t") == "clip") onClipFromMac(msg)
            }
        } catch (_: IOException) {
        } finally {
            if (mac === writer) {
                mac = null
                Status.macConnected = false
                event("Mac disconnected")
            }
            runCatching { socket.close() }
        }
    }

    private fun onClipFromMac(msg: JSONObject) {
        val text = msg.optString("text")
        event("Mac → phone (${text.length} chars, ${System.currentTimeMillis() - msg.optLong("ts")} ms)")
        if (helper != null) {
            write(helper, msg)
        } else {
            // Fallback: background apps may still *write* the clipboard.
            main.post {
                getSystemService(ClipboardManager::class.java)
                    .setPrimaryClip(ClipData.newPlainText("Nearside", text))
            }
        }
    }

    private fun sendStatus() {
        write(mac, JSONObject().put("t", "status").put("helper", helper != null))
    }

    private fun advertise() {
        val info = NsdServiceInfo().apply {
            serviceName = "Nearside ${android.os.Build.MODEL}"
            serviceType = "_nearside._tcp"
            port = PORT
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) = event("advertised as ${info.serviceName}")
            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) = event("advertise failed: $code")
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {}
        }
        nsdListener = listener
        getSystemService(NsdManager::class.java).registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    // --- Helper side ----------------------------------------------------------------------

    private fun helperLoop() {
        while (running) {
            val socket = LocalSocket()
            try {
                socket.connect(LocalSocketAddress("nearside-helper"))
            } catch (e: IOException) {
                runCatching { socket.close() }
                Thread.sleep(2000)
                continue
            }
            val writer = socket.outputStream.bufferedWriter()
            helper = writer
            Status.helperConnected = true
            event("helper connected")
            sendStatus()
            try {
                socket.inputStream.bufferedReader().forEachLine { line ->
                    val msg = runCatching { JSONObject(line) }.getOrNull() ?: return@forEachLine
                    when (msg.optString("t")) {
                        "hello" -> msg.optString("token").takeIf { it.isNotEmpty() }
                            ?.let { Auth.store(this, it) }
                        "clip" -> {
                            event("phone → Mac (${msg.optString("text").length} chars)")
                            write(mac, msg)
                        }
                    }
                }
            } catch (_: IOException) {
            }
            helper = null
            Status.helperConnected = false
            event("helper disconnected")
            sendStatus()
            runCatching { socket.close() }
        }
    }

    // --- Wireless debugging upkeep ----------------------------------------------------------

    private fun watchWifi() {
        val cm = getSystemService(ConnectivityManager::class.java)
        val callback = object : ConnectivityManager.NetworkCallback() {
            // Android switches wireless debugging off when Wi-Fi changes; turn it back on so the
            // Mac can restart the helper.
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

    // --- Utilities ------------------------------------------------------------------------

    private fun write(target: Writer?, msg: JSONObject) {
        val w = target ?: return
        io.execute {
            try {
                w.write(msg.toString())
                w.write("\n")
                w.flush()
            } catch (_: IOException) {
            }
        }
    }

    private fun event(text: String) {
        Status.lastEvent = text
        android.util.Log.i("Nearside", text)
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
