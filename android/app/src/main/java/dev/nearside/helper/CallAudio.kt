package dev.nearside.helper

import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaRecorder
import android.os.SystemClock
import android.telephony.TelephonyManager
import dev.nearside.helper.display.DisplayWire
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * A phone call's sound on the Mac, both ways, over a "call" stream on the display socket (same
 * single-use tickets and proofs as a window's streams):
 * - their voice: the call's downlink (VOICE_DOWNLINK, which the shell may record), as Opus in
 *   AUDIO packets, like a window's sound;
 * - your voice: MIC on asks the Mac for its microphone; its MIC_AUDIO plays into the call's
 *   uplink through the telephony output (what Pixel's Call Screen speaks through).
 * Meanwhile the phone's microphone is muted and its earpiece turned down; both come back when the
 * stream closes (the Mac moved the call to the phone, or went away) or the call ends.
 */
object CallAudio {
    private const val KBPS = 32
    private const val FRAME_MS = 20

    @Volatile var active = false
        private set
    @Volatile private var conn: DisplayWire.Conn? = null

    /** The Mac's call stream: takes over from any earlier one. */
    fun attach(c: DisplayWire.Conn) {
        synchronized(this) {
            conn?.close()
            conn = c
        }
        Thread({ run(c) }, "call-audio").start()
    }

    private fun inCall(): Boolean =
        @Suppress("DEPRECATION") runCatching { Calls.telephony!!.callState == TelephonyManager.CALL_STATE_OFFHOOK }.getOrDefault(false)

    private fun run(c: DisplayWire.Conn) {
        // Wait for the call to connect (the Mac may open this as it's placing or answering one).
        val deadline = SystemClock.uptimeMillis() + 30_000
        while (!inCall() && !c.isClosed && SystemClock.uptimeMillis() < deadline) Thread.sleep(200)
        if (!inCall() || c.isClosed) { Log.d("call audio: no call"); return c.close() }
        val audio = Calls.audio ?: return c.close()

        val rate = 48_000
        val record = runCatching {
            AudioRecord.Builder().setContext(FakeContext.instance).setAudioSource(MediaRecorder.AudioSource.VOICE_DOWNLINK)
                .setAudioFormat(AudioFormat.Builder().setSampleRate(rate).setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_IN_MONO).build())
                .setBufferSizeInBytes(rate / 5 * 2).build()
        }.onFailure { Log.d("call audio: no downlink: ${it.cause ?: it}") }.getOrNull() ?: return c.close()
        val tx = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull { it.type == AudioDeviceInfo.TYPE_TELEPHONY }
        val track = tx?.let { device ->
            runCatching {
                AudioTrack.Builder()
                    .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                    .setAudioFormat(AudioFormat.Builder().setSampleRate(48_000).setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                    .setTransferMode(AudioTrack.MODE_STREAM).build().also { it.setPreferredDevice(device) }
            }.getOrNull()
        }
        if (track == null) {
            // Without a way in, the Mac would hear the call but you'd still have to talk into the
            // phone: half a call. Refuse, and it stays on the phone.
            Log.d("call audio: no telephony output; staying on the phone")
            record.release()
            return c.close()
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS).apply {
            configure(MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, rate, 1).apply {
                setInteger(MediaFormat.KEY_BIT_RATE, KBPS * 1000)
            }, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            start()
        }

        val volume = runCatching { audio.getStreamVolume(AudioManager.STREAM_VOICE_CALL) }.getOrNull()
        active = true
        runCatching { audio.isMicrophoneMute = true }
        runCatching { audio.setStreamVolume(AudioManager.STREAM_VOICE_CALL, audio.getStreamMinVolume(AudioManager.STREAM_VOICE_CALL), 0) }
        record.startRecording()
        track.play()
        c.send(DisplayWire.AUDIO_CONFIG, ByteBuffer.allocate(5).putInt(rate).put(1).array())
        c.send(DisplayWire.MIC, byteArrayOf(1))
        Log.d("call audio: on the Mac (uplink routed to ${track.routedDevice?.type})")

        val down = Thread({ downlink(c, record, codec, rate) }, "call-downlink").apply { start() }
        try {
            while (!c.isClosed) {
                val (type, body) = c.read(64 * 1024) ?: break
                when (type) {
                    DisplayWire.MIC_AUDIO -> if (body.size % 2 == 0) track.write(body, 0, body.size)
                    DisplayWire.MIC_UNAVAILABLE -> { Log.d("call audio: the Mac has no microphone; back to the phone"); break }
                }
            }
        } finally {
            c.close()
            down.join(1000)
            runCatching { record.stop() }; record.release()
            runCatching { track.stop() }; track.release()
            runCatching { codec.stop() }; codec.release()
            active = false
            runCatching { audio.isMicrophoneMute = Calls.mutedByMac }
            volume?.let { v -> runCatching { audio.setStreamVolume(AudioManager.STREAM_VOICE_CALL, v, 0) } }
            Log.d("call audio: back on the phone")
        }
    }

    /** Their voice, to the Mac, until the stream closes or the call ends. */
    private fun downlink(c: DisplayWire.Conn, record: AudioRecord, codec: MediaCodec, rate: Int) {
        val frame = ShortArray(rate * FRAME_MS / 1000)
        val info = MediaCodec.BufferInfo()
        var checked = SystemClock.uptimeMillis()
        try {
            while (!c.isClosed) {
                val n = record.read(frame, 0, frame.size)
                if (n <= 0) { Thread.sleep(FRAME_MS.toLong()); continue }
                val now = SystemClock.uptimeMillis()
                if (now - checked > 1000) {
                    checked = now
                    if (!inCall()) { Log.d("call audio: the call ended"); c.close(); break }
                }
                val index = codec.dequeueInputBuffer(10_000)
                if (index >= 0) {
                    val input = codec.getInputBuffer(index)!!
                    input.clear()
                    input.order(ByteOrder.nativeOrder()).asShortBuffer().put(frame, 0, n)
                    codec.queueInputBuffer(index, 0, n * 2, now * 1000, 0)
                }
                while (true) {
                    val out = codec.dequeueOutputBuffer(info, 0)
                    if (out < 0) break
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                        val buf = codec.getOutputBuffer(out)!!
                        val packet = ByteBuffer.allocate(8 + info.size).putLong(info.presentationTimeUs)
                        buf.position(info.offset).limit(info.offset + info.size)
                        packet.put(buf)
                        c.send(DisplayWire.AUDIO, packet.array())
                    }
                    codec.releaseOutputBuffer(out, false)
                }
            }
        } catch (e: Exception) {
            if (!c.isClosed) Log.d("call audio: downlink ended ($e)")
            c.close()
        }
    }
}
