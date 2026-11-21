// The phone's system bars on our displays (via the app's SystemBarsHost).
package dev.nearside.helper.display

import android.content.AttributionSource
import android.content.pm.ProviderInfo
import android.os.Binder
import android.os.Bundle
import android.os.IBinder
import android.os.Parcel
import dev.nearside.helper.FakeContext
import dev.nearside.helper.Log

/**
 * Our displays have no status or gesture bar, so apps lay out against bare edges: YouTube drew
 * its status-bar strip over its content and its bottom bar on the edge. The app's
 * [dev.nearside.phone.SystemBarsHost] gives a display the phone's own bar sizes (an
 * invisible window providing the insets); the Mac then hides the status-bar area.
 *
 * The host is an instrumentation (only it may add such windows: see there), started here once.
 * Starting an instrumentation force-stops the app first, so the app restarts once (~3 s) when
 * the helper starts; the app link reconnects by itself.
 */
object SystemBars {
    private const val PACKAGE = "dev.nearside"
    private const val HOST = "$PACKAGE/$PACKAGE.phone.SystemBarsHost"
    private const val AUTHORITY = "$PACKAGE.bars"
    private const val ADD = 1    // as SystemBarsHost
    private const val REMOVE = 2

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

    /** Starts the host (the app restarts once). */
    @Synchronized
    fun start() {
        if (host?.isAlive == true) return
        runCatching {
            host = ProcessBuilder("am", "instrument", "-w", "--no-hidden-api-checks", HOST).redirectErrorStream(true).start().also { p ->
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
        val bars = Bars(phone.top * dpi / phoneDpi, phone.bottom * dpi / phoneDpi)
        val host = binder ?: awaitHost() ?: return null
        return if (add(host, id, bars)) bars.also { displays[id] = it } else null
    }

    @Synchronized
    fun remove(id: Int) {
        if (displays.remove(id) == null) return
        transact(binder ?: return, REMOVE) { it.writeInt(id) }
    }

    private fun add(host: IBinder, id: Int, bars: Bars) =
        transact(host, ADD) { it.writeInt(id); it.writeInt(bars.top); it.writeInt(bars.bottom) }

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
    private fun awaitHost(): IBinder? {
        if (host?.isAlive != true) start()
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
