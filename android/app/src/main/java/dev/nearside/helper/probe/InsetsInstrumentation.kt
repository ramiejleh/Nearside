// Probe (throwaway): adds an invisible window providing the phone's status-bar and gesture-bar
// insets to a display, from our app's process with the shell's permissions (the helper itself,
// a bare app_process, may not add windows on Android 17: "Unknown pid").
//
//   am instrument -w -e display N -e top 204 -e bottom 72 -e seconds 50 \
//       dev.nearside/dev.nearside.helper.probe.InsetsInstrumentation
package dev.nearside.helper.probe

import android.annotation.SuppressLint
import android.app.Instrumentation
import android.graphics.Insets
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.os.Binder
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager

@SuppressLint("PrivateApi", "WrongConstant")
class InsetsInstrumentation : Instrumentation() {
    private var args = Bundle()

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        args = arguments ?: Bundle()
        start()
    }

    override fun onStart() {
        val out = Bundle()
        val displayId = args.getString("display")!!.toInt()
        val top = args.getString("top", "204").toInt()
        val bottom = args.getString("bottom", "72").toInt()
        val seconds = args.getString("seconds", "50").toLong()
        uiAutomation.adoptShellPermissionIdentity()
        val done = Object()
        Handler(Looper.getMainLooper()).post {
            try {
                val display = context.getSystemService(DisplayManager::class.java).getDisplay(displayId)
                val ctx = context.createDisplayContext(display).createWindowContext(2041, null)
                val lp = WindowManager.LayoutParams(1, 1, 2041,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN, PixelFormat.TRANSPARENT)
                lp.gravity = Gravity.TOP or Gravity.START
                lp.title = "nearside-insets"
                val providerClass = Class.forName("android.view.InsetsFrameProvider")
                providerClass.constructors.forEach { android.util.Log.i("InsetsProbe", "ctor $it") }
                val pctor = providerClass.constructors.first { it.parameterTypes.size == 3 && it.parameterTypes[1] == Int::class.javaPrimitiveType }
                val setSource = providerClass.getMethod("setSource", Int::class.javaPrimitiveType)
                val setSize = providerClass.getMethod("setInsetsSize", Insets::class.java)
                val sourceDisplay = providerClass.getField("SOURCE_DISPLAY").getInt(null)
                val owner = Binder()
                val status = pctor.newInstance(owner, 0, WindowInsets.Type.statusBars())
                setSource.invoke(status, sourceDisplay); setSize.invoke(status, Insets.of(0, top, 0, 0))
                val nav = pctor.newInstance(owner, 1, WindowInsets.Type.navigationBars())
                setSource.invoke(nav, sourceDisplay); setSize.invoke(nav, Insets.of(0, 0, 0, bottom))
                val array = java.lang.reflect.Array.newInstance(providerClass, 2)
                java.lang.reflect.Array.set(array, 0, status); java.lang.reflect.Array.set(array, 1, nav)
                WindowManager.LayoutParams::class.java.getField("providedInsets").set(lp, array)
                ctx.getSystemService(WindowManager::class.java).addView(View(ctx), lp)
                out.putString("result", "insets window added on display $displayId (top $top, bottom $bottom)")
            } catch (t: Throwable) {
                out.putString("result", "failed: $t ${t.cause ?: ""}")
            }
            synchronized(done) { done.notifyAll() }
        }
        synchronized(done) { done.wait(5000) }
        sendStatus(0, out)
        Thread.sleep(seconds * 1000)
        uiAutomation.dropShellPermissionIdentity()
        finish(0, out)
    }
}
