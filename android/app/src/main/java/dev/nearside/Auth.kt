package dev.nearside

import android.content.Context
import java.security.MessageDigest

/**
 * PoC-grade authentication: a random secret owned by the Mac. The Mac passes it to the helper
 * (env var, over trusted ADB); the helper hands it to us over its uid-checked socket, so no
 * other app on the phone can plant or read it. The Mac must send it as its first message.
 * The traffic is still plaintext, so this stops drive-by LAN clients, not eavesdroppers.
 * The real app replaces this with TLS and pinned keys.
 */
object Auth {
    private const val PREFS = "auth"
    private const val KEY = "token"

    fun store(context: Context, token: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, token).apply()
    }

    fun isValid(context: Context, candidate: String): Boolean {
        val token = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null) ?: return false
        if (token.length < 32) return false
        return MessageDigest.isEqual(token.toByteArray(), candidate.toByteArray())
    }
}
