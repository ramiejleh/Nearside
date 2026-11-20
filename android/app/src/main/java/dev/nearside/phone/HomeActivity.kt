package dev.nearside.phone

import android.app.Activity
import android.app.ActivityOptions
import android.content.Intent
import android.content.pm.ResolveInfo
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.GridView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The home screen of the Mac's "phone" window. It runs on that window's own virtual display
 * (Android 17 drops launches from the system launcher on such displays, so we bring our own) and
 * opens apps on the same display. Only the shell (the helper) may start it.
 * Gate A version: a plain icon grid; the designed version comes with the phone-window milestone.
 */
class HomeActivity : Activity() {
    private lateinit var apps: List<ResolveInfo>

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        apps = packageManager.queryIntentActivities(launcher, 0)
            .filter { it.activityInfo.packageName != packageName }
            .sortedBy { it.loadLabel(packageManager).toString().lowercase() }
        val density = resources.displayMetrics.density
        setContentView(GridView(this).apply {
            numColumns = 4
            setBackgroundColor(Color.BLACK)
            setPadding((12 * density).toInt(), (24 * density).toInt(), (12 * density).toInt(), 0)
            verticalSpacing = (16 * density).toInt()
            adapter = Adapter(density)
            setOnItemClickListener { _, _, position, _ -> open(apps[position]) }
        })
    }

    private fun open(app: ResolveInfo) {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            .setClassName(app.activityInfo.packageName, app.activityInfo.name)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        val options = ActivityOptions.makeBasic().setLaunchDisplayId(display.displayId)
        startActivity(intent, options.toBundle())
    }

    private inner class Adapter(private val density: Float) : BaseAdapter() {
        override fun getCount() = apps.size
        override fun getItem(position: Int) = apps[position]
        override fun getItemId(position: Int) = position.toLong()
        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val cell = (convertView as? LinearLayout) ?: LinearLayout(this@HomeActivity).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                addView(ImageView(context), LinearLayout.LayoutParams((52 * density).toInt(), (52 * density).toInt()))
                addView(TextView(context).apply {
                    setTextColor(Color.WHITE); textSize = 12f; maxLines = 1; gravity = Gravity.CENTER
                })
            }
            val app = apps[position]
            (cell.getChildAt(0) as ImageView).setImageDrawable(app.loadIcon(packageManager))
            (cell.getChildAt(1) as TextView).text = app.loadLabel(packageManager)
            return cell
        }
    }
}
