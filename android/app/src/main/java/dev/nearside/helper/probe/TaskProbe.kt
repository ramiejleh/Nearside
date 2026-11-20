// Gate A probe (throwaway): moves a root task between displays, on top or at the bottom.
//   app_process / dev.nearside.helper.probe.TaskProbe <taskId> <displayId> top|bottom
package dev.nearside.helper.probe

import android.annotation.SuppressLint
import android.os.IBinder

@SuppressLint("PrivateApi", "DiscouragedPrivateApi")
object TaskProbe {
    @JvmStatic
    fun main(args: Array<String>) {
        val task = args[0].toInt()
        val display = args[1].toInt()
        val onTop = args.getOrElse(2) { "top" } == "top"
        val binder = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java)
            .invoke(null, "activity_task") as IBinder
        val atm = Class.forName("android.app.IActivityTaskManager\$Stub").getMethod("asInterface", IBinder::class.java)
            .invoke(null, binder)!!
        try {
            atm.javaClass.getMethod("moveRootTaskToDisplayOnTopOrBottom", Int::class.java, Int::class.java, Boolean::class.java)
                .invoke(atm, task, display, onTop)
            println("moved $task -> $display onTop=$onTop")
        } catch (t: Throwable) {
            println("moveRootTaskToDisplayOnTopOrBottom failed: ${t.cause ?: t}; trying moveRootTaskToDisplay")
            atm.javaClass.getMethod("moveRootTaskToDisplay", Int::class.java, Int::class.java).invoke(atm, task, display)
            println("moved $task -> $display")
        }
    }
}
