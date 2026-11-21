// The phone's temperature, as Android grades it, for the encoder budget.
package dev.nearside.helper.display

import android.os.PowerManager
import dev.nearside.helper.FakeContext
import dev.nearside.helper.Log
import java.util.concurrent.Executors

object Thermal {
    /** PowerManager.THERMAL_STATUS_*: 0 none … 2 moderate, 3 severe, 4+ critical. */
    @Volatile var status = PowerManager.THERMAL_STATUS_NONE
        private set

    /** Called on a change (sessions re-apply their budget and tell the Mac). */
    @Volatile var onChange: (() -> Unit)? = null

    val moderate get() = status >= PowerManager.THERMAL_STATUS_MODERATE
    val severe get() = status >= PowerManager.THERMAL_STATUS_SEVERE

    fun start() = runCatching {
        val power = FakeContext.instance.getSystemService(PowerManager::class.java)!!
        status = power.currentThermalStatus
        power.addThermalStatusListener(Executors.newSingleThreadExecutor { Thread(it, "thermal") }) { new ->
            if (new == status) return@addThermalStatusListener
            Log.d("thermal status $status → $new")
            status = new
            onChange?.invoke()
        }
        Log.d("thermal status $status")
    }.onFailure { Log.d("thermal status unavailable: ${it.cause ?: it}") }
}
