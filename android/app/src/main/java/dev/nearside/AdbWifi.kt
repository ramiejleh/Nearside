package dev.nearside

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings

/** Last noteworthy event, shown by [MainActivity]. */
object Status {
    @Volatile var lastEvent = "—"
}

/**
 * Keeps wireless debugging on so the Mac (an already-trusted ADB host) can restart the helper
 * after a reboot or network change. Needs WRITE_SECURE_SETTINGS, granted once by the Mac.
 */
object AdbWifi {
    fun canWrite(context: Context) =
        context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED

    fun isEnabled(context: Context) =
        Settings.Global.getInt(context.contentResolver, "adb_wifi_enabled", 0) == 1

    // The default 7-day authorization expiry is kept on purpose; the Mac renews it by
    // reconnecting over ADB periodically (see `run` in the Mac CLI).
    fun ensureEnabled(context: Context) {
        if (!canWrite(context) || isEnabled(context)) return
        // Android 17 additionally requires MANAGE_DEBUGGING here, which apps can't be granted.
        runCatching { Settings.Global.putInt(context.contentResolver, "adb_wifi_enabled", 1) }
            .onSuccess { Status.lastEvent = "re-enabled wireless debugging" }
            .onFailure {
                Status.lastEvent = "can't re-enable wireless debugging: ${it.message}"
                android.util.Log.w("Nearside", "cannot enable wireless debugging: ${it.message}")
            }
    }
}
