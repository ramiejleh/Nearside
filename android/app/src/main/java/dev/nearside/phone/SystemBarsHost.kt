package dev.nearside.phone

import android.annotation.SuppressLint
import android.app.Instrumentation
import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.graphics.Insets
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
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
 * needs the shell's STATUS_BAR_SERVICE: so this runs in its own process of our app as an
 * instrumentation started by the helper (`am instrument --no-hidden-api-checks`), holding the
 * shell's permissions. Shell and apps can't reach each other's sockets (SELinux), so the helper
 * gets [binder] from [SystemBarsProvider] and calls it (shell uid only); it ends when the helper goes.
 */
@SuppressLint("PrivateApi", "WrongConstant")
class SystemBarsHost : Instrumentation() {
    companion object {
        private const val TAG = "NearsideBars"
        private const val TYPE_STATUS_BAR_ADDITIONAL = 2041
        const val SHELL_UID = 2000
        const val ADD = 1   // i32 display, i32 top, i32 bottom → i32 0 ok / 1 failed, string reason
        const val REMOVE = 2 // i32 display

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
        uiAutomation.adoptShellPermissionIdentity()
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
                        ADD -> { val (d, t, b) = Triple(data.readInt(), data.readInt(), data.readInt()); onMain { add(d, t, b) } }
                        REMOVE -> { val d = data.readInt(); onMain { remove(d) } }
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
        uiAutomation.dropShellPermissionIdentity()
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

    private fun add(displayId: Int, top: Int, bottom: Int) {
        remove(displayId)
        val display = context.getSystemService(DisplayManager::class.java).getDisplay(displayId) ?: error("no display $displayId")
        val window = context.createDisplayContext(display).createWindowContext(TYPE_STATUS_BAR_ADDITIONAL, null)
        val params = WindowManager.LayoutParams(1, 1, TYPE_STATUS_BAR_ADDITIONAL,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN, PixelFormat.TRANSPARENT)
        params.gravity = Gravity.TOP or Gravity.START
        params.title = "Nearside system bars"
        // Hidden API: InsetsFrameProvider(owner, index, type), sized from the display's edges.
        val provider = Class.forName("android.view.InsetsFrameProvider")
        val make = provider.getConstructor(Any::class.java, Int::class.javaPrimitiveType, Int::class.javaPrimitiveType)
        val fromDisplay = provider.getField("SOURCE_DISPLAY").getInt(null)
        val owner = Binder()
        fun inset(index: Int, type: Int, size: Insets) = make.newInstance(owner, index, type).also {
            provider.getMethod("setSource", Int::class.javaPrimitiveType).invoke(it, fromDisplay)
            provider.getMethod("setInsetsSize", Insets::class.java).invoke(it, size)
        }
        val provided = java.lang.reflect.Array.newInstance(provider, 2)
        java.lang.reflect.Array.set(provided, 0, inset(0, WindowInsets.Type.statusBars(), Insets.of(0, top, 0, 0)))
        java.lang.reflect.Array.set(provided, 1, inset(1, WindowInsets.Type.navigationBars(), Insets.of(0, 0, 0, bottom)))
        WindowManager.LayoutParams::class.java.getField("providedInsets").set(params, provided)
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
