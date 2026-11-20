// Probe (throwaway): does a VirtualDevice's own clipboard work while the phone is locked?
// Needs a companion association owned by the shell: `cmd companiondevice associate 0 com.android.shell`.
//   app_process / dev.nearside.helper.probe.ClipProbe <associationId>
package dev.nearside.helper.probe

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.Context
import android.graphics.PixelFormat
import android.hardware.display.VirtualDisplayConfig
import android.media.ImageReader
import android.os.IBinder
import android.os.Looper
import dev.nearside.helper.FakeContext
import dev.nearside.helper.Workarounds

@SuppressLint("PrivateApi", "WrongConstant")
object ClipProbe {
    @JvmStatic
    fun main(args: Array<String>) {
        Looper.prepareMainLooper()
        Workarounds.apply()
        val association = args[0].toInt()
        val vdmService = Class.forName("android.companion.virtual.IVirtualDeviceManager\$Stub").getMethod("asInterface", IBinder::class.java)
            .invoke(null, Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java).invoke(null, "virtualdevice"))!!
        val vdmClass = Class.forName("android.companion.virtual.VirtualDeviceManager")
        val vdm = vdmClass.getDeclaredConstructor(Class.forName("android.companion.virtual.IVirtualDeviceManager"), Context::class.java)
            .apply { isAccessible = true }.newInstance(vdmService, FakeContext.instance)
        val paramsClass = Class.forName("android.companion.virtual.VirtualDeviceParams")
        val params = Class.forName("android.companion.virtual.VirtualDeviceParams\$Builder").getConstructor().newInstance()
            .let { it.javaClass.getMethod("build").invoke(it) }
        val device = vdm.javaClass.getMethod("createVirtualDevice", Int::class.java, paramsClass).invoke(vdm, association, params)!!
        val deviceId = device.javaClass.getMethod("getDeviceId").invoke(device) as Int
        println("virtual device $deviceId")

        val reader = ImageReader.newInstance(800, 1200, PixelFormat.RGBA_8888, 2)
        val flags = (1 shl 0) or (1 shl 3) or (1 shl 6) or (1 shl 10) or (1 shl 11) or (1 shl 12) or (1 shl 14)
        val config = VirtualDisplayConfig.Builder("clip-probe", 800, 1200, 320).setSurface(reader.surface).setFlags(flags).build()
        val display = device.javaClass.methods.first { it.name == "createVirtualDisplay" && it.parameterCount == 3 }
            .invoke(device, config, null, null) as android.hardware.display.VirtualDisplay
        val displayId = display.display.displayId
        println("display $displayId")

        fun sh(cmd: String) = Runtime.getRuntime().exec(arrayOf("sh", "-c", cmd)).waitFor()
        sh("am start --display $displayId -n dev.nearside/.helper.probe.KeyTestActivity")
        Thread.sleep(2500)

        val clipboard = Class.forName("android.content.IClipboard\$Stub").getMethod("asInterface", IBinder::class.java)
            .invoke(null, Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java).invoke(null, "clipboard"))!!
        val set = clipboard.javaClass.methods.first { it.name == "setPrimaryClip" }
        val get = clipboard.javaClass.methods.first { it.name == "getPrimaryClip" }
        println("set: " + runCatching {
            set.invoke(clipboard, ClipData.newPlainText("p", "fromMac"), "com.android.shell", null, 0, deviceId); "ok"
        }.getOrElse { "${it.cause ?: it}" })
        sh("input -d $displayId keycombination KEYCODE_CTRL_LEFT KEYCODE_V")
        Thread.sleep(800)
        sh("input -d $displayId text Typed")
        sh("input -d $displayId keycombination KEYCODE_CTRL_LEFT KEYCODE_A")
        sh("input -d $displayId keycombination KEYCODE_CTRL_LEFT KEYCODE_C")
        Thread.sleep(800)
        val clip = runCatching { get.invoke(clipboard, "com.android.shell", null, 0, deviceId) as ClipData? }
            .getOrElse { println("get failed: ${it.cause ?: it}"); null }
        println("device clip after app copy: ${clip?.getItemAt(0)?.text}")
        val main = runCatching { get.invoke(clipboard, "com.android.shell", null, 0, 0) as ClipData? }.getOrNull()
        println("phone clip: ${main?.getItemAt(0)?.text}")
        display.release()
        device.javaClass.getMethod("close").invoke(device)
        println("done")
        System.exit(0)
    }
}
