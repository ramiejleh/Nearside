// Task events from the window manager (a task stack listener), for what polling can't see.
package dev.nearside.helper.display

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.os.Binder
import android.os.Parcel
import dev.nearside.helper.Log
import java.lang.reflect.Proxy

/**
 * Tells us when something tries to start an app whose task is already running ("restart
 * attempt"): tapping an app's icon on the phone while it's in a Mac window brings its task to
 * the front *where it is* (our display) — the window just flickers, and nothing comes to the phone.
 *
 * ITaskStackListener is hidden, so it can't be subclassed here: the listener is a plain Binder
 * that decodes the one call it wants, using the transaction code from Android's own generated
 * Stub, behind a Proxy that hands the window manager that Binder.
 */
@SuppressLint("PrivateApi", "DiscouragedPrivateApi")
object TaskEvents {
    private const val DESCRIPTOR = "android.app.ITaskStackListener"

    /** Called with the task's id, off the main thread. */
    @Volatile var onRestartAttempt: ((taskId: Int) -> Unit)? = null

    private val restartCode by lazy {
        Class.forName("$DESCRIPTOR\$Stub").getDeclaredField("TRANSACTION_onActivityRestartAttempt")
            .apply { isAccessible = true }.getInt(null)
    }

    private val binder = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code == INTERFACE_TRANSACTION) { reply?.writeString(DESCRIPTOR); return true }
            if (code != restartCode) return true // the many other events: not ours
            runCatching {
                data.enforceInterface(DESCRIPTOR)
                // onActivityRestartAttempt(in RunningTaskInfo task, boolean homeTaskVisible, …)
                val task = if (data.readInt() != 0) ActivityManager.RunningTaskInfo.CREATOR.createFromParcel(data) else null
                task?.let { onRestartAttempt?.invoke(it.taskId) }
            }.onFailure { Log.d("task event unreadable: $it") }
            return true
        }
    }

    private var listener: Any? = null

    /**
     * Listens while phone-app windows are open (`on`), not otherwise: the window manager calls
     * every listener on each task change on the phone, which would wake us for nothing.
     */
    @Synchronized
    fun listen(on: Boolean) = runCatching {
        if (on == (listener != null)) return@runCatching
        val listenerClass = Class.forName(DESCRIPTOR)
        val atm = Class.forName("android.app.ActivityTaskManager").getMethod("getService").invoke(null)!!
        if (on) {
            val proxy = Proxy.newProxyInstance(listenerClass.classLoader, arrayOf(listenerClass)) { _, method, _ ->
                if (method.name == "asBinder") binder else null
            }
            atm.javaClass.getMethod("registerTaskStackListener", listenerClass).invoke(atm, proxy)
            listener = proxy
            Log.d("task events: listening (restart code $restartCode)")
        } else {
            atm.javaClass.getMethod("unregisterTaskStackListener", listenerClass).invoke(atm, listener)
            listener = null
            Log.d("task events: stopped")
        }
    }.onFailure { Log.d("task events unavailable: ${it.cause ?: it}") }
}
