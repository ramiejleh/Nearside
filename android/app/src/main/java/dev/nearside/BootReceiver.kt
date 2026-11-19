package dev.nearside

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * After a reboot, try to make sure wireless debugging is on so the Mac can restart the helper.
 * Android 17 restores it by itself and denies this write (MANAGE_DEBUGGING); the attempt is
 * kept for older versions, where WRITE_SECURE_SETTINGS is enough. No service, no notification:
 * the helper runs independently of the app.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // Both are protected broadcasts only the system can send; ignore anything else.
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        AdbWifi.ensureEnabled(context)
    }
}
