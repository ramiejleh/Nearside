// The phone's system bars on our displays (via the app's SystemBarsHost).
package dev.nearside.helper.display

import android.content.AttributionSource
import android.content.pm.ProviderInfo
import android.graphics.Insets
import android.graphics.PixelFormat
import android.os.Binder
import android.os.Bundle
import android.os.IBinder
import android.os.Parcel
import android.view.Gravity
import android.view.WindowInsets
import android.view.WindowManager
import dev.nearside.helper.FakeContext
import dev.nearside.helper.Log

/**
 * Our displays have no status or gesture bar, so apps lay out against bare edges: YouTube drew
 * its status-bar strip over its content and its bottom bar on the edge. The app's
 * [dev.nearside.phone.SystemBarsHost] gives a display the phone's own bar sizes (an
 * invisible window providing the insets); the Mac then hides the status-bar area.
 *
 * The host is an instrumentation (only it may add such windows: see there). It runs only while
 * it's needed: started when the Mac's launcher asks for the app list (or by the first window),
 * and finished ten minutes after the last window closes, since a running instrumentation keeps
 * its process at foreground priority (never frozen). `--no-restart` keeps the app itself
 * running when the host starts and ends.
 */
object SystemBars {
    private const val PACKAGE = "dev.nearside"
    private const val HOST = "$PACKAGE/$PACKAGE.phone.SystemBarsHost"
    private const val AUTHORITY = "$PACKAGE.bars"
    private const val ADD = 1    // as SystemBarsHost
    private const val REMOVE = 2
    private const val FINISH = 3
    private const val TYPE_STATUS_BAR_ADDITIONAL = 2041
    private const val IDLE_MS = 10 * 60_000L

    /** The phone's bars in px, from the window manager (0 if unknown). */
    class Bars(val top: Int, val bottom: Int)

    val phone: Bars by lazy {
        val text = runCatching {
            val p = Runtime.getRuntime().exec(arrayOf("dumpsys", "window"))
            p.inputStream.bufferedReader().readText().also { p.waitFor() }
        }.getOrDefault("")
        fun height(type: String) = Regex("type=$type frame=\\[\\d+,(\\d+)\\]\\[\\d+,(\\d+)\\]").find(text)
            ?.groupValues?.let { it[2].toInt() - it[1].toInt() } ?: 0
        Bars(height("statusBars"), height("navigationBars")).also { Log.d("system bars: top ${it.top} px, bottom ${it.bottom} px") }
    }

    private var host: Process? = null
    private var binder: IBinder? = null
    /** Our token for the host: it ends when we do. */
    private val token = Binder()
    /** Displays that have bars, with theirs: given again if the host had to be restarted. */
    private val displays = HashMap<Int, Bars>()
    private val timer = java.util.concurrent.Executors.newSingleThreadScheduledExecutor()
    private var finishing: java.util.concurrent.ScheduledFuture<*>? = null

    /** Starts the host ahead of the first window, if it isn't running. */
    fun prewarm() {
        synchronized(this) {
            finishing?.cancel(false)
            start()
            if (displays.isEmpty()) finishLater() // in case no window comes
        }
        // Hand it our token as soon as it's up, so it ends with us even if no window comes.
        Thread({ synchronized(this) { if (binder == null) awaitHost(start = false) } }, "bars-prewarm").start()
    }

    /** No windows left: finish the host after a while (a new window in the meantime keeps it). */
    @Synchronized
    fun finishLater() {
        finishing?.cancel(false)
        finishing = timer.schedule({ finishIfUnused() }, IDLE_MS, java.util.concurrent.TimeUnit.MILLISECONDS)
    }

    @Synchronized
    private fun finishIfUnused() {
        if (displays.isNotEmpty() || host?.isAlive != true) return
        val b = binder ?: awaitHost(start = false)
        if (b != null) transact(b, FINISH) {}
        binder = null
        Log.d("system bars host finished (unused)")
    }

    @Synchronized
    private fun start() {
        if (host?.isAlive == true) return
        runCatching {
            host = ProcessBuilder("am", "instrument", "-w", "--no-restart", "--no-hidden-api-checks", HOST).redirectErrorStream(true).start().also { p ->
                Thread({ p.inputStream.bufferedReader().forEachLine { Log.d("system bars host: $it") } }, "bars-host").start()
            }
            Log.d("system bars host starting")
        }.onFailure { Log.d("system bars host failed to start: $it") }
    }

    /**
     * Gives display [id] (at [dpi]) the phone's bars, scaled from the phone's density; the bars
     * given (px), or null if it couldn't (the display then has none).
     */
    @Synchronized
    fun add(id: Int, dpi: Int, phoneDpi: Int): Bars? {
        if (phone.top <= 0) return null
        finishing?.cancel(false)
        val bars = Bars(phone.top * dpi / phoneDpi, phone.bottom * dpi / phoneDpi)
        val host = binder ?: awaitHost()
        val added = host != null && add(host, id, bars)
        if (added) displays[id] = bars else if (displays.isEmpty()) finishLater()
        return if (added) bars else null
    }

