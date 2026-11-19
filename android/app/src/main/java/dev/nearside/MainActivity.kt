package dev.nearside

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import dev.nearside.link.HelperConnection

/** PoC status screen: one glance tells whether each moving part is alive. */
class MainActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var statusView: TextView
    private val refresh = object : Runnable {
        override fun run() {
            render()
            handler.postDelayed(this, 1000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = (24 * resources.displayMetrics.density).toInt()
        statusView = TextView(this).apply { textSize = 16f; setLineSpacing(0f, 1.3f) }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad * 2, pad, pad)
            addView(TextView(context).apply { text = "Nearside PoC"; textSize = 24f })
            addView(statusView)
            addView(button("Disable battery optimisation") {
                startActivity(
                    Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")),
                )
            })
        }
        setContentView(root)
    }

    override fun onResume() {
        super.onResume()
        handler.post(refresh)
    }

    override fun onPause() {
        handler.removeCallbacks(refresh)
        super.onPause()
    }

    private fun render() {
        val battery = getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)
        fun mark(ok: Boolean) = if (ok) "✅" else "❌"
        statusView.text = buildString {
            appendLine()
            appendLine("${mark(AdbWifi.canWrite(this@MainActivity))} Setup permission granted by Mac")
            appendLine("${mark(AdbWifi.isEnabled(this@MainActivity))} Wireless debugging on")
            appendLine("${mark(battery)} Battery optimisation off")
            appendLine("${mark(HelperConnection.helper != null)} Linked to clipboard helper")
            appendLine("${mark(HelperConnection.macConnected)} Mac connected")
            appendLine()
            appendLine("Last event: ${Status.lastEvent}")
        }
    }

    private fun button(label: String, onClick: () -> Unit) =
        Button(this).apply { text = label; setOnClickListener { onClick() } }
}
