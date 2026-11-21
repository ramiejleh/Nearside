package dev.nearside.helper.display

import android.net.LocalServerSocket
import android.net.LocalSocket
import dev.nearside.helper.Log
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Binary protocol of the display streams (docs/display-protocol.md). Every packet:
 * u8 type, u8 flags, u32 big-endian length, payload. The first packet of a stream is HELLO.
 */
object DisplayWire {
    const val HELLO = 0x01
    // Mac → phone (control stream)
    const val OPEN = 0x10; const val RESUME = 0x11; const val TOUCH = 0x12; const val RESIZE = 0x13
    const val NAV = 0x14; const val PING = 0x15; const val VISIBILITY = 0x16; const val CLOSE = 0x17
    const val SYNC = 0x18; const val SCROLL = 0x19; const val MOUSE = 0x1A
    const val KEY = 0x1B; const val TEXT = 0x1C; const val LAYOUT = 0x1D; const val PASTE = 0x1E
    /** ACK: u64 pts of a video frame the Mac received. */
    const val ACK = 0x1F
    // phone → Mac (control stream)
    const val TASK = 0x20; const val TASK_GONE = 0x21; const val PONG = 0x22; const val ERROR = 0x23
    /** THERMAL: u8 1 if quality is reduced because the phone is warm, 0 when back to normal. */
    const val THERMAL = 0x24
    /** SECURE: u8 1 if an app window on the display blocks capture (FLAG_SECURE: it shows black). */
    const val SECURE = 0x25
    /** Mac → phone BLACK: u8 1 when the picture has gone all black (check for SECURE), 0 when not. */
    const val BLACK = 0x40
    // phone → Mac (video stream)
    const val CONFIG = 0x30; const val FRAME = 0x31
    // phone → Mac (audio stream): AUDIO_CONFIG u32 rate, u8 channels; AUDIO u64 pts µs, Opus packet
    const val AUDIO_CONFIG = 0x32; const val AUDIO = 0x33

    const val ROLE_CONTROL = 1; const val ROLE_VIDEO = 2; const val ROLE_AUDIO = 3
    const val NAV_BACK = 1; const val NAV_HOME = 2
    /** OPEN target for the phone window: our home screen, with apps opened from it on top. */
    const val HOME_TARGET = "home"
    /**
     * OPEN target for a notification opened on the Mac: this prefix + its key in hex (keys hold
     * any characters). The app's task comes over and the notification's own intent opens on the
     * display. NOTIFICATION (utf8 key) does the same in a window that's already open.
     */
    const val NOTIFICATION_TARGET = "notification:"
    const val NOTIFICATION = 0x45
    /** Files dropped on the window (utf8 names, one per line, already in the app's shared folder): shared to the app on top. */
    const val SHARE = 0x46
    /** u8 0: the window's sound plays on the phone, not the Mac (sent right after OPEN). */
    const val SOUND = 0x47
    /** Several fingers at once (pinch, rotate): u32 gen, u64 Mac µs, u8 n, n × (u8 action, u8 pointer, f32 x, f32 y). */
    const val TOUCHES = 0x48
    // Phone window, Mac → phone: RECENTS (no body), TASK_FRONT / TASK_REMOVE (i32 task), DOCK (utf8
    // packages, one per line). Phone → Mac: TASKS (utf8 JSON [{id, pkg}], top first), SNAPSHOT
    // (i32 task + JPEG).
    const val RECENTS = 0x41; const val TASK_FRONT = 0x42; const val TASK_REMOVE = 0x43; const val DOCK = 0x44
    const val TASKS = 0x26; const val SNAPSHOT = 0x27
    /** The display's system bars (u16 top, u16 bottom px): the Mac hides the top one. */
    const val INSETS = 0x28
    /** VISIBILITY: the window in use, hidden, or on screen but not in use. */
    const val VIS_FOCUSED = 0; const val VIS_HIDDEN = 1; const val VIS_VISIBLE = 2
    const val MOUSE_HOVER = 0; const val MOUSE_EXIT = 1; const val MOUSE_SECONDARY_DOWN = 2; const val MOUSE_SECONDARY_UP = 3
    const val GONE_EXITED = 0; const val GONE_MOVED = 1
    const val ERR_NOT_FOUND = 1; const val ERR_LAUNCH = 2; const val ERR_NO_SESSION = 3; const val ERR_BUSY = 4
    const val VERSION = 1
    private const val MAX_PACKET = 1024 * 1024 // control packets are small; a paste can be long

