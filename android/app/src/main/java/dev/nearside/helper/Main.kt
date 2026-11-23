package dev.nearside.helper

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.Handler
import android.os.Looper
import dev.nearside.helper.display.DisplayServer
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
 * `{"t":"clip","text":"…","ts":<epoch ms>}` flows both ways. Other message types are relayed
 * to and from the Nearside app over a Binder (see [AppLink]); `{"t":"app","linked":bool}`
 * tells the Mac whether that link is up.
 */
object Main {
    const val SOCKET_NAME = "nearside-helper"
    private const val SHELL_UID = 2000

    private val io = Executors.newSingleThreadExecutor()
    @Volatile private var client: Writer? = null
    /** The Mac using the phone now (see [serve]): its id, name and socket. */
    private class Owner(val id: String, val name: String, val socket: LocalSocket, val writer: Writer)
    @Volatile private var owner: Owner? = null
    /** The Mac's last clip and when it was set here: its echo (Android fires twice) isn't sent back. */
    @Volatile private var lastSetByMac: String? = null
    @Volatile private var lastSetByMacAt = 0L
    private lateinit var displays: DisplayServer
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
            val now = System.currentTimeMillis()
            // Our own echo. Only right after setting it: copying the same text again later on
            // the phone is a real copy.
            if (text == lastSetByMac && now - lastSetByMacAt < 2000) return@addPrimaryClipChangedListener
            // Android 17 fires this listener twice per copy (~50 ms apart); send once.
            if (text == lastSent && now - lastSentAt < 1000) return@addPrimaryClipChangedListener
            lastSent = text
            lastSentAt = now
            Log.d("clip changed (${text.length} chars)")
            send(JSONObject().put("t", "clip").put("text", text).put("ts", System.currentTimeMillis()))
        }

        // Pastes into phone-app windows: set on the main looper (waited for, so the paste that
        // follows reads it), marked as the Mac's so it isn't sent back.
        dev.nearside.helper.display.PhoneClipboard.set = { text ->
            val latch = java.util.concurrent.CountDownLatch(1)
            main.post {
                try {
                    lastSetByMac = text
                    lastSetByMacAt = System.currentTimeMillis()
                    clipboard.setPrimaryClip(ClipData.newPlainText("Nearside", text))
                } finally { latch.countDown() }
            }
            latch.await(500, java.util.concurrent.TimeUnit.MILLISECONDS)
        }
        // Phone-app windows have their own clipboard (the virtual device's, readable while locked):
        // what's copied there goes to the Mac like a phone copy, and the Mac's clips land there too.
        dev.nearside.helper.display.PhoneDevice.onCopied = { text ->
            send(JSONObject().put("t", "clip").put("text", text).put("ts", System.currentTimeMillis()))
        }
        dev.nearside.helper.display.PhoneClipboard.get = {
            clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()
        }

        // Phone apps can be used from the Mac while the phone is locked, so the phone must always
        // show that: no app link (no notification) means no new sessions, and a relink re-posts it.
        displays = DisplayServer(canNotify = { AppLink.isLinked }) { open ->
            AppLink.deliver(JSONObject().put("t", "display-state").put("open", open))
        }.also { it.start() } // the app list and the system-bars host start when first needed
        AppLink.stopApps = { displays.closeAll() }
        AppLink.onUnlinked = {
            // Without the app, the phone shows nothing about apps open on the Mac: if it doesn't
            // come back soon (e.g. force-stopped), end the sessions.
            Thread {
                Thread.sleep(10_000)
                if (!AppLink.isLinked && displays.openCount > 0) {
                    Log.d("app still unlinked; closing phone-app sessions")
                    displays.closeAll()
                }
            }.start()
        }
        AppLink.onLinked = {
            AppLink.deliver(JSONObject().put("t", "display-state").put("open", displays.openCount))
        }

        AppLink.toMac = { msg -> client != null && send(msg) }
        AppLink.macConnected = { client != null }
        Calls.toMac = { msg -> client != null && send(msg) }
        AppLink.start()

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
     *   Mac → {"t":"hello-mac","nonce":Nm,"id","name","passive"}   (id: whose token, see MacTokens)
     *   us  → {"t":"challenge","proof":HMAC(token,"nearside-helper:"+Nm),"nonce":Nh}
     *   Mac → {"t":"auth","proof":HMAC(token,"nearside-mac:"+Nh)}
     * The Mac sends nothing sensitive until it has verified our proof, so an app squatting
     * our socket name learns nothing.
     *
     * One Mac at a time. Another Mac connecting takes the phone over: the first one's app
     * windows close (their apps go back to the phone) and it's told {"t":"taken-over","by"}. A
     * Mac that was taken over connects "passive": then it's only answered {"t":"busy","by"}
     * while another Mac has the phone, so two Macs never take it from each other in turn.
     */
    private fun serve(socket: LocalSocket, starterToken: String, clipboard: ClipboardManager, main: Handler) {
        val macId: String
        val macName: String
        val token: String
        try {
            socket.soTimeout = 5000
            val out = socket.outputStream
            val hello = JSONObject(readBoundedLine(socket.inputStream, 512))
            val macNonce = hello.optString("nonce")
            if (hello.optString("t") != "hello-mac" || macNonce.length != 64) throw IOException("bad hello")
            // Older Macs send no id: the starter's.
            macId = hello.optString("id").ifEmpty { MacTokens.idOf(starterToken) }
            macName = hello.optString("name").filter { it >= ' ' }.take(64).ifEmpty { "another Mac" }
            token = MacTokens.token(macId, starterToken) ?: throw IOException("unknown Mac $macId")
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
            val current = owner
            if (current != null && current.id != macId) {
                if (hello.optBoolean("passive")) { // waiting for the phone to be free
                    out.write("${JSONObject().put("t", "busy").put("by", current.name)}\n".toByteArray())
                    out.flush()
                    socket.close()
                    return
                }
                Log.d("Mac \"$macName\" takes the phone over from \"${current.name}\"")
                io.execute { // after anything still queued for it
                    runCatching {
                        current.writer.write("${JSONObject().put("t", "taken-over").put("by", macName)}\n")
                        current.writer.flush()
                    }
                    // Shut down first: a close alone doesn't wake its reader thread.
                    runCatching { current.socket.shutdownInput() }
                    runCatching { current.socket.shutdownOutput() }
                    runCatching { current.socket.close() }
                }
                displays.closeAll() // its windows' apps go back to the phone
            }
        } catch (e: Exception) {
            Log.d("Mac hello refused: ${e.message}")
            runCatching { socket.close() }
            return
        }

        val writer = socket.outputStream.bufferedWriter()
        owner = Owner(macId, macName, socket, writer)
        client = writer // one Mac at a time; the newest wins
        Log.d("Mac connected (\"$macName\")")
        send(JSONObject().put("t", "hello").put("sdk", android.os.Build.VERSION.SDK_INT))
        send(JSONObject().put("t", "app").put("linked", AppLink.isLinked))
        AppLink.macConnectionChanged(true)
        Calls.macConnectionChanged(true)
        try {
            socket.inputStream.bufferedReader().forEachLine { line ->
                val msg = runCatching { JSONObject(line) }.getOrNull() ?: return@forEachLine
                val type = msg.optString("t")
                if (type.startsWith("display-")) {
                    handleDisplay(msg, token)
                } else if (type == "call-place" || type == "call-mute") {
                    Calls.handle(msg)
                } else if (type != "clip") {
                    AppLink.deliver(msg) // everything else is for the app's features
                } else {
                    val text = msg.optString("text")
                    Log.d("set clip from Mac (${text.length} chars, ${System.currentTimeMillis() - msg.optLong("ts")} ms)")
                    main.post {
                        lastSetByMac = text
                        lastSetByMacAt = System.currentTimeMillis()
                        clipboard.setPrimaryClip(ClipData.newPlainText("Nearside", text))
                        dev.nearside.helper.display.PhoneDevice.setClipEverywhere(text)
                    }
                }
            }
        } catch (_: IOException) {
        } finally {
            if (client === writer) {
                client = null
                AppLink.macConnectionChanged(false)
                Calls.macConnectionChanged(false)
            }
            if (owner?.writer === writer) owner = null
            runCatching { socket.close() }
            Log.d("Mac disconnected")
        }
    }

    /** Phone-apps requests on the control link (the streams themselves use nearside-display). */
    private fun handleDisplay(msg: JSONObject, token: String) {
        when (msg.optString("t")) {
            "display-ticket" -> send(JSONObject().put("t", "display-ticket").put("req", msg.opt("req"))
                .put("ticket", displays.issueTicket(token) ?: JSONObject.NULL))
            "display-apps" -> Thread {
                // The Mac's launcher is open: an app window is likely next, so get its bars ready.
                dev.nearside.helper.display.SystemBars.prewarm()
                val started = System.currentTimeMillis()
                val reply = runCatching { dev.nearside.helper.display.AppCatalog.apps() }.getOrElse {
                    Log.d("display-apps failed: $it")
                    JSONObject().put("t", "display-apps").put("error", it.toString())
                }
                Log.d("display-apps: ${reply.optJSONArray("apps")?.length() ?: 0} apps in ${System.currentTimeMillis() - started} ms")
                send(reply.put("req", msg.opt("req")))
            }.start()
            "display-icons" -> Thread {
                val ids = msg.optJSONArray("ids")?.let { a -> List(a.length()) { a.optString(it) } }.orEmpty().take(24)
                val reply = runCatching { dev.nearside.helper.display.AppCatalog.icons(ids) }
                    .getOrElse { JSONObject().put("t", "display-icons").put("error", it.toString()) }
                send(reply.put("req", msg.opt("req")))
            }.start()
            "display-layouts" -> Thread { // for the Mac's keyboard-layout setting
                val labels = org.json.JSONArray(dev.nearside.helper.display.Hidden.keyboardLayouts.map { it.label }.distinct().sorted())
                send(JSONObject().put("t", "display-layouts").put("layouts", labels).put("req", msg.opt("req")))
            }.start()
            "display-stop-all" -> displays.closeAll()
        }
    }

    private fun send(msg: JSONObject): Boolean {
        val w = client ?: return false
        io.execute {
            try {
                w.write(msg.toString())
                w.write("\n")
                w.flush()
            } catch (_: IOException) {
                if (client === w) client = null
            }
        }
        return true
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
