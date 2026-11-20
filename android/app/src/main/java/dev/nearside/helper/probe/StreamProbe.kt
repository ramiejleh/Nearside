// Gate B probe: streams an app on its own virtual display to the Mac viewer (`atview`) over
// adb (localabstract:nearside-probe) and takes touch/resize/ping back. The real DisplayServer
// grows from this; it adds tickets + HMAC auth, separate ctl/video/audio streams, GL, budgets.
// Display/encoder/injection adapted from scrcpy (Apache-2.0, Genymobile).
//
// Wire (all big-endian), every packet: u8 type, u32 length, payload.
//   Mac → phone hello (first packet): HELLO=1 {u8 role 'v'|'p'|'t', role 'v': u16 w, u16 h,
//     u16 dpi, u8 fps, u32 kbps, utf8 component}
//   phone → Mac: CONFIG=2 {u16 w, u16 h, u32 gen, annex-B VPS/SPS/PPS}
//                FRAME=3 {u32 gen, u64 ptsUs (CLOCK_MONOTONIC), u64 encodedUs, u8 key, annex-B data}
//                PONG=12 {u64 t0, u64 phoneUs}   BULK=20 {bytes} (role 't')
//   Mac → phone: TOUCH=10 {u8 action, u32 gen, f32 x, f32 y} (x/y normalised 0…1)
//                PING=11 {u64 t0}   RESIZE=13 {u16 w, u16 h, u16 dpi}
package dev.nearside.helper.probe

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.Looper
import android.os.SystemClock
import android.view.InputDevice
import android.view.InputEvent
import android.view.MotionEvent
import dev.nearside.helper.FakeContext
import dev.nearside.helper.Workarounds
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.nio.ByteBuffer

@SuppressLint("PrivateApi", "DiscouragedPrivateApi", "WrongConstant")
object StreamProbe {
    private const val FLAGS = (1 shl 0) or (1 shl 3) or (1 shl 6) or (1 shl 10) or (1 shl 11) or
        (1 shl 12) or (1 shl 13) or (1 shl 14) // PUBLIC|OWN_CONTENT_ONLY|SUPPORTS_TOUCH|TRUSTED|OWN_DISPLAY_GROUP|ALWAYS_UNLOCKED|TOUCH_FEEDBACK_DISABLED|OWN_FOCUS

    private val displayManager by lazy {
        DisplayManager::class.java.getDeclaredConstructor(Context::class.java).apply { isAccessible = true }
            .newInstance(FakeContext.instance) as DisplayManager
    }
    private val inputManager: Any by lazy {
        Class.forName("android.hardware.input.InputManagerGlobal").getMethod("getInstance").invoke(null)!!
    }
    private val injectMethod by lazy {
        inputManager.javaClass.getMethod("injectInputEvent", InputEvent::class.java, Int::class.java)
    }
    private val setDisplayId by lazy { InputEvent::class.java.getMethod("setDisplayId", Int::class.java) }

    @JvmStatic
    fun main(args: Array<String>) {
        Looper.prepareMainLooper()
        Workarounds.apply()
        val server = try {
            LocalServerSocket("nearside-probe")
        } catch (e: IOException) {
            println("probe already running"); return
        }
        println("listening")
        while (true) {
            val socket = server.accept()
            if (socket.peerCredentials.uid != 2000) { socket.close(); continue }
            Thread { serve(socket) }.start()
        }
    }

    private fun serve(socket: LocalSocket) {
        val input = DataInputStream(socket.inputStream.buffered())
        val output = DataOutputStream(socket.outputStream.buffered(256 * 1024))
        try {
            val type = input.readUnsignedByte()
            val hello = ByteArray(input.readInt()).also { input.readFully(it) }
            require(type == 1)
            val b = ByteBuffer.wrap(hello)
            when (b.get().toInt().toChar()) {
                'p' -> pings(input, output)
                't' -> bulk(output)
                'v' -> Session(b, input, output).run()
            }
        } catch (t: Throwable) {
            println("session ended: $t")
        } finally {
            runCatching { socket.close() }
        }
    }

    private fun pings(input: DataInputStream, output: DataOutputStream) {
        while (true) {
            val type = input.readUnsignedByte()
            val body = ByteArray(input.readInt()).also { input.readFully(it) }
            if (type != 11) continue
            synchronized(output) {
                output.writeByte(12); output.writeInt(16)
                output.write(body, 0, 8); output.writeLong(System.nanoTime() / 1000)
                output.flush()
            }
        }
    }

    private fun bulk(output: DataOutputStream) {
        val chunk = ByteArray(64 * 1024)
        while (true) {
            output.writeByte(20); output.writeInt(chunk.size); output.write(chunk)
        }
    }

