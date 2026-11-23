// A window's sound, for the Mac: what apps on its display play, captured by the virtual device
// (VirtualAudioDevice: those apps play into it instead of the phone's speaker, so the phone stays
// silent) and sent as Opus on the session's audio stream.
//
// And the other way, the Mac's microphone: what those apps record comes from the device's
// injection instead of the phone's microphone. When one starts recording (a call, a voice note)
// we send MIC on, the Mac opens its microphone and sends MIC_AUDIO back until MIC off; a Mac that
// can't (no permission) sends MIC_UNAVAILABLE, and the apps record from the phone again.
package dev.nearside.helper.display

import android.annotation.SuppressLint
import android.hardware.display.VirtualDisplay
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.SystemClock
import dev.nearside.helper.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors

@SuppressLint("PrivateApi", "WrongConstant")
class AudioStreamer(private val name: String) {
    companion object {
        const val RATE = 48_000
        const val KBPS = 128
        /** 20 ms: Opus's usual frame. */
        const val FRAME_MS = 20
        const val SILENCE_AFTER_MS = 300L
        /** The Mac's microphone: 48 kHz mono 16-bit PCM. */
        const val MIC_RATE = 48_000
    }

    private var device: Any? = null
    private var capture: Any? = null
    private var codec: MediaCodec? = null
    @Volatile private var injection: Any? = null
    private val injectionWrite by lazy {
        injection?.javaClass?.methods?.firstOrNull {
            it.name == "write" && it.parameterCount == 3 && it.parameterTypes[0] == ByteArray::class.java
        }
    }
    /** An app on the display is recording (main thread of [executor]). */
    @Volatile private var recording = false
    private var channels = 2
    @Volatile private var conn: DisplayWire.Conn? = null
    /** When something on the display last made a sound (uptime ms). */
    @Volatile var lastSoundAt = 0L
    /** Not sending: silent for [SILENCE_AFTER_MS] (see the loop). */
    private var quiet = false
    private var emptyReads = 0
        private set
    @Volatile private var stopped = false
    /** null until [start] has run; then whether sound is captured. */
    @Volatile private var capturing: Boolean? = null
    private val executor = Executors.newSingleThreadExecutor { Thread(it, "$name-audio-device") }

    private fun call(o: Any, name: String, vararg a: Any?): Any? =
        o.javaClass.methods.first { it.name == name && it.parameterCount == a.size }.invoke(o, *a)

    /** Starts capturing [display]'s sound; false if the virtual device can't (then it plays on the phone). */
    fun start(phone: PhoneDevice, display: VirtualDisplay): Boolean = startCapture(phone, display).also { ok ->
        synchronized(this) {
            capturing = ok
            conn?.let { if (ok) sendConfig(it) else it.close() } // the Mac's stream may be here already
        }
    }

