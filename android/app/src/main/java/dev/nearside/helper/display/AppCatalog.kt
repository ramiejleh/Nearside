// The phone's launchable apps for the Mac's launcher: names, when each was last used, and icons.
package dev.nearside.helper.display

import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.ResolveInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.AdaptiveIconDrawable
import android.util.Base64
import dev.nearside.helper.FakeContext
import dev.nearside.helper.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

object AppCatalog {
    const val ICON_PX = 192

    private val pm get() = FakeContext.instance.packageManager

    /** Names are kept per `pkg/activity@lastUpdateTime`: reading them all took up to 5.6 s. */
    private val labels = HashMap<String, String>()

    private fun launchable(): List<ResolveInfo> =
        pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
            .filter { it.activityInfo.packageName != "dev.nearside" }

    private fun version(pkg: String) = runCatching { pm.getPackageInfo(pkg, 0).lastUpdateTime }.getOrDefault(0L)

    /**
     * The launchable apps by name: `pkg`, `activity`, `label`, `ver` (the package's last update,
     * which also versions its icon) and `used` (when it was last in the foreground, ms; 0 if not
     * in the last 30 days).
     */
    @Synchronized
    fun apps(): JSONObject {
        val used = lastUsed()
        val list = launchable().map { info ->
            val a = info.activityInfo
            val ver = version(a.packageName)
            Triple(info, ver, labels.getOrPut("${a.packageName}/${a.name}@$ver") { info.loadLabel(pm).toString() })
        }.sortedBy { it.third.lowercase() }
        val apps = JSONArray()
        for ((info, ver, label) in list) {
            val a = info.activityInfo
            apps.put(JSONObject().put("pkg", a.packageName).put("activity", a.name).put("label", label)
                .put("ver", ver).put("used", used[a.packageName] ?: 0L))
        }
        return JSONObject().put("t", "display-apps").put("apps", apps).put("statusBarDp", statusBar)
            .put("screenDp", screenDp())
    }

    /** Last foreground time per package (usage stats; the shell may read them). */
    private fun lastUsed(): Map<String, Long> = runCatching {
        val usm = FakeContext.instance.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val now = System.currentTimeMillis()
        usm.queryAndAggregateUsageStats(now - 30L * 24 * 3600 * 1000, now)
            .mapValues { it.value.lastTimeUsed }.filterValues { it > 0 }
    }.onFailure { Log.d("usage stats unavailable: ${it.cause ?: it}") }.getOrDefault(emptyMap())

    /**
     * Icons for `pkg/activity` ids, as [ICON_PX] px PNGs (base64). Adaptive icons come full-bleed
     * and unmasked (`adaptive`: true) so the Mac can give them its own rounded-square shape;
     * others come as drawn, transparent around their shape.
     */
    fun icons(ids: List<String>): JSONObject {
        val wanted = ids.toSet()
        val icons = JSONArray()
        for (info in launchable()) {
            val a = info.activityInfo
            val id = "${a.packageName}/${a.name}"
            if (id !in wanted) continue
            runCatching {
                val drawable = info.loadIcon(pm)
                val bitmap = Bitmap.createBitmap(ICON_PX, ICON_PX, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bitmap)
                val adaptive = drawable is AdaptiveIconDrawable
                if (drawable is AdaptiveIconDrawable) {
                    // The layers are 1.5× the icon, centred; the masked area is the icon's bounds.
                    val inset = ICON_PX / 4
                    for (layer in listOfNotNull(drawable.background, drawable.foreground)) {
                        layer.setBounds(-inset, -inset, ICON_PX + inset, ICON_PX + inset)
                        layer.draw(canvas)
                    }
                } else {
                    drawable.setBounds(0, 0, ICON_PX, ICON_PX)
                    drawable.draw(canvas)
                }
                val png = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
                bitmap.recycle()
                icons.put(JSONObject().put("id", id).put("ver", version(a.packageName)).put("adaptive", adaptive)
                    .put("png", Base64.encodeToString(png, Base64.NO_WRAP)))
            }.onFailure { Log.d("icon for $id failed: $it") }
        }
        return JSONObject().put("t", "display-icons").put("icons", icons)
    }

    /**
     * The phone's status-bar height in dp. Some apps (Instagram) leave that much empty at the top
     * of any window, status bar or not; the Mac crops it off for them.
     */
    val statusBar by lazy { statusBarDp() }

    private fun statusBarDp(): Int {
        val density = android.content.res.Resources.getSystem().displayMetrics.density
        // The real bar, as the window manager has it on the phone's screen (Pixels size it to the
        // camera cutout at runtime: 68 dp on a Pixel 9 Pro, where the resource still says 24).
        val real = runCatching {
            val p = Runtime.getRuntime().exec(arrayOf("dumpsys", "window"))
            val text = p.inputStream.bufferedReader().readText().also { p.waitFor() }
            Regex("type=statusBars frame=\\[\\d+,(\\d+)\\]\\[\\d+,(\\d+)\\]").find(text)
                ?.groupValues?.let { (it[2].toInt() - it[1].toInt()) / density }
        }.getOrNull()
        val resource = runCatching {
            val res = android.content.res.Resources.getSystem()
            res.getDimensionPixelSize(res.getIdentifier("status_bar_height", "dimen", "android")) / density
        }.getOrNull()
        return Math.round(real?.takeIf { it > 0 } ?: resource ?: 0f).also { Log.d("status bar: $it dp (window manager $real, resource $resource)") }
    }

    /** The phone's screen in dp, "WxH" (portrait): the phone window has its shape. */
    private fun screenDp(): String = runCatching {
        val m = android.util.DisplayMetrics()
        @Suppress("DEPRECATION")
        Hidden.displayManager.getDisplay(android.view.Display.DEFAULT_DISPLAY).getRealMetrics(m)
        val w = minOf(m.widthPixels, m.heightPixels) / m.density
        val h = maxOf(m.widthPixels, m.heightPixels) / m.density
        "${Math.round(w)}x${Math.round(h)}"
    }.getOrDefault("")

    /** Reads the names (and the status bar) in the background when the helper starts. */
    fun warmUp() {
        Thread({
            val started = System.currentTimeMillis()
            val n = runCatching { apps().optJSONArray("apps")?.length() }.getOrNull()
            Log.d("app list ready: $n apps in ${System.currentTimeMillis() - started} ms")
        }, "apps-warm-up").start()
    }
}
