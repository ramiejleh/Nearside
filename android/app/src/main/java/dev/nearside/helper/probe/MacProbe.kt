// Probe (throwaway): a second Mac, for testing phone takeover. Stores its own token the way a
// Mac does (MacTokens), connects to the helper as "Test Mac" and prints what it gets.
//
//   CLASSPATH=<apk> app_process / dev.nearside.helper.probe.MacProbe [passive] [seconds]
package dev.nearside.helper.probe

import android.net.LocalSocket
import android.net.LocalSocketAddress
import dev.nearside.helper.MacTokens
import org.json.JSONObject
import java.io.File
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

object MacProbe {
    private fun hmac(key: String, msg: String) = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key.toByteArray(), "HmacSHA256")) }
        .doFinal(msg.toByteArray()).joinToString("") { "%02x".format(it) }

    private fun hex() = ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }

    @JvmStatic
    fun main(args: Array<String>) {
        val passive = args.getOrNull(0) == "passive"
        val seconds = args.getOrNull(1)?.toLongOrNull() ?: 30
        val token = hex()
        val id = MacTokens.idOf(token)
        val dir = File("/data/local/tmp/nearside-macs").apply { mkdirs() }
        File(dir, id).writeText(token)
        val socket = LocalSocket().apply { connect(LocalSocketAddress("nearside-helper")) }
        val out = socket.outputStream
        val input = socket.inputStream.bufferedReader()
        val nonce = hex()
        out.write("${JSONObject().put("t", "hello-mac").put("nonce", nonce).put("id", id).put("name", "Test Mac").put("passive", passive)}\n".toByteArray())
        val challenge = JSONObject(input.readLine() ?: return println("closed before the challenge"))
        println("helper proof ok: ${challenge.optString("proof") == hmac(token, "nearside-helper:$nonce")}")
        out.write("${JSONObject().put("t", "auth").put("proof", hmac(token, "nearside-mac:${challenge.optString("nonce")}"))}\n".toByteArray())
        val end = System.currentTimeMillis() + seconds * 1000
        Thread { Thread.sleep(seconds * 1000); runCatching { socket.shutdownInput(); socket.close() } }.start()
        while (System.currentTimeMillis() < end) {
            val line = runCatching { input.readLine() }.getOrNull() ?: break
            println("got: ${line.take(120)}")
        }
        File(dir, id).delete()
        println("done")
    }
}
