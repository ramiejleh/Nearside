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
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.Writer
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.Executors
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlin.system.exitProcess

/**
 * Privileged helper. The Mac starts it over wireless ADB:
 *
 *   NEARSIDE_TOKEN=<t> CLASSPATH=<apk> app_process / dev.nearside.helper.Main
 *
 * It runs as the shell user and watches the clipboard. The Mac reaches it through
 * `adb forward tcp:<port> localabstract:nearside-helper`: the link rides adb's TLS and is
 * never exposed on the LAN. Apps can't connect at all (SELinux denies untrusted_app →
 * shell sockets), and we additionally require the peer to be adbd (shell uid) plus a mutual
 * token proof (see [serve]). Protocol: newline-delimited JSON; after the handshake
 * `{"t":"clip","text":"…","ts":<epoch ms>}` flows both ways.
 */
object Main {
    const val SOCKET_NAME = "nearside-helper"
    private const val SHELL_UID = 2000

    private val io = Executors.newSingleThreadExecutor()
    @Volatile private var client: Writer? = null
    @Volatile private var lastSetByMac: String? = null
    private var lastSent: String? = null // main looper only
    private var lastSentAt = 0L

    @JvmStatic
    fun main(args: Array<String>) {
        setProcessName("nearside-helper")
        Looper.prepareMainLooper()
        Workarounds.apply()

        val token = System.getenv("NEARSIDE_TOKEN")
        if (token == null || token.length < 32) {
            Log.d("missing NEARSIDE_TOKEN; exiting")
            exitProcess(1)
        }
        val server = try {
            LocalServerSocket(SOCKET_NAME)
        } catch (e: IOException) {
            Log.d("socket in use, another helper is running; exiting")
            exitProcess(0)
        }

        val clipboard = FakeContext.instance.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
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
            // Android 17 fires this listener twice per copy (~50 ms apart); send once.
            val now = System.currentTimeMillis()
            if (text == lastSent && now - lastSentAt < 1000) return@addPrimaryClipChangedListener
            lastSent = text
            lastSentAt = now
            Log.d("clip changed (${text.length} chars)")
            send(JSONObject().put("t", "clip").put("text", text).put("ts", System.currentTimeMillis()))
        }

        Thread({ acceptLoop(server, token, clipboard, main) }, "accept").start()
        Log.d("helper ready (uid=${android.os.Process.myUid()}, sdk=${android.os.Build.VERSION.SDK_INT})")
        Looper.loop()
    }

    private fun acceptLoop(server: LocalServerSocket, token: String, clipboard: ClipboardManager, main: Handler) {
        while (true) {
            val socket: LocalSocket = try { server.accept() } catch (e: IOException) { continue }
            val peer = runCatching { socket.peerCredentials.uid }.getOrDefault(-1)
            if (peer != SHELL_UID) {
                Log.d("rejecting peer uid $peer")
                runCatching { socket.close() }
                continue
            }
            Thread({ serve(socket, token, clipboard, main) }, "client").start()
        }
    }

    /**
     * Mutual challenge-response; the token itself never crosses the link.
     *   Mac → {"t":"hello-mac","nonce":Nm}
     *   us  → {"t":"challenge","proof":HMAC(token,"nearside-helper:"+Nm),"nonce":Nh}
     *   Mac → {"t":"auth","proof":HMAC(token,"nearside-mac:"+Nh)}
     * The Mac sends nothing sensitive until it has verified our proof, so an app squatting
     * our socket name learns nothing.
     */
    private fun serve(socket: LocalSocket, token: String, clipboard: ClipboardManager, main: Handler) {
        try {
            socket.soTimeout = 5000
            val out = socket.outputStream
            val hello = JSONObject(readBoundedLine(socket.inputStream, 512))
            val macNonce = hello.optString("nonce")
            if (hello.optString("t") != "hello-mac" || macNonce.length != 64) throw IOException("bad hello")
            val ourNonce = randomHex()
            val challenge = JSONObject().put("t", "challenge")
                .put("proof", hmacHex(token, "nearside-helper:$macNonce")).put("nonce", ourNonce)
            out.write("$challenge\n".toByteArray())
            out.flush()
            val auth = JSONObject(readBoundedLine(socket.inputStream, 512))
            val expected = hmacHex(token, "nearside-mac:$ourNonce")
            if (auth.optString("t") != "auth" ||
                !MessageDigest.isEqual(expected.toByteArray(), auth.optString("proof").toByteArray())) {
                Log.d("rejecting client that failed authentication")
                socket.close()
                return
            }
            socket.soTimeout = 0
        } catch (e: Exception) {
            runCatching { socket.close() }
            return
        }

        val writer = socket.outputStream.bufferedWriter()
        client = writer // one Mac at a time; the newest wins
        Log.d("Mac connected")
        send(JSONObject().put("t", "hello").put("sdk", android.os.Build.VERSION.SDK_INT))
        try {
            socket.inputStream.bufferedReader().forEachLine { line ->
                val msg = runCatching { JSONObject(line) }.getOrNull() ?: return@forEachLine
                if (msg.optString("t") == "clip") {
                    val text = msg.optString("text")
                    Log.d("set clip from Mac (${text.length} chars, ${System.currentTimeMillis() - msg.optLong("ts")} ms)")
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
            Log.d("Mac disconnected")
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

    private fun hmacHex(key: String, message: String): String {
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key.toByteArray(), "HmacSHA256")) }
        return mac.doFinal(message.toByteArray()).joinToString("") { "%02x".format(it) }
    }

    private fun randomHex(): String =
        ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }

    /** One '\n'-terminated line of at most [max] bytes; unbuffered so nothing past it is consumed. */
    private fun readBoundedLine(input: InputStream, max: Int): String {
        val bytes = ByteArrayOutputStream()
        while (true) {
            val b = input.read()
            if (b == -1) throw IOException("eof")
            if (b == '\n'.code) return bytes.toString(Charsets.UTF_8.name())
            if (bytes.size() >= max) throw IOException("line too long")
            bytes.write(b)
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
