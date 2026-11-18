package dev.nearside

import android.content.Context
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * PoC-grade authentication: a random secret owned by the Mac. The Mac passes it to the helper
 * (env var, over trusted ADB); the helper hands it to us over its uid-checked socket, so no
 * other app on the phone can plant or read it. The Mac proves it knows the token by answering
 * a random challenge, so the token never crosses the network.
 * Still plaintext: an active man-in-the-middle can relay the handshake and read clips.
 * The real app replaces this with TLS and pinned keys.
 */
object Auth {
    private const val PREFS = "auth"
    private const val KEY = "token"

    fun store(context: Context, token: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, token).apply()
    }

    /** A fresh random challenge; the Mac must answer with [expectedResponse] for it. */
    fun newNonce(): String {
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        return bytes.joinToString("") { "%02x".format(it) }
    }

    /** Checks the Mac's proof: HMAC-SHA256(token, "nearside-mac:" + nonce), hex. */
    fun verifyMac(context: Context, nonce: String, response: String): Boolean {
        val expected = hmac(context, "nearside-mac:$nonce") ?: return false
        return MessageDigest.isEqual(expected.toByteArray(), response.toByteArray())
    }

    /** Our proof for the Mac's nonce. A distinct label stops a reflected Mac proof being reused. */
    fun phoneProof(context: Context, macNonce: String): String? = hmac(context, "nearside-phone:$macNonce")

    private fun hmac(context: Context, message: String): String? {
        val token = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null) ?: return null
        if (token.length < 32) return null
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(token.toByteArray(), "HmacSHA256")) }
        return mac.doFinal(message.toByteArray()).joinToString("") { "%02x".format(it) }
    }
}