    /** OPEN: u16 width, u16 height, u16 dpi, u8 fps, u32 kbps, utf8 target (package or pkg/activity). */
    class Open(val width: Int, val height: Int, val dpi: Int, val fps: Int, val kbps: Int, val target: String) {
        companion object {
            fun parse(b: ByteArray): Open? {
                if (b.size < 12) return null
                val buf = ByteBuffer.wrap(b)
                val w = buf.short.toInt() and 0xffff
                val h = buf.short.toInt() and 0xffff
                val dpi = buf.short.toInt() and 0xffff
                val fps = buf.get().toInt() and 0xff
                val kbps = buf.int
                val target = String(b, 11, b.size - 11)
                if (w !in 64..4096 || h !in 64..4096 || dpi !in 72..640 || fps !in 1..120 || kbps !in 500..100_000) return null
                if (!target.matches(Regex("[A-Za-z0-9_.]+(/[A-Za-z0-9_.$]+)?")) &&
                    !target.matches(Regex("${NOTIFICATION_TARGET}([0-9a-f]{2}){1,1024}"))) return null
                return Open(w and 1.inv(), h and 1.inv(), dpi, fps, kbps, target)
            }
        }
    }

    /** One stream to the Mac. Writes are serialised; a failed write closes it. */
    class Conn(private val socket: LocalSocket) {
        private val input = DataInputStream(socket.inputStream.buffered())
        private val raw = socket.outputStream
        private val output = DataOutputStream(raw.buffered(256 * 1024))
        /** For [sendFrame]'s packet header, reused. */
        private var scratch = ByteArray(0)
        @Volatile var isClosed = false
            private set

        fun read(max: Int = MAX_PACKET): Pair<Int, ByteArray>? = try {
            val type = input.readUnsignedByte()
            input.readUnsignedByte() // flags
            val length = input.readInt()
            if (length < 0 || length > max) throw IOException("packet too large ($length)")
            type to ByteArray(length).also { input.readFully(it) }
        } catch (e: IOException) {
            null
        }

        fun send(type: Int, payload: ByteArray) {
            if (isClosed) return
            try {
                synchronized(output) {
                    output.writeByte(type); output.writeByte(0); output.writeInt(payload.size)
                    output.write(payload)
                    output.flush()
                }
            } catch (e: IOException) {
                close()
            }
        }

        /**
         * A packet whose body is [header] then [size] bytes of [body]: written straight to the
         * socket (no copy, not through the buffer).
         */
        fun sendFrame(type: Int, header: ByteArray, body: ByteArray, size: Int) {
            if (isClosed) return
            try {
                synchronized(output) {
                    output.flush() // anything smaller still waiting goes first
                    val start = 6 + header.size
                    if (scratch.size < start) scratch = ByteArray(start)
                    val s = scratch
                    s[0] = type.toByte(); s[1] = 0
                    val length = header.size + size
                    s[2] = (length ushr 24).toByte(); s[3] = (length ushr 16).toByte(); s[4] = (length ushr 8).toByte(); s[5] = length.toByte()
                    System.arraycopy(header, 0, s, 6, header.size)
                    raw.write(s, 0, start)
                    raw.write(body, 0, size)
                }
            } catch (e: IOException) {
                close()
            }
        }

        fun setTimeout(ms: Int) { socket.soTimeout = ms }

        fun close() {
            isClosed = true
            runCatching { socket.shutdownInput() }
            runCatching { socket.close() }
        }
    }
}

/**
 * Accepts the Mac's display streams on `nearside-display` (reached over adb only; peers must be
 * the shell user, i.e. adbd). Every stream proves itself with a single-use ticket handed out on the
 * already-authenticated control link, plus an HMAC with the shared token, so nothing else on the
 * phone can open a stream or capture an app.
 */