    private class Session(hello: ByteBuffer, val input: DataInputStream, val output: DataOutputStream) {
        var w = hello.short.toInt() and 0xffff
        var h = hello.short.toInt() and 0xffff
        var dpi = hello.short.toInt() and 0xffff
        val fps = hello.get().toInt() and 0xff
        val kbps = hello.int
        val component = String(hello.array(), hello.position(), hello.remaining())
        @Volatile var gen = 0
        @Volatile var codec: MediaCodec? = null
        @Volatile var closed = false
        lateinit var display: VirtualDisplay
        var downTime = 0L

        fun run() {
            val first = newEncoder()
            display = displayManager.createVirtualDisplay("nearside-probe", w, h, dpi, first.second, FLAGS)
            val displayId = display.display.displayId
            println("session display=$displayId ${w}x$h@$dpi $component")
            Thread { encodeLoop() }.apply { name = "encoder-out" }.start()
            Runtime.getRuntime().exec(arrayOf("am", "start", "--display", "$displayId", "-n", component)).waitFor()
            try {
                controlLoop(displayId)
            } finally {
                closed = true
                display.release()
                codec?.let { runCatching { it.stop() }; it.release() }
                println("session closed")
            }
        }

        fun newEncoder(): Pair<MediaCodec, android.view.Surface> {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, w, h).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, kbps * 1000)
                setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setFloat(MediaFormat.KEY_I_FRAME_INTERVAL, 10f)
                setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000)
                setInteger(MediaFormat.KEY_PRIORITY, 0)
                setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
                setInteger(MediaFormat.KEY_PREPEND_HEADER_TO_SYNC_FRAMES, 1)
                setFloat("max-fps-to-encoder", fps.toFloat())
            }
            val c = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)
            c.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val surface = c.createInputSurface()
            c.start()
            gen++
            codec = c
            return c to surface
        }

        fun encodeLoop() {
            val info = MediaCodec.BufferInfo()
            var outUs = 0L
            while (!closed) {
                val c = codec ?: break
                val myGen = gen
                // A resize swaps the codec under us; the old one then throws, which is fine.
                val data = try {
                    val index = c.dequeueOutputBuffer(info, 50_000)
                    if (index < 0) continue
                    val buf = c.getOutputBuffer(index) ?: continue
                    outUs = System.nanoTime() / 1000
                    ByteArray(info.size).also { buf.get(it); c.releaseOutputBuffer(index, false) }
                } catch (e: IllegalStateException) {
                    continue
                }
                try {
                    synchronized(output) {
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                            output.writeByte(2); output.writeInt(8 + data.size)
                            output.writeShort(w); output.writeShort(h); output.writeInt(myGen)
                        } else {
                            output.writeByte(3); output.writeInt(21 + data.size)
                            output.writeInt(myGen); output.writeLong(info.presentationTimeUs)
                            output.writeLong(outUs)
                            output.writeByte(if (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0) 1 else 0)
                        }
                        output.write(data)
                        output.flush()
                    }
                } catch (e: IOException) {
                    closed = true
                }
            }
        }

        fun controlLoop(displayId: Int) {
            while (!closed) {
                val type = input.readUnsignedByte()
                val body = ByteBuffer.wrap(ByteArray(input.readInt()).also { input.readFully(it) })
                when (type) {
                    10 -> touch(displayId, body.get().toInt(), body.int, body.float, body.float)
                    11 -> synchronized(output) {
                        output.writeByte(12); output.writeInt(16)
                        output.writeLong(body.long); output.writeLong(System.nanoTime() / 1000)
                        output.flush()
                    }
                    13 -> resize(body.short.toInt() and 0xffff, body.short.toInt() and 0xffff, body.short.toInt() and 0xffff)
                }
            }
        }

        fun resize(nw: Int, nh: Int, ndpi: Int) {
            if (nw == w && nh == h && ndpi == dpi) return
            val old = codec
            w = nw; h = nh; dpi = ndpi
            val (_, surface) = newEncoder()
            display.resize(w, h, dpi)
            display.surface = surface
            old?.let { runCatching { it.stop() }; it.release() }
            println("resized ${w}x$h@$dpi gen=$gen")
        }

        fun touch(displayId: Int, action: Int, touchGen: Int, x: Float, y: Float) {
            if (touchGen != gen) return // meant for a frame size that's gone
            val now = SystemClock.uptimeMillis()
            if (action == MotionEvent.ACTION_DOWN) downTime = now
            val event = MotionEvent.obtain(downTime, now, action, x * w, y * h, 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            setDisplayId.invoke(event, displayId)
            injectMethod.invoke(inputManager, event, 0) // INJECT_INPUT_EVENT_MODE_ASYNC
            event.recycle()
        }
    }
}
