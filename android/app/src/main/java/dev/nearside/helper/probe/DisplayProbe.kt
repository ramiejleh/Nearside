// Gate A probe (throwaway). Creates a virtual display the way the real feature will, encodes it
// with the hardware HEVC encoder into /data/local/tmp/probe-<name>.h265 and reports stats.
// Apps are launched/moved/tapped from `adb shell` (am start --display, input -d, am display
// move-stack) while it runs. Display creation adapted from scrcpy (Apache-2.0, Genymobile):
// server/.../video/NewDisplayCapture.java, wrappers/DisplayManager.java.
//
//   CLASSPATH=<apk> app_process / dev.nearside.helper.probe.DisplayProbe \
//       <name> <w> <h> <dpi> <seconds> [app|cms|cmsfree] [fps]
package dev.nearside.helper.probe

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Looper
import dev.nearside.helper.FakeContext
import dev.nearside.helper.Workarounds
import java.io.FileOutputStream
import kotlin.system.exitProcess

@SuppressLint("PrivateApi", "WrongConstant")
object DisplayProbe {
    private const val PUBLIC = 1 shl 0
    private const val OWN_CONTENT_ONLY = 1 shl 3
    private const val SUPPORTS_TOUCH = 1 shl 6
    private const val SHOULD_SHOW_SYSTEM_DECORATIONS = 1 shl 9
    private const val TRUSTED = 1 shl 10
    private const val OWN_DISPLAY_GROUP = 1 shl 11
    private const val ALWAYS_UNLOCKED = 1 shl 12
    private const val TOUCH_FEEDBACK_DISABLED = 1 shl 13
    private const val OWN_FOCUS = 1 shl 14
    private const val ALLOWS_CONTENT_MODE_SWITCH = 1 shl 17

    @JvmStatic
    fun main(args: Array<String>) {
        Looper.prepareMainLooper()
        Workarounds.apply()
        val name = args.getOrElse(0) { "a" }
        val w = args.getOrElse(1) { "1080" }.toInt()
        val h = args.getOrElse(2) { "2400" }.toInt()
        val dpi = args.getOrElse(3) { "420" }.toInt()
        val seconds = args.getOrElse(4) { "30" }.toLong()
        val mode = args.getOrElse(5) { "app" }
        val fps = args.getOrElse(6) { "60" }.toInt()

        var flags = PUBLIC or SUPPORTS_TOUCH or TRUSTED or OWN_DISPLAY_GROUP or ALWAYS_UNLOCKED or
            TOUCH_FEEDBACK_DISABLED or OWN_FOCUS
        if (mode.startsWith("cms")) flags = flags or ALLOWS_CONTENT_MODE_SWITCH
        if (mode == "own") flags = flags or OWN_CONTENT_ONLY

        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, 12_000_000)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setFloat(MediaFormat.KEY_I_FRAME_INTERVAL, 10f)
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            setFloat("max-fps-to-encoder", fps.toFloat())
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)
        val caps = codec.codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_HEVC)
        println("encoder ${codec.name} maxInstances=${caps.maxSupportedInstances}")
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = codec.createInputSurface()
        codec.start()

        val ctor = DisplayManager::class.java.getDeclaredConstructor(Context::class.java)
        ctor.isAccessible = true
        val dm = ctor.newInstance(FakeContext.instance) as DisplayManager
        val display: VirtualDisplay = try {
            dm.createVirtualDisplay("nearside-$name", w, h, dpi, surface, flags)
        } catch (t: Throwable) {
            println("createVirtualDisplay failed: $t")
            exitProcess(2)
        }
        println("display ${display.display.displayId} ${w}x$h@$dpi flags=0x${flags.toString(16)} mode=$mode")

        val out = FileOutputStream("/data/local/tmp/probe-$name.h265")
        val info = MediaCodec.BufferInfo()
        val start = System.nanoTime()
        var frames = 0
        var bytes = 0L
        var keyframes = 0
        var lastReport = start
        if (args.getOrNull(7) == "bitrate") Thread {
            Thread.sleep(seconds * 500)
            codec.setParameters(android.os.Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, 2_000_000) })
            println("bitrate -> 2 Mbps")
        }.start()
        if (args.getOrNull(7) == "suspend") Thread {
            Thread.sleep(seconds * 333)
            codec.setParameters(android.os.Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_SUSPEND, 1) })
            println("suspended")
            Thread.sleep(seconds * 333)
            codec.setParameters(android.os.Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_SUSPEND, 0)
                putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            })
            println("resumed")
        }.start()
        while (System.nanoTime() - start < seconds * 1_000_000_000) {
            val index = codec.dequeueOutputBuffer(info, 100_000)
            if (index < 0) continue
            val buf = codec.getOutputBuffer(index)!!
            val chunk = ByteArray(info.size)
            buf.get(chunk)
            out.write(chunk)
            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                frames++
                bytes += info.size
                if (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0) keyframes++
            }
            codec.releaseOutputBuffer(index, false)
            val now = System.nanoTime()
            if (now - lastReport > 5_000_000_000) {
                val secs = (now - lastReport) / 1e9
                println("stats frames=$frames kbps=${(bytes * 8 / secs / 1000).toInt()} keyframes=$keyframes")
                frames = 0; bytes = 0; lastReport = now
            }
        }
        out.close()
        display.release()
        codec.stop()
        codec.release()
        println("done")
        exitProcess(0)
    }
}