    private fun startCapture(phone: PhoneDevice, display: VirtualDisplay): Boolean = runCatching {
        val d = phone.createAudioDevice(display, executor, recordingCallback()) ?: return false
        device = d
        // Stereo if the device takes it, else mono.
        val cap = listOf(AudioFormat.CHANNEL_IN_STEREO to 2, AudioFormat.CHANNEL_IN_MONO to 1).firstNotNullOfOrNull { (mask, n) ->
            runCatching {
                val format = AudioFormat.Builder().setSampleRate(RATE).setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(mask).build()
                call(d, "startAudioCapture", format)!!.also { channels = n }
            }.onFailure { Log.d("$name: capture at $n ch failed: ${it.cause ?: it}") }.getOrNull()
        } ?: error("no capture format")
        capture = cap
        call(cap, "startRecording")
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, RATE, channels).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, KBPS * 1000)
        }
        codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS).apply {
            configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            start()
        }
        Thread(::loop, "$name-audio").start()
        Log.d("$name: audio capture started (${channels} ch, Opus $KBPS kbps)")
        startInjection(d)
        true
    }.onFailure {
        Log.d("$name: no audio capture (${it.cause ?: it}); sound stays on the phone")
        stop()
    }.getOrDefault(false)

    /**
     * The Mac's audio stream (again after a reconnect). It can arrive before [start] has run:
     * then it waits, and is closed if there's no capture (the sound stays on the phone).
     */
    @Synchronized
    fun attach(c: DisplayWire.Conn) {
        conn?.close()
        conn = c
        when (capturing) {
            true -> sendConfig(c)
            false -> c.close()
            null -> {}
        }
    }

    private fun sendConfig(c: DisplayWire.Conn) {
        c.send(DisplayWire.AUDIO_CONFIG, ByteBuffer.allocate(5).putInt(RATE).put(channels.toByte()).array())
        if (injection != null) {
            c.send(DisplayWire.MIC, byteArrayOf(if (recording) 1 else 0))
            Thread({ readMic(c) }, "$name-mic").start()
        }
    }

    // MARK: The Mac's microphone

    /** Before any app records: a recording that has started keeps the source it started with. */
    private fun startInjection(d: Any) {
        injection = runCatching {
            val format = AudioFormat.Builder().setSampleRate(MIC_RATE).setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build()
            call(d, "startAudioInjection", format)!!.also { call(it, "play") }
        }.onSuccess { Log.d("$name: microphone injection ready") }
            .onFailure { Log.d("$name: no microphone injection (${it.cause ?: it}); apps here record from the phone") }
            .getOrNull()
    }

    /** Tells the Mac when apps on the display start and stop recording. */
    private fun recordingCallback(): Any? = runCatching {
        val type = Class.forName("android.companion.virtual.audio.VirtualAudioDevice\$AudioConfigurationChangeCallback")
        java.lang.reflect.Proxy.newProxyInstance(type.classLoader, arrayOf(type)) { proxy, method, args ->
            when (method.name) {
                "onRecordingConfigChanged" -> {
                    val now = (args?.getOrNull(0) as? List<*>)?.isNotEmpty() == true
                    if (now != recording) {
                        recording = now
                        Log.d("$name: an app here ${if (now) "started" else "stopped"} recording")
                        if (injection != null) conn?.send(DisplayWire.MIC, byteArrayOf(if (now) 1 else 0))
                    }
                    null
                }
                "hashCode" -> System.identityHashCode(proxy)
                "equals" -> proxy === args?.getOrNull(0)
                "toString" -> "AudioConfigurationChangeCallback"
                else -> null
            }
        }
    }.onFailure { Log.d("$name: no recording callback: ${it.cause ?: it}") }.getOrNull()

    /** The Mac's microphone, from its stream, into what the display's apps record. */
    private fun readMic(c: DisplayWire.Conn) {
        var frames = 0L
        while (!stopped && !c.isClosed) {
            val (type, body) = c.read(64 * 1024) ?: break
            when (type) {
                DisplayWire.MIC_AUDIO -> {
                    val inj = injection ?: continue
                    if (body.size % 2 != 0) continue
                    runCatching { injectionWrite?.invoke(inj, body, 0, body.size) }
                    if (frames++ == 0L) Log.d("$name: the Mac's microphone is coming in")
                }
                DisplayWire.MIC_UNAVAILABLE -> {
                    Log.d("$name: the Mac has no microphone for us; apps here record from the phone")
                    stopInjection()
                }
            }
        }
    }

    @Synchronized
    private fun stopInjection() {
        injection?.let { i -> runCatching { call(i, "close") } }
        injection = null
    }

    private fun loop() {
        val cap = capture ?: return
        val codec = codec ?: return
        val read = cap.javaClass.methods.first {
            it.name == "read" && it.parameterCount == 3 && it.parameterTypes[0] == ShortArray::class.java
        }
        val frame = ShortArray(RATE * FRAME_MS / 1000 * channels)
        val info = MediaCodec.BufferInfo()
        try {
            while (!stopped) {
                // Blocks until a frame's worth is there: the capture paces the loop.
                val n = read.invoke(cap, frame, 0, frame.size) as Int
                if (n < 0) break
                // Nothing (the display is asleep: its audio device stops): don't spin, wait a frame.
                if (n == 0) { Thread.sleep(if (++emptyReads > 10) 100L else FRAME_MS.toLong()); continue }
                emptyReads = 0
                val now = SystemClock.uptimeMillis()
                for (i in 0 until n) if (frame[i] > 64 || frame[i] < -64) { lastSoundAt = now; break }
                val pts = now * 1000 - FRAME_MS * 1000L
                // Silence isn't sent: after a moment of it (the sound's tail goes out first), one
                // empty packet tells the Mac to let its buffer run dry, then nothing until there's
                // sound again (otherwise 50 packets a second keep the phone's Wi-Fi awake for nothing).
                if (now - lastSoundAt > SILENCE_AFTER_MS) {
                    if (!quiet) {
                        quiet = true
                        if (capturing == true) conn?.takeIf { !it.isClosed }?.send(DisplayWire.AUDIO, ByteBuffer.allocate(8).putLong(pts).array())
                    }
                    continue
                }
                quiet = false
                val index = codec.dequeueInputBuffer(10_000)
                if (index >= 0) {
                    val input = codec.getInputBuffer(index)!!
                    input.clear()
                    input.order(ByteOrder.nativeOrder()).asShortBuffer().put(frame, 0, n)
                    codec.queueInputBuffer(index, 0, n * 2, pts, 0)
                }
                while (true) {
                    val out = codec.dequeueOutputBuffer(info, 0)
                    if (out < 0) break
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                        val buf = codec.getOutputBuffer(out)!!
                        val packet = ByteBuffer.allocate(8 + info.size).putLong(info.presentationTimeUs)
                        buf.position(info.offset).limit(info.offset + info.size)
                        packet.put(buf)
                        if (capturing == true) conn?.takeIf { !it.isClosed }?.send(DisplayWire.AUDIO, packet.array())
                    }
                    codec.releaseOutputBuffer(out, false)
                }
            }
        } catch (e: Exception) {
            if (!stopped) Log.d("$name: audio ended ($e)")
        }
    }

    @Synchronized
    fun stop() {
        stopped = true
        capturing = false
        stopInjection()
        capture?.let { c -> runCatching { call(c, "stop") } }
        device?.let { d -> runCatching { call(d, "close") } }
        codec?.let { runCatching { it.stop() }; it.release() }
        capture = null; device = null; codec = null
        conn?.close()
        executor.shutdown()
    }
}
