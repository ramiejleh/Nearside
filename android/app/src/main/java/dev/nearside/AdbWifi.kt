package dev.nearside

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings

/**
 * Keeps wireless debugging on so the Mac (an already-trusted ADB host) can restart the helper
 * after a reboot or network change. Needs WRITE_SECURE_SETTINGS, granted once by the Mac.
 */
object AdbWifi {
    fun canWrite(context: Context) =
        context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED

    fun isEnabled(context: Context) =
        Settings.Global.getInt(context.contentResolver, "adb_wifi_enabled", 0) == 1

    fun ensureEnabled(context: Context) {
        if (!canWrite(context)) return
        val cr = context.contentResolver
        runCatching {
            // 0 = never revoke the Mac's authorization (default revokes after 7 days unused).
            Settings.Global.putLong(cr, "adb_allowed_connection_time", 0)
            if (!isEnabled(context)) Settings.Global.putInt(cr, "adb_wifi_enabled", 1)
        }.onFailure { android.util.Log.w("Nearside", "cannot enable wireless debugging", it) }
    }
}