class DisplayServer(
    private val canNotify: () -> Boolean,
    private val onSessionsChanged: (Int) -> Unit,
) {
    /** [token]: the Mac's that asked for it (each Mac has its own; see MacTokens). */
    private class Ticket(val expires: Long, val token: String, val usedRoles: MutableSet<Int> = mutableSetOf())

    private val tickets = ConcurrentHashMap<String, Ticket>()
    private val sessions = ConcurrentHashMap<String, DisplaySession>()
    private val random = SecureRandom()
    /** False if our socket name was taken (by something else): then no tickets are issued. */
    @Volatile private var listening = false
    val openCount get() = sessions.size

    /**
     * While windows are open: if a window's control thread is stuck on one packet (input and
     * pings stop reaching the app: the window freezes), write every thread's stack to the log,
     * once, so the cause can be found.
     */
    private val watchdog = java.util.concurrent.Executors.newSingleThreadScheduledExecutor { Thread(it, "display-watchdog").apply { isDaemon = true } }
    @Volatile private var dumped = false
    private var watching: java.util.concurrent.ScheduledFuture<*>? = null

    /** The watchdog runs only while windows are open (otherwise the helper sleeps). */
    @Synchronized
    private fun watchdog(on: Boolean) {
        if (on == (watching != null)) return
        watching = if (on) watchdog.scheduleWithFixedDelay({ runCatching { watch() } }, 10, 10, TimeUnit.SECONDS)
            else { watching?.cancel(false); null }
    }

    private fun watch() {
        if (dumped || sessions.isEmpty()) return
        val stuck = sessions.values.filter { it.stuckFor(10_000) }
        if (stuck.isEmpty()) return
        dumped = true
        Log.d("watchdog: control stuck for ${stuck.joinToString { it.id }}; all threads:")
        for ((thread, stack) in Thread.getAllStackTraces()) {
            Log.d("  \"${thread.name}\" ${thread.state}")
            stack.take(25).forEach { Log.d("      at $it") }
        }
    }

    fun start() {
        val server = try {
            LocalServerSocket(SOCKET)
        } catch (e: IOException) {
            Log.d("display socket unavailable ($e); phone apps disabled"); return
        }
        listening = true
        // An app in a window opened again on the phone (its icon, Recents…): it goes to the phone.
        TaskEvents.onRestartAttempt = { task -> sessions.values.firstOrNull { it.owns(task) }?.openedOnPhone(task) }
        TaskEvents.onTasksChanged = { sessions.values.forEach { it.tasksChanged() } }
        Thermal.onChange = {
            rebalance()
            sessions.values.forEach { it.thermalChanged() }
        }
        Thermal.start()
        Thread({
            while (true) {
                val socket = try { server.accept() } catch (e: IOException) { continue }
                if (runCatching { socket.peerCredentials.uid }.getOrDefault(-1) != 2000) {
                    runCatching { socket.close() }; continue
                }
                Thread({ handshake(socket) }, "display-hello").start()
            }
        }, "display-accept").start()
    }

    /** A ticket for the Mac's next display streams: random, single use per role, 10 seconds. */
    fun issueTicket(token: String): String? {
        if (!listening) return null
        val now = System.currentTimeMillis()
        tickets.entries.removeIf { it.value.expires < now }
        val ticket = ByteArray(32).also(random::nextBytes).toHex()
        tickets[ticket] = Ticket(now + 10_000, token)
        return ticket
    }

    /** HELLO: "ATD1", u16 version, u8 role, 16-byte session id, 32-byte ticket, 32-byte HMAC. */
    private fun handshake(socket: LocalSocket) {
        val conn = DisplayWire.Conn(socket)
        try {
            conn.setTimeout(5000)
            val (type, hello) = conn.read(128) ?: return conn.close()
            if (type != DisplayWire.HELLO || hello.size != 87 || String(hello, 0, 4) != "ATD1") return conn.close()
            val b = ByteBuffer.wrap(hello, 4, hello.size - 4)
            if (b.short.toInt() != DisplayWire.VERSION) return conn.close()
            val role = b.get().toInt()
            val sid = ByteArray(16).also { b.get(it) }.toHex()
            val ticket = ByteArray(32).also { b.get(it) }.toHex()
            val proof = ByteArray(32).also { b.get(it) }
            val t = tickets[ticket]
            val expected = if (t == null) ByteArray(32) else hmac(t.token, "nearside-display:$role:$sid:$ticket")
            if (t == null || t.expires < System.currentTimeMillis() || !MessageDigest.isEqual(expected, proof) ||
                !synchronized(t) { t.usedRoles.add(role) }) {
                Log.d("display stream refused (bad or used ticket)")
                return conn.close()
            }
            // Prove we're the real helper (not something squatting our socket name) before the
            // Mac sends input or trusts any video: HMAC over the same values, server-labelled.
            conn.send(DisplayWire.HELLO, hmac(t.token, "nearside-display-server:$role:$sid:$ticket"))
            when (role) {
                DisplayWire.ROLE_CONTROL -> control(conn, sid)
                DisplayWire.ROLE_VIDEO, DisplayWire.ROLE_AUDIO -> {
                    // The control stream's OPEN may still be starting the session.
                    var session = sessions[sid]
                    for (i in 0 until 30) { if (session != null) break; Thread.sleep(100); session = sessions[sid] }
                    if (session == null) return conn.close()
                    conn.setTimeout(0)
                    if (role == DisplayWire.ROLE_VIDEO) session.attachVideo(conn) else session.attachAudio(conn)
                }
                else -> conn.close()
            }
        } catch (e: Exception) {
            Log.d("display hello failed: $e")
            conn.close()
        }
    }

    private fun control(conn: DisplayWire.Conn, sid: String) {
        val (type, body) = conn.read() ?: return conn.close()
        // The Mac pings at least every 5 s: 15 s of silence means it's gone (it may have vanished
        // without closing anything: Wi-Fi off, asleep), and the session's grace period starts.
        // Without this the display stayed awake until adbd noticed, minutes later.
        conn.setTimeout(15_000)
        val existing = sessions[sid]
        when {
            type == DisplayWire.RESUME && existing != null && !existing.isClosed -> existing.attachControl(conn)
            type == DisplayWire.OPEN && existing == null -> {
                val open = DisplayWire.Open.parse(body) ?: return conn.close()
                // Just after the helper starts, the app restarts once (SystemBars): give it a moment.
                for (i in 0 until 50) { if (canNotify()) break; Thread.sleep(200) }
                if (!canNotify()) {
                    conn.send(DisplayWire.ERROR, byteArrayOf(DisplayWire.ERR_LAUNCH.toByte()) +
                        "Nearside on your phone isn't running. Open it once, then try again.".toByteArray())
                    return conn.close()
                }
                // One phone window: our home screen is a single task, and a second window (or one
                // left waiting for a Mac that went) would pull it back and forth between displays.
                if (open.target == DisplayWire.HOME_TARGET) {
                    sessions.values.filter { it.isHome }.forEach { it.close(toPhone = true) }
                }
                val session = DisplaySession(sid, this, open)
                sessions[sid] = session
                TaskEvents.listen(true)
                watchdog(true)
                try {
                    session.start()
                } catch (t: Throwable) {
                    Log.d("display session $sid failed to start: $t")
                    sessions.remove(sid)
                    if (sessions.isEmpty()) { TaskEvents.listen(false); watchdog(false) }
                    val (code, text) = if (t is DisplaySession.EncoderBusy) DisplayWire.ERR_BUSY to "Your phone can't show more apps at once."
                        else DisplayWire.ERR_LAUNCH to "couldn't start: $t"
                    conn.send(DisplayWire.ERROR, byteArrayOf(code.toByte()) + text.toByteArray())
                    return conn.close()
                }
                session.attachControl(conn)
                onSessionsChanged(sessions.size)
                rebalance()
            }
            else -> {
                conn.send(DisplayWire.ERROR, byteArrayOf(DisplayWire.ERR_NO_SESSION.toByte()) + "no such session".toByteArray())
                conn.close()
            }
        }
    }

    /**
     * An app is about to move from [displayId] into another window. If that's an app window of
     * ours, it gives up its sound first: Android routes an app's sound to one virtual audio
     * device, and while the old window's still claims the app (its session waiting for the Mac
     * to come back, say), the new window's claim is ignored, and once the old one lets go the
     * sound plays on the phone's speaker. (A home window keeps its sound: its other apps use it.)
     */
    fun releaseSoundOn(displayId: Int) {
        sessions.values.firstOrNull { it.displayId == displayId && !it.isHome }?.releaseSound()
    }

    fun ended(session: DisplaySession) {
        sessions.remove(session.id)
        if (sessions.isEmpty()) { TaskEvents.listen(false); watchdog(false) }
        onSessionsChanged(sessions.size)
        rebalance()
    }

    /**
     * The phone's one hardware encoder block, shared: about 440 Mpx/s measured (three phone-sized
     * windows at 57 fps), less when warm. Windows in use get their full rate; the others on screen
     * split what's left (30 fps at most, 5 at least, in steps so encoders aren't swapped for small
     * changes); hidden ones take nothing.
     */
    @Synchronized
    fun rebalance() {
        val budget = PIXEL_BUDGET * (if (Thermal.moderate) 0.7 else 1.0)
        val encoding = sessions.values.filter { it.isEncoding }
        val (focused, others) = encoding.partition { it.isFocused }
        val left = budget - focused.sumOf { it.pixels.toDouble() * it.focusedFps }
        val pixels = others.sumOf { it.pixels.toDouble() }
        val share = if (pixels <= 0) 30 else STEPS.firstOrNull { it * pixels <= left } ?: STEPS.last()
        sessions.values.forEach { it.setShare(share) }
        if (others.isNotEmpty()) Log.d("budget: ${focused.size} in use, ${others.size} on screen at $share fps")
    }

    /** Ends every session, apps back to the phone (the phone's "Stop" button, or a new Mac). */
    fun closeAll() = sessions.values.toList().forEach { it.close(toPhone = true) }

    private fun hmac(token: String, message: String): ByteArray =
        Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(token.toByteArray(), "HmacSHA256")) }
            .doFinal(message.toByteArray())

    private fun ByteArray.toHex() = joinToString("") { "%02x".format(it) }

    companion object {
        const val SOCKET = "nearside-display"
        const val PIXEL_BUDGET = 440e6
        private val STEPS = listOf(30, 20, 15, 10, 5)
    }
}