    @Synchronized
    fun remove(id: Int) {
        if (displays.remove(id) == null) return
        binder?.let { b -> transact(b, REMOVE) { it.writeInt(id) } }
        if (displays.isEmpty()) finishLater()
    }

    private fun add(host: IBinder, id: Int, bars: Bars) =
        transact(host, ADD) { it.writeInt(id); barWindow(bars).writeToParcel(it, 0) }

    /**
     * The bar window's layout, built here: its insets are hidden API, which the shell may use but
     * the app (whose process the host joins, with hidden-API checks on) may not. The host
     * unparcels it with the public CREATOR and adds the window.
     */
    private fun barWindow(bars: Bars): WindowManager.LayoutParams {
        val params = WindowManager.LayoutParams(1, 1, TYPE_STATUS_BAR_ADDITIONAL,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN, PixelFormat.TRANSPARENT)
        params.gravity = Gravity.TOP or Gravity.START
        params.title = "Nearside system bars"
        // InsetsFrameProvider(owner, index, type), sized from the display's edges.
        val provider = Class.forName("android.view.InsetsFrameProvider")
        val make = provider.getConstructor(Any::class.java, Int::class.javaPrimitiveType, Int::class.javaPrimitiveType)
        val fromDisplay = provider.getField("SOURCE_DISPLAY").getInt(null)
        val owner = Binder()
        fun inset(index: Int, type: Int, size: Insets) = make.newInstance(owner, index, type).also {
            provider.getMethod("setSource", Int::class.javaPrimitiveType).invoke(it, fromDisplay)
            provider.getMethod("setInsetsSize", Insets::class.java).invoke(it, size)
        }
        val provided = java.lang.reflect.Array.newInstance(provider, 2)
        java.lang.reflect.Array.set(provided, 0, inset(0, WindowInsets.Type.statusBars(), Insets.of(0, bars.top, 0, 0)))
        java.lang.reflect.Array.set(provided, 1, inset(1, WindowInsets.Type.navigationBars(), Insets.of(0, 0, 0, bars.bottom)))
        WindowManager.LayoutParams::class.java.getField("providedInsets").set(params, provided)
        return params
    }

    private fun transact(host: IBinder, code: Int, write: (Parcel) -> Unit): Boolean {
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            write(data)
            host.transact(code, data, reply, 0)
            val ok = reply.readInt() == 0
            if (!ok) Log.d("system bars: call $code failed: ${reply.readString()}")
            ok
        } catch (e: Exception) {
            Log.d("system bars: host unreachable: $e")
            false
        } finally {
            data.recycle(); reply.recycle()
        }
    }

    /** The host's Binder, once it's up (it starts with the app's process: seconds); null if it doesn't come. */
    private fun awaitHost(start: Boolean = true): IBinder? {
        if (host?.isAlive != true) { if (start) start() else return null }
        val deadline = System.currentTimeMillis() + 10_000
        while (System.currentTimeMillis() < deadline) {
            val b = runCatching { fetchHost() }.onFailure { Log.d("system bars: provider: ${it.cause ?: it}") }.getOrNull()
            if (b != null) {
                binder = b
                b.linkToDeath({ synchronized(this) { if (binder === b) { binder = null; Log.d("system bars host gone") } } }, 0)
                // A restarted host has none: give back the displays' bars.
                for ((id, bars) in displays) add(b, id, bars)
                return b
            }
            Thread.sleep(250)
        }
        Log.d("system bars host didn't come up")
        return null
    }

    /** SystemBarsProvider.call("host"): the host's Binder (from our package only), if it runs. */
    private fun fetchHost(): IBinder? {
        val am = Class.forName("android.app.ActivityManager").getMethod("getService").invoke(null)!!
        val ref: IBinder = Binder()
        val holder = am.javaClass
            .getMethod("getContentProviderExternal", String::class.java, Int::class.javaPrimitiveType, IBinder::class.java, String::class.java)
            .invoke(am, AUTHORITY, 0, ref, "nearside") ?: return null
        try {
            val info = holder.javaClass.getField("info").get(holder) as ProviderInfo
            if (info.packageName != PACKAGE) { Log.d("system bars: $AUTHORITY belongs to ${info.packageName}"); return null }
            val provider = holder.javaClass.getField("provider").get(holder)!!
            val s = String::class.java
            val reply = provider.javaClass.getMethod("call", AttributionSource::class.java, s, s, s, Bundle::class.java)
                .invoke(provider, FakeContext.instance.attributionSource, AUTHORITY, "host", null,
                    Bundle().apply { putBinder("helper", token) }) as Bundle?
            return reply?.getBinder("host")
        } finally {
            runCatching {
                am.javaClass.getMethod("removeContentProviderExternal", String::class.java, IBinder::class.java).invoke(am, AUTHORITY, ref)
            }
        }
    }
}
