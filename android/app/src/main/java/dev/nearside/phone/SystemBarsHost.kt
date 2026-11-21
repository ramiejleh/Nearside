package dev.nearside.phone

import android.annotation.SuppressLint
import android.app.Instrumentation
import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.hardware.display.DisplayManager
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.util.Log
import android.view.View
import android.view.WindowManager
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Gives the helper's virtual displays the phone's system bars: an invisible window per display
 * that provides a status-bar inset at the top and a gesture-bar inset at the bottom, the phone's
 * own sizes. Apps then lay out exactly as on the phone (YouTube otherwise drew its status-bar
 * strip over its content, and its bottom bar against the edge); the Mac hides the status-bar area.
 *
 * Only a process the activity manager knows may add windows on Android 17, and providing insets
 * needs the shell's STATUS_BAR_SERVICE: so this runs in the app's process as an instrumentation
 * started by the helper (`am instrument --no-restart --no-hidden-api-checks`: it joins the running
 * app without restarting it), borrowing two of the shell's permissions while it adds a window.
 * Shell and apps can't reach each other's sockets (SELinux), so the helper gets [binder] from
 * [SystemBarsProvider] and calls it (shell uid only). It ends when the helper goes, or when the
 * helper says it's no longer needed (FINISH).
 */
@SuppressLint("PrivateApi", "WrongConstant")
class SystemBarsHost : Instrumentation() {
    companion object {
        private const val TAG = "NearsideBars"
        const val SHELL_UID = 2000
        const val ADD = 1   // i32 display, the window's LayoutParams (parcelled) → i32 0 ok / 1 failed, string reason
        const val REMOVE = 2 // i32 display
        const val FINISH = 3 // no longer needed: end (the helper starts it again when it is)

        /** Set while the host runs (this process is the instrumented one). */
        @Volatile var binder: IBinder? = null
        /** The running host (this process is the instrumented one), else null. */
        @Volatile var instance: SystemBarsHost? = null
    }

    private val main by lazy { Handler(Looper.getMainLooper()) }
    private val windows = HashMap<Int, View>() // main thread only
    private val done = CountDownLatch(1)
    /** The helper's token: when it dies, so does the host. */
    @Volatile private var helper: IBinder? = null

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        context.getSystemService(DisplayManager::class.java).registerDisplayListener(object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) {}
            override fun onDisplayChanged(displayId: Int) {}
            override fun onDisplayRemoved(displayId: Int) { windows.remove(displayId) } // gone with it
        }, main)
        binder = object : Binder() {
            override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
                if (Binder.getCallingUid() != SHELL_UID) return false
                val result = runCatching {
                    when (code) {
                        ADD -> {
                            val d = data.readInt()
                            val params = WindowManager.LayoutParams.CREATOR.createFromParcel(data)
                            onMain { add(d, params) }
                        }
                        REMOVE -> { val d = data.readInt(); onMain { remove(d) } }
                        FINISH -> done.countDown()
                        else -> return super.onTransact(code, data, reply, flags)
                    }
                }
                reply?.writeInt(if (result.isSuccess) 0 else 1)
                reply?.writeString(result.exceptionOrNull()?.let { "${it.cause ?: it}" })
                return true
            }
        }
        instance = this
        Log.i(TAG, "ready")
        done.await() // until the helper goes
        instance = null
        binder = null
        onMain { windows.keys.toList().forEach(::remove) }
        finish(0, Bundle())
    }

    /** The helper said hello (through the provider): end with it. */
    fun watch(token: IBinder) {
        helper = token
        runCatching { token.linkToDeath({ if (helper === token) done.countDown() }, 0) }.onFailure { done.countDown() }
    }

    private fun onMain(block: () -> Unit) {
        var failure: Throwable? = null
        val finished = CountDownLatch(1)
        main.post { try { block() } catch (t: Throwable) { failure = t } finally { finished.countDown() } }
        if (!finished.await(3, TimeUnit.SECONDS)) error("timed out")
        failure?.let { throw it }
    }

    /** Only the two shell permissions a bar window needs, and only while adding it. */
    private fun add(displayId: Int, params: WindowManager.LayoutParams) {
        remove(displayId)
        uiAutomation.adoptShellPermissionIdentity("android.permission.INTERNAL_SYSTEM_WINDOW", "android.permission.STATUS_BAR_SERVICE")
        try { addWindow(displayId, params) } finally { uiAutomation.dropShellPermissionIdentity() }
    }

    /** [params] come from the helper, insets and all (hidden API, which only it may use). */
    private fun addWindow(displayId: Int, params: WindowManager.LayoutParams) {
        val display = context.getSystemService(DisplayManager::class.java).getDisplay(displayId) ?: error("no display $displayId")
        val window = context.createDisplayContext(display).createWindowContext(params.type, null)
        val view = View(window)
        window.getSystemService(WindowManager::class.java).addView(view, params)
        windows[displayId] = view
    }

    private fun remove(displayId: Int) {
        val view = windows.remove(displayId) ?: return
        runCatching { view.context.getSystemService(WindowManager::class.java).removeViewImmediate(view) }
    }
}

/**
 * Hands the helper the [SystemBarsHost]'s Binder (in the host's process; nothing if this process
 * isn't the instrumented one), and takes the helper's token. Only the shell uid may call.
 */
class SystemBarsProvider : ContentProvider() {
    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        if (Binder.getCallingUid() != SystemBarsHost.SHELL_UID) throw SecurityException("shell only")
        if (method != "host") return null
        val host = SystemBarsHost.binder ?: return Bundle()
        extras?.getBinder("helper")?.let { SystemBarsHost.instance?.watch(it) }
        return Bundle().apply { putBinder("host", host) }
    }

    override fun onCreate() = true
    override fun query(uri: Uri, p: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<out String>?) = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<out String>?) = 0
}
