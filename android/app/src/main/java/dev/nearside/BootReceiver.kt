package dev.nearside

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** After a reboot (or an app update) bring everything back without the user. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // Both are protected broadcasts only the system can send; ignore anything else.
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        AdbWifi.ensureEnabled(context)
        SyncService.start(context)
    }
}
