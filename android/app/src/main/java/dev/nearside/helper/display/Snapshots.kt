// Task snapshots (the pictures Recents shows), for the phone window's Recents on the Mac.
package dev.nearside.helper.display

import android.annotation.SuppressLint
import android.graphics.Bitmap
import dev.nearside.helper.Log
import java.io.ByteArrayOutputStream

@SuppressLint("PrivateApi")
object Snapshots {
    /** Card width on the Mac (points) × 2 for Retina. */
    private const val WIDTH = 360

    private val manager: Any by lazy {
        val atm = Class.forName("android.app.ActivityTaskManager").getMethod("getService").invoke(null)!!
        atm.javaClass.getMethod("getTaskSnapshotManager").invoke(atm)!!
    }

    /**
     * A task's last picture as a JPEG, [WIDTH] px wide; null if it has none. Android 17:
     * ITaskSnapshotManager.getTaskSnapshot(taskId, latestCaptureTime, resolution: 1 full, 2 low)
     * and TaskSnapshot.wrapToBitmap() (getHardwareBuffer() returns null now). The first copy out
     * of the hardware bitmap sets up rendering (~2.7 s); later ones are quick.
     */
    fun jpeg(taskId: Int, visible: Boolean): ByteArray? = runCatching {
        // A task's snapshot is stored when it goes to the background: the one showing gets a
        // fresh one (takeUserTaskSnapshot, ~40 ms), as the phone's own Recents does.
        val take = { manager.javaClass.methods.first { it.name == "takeUserTaskSnapshot" }.invoke(manager, taskId) }
        val get = {
            val m = manager.javaClass.methods.first { it.name == "getTaskSnapshot" }
            if (m.parameterCount == 3) m.invoke(manager, taskId, 0L, 2) else null
        }
        val snapshot = (if (visible) take() ?: get() else get() ?: take()) ?: return null
        try {
            val hardware = snapshot.javaClass.getMethod("wrapToBitmap").invoke(snapshot) as Bitmap? ?: return null
            val soft = hardware.copy(Bitmap.Config.ARGB_8888, false) ?: return null
            val scaled = Bitmap.createScaledBitmap(soft, WIDTH, WIDTH * soft.height / soft.width, true)
            ByteArrayOutputStream().also { scaled.compress(Bitmap.CompressFormat.JPEG, 78, it) }.toByteArray()
                .also { soft.recycle(); scaled.recycle() }
        } finally {
            runCatching { snapshot.javaClass.getMethod("closeBuffer").invoke(snapshot) }
        }
    }.onFailure { Log.d("snapshot of task $taskId failed: ${it.cause ?: it}") }.getOrNull()

    /** The first copy out of a hardware bitmap sets up rendering (~2.7 s): done ahead of time. */
    fun warmUp() = Thread({
        runCatching { Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888).copy(Bitmap.Config.HARDWARE, false)?.copy(Bitmap.Config.ARGB_8888, false) }
    }, "snapshots-warm-up").start()
}
