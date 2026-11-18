package dev.nearside

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** After a reboot (or an app update) bring everything back without the user. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        AdbWifi.ensureEnabled(context)
        SyncService.start(context)
    }
}
