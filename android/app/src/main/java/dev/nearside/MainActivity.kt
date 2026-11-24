package dev.nearside

import android.app.Activity
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import dev.nearside.link.HelperConnection

/**
 * The app's one screen: whether the Mac is connected, and a checklist of what Nearside needs,
 * with a button wherever the user has something to do. Follows light and dark mode and keeps
 * clear of the system bars (the app draws edge to edge).
 */
class MainActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private val refresh = object : Runnable {
        override fun run() {
            render()
            handler.postDelayed(this, 1000)
        }
    }

    private val dark get() = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    private val pageColor get() = if (dark) 0xFF121214.toInt() else 0xFFF2F2F4.toInt()
    private val surface get() = if (dark) 0xFF1E1E22.toInt() else Color.WHITE
    private val ink get() = if (dark) 0xFFF2F2F4.toInt() else 0xFF1C1C1F.toInt()
    private val soft get() = if (dark) 0xFF9E9EA6.toInt() else 0xFF5D5F66.toInt()
    private val divider get() = if (dark) 0xFF2E2E34.toInt() else 0xFFE4E5E8.toInt()

    private lateinit var connection: LinearLayout
    private lateinit var connectionTitle: TextView
    private lateinit var connectionDetail: TextView
    private lateinit var checklist: LinearLayout
    private lateinit var footer: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        actionBar?.hide()
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        window.decorView.systemUiVisibility = if (dark) 0 else
            View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR

        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(28))
        }
        column.addView(header())
        connection = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(22), dp(22), dp(22), dp(22)) }
        connectionTitle = text(22f, bold = true)
        connectionDetail = text(15f).apply { setPadding(0, dp(6), 0, 0) }
        connection.addView(connectionTitle)
        connection.addView(connectionDetail)
        column.addView(connection, block(top = 24))
        column.addView(text(15f, bold = true).apply { text = "Setup"; setTextColor(soft); setPadding(dp(6), 0, 0, dp(8)) }, block(top = 28))
        checklist = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(surface, 22)
        }
        column.addView(checklist, block())
        footer = text(13f).apply { setTextColor(soft); setPadding(dp(6), 0, dp(6), 0) }
        column.addView(footer, block(top = 20))

        val scroll = ScrollView(this).apply {
            setBackgroundColor(pageColor)
            isFillViewport = true
            addView(column)
            // Edge to edge: keep the content clear of the status and navigation bars.
            setOnApplyWindowInsetsListener { view, insets ->
                val bars = insets.getInsets(WindowInsets.Type.systemBars())
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
                insets
            }
            clipToPadding = false
        }
        setContentView(scroll)
    }

    override fun onResume() {
        super.onResume()
        handler.post(refresh)
    }

    override fun onPause() {
        handler.removeCallbacks(refresh)
        super.onPause()
    }

    private fun header() = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        addView(ImageView(context).apply {
            setImageResource(R.drawable.ic_launcher_foreground)
            background = rounded(0xFF1C1C1F.toInt(), 14)
            if (dark) (background as GradientDrawable).setStroke(dp(1), 0xFF3A3A40.toInt())
            scaleType = ImageView.ScaleType.FIT_CENTER
            setPadding(-dp(6), -dp(6), -dp(6), -dp(6))
            clipToOutline = true
        }, LinearLayout.LayoutParams(dp(52), dp(52)))
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), 0, 0, 0)
            addView(text(26f, bold = true).apply { text = "Nearside" })
            addView(text(15f).apply { text = "Your phone, on your ${Desktop.name(this@MainActivity)}"; setTextColor(soft) })
        })
    }

    private fun render() {
        val linked = HelperConnection.helper != null
        val connected = HelperConnection.macConnected
        if (connected) {
            connection.background = GradientDrawable(GradientDrawable.Orientation.TL_BR,
                intArrayOf(0xFF1B2A4A.toInt(), 0xFF2A1B3D.toInt(), 0xFF0B0D14.toInt())).apply { cornerRadius = dp(22).toFloat() }
            connectionTitle.text = "Connected to your ${Desktop.name(this@MainActivity)}"
            connectionTitle.setTextColor(Color.WHITE)
            connectionDetail.text = "Your clipboard, notifications, messages and apps are shared with it. There's nothing to do here."
            connectionDetail.setTextColor(0xB8FFFFFF.toInt())
        } else {
            connection.background = rounded(surface, 22)
            connectionTitle.text = "Waiting for your ${Desktop.name(this@MainActivity)}"
            connectionTitle.setTextColor(ink)
            connectionDetail.text = "Open Nearside on your ${Desktop.name(this@MainActivity)}, with this phone on the same Wi-Fi or plugged in by USB. It connects by itself."
            connectionDetail.setTextColor(soft)
        }

        val battery = getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)
        val wireless = AdbWifi.isEnabled()
        checklist.removeAllViews()
        row("Set up by your ${Desktop.name(this@MainActivity)}", AdbWifi.canWrite(this),
            "Your ${Desktop.name(this@MainActivity)} gave Nearside what it needs.", "Pair with Nearside on your ${Desktop.name(this@MainActivity)} to finish setup.")
        row("Wireless debugging", wireless ?: false,
            "On, so your ${Desktop.name(this@MainActivity)} can reach this phone over Wi-Fi.",
            if (wireless == null) "Shown once your ${Desktop.name(this@MainActivity)} has connected." else "Off. Your ${Desktop.name(this@MainActivity)} reconnects over USB, or turn it on in Developer options.")
        row("Linked to the helper", linked,
            "Your ${Desktop.name(this@MainActivity)}'s helper is running on this phone.", "It starts when your ${Desktop.name(this@MainActivity)} connects.")
        row("Notifications", NotificationMirror.instance != null,
            "Your notifications show on your ${Desktop.name(this@MainActivity)}.", "Allow notification access so they can.",
            action = "Allow" to { startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) })
        row("Runs in the background", battery,
            "Android won't pause Nearside.", "Android may pause Nearside, and your ${Desktop.name(this@MainActivity)} loses touch with it.",
            action = "Allow" to {
                startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
            }, last = true)

        val version = runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull() ?: ""
        footer.text = "Last event: ${Status.lastEvent}\nVersion $version"
    }

    /** One checklist line: its state, what it means, and a button when there's something to do. */
    private fun row(title: String, ok: Boolean, okText: String, todoText: String,
                    action: Pair<String, () -> Unit>? = null, last: Boolean = false) {
        val line = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(18), dp(16), dp(16), dp(16))
            contentDescription = "$title: ${if (ok) okText else todoText}"
        }
        line.addView(ImageView(this).apply { setImageResource(if (ok) R.drawable.ic_status_ok else R.drawable.ic_status_todo) },
            LinearLayout.LayoutParams(dp(26), dp(26)))
        line.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), 0, dp(8), 0)
            addView(text(16f, bold = true).apply { text = title })
            addView(text(14f).apply { text = if (ok) okText else todoText; setTextColor(soft); setPadding(0, dp(2), 0, 0) })
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        if (!ok && action != null) {
            line.addView(text(14f, bold = true).apply {
                text = action.first
                setTextColor(if (dark) 0xFF141417.toInt() else Color.WHITE)
                background = rounded(if (dark) 0xFFF2F2F4.toInt() else 0xFF1C1C1F.toInt(), 99)
                setPadding(dp(16), dp(8), dp(16), dp(8))
                isClickable = true
                setOnClickListener { action.second() }
            })
        }
        checklist.addView(line)
        if (!last) checklist.addView(View(this).apply { setBackgroundColor(divider) },
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(1)).apply { marginStart = dp(58) })
    }

    private fun text(size: Float, bold: Boolean = false) = TextView(this).apply {
        textSize = size
        setTextColor(ink)
        setLineSpacing(0f, 1.15f)
        if (bold) typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    }

    private fun rounded(color: Int, radiusDp: Int) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(radiusDp).toFloat()
    }

    private fun block(top: Int = 0) = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        .apply { topMargin = dp(top) }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}
