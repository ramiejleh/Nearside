// Probe (throwaway): can the shell give a virtual display the phone's system-bar insets, so apps
// lay out as on the phone (content below the status bar, above the gesture bar)? Adds an invisible
// window providing statusBars (top) and navigationBars (bottom) insets, then waits while an app is
// started on the display from adb (`am start --display N …`).
//
//   CLASSPATH=<apk> app_process / dev.nearside.helper.probe.InsetsProbe <topPx> <bottomPx> <seconds>
package dev.nearside.helper.probe

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Insets
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.media.ImageReader
import android.os.Binder
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import dev.nearside.helper.FakeContext
import dev.nearside.helper.Workarounds
import java.lang.reflect.Proxy
import kotlin.system.exitProcess

@SuppressLint("PrivateApi", "WrongConstant")
object InsetsProbe {
    @JvmStatic
    fun main(args: Array<String>) {
        Looper.prepareMainLooper()
        Workarounds.apply()
        val top = args.getOrElse(0) { "204" }.toInt()
        val bottom = args.getOrElse(1) { "72" }.toInt()
        val seconds = args.getOrElse(2) { "40" }.toLong()
        val w = 1280; val h = 2856

        val reader = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        reader.setOnImageAvailableListener({ it.acquireLatestImage()?.close() }, Handler(Looper.getMainLooper()))
        val ctor = DisplayManager::class.java.getDeclaredConstructor(Context::class.java).apply { isAccessible = true }
        val dm = ctor.newInstance(FakeContext.instance) as DisplayManager
        val flags = (1 shl 0) or (1 shl 3) or (1 shl 6) or (1 shl 10) or (1 shl 11) or (1 shl 12) or (1 shl 13) or (1 shl 14)
        val vd = dm.createVirtualDisplay("nearside-insets", w, h, 480, reader.surface, flags)
        val id = vd.display.displayId
        println("display $id")

        Handler(Looper.getMainLooper()).postDelayed({ vd.release(); println("done"); exitProcess(0) }, seconds * 1000)
        Looper.loop()
    }
}
