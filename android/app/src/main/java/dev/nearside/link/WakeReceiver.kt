package dev.nearside.link

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Does nothing on purpose. Android 17 freezes this app even while it's a bound notification
 * listener, and binder calls from the helper then just queue up. Broadcasts always thaw the
 * receiver, so the helper sends this after each message and the queued calls run.
 * Guarded by INTERACT_ACROSS_USERS_FULL (shell has it, third-party apps can't).
 */
class WakeReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION = "dev.nearside.WAKE"
    }

    override fun onReceive(context: Context, intent: Intent) = Unit
}
