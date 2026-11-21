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
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Binary protocol of the display streams (vault/phone-apps-plan.md). Every packet:
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
    // phone → Mac (video stream)
    const val CONFIG = 0x30; const val FRAME = 0x31
    // phone → Mac (audio stream): AUDIO_CONFIG u32 rate, u8 channels; AUDIO u64 pts µs, Opus packet
    const val AUDIO_CONFIG = 0x32; const val AUDIO = 0x33

    const val ROLE_CONTROL = 1; const val ROLE_VIDEO = 2; const val ROLE_AUDIO = 3
    const val NAV_BACK = 1
    /** VISIBILITY: the window in use, hidden, or on screen but not in use. */
    const val VIS_FOCUSED = 0; const val VIS_HIDDEN = 1; const val VIS_VISIBLE = 2
    const val MOUSE_HOVER = 0; const val MOUSE_EXIT = 1; const val MOUSE_SECONDARY_DOWN = 2; const val MOUSE_SECONDARY_UP = 3
    const val GONE_EXITED = 0; const val GONE_MOVED = 1
    const val ERR_NOT_FOUND = 1; const val ERR_LAUNCH = 2; const val ERR_NO_SESSION = 3
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
                if (!target.matches(Regex("[A-Za-z0-9_.]+(/[A-Za-z0-9_.$]+)?"))) return null
                return Open(w and 1.inv(), h and 1.inv(), dpi, fps, kbps, target)
            }
        }
    }

    /** One stream to the Mac. Writes are serialised; a failed write closes it. */
    class Conn(private val socket: LocalSocket) {
        private val input = DataInputStream(socket.inputStream.buffered())
        private val output = DataOutputStream(socket.outputStream.buffered(256 * 1024))
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
    private val token: String,
    private val canNotify: () -> Boolean,
    private val onSessionsChanged: (Int) -> Unit,
) {
    private class Ticket(val expires: Long, val usedRoles: MutableSet<Int> = mutableSetOf())

    private val tickets = ConcurrentHashMap<String, Ticket>()
    private val sessions = ConcurrentHashMap<String, DisplaySession>()
    private val random = SecureRandom()
    /** False if our socket name was taken (by something else): then no tickets are issued. */
    @Volatile private var listening = false
    val openCount get() = sessions.size

    fun start() {
        val server = try {
            LocalServerSocket(SOCKET)
        } catch (e: IOException) {
            Log.d("display socket unavailable ($e); phone apps disabled"); return
        }
        listening = true
        // An app in a window opened again on the phone (its icon, Recents…): it goes to the phone.
        TaskEvents.onRestartAttempt = { task -> sessions.values.firstOrNull { it.owns(task) }?.openedOnPhone() }
        TaskEvents.register()
        Thermal.onChange = { sessions.values.forEach { it.thermalChanged() } }
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
    fun issueTicket(): String? {
        if (!listening) return null
        val now = System.currentTimeMillis()
        tickets.entries.removeIf { it.value.expires < now }
        val ticket = ByteArray(32).also(random::nextBytes).toHex()
        tickets[ticket] = Ticket(now + 10_000)
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
            val expected = hmac("nearside-display:$role:$sid:$ticket")
            if (t == null || t.expires < System.currentTimeMillis() || !MessageDigest.isEqual(expected, proof) ||
                !synchronized(t) { t.usedRoles.add(role) }) {
                Log.d("display stream refused (bad or used ticket)")
                return conn.close()
            }
            // Prove we're the real helper (not something squatting our socket name) before the
            // Mac sends input or trusts any video: HMAC over the same values, server-labelled.
            conn.send(DisplayWire.HELLO, hmac("nearside-display-server:$role:$sid:$ticket"))
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
        conn.setTimeout(0)
        val existing = sessions[sid]
        when {
            type == DisplayWire.RESUME && existing != null && !existing.isClosed -> existing.attachControl(conn)
            type == DisplayWire.OPEN && existing == null -> {
                val open = DisplayWire.Open.parse(body) ?: return conn.close()
                if (!canNotify()) {
                    conn.send(DisplayWire.ERROR, byteArrayOf(DisplayWire.ERR_LAUNCH.toByte()) +
                        "Nearside on your phone isn't running. Open it once, then try again.".toByteArray())
                    return conn.close()
                }
                val session = DisplaySession(sid, this, open)
                sessions[sid] = session
                try {
                    session.start()
                } catch (t: Throwable) {
                    Log.d("display session $sid failed to start: $t")
                    sessions.remove(sid)
                    conn.send(DisplayWire.ERROR, byteArrayOf(DisplayWire.ERR_LAUNCH.toByte()) + "couldn't start: $t".toByteArray())
                    return conn.close()
                }
                session.attachControl(conn)
                onSessionsChanged(sessions.size)
            }
            else -> {
                conn.send(DisplayWire.ERROR, byteArrayOf(DisplayWire.ERR_NO_SESSION.toByte()) + "no such session".toByteArray())
                conn.close()
            }
        }
    }

    fun ended(session: DisplaySession) {
        sessions.remove(session.id)
        onSessionsChanged(sessions.size)
    }

    /** Ends every session, apps back to the phone (the phone's "Stop" button, or a new Mac). */
    fun closeAll() = sessions.values.toList().forEach { it.close(toPhone = true) }

    private fun hmac(message: String): ByteArray =
        Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(token.toByteArray(), "HmacSHA256")) }
            .doFinal(message.toByteArray())

    private fun ByteArray.toHex() = joinToString("") { "%02x".format(it) }

    companion object {
        const val SOCKET = "nearside-display"
    }
}
