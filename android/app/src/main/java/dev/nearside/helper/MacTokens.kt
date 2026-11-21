// Which Macs may use the phone: each has its own secret token.
package dev.nearside.helper

import java.io.File
import java.security.MessageDigest

/**
 * Every Mac has its own random token. The Mac that starts the helper hands its token over in
 * the environment; any other paired Mac stores its token over adb in [DIR], a folder only the
 * shell user can read (apps can't), as `<id>` — the id being a hash of the token, so it says
 * nothing about it. A Mac names its id in its hello; we look the token up and run the usual
 * challenge with it.
 */
object MacTokens {
    private val DIR = File("/data/local/tmp/nearside-macs")

    /** "nearside-id:" + token, SHA-256, the first 16 hex digits (the Mac computes the same). */
    fun idOf(token: String): String =
        MessageDigest.getInstance("SHA-256").digest("nearside-id:$token".toByteArray())
            .joinToString("") { "%02x".format(it) }.take(16)

    /** The token of Mac [id] (the starter's, or one stored by another Mac); null if unknown. */
    fun token(id: String, starter: String): String? {
        if (id == idOf(starter)) return starter
        if (!id.matches(Regex("[0-9a-f]{16}"))) return null
        val stored = runCatching { File(DIR, id).readText().trim() }.getOrNull() ?: return null
        return stored.takeIf { it.matches(Regex("[0-9a-f]{64}")) && idOf(it) == id }
    }
}
