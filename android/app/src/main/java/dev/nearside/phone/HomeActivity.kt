package dev.nearside.phone

import android.app.Activity
import android.app.ActivityOptions
import android.content.Intent
import android.content.pm.ResolveInfo
import android.graphics.Color
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.FrameLayout
import android.widget.GridView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextClock
import android.widget.TextView
import android.window.OnBackInvokedDispatcher
import java.util.concurrent.Executors

/**
 * The home screen of the Mac's phone window. It runs on that window's own virtual display
 * (Android 17 drops launches from the system launcher on such displays, so we bring our own) and
 * opens apps on the same display. Only the shell (the helper) may start it; the helper passes
 * the dock (the Mac's favourite phone apps) as the "dock" extra.
 *
 * A clock and date, every app in a grid, and the dock in a frosted bar, over a deep gradient.
 * Icons load in the background so it shows at once; Back does nothing here, as on a phone.
 */
class HomeActivity : Activity() {
    private class App(val info: ResolveInfo, val label: String) {
        var icon: Drawable? = null
    }

    private val loader = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var apps: List<App> = emptyList()
    private var dockPackages: List<String> = emptyList()
    private lateinit var grid: GridView
    private lateinit var dockBar: LinearLayout
    private val adapter = Adapter()
    private val dp get() = resources.displayMetrics.density

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setDecorFitsSystemWindows(false)
        onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT) {} // home: nowhere to go
        dockPackages = intent.getStringArrayExtra("dock")?.toList().orEmpty()
        setContentView(layout())
        load()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringArrayExtra("dock")?.toList()?.let { if (it != dockPackages) { dockPackages = it; showDock() } }
        grid.smoothScrollToPosition(0)
    }

    /** About one column per 96 dp: 4 on a phone, more on a foldable or tablet-sized window. */
    private fun columns() = maxOf(4, (resources.configuration.screenWidthDp / 96))

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        grid.numColumns = columns() // the Mac's toolbox switched the size
    }

    override fun onResume() {
        super.onResume()
        if (apps.isNotEmpty()) load() // apps installed or removed meanwhile
    }

    override fun onDestroy() {
        loader.shutdownNow()
        super.onDestroy()
    }

    // MARK: Layout

    private fun layout(): View {
        val root = FrameLayout(this)
        root.background = GradientDrawable(GradientDrawable.Orientation.TL_BR,
            intArrayOf(Color.rgb(0x1B, 0x2A, 0x4A), Color.rgb(0x2A, 0x1B, 0x3D), Color.rgb(0x0B, 0x0D, 0x14)))

        val column = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val clock = TextClock(this).apply {
            format12Hour = "h:mm"; format24Hour = "HH:mm"
            textSize = 64f
            setTextColor(Color.WHITE)
            typeface = android.graphics.Typeface.create("sans-serif-light", android.graphics.Typeface.NORMAL)
            setShadowLayer(6 * dp, 0f, dp, 0x40000000)
        }
        val date = TextClock(this).apply {
            format12Hour = "EEEE d MMMM"; format24Hour = "EEEE d MMMM"
            textSize = 17f
            setTextColor(0xD9FFFFFF.toInt())
        }
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding((28 * dp).toInt(), (56 * dp).toInt(), (28 * dp).toInt(), (20 * dp).toInt())
            addView(clock); addView(date)
        }
        grid = GridView(this).apply {
            numColumns = columns()
            verticalSpacing = (18 * dp).toInt()
            setPadding((10 * dp).toInt(), (8 * dp).toInt(), (10 * dp).toInt(), (16 * dp).toInt())
            clipToPadding = false
            isVerticalScrollBarEnabled = false
            selector = android.graphics.drawable.ColorDrawable(Color.TRANSPARENT)
            adapter = this@HomeActivity.adapter
            setOnItemClickListener { _, _, position, _ -> open(apps[position].info) }
        }
        column.addView(header)
        column.addView(grid, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        root.addView(column)

        // The dock: its own row under the grid (not over it: the frosted bar showed the grid through).
        dockBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                cornerRadius = 30 * dp
                setColor(0x2EFFFFFF)
                setStroke(dp.toInt().coerceAtLeast(1), 0x1FFFFFFF)
            }
            setPadding((12 * dp).toInt(), (10 * dp).toInt(), (12 * dp).toInt(), (10 * dp).toInt())
        }
        column.addView(dockBar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            topMargin = (6 * dp).toInt()
            bottomMargin = (22 * dp).toInt()
        })
        return root
    }

    private fun showDock() {
        dockBar.removeAllViews()
        val byPackage = apps.associateBy { it.info.activityInfo.packageName }
        val dock = dockPackages.mapNotNull { byPackage[it] }.take(5)
        dockBar.visibility = if (dock.isEmpty()) View.GONE else View.VISIBLE
        for (app in dock) {
            dockBar.addView(ImageView(this).apply {
                setImageDrawable(app.icon)
                contentDescription = app.label
                setOnClickListener { open(app.info) }
                foreground = getDrawable(android.R.drawable.list_selector_background)
            }, LinearLayout.LayoutParams((54 * dp).toInt(), (54 * dp).toInt()).apply {
                marginStart = (6 * dp).toInt(); marginEnd = (6 * dp).toInt()
            })
        }
    }

    // MARK: Apps

    private fun load() {
        loader.execute {
            val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            val list = packageManager.queryIntentActivities(launcher, 0)
                .filter { it.activityInfo.packageName != packageName }
                .map { App(it, it.loadLabel(packageManager).toString()) }
                .sortedBy { it.label.lowercase() }
            main.post { apps = list; adapter.notifyDataSetChanged(); showDock() }
            for (app in list) {
                if (Thread.interrupted()) return@execute
                app.icon = runCatching { app.info.loadIcon(packageManager) }.getOrNull()
            }
            main.post { adapter.notifyDataSetChanged(); showDock() }
        }
    }

    private fun open(app: ResolveInfo) {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            .setClassName(app.activityInfo.packageName, app.activityInfo.name)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        startActivity(intent, ActivityOptions.makeBasic().setLaunchDisplayId(display.displayId).toBundle())
    }

    private inner class Adapter : BaseAdapter() {
        override fun getCount() = apps.size
        override fun getItem(position: Int) = apps[position]
        override fun getItemId(position: Int) = position.toLong()
        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val cell = (convertView as? LinearLayout) ?: LinearLayout(this@HomeActivity).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                addView(ImageView(context), LinearLayout.LayoutParams((56 * dp).toInt(), (56 * dp).toInt()))
                addView(TextView(context).apply {
                    setTextColor(0xF2FFFFFF.toInt())
                    textSize = 12f
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                    gravity = Gravity.CENTER
                    setShadowLayer(4 * dp, 0f, dp / 2, 0x66000000)
                    setPadding((4 * dp).toInt(), (6 * dp).toInt(), (4 * dp).toInt(), 0)
                })
            }
            val app = apps[position]
            (cell.getChildAt(0) as ImageView).setImageDrawable(app.icon)
            (cell.getChildAt(1) as TextView).text = app.label
            cell.contentDescription = app.label
            return cell
        }
    }
}
