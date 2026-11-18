package dev.nearside.helper

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.IOException
import java.io.Writer
import java.util.concurrent.Executors
import kotlin.system.exitProcess

/**
 * Privileged helper. The Mac starts it over wireless ADB:
 *
 *   CLASSPATH=<apk> app_process / dev.nearside.helper.Main
 *
 * It runs as the shell user, watches the clipboard, and serves it to the Nearside app
 * (and only that app, checked by peer uid) over the abstract unix socket below.
 * Protocol: newline-delimited JSON, `{"t":"clip","text":"…","ts":<epoch ms>}` both ways.
 */
object Main {
    const val SOCKET_NAME = "nearside-helper"
    private const val APP_PACKAGE = "dev.nearside"

    private val io = Executors.newSingleThreadExecutor()
    @Volatile private var client: Writer? = null
    @Volatile private var lastSetByMac: String? = null

    @JvmStatic
    fun main(args: Array<String>) {
        setProcessName("nearside-helper")
        Looper.prepareMainLooper()
        Workarounds.apply()

        val server = try {
            LocalServerSocket(SOCKET_NAME)
        } catch (e: IOException) {
            Log.d("socket in use, another helper is running; exiting")
            exitProcess(0)
        }

        val context = FakeContext.instance
        val appUid = try {
            context.packageManager.getApplicationInfo(APP_PACKAGE, 0).uid
        } catch (t: Throwable) {
            Log.d("cannot resolve uid of $APP_PACKAGE: $t")
            exitProcess(1)
        }

        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val main = Handler(Looper.getMainLooper())

        clipboard.addPrimaryClipChangedListener {
            val clip = clipboard.primaryClip ?: return@addPrimaryClipChangedListener
            if (clip.itemCount == 0) return@addPrimaryClipChangedListener
            if (clip.description.extras?.getBoolean("android.content.extra.IS_SENSITIVE") == true) {
                Log.d("skipping sensitive clip")
                return@addPrimaryClipChangedListener
            }
            val text = clip.getItemAt(0).text?.toString() ?: return@addPrimaryClipChangedListener
            if (text == lastSetByMac) return@addPrimaryClipChangedListener // our own echo
            Log.d("clip changed (${text.length} chars)")
            send(JSONObject().put("t", "clip").put("text", text).put("ts", System.currentTimeMillis()))
        }

        Thread({ acceptLoop(server, appUid, clipboard, main) }, "accept").start()
        Log.d("helper ready (uid=${android.os.Process.myUid()}, app uid=$appUid)")
        Looper.loop()
    }

    private fun acceptLoop(server: LocalServerSocket, appUid: Int, clipboard: ClipboardManager, main: Handler) {
        while (true) {
            val socket: LocalSocket = try { server.accept() } catch (e: IOException) { continue }
            val peer = socket.peerCredentials.uid
            if (peer != appUid) {
                Log.d("rejecting peer uid $peer")
                socket.close()
                continue
            }
            Log.d("app connected")
            Thread({ serve(socket, clipboard, main) }, "client").start()
        }
    }

    private fun serve(socket: LocalSocket, clipboard: ClipboardManager, main: Handler) {
        val writer = socket.outputStream.bufferedWriter()
        client = writer
        // The Mac's shared secret, passed in by the Mac when it launched us (see Auth.kt).
        val hello = JSONObject().put("t", "hello").put("sdk", android.os.Build.VERSION.SDK_INT)
        System.getenv("NEARSIDE_TOKEN")?.let { hello.put("token", it) }
        send(hello)
        try {
            socket.inputStream.bufferedReader().forEachLine { line ->
                val msg = runCatching { JSONObject(line) }.getOrNull() ?: return@forEachLine
                if (msg.optString("t") == "clip") {
                    val text = msg.optString("text")
                    main.post {
                        lastSetByMac = text
                        clipboard.setPrimaryClip(ClipData.newPlainText("Nearside", text))
                    }
                }
            }
        } catch (_: IOException) {
        } finally {
            if (client === writer) client = null
            runCatching { socket.close() }
            Log.d("app disconnected")
        }
    }

    private fun send(msg: JSONObject) {
        val w = client ?: return
        io.execute {
            try {
                w.write(msg.toString())
                w.write("\n")
                w.flush()
            } catch (_: IOException) {
                if (client === w) client = null
            }
        }
    }

    @SuppressLint("PrivateApi", "DiscouragedPrivateApi")
    private fun setProcessName(name: String) {
        // Makes the helper findable with `ps -A | grep nearside-helper`.
        runCatching {
            android.os.Process::class.java.getDeclaredMethod("setArgV0", String::class.java).invoke(null, name)
        }
    }
}

object Log {
    fun d(msg: String) = println("[nearside-helper ${System.currentTimeMillis()}] $msg")
}
