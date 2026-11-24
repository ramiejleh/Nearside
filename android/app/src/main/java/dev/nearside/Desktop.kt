package dev.nearside

import android.content.Context

/**
 * What the phone calls the computer it works with: "Mac" or "PC" (the last one that connected,
 * remembered), or "computer" before any has. The helper says which on each connection.
 */
object Desktop {
    private const val PREFS = "desktop"
    @Volatile private var kind: String? = null

    /** "Mac", "PC" or "computer", for "your …" in the phone's text. */
    fun name(context: Context): String {
        val k = kind ?: context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString("kind", "").orEmpty().also { kind = it }
        return when (k) { "mac" -> "Mac"; "pc" -> "PC"; else -> "computer" }
    }

    fun set(context: Context, value: String) {
        if (value != "mac" && value != "pc" || value == kind) return
        kind = value
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("kind", value).apply()
    }
}
