// Gate A probe (throwaway): captures one app's audio (by uid) with an AudioPolicy loop-back mix,
// so the phone stays silent, and reports the level. Adapted from scrcpy (Apache-2.0, Genymobile):
// server/.../audio/AudioPlaybackCapture.java.
//   app_process / dev.nearside.helper.probe.AudioProbe <uid> <seconds> [render]
package dev.nearside.helper.probe

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.os.Looper
import dev.nearside.helper.FakeContext
import dev.nearside.helper.Workarounds
import java.io.FileOutputStream
import kotlin.math.sqrt
import kotlin.system.exitProcess

@SuppressLint("PrivateApi", "MissingPermission")
object AudioProbe {
    @JvmStatic
    fun main(args: Array<String>) {
        Looper.prepareMainLooper()
        Workarounds.apply()
        val uid = args[0].toInt()
        val seconds = args.getOrElse(1) { "10" }.toLong()
        val routeFlags = if (args.getOrNull(2) == "render") 3 else 2 // LOOP_BACK_RENDER : LOOP_BACK

        val format = AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_IN_STEREO).build()

        val ruleBuilderClass = Class.forName("android.media.audiopolicy.AudioMixingRule\$Builder")
        val ruleBuilder = ruleBuilderClass.getConstructor().newInstance()
        ruleBuilderClass.getMethod("setTargetMixRole", Int::class.java).invoke(ruleBuilder, 0) // MIX_ROLE_PLAYERS
        ruleBuilderClass.getMethod("addMixRule", Int::class.java, Any::class.java).invoke(ruleBuilder, 4, uid) // RULE_MATCH_UID
        val rule = ruleBuilderClass.getMethod("build").invoke(ruleBuilder)

        val mixBuilderClass = Class.forName("android.media.audiopolicy.AudioMix\$Builder")
        val mixBuilder = mixBuilderClass.getConstructor(rule.javaClass).newInstance(rule)
        mixBuilderClass.getMethod("setFormat", AudioFormat::class.java).invoke(mixBuilder, format)
        mixBuilderClass.getMethod("setRouteFlags", Int::class.java).invoke(mixBuilder, routeFlags)
        val mix = mixBuilderClass.getMethod("build").invoke(mixBuilder)

        val policyBuilderClass = Class.forName("android.media.audiopolicy.AudioPolicy\$Builder")
        val policyBuilder = policyBuilderClass.getConstructor(Context::class.java).newInstance(FakeContext.instance)
        policyBuilderClass.getMethod("addMix", mix.javaClass).invoke(policyBuilder, mix)
        val policy = policyBuilderClass.getMethod("build").invoke(policyBuilder)

        val policyClass = Class.forName("android.media.audiopolicy.AudioPolicy")
        val register = Class.forName("android.media.AudioManager").getDeclaredMethod("registerAudioPolicyStatic", policyClass)
        register.isAccessible = true
        val result = register.invoke(null, policy) as Int
        println("registerAudioPolicyStatic=$result route=$routeFlags uid=$uid")
        if (result != 0) exitProcess(2)
        val record = policyClass.getMethod("createAudioRecordSink", mix.javaClass).invoke(policy, mix) as AudioRecord
        record.startRecording()
        println("recording state=${record.recordingState}")

        val out = FileOutputStream("/data/local/tmp/probe-audio.pcm")
        val buf = ShortArray(4800) // 50 ms stereo
        val bytes = ByteArray(buf.size * 2)
        val end = System.nanoTime() + seconds * 1_000_000_000
        var windowSq = 0.0
        var windowN = 0
        var lastReport = System.nanoTime()
        while (System.nanoTime() < end) {
            val n = record.read(buf, 0, buf.size)
            if (n <= 0) continue
            for (i in 0 until n) {
                windowSq += buf[i].toDouble() * buf[i]
                bytes[2 * i] = (buf[i].toInt() and 0xff).toByte()
                bytes[2 * i + 1] = (buf[i].toInt() shr 8).toByte()
            }
            windowN += n
            out.write(bytes, 0, n * 2)
            if (System.nanoTime() - lastReport > 1_000_000_000) {
                println("rms=${sqrt(windowSq / windowN).toInt()}")
                windowSq = 0.0; windowN = 0; lastReport = System.nanoTime()
            }
        }
        record.stop()
        out.close()
        policyClass.getMethod("setRegistration", String::class.java).runCatching { }
        Class.forName("android.media.AudioManager").getDeclaredMethod("unregisterAudioPolicyAsyncStatic", policyClass)
            .runCatching { isAccessible = true; invoke(null, policy) }
        println("done")
        exitProcess(0)
    }
}
