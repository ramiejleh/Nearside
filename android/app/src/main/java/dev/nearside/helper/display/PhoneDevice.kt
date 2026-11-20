// The Android "virtual device" every phone-app window lives on (Android's app-streaming framework,
// VirtualDeviceManager, as the shell). Over plain virtual displays it gives the windows:
//  - their own clipboard, which works while the phone is locked (Android refuses every read of
//    the phone's clipboard while locked, so copying from a window couldn't reach the Mac);
//  - their own keyboard (VirtualKeyboard), whose keys keep its layout;
//  - an always-unlocked lock state, independent of the phone's.
// It needs a companion association owned by the shell (app-streaming profile), created once with
// `cmd companiondevice associate` and kept. If any of it fails, sessions fall back to plain
// displays. Measured in vault/phone-apps-plan.md ("VirtualDevice wider spike").
package dev.nearside.helper.display

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.ContextWrapper
import android.hardware.display.VirtualDisplay
import android.hardware.display.VirtualDisplayConfig
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.view.Surface
import dev.nearside.helper.FakeContext
import dev.nearside.helper.Log
import java.util.concurrent.Executors

@SuppressLint("PrivateApi", "DiscouragedPrivateApi", "WrongConstant")
object PhoneDevice {
    /** A locally administered placeholder: app-streaming associations don't name real hardware. */
    private const val MAC = "02:00:00:a7:00:01"
    private const val PROFILE = "android.app.role.COMPANION_DEVICE_APP_STREAMING"

    private val executor = Executors.newSingleThreadExecutor { Thread(it, "virtual-device") }
    private var device: Any? = null
    private var users = 0
    @Volatile var deviceId = Context.DEVICE_ID_DEFAULT
        private set

    /** Called with text an app on our displays copied (the Mac gets it). */
    @Volatile var onCopied: ((String) -> Unit)? = null

    private fun call(o: Any, name: String, vararg a: Any?): Any? =
        o.javaClass.methods.first { it.name == name && it.parameterCount == a.size }.invoke(o, *a)

    private fun sh(cmd: String): String = runCatching {
        val p = Runtime.getRuntime().exec(arrayOf("sh", "-c", cmd))
        (p.inputStream.bufferedReader().readText() + p.errorStream.bufferedReader().readText()).also { p.waitFor() }
    }.getOrDefault("")

    private fun association(): Int? {
        fun find() = Regex("mId=(\\d+), mUserId=0, mPackageName='com.android.shell'[^\\n]*$PROFILE")
            .find(sh("cmd companiondevice list 0"))?.groupValues?.get(1)?.toInt()
        find()?.let { return it }
        Log.d("virtual device: creating the companion association")
        sh("cmd companiondevice associate 0 com.android.shell $MAC $PROFILE")
        return find()
    }

    /** Takes a reference on the device, creating it if needed; false: use plain displays. */
    @Synchronized
    fun acquire(): Boolean {
        if (device == null) device = runCatching { create() }
            .onFailure { Log.d("virtual device unavailable (${it.cause ?: it}); using plain displays") }.getOrNull()
        if (device != null) users++
        return device != null
    }

    @Synchronized
    fun release() {
        if (device == null || --users > 0) return
        clipboard?.removePrimaryClipChangedListener(clipListener)
        clipboard = null
        runCatching { call(device!!, "close") }
        device = null
        deviceId = Context.DEVICE_ID_DEFAULT
        Log.d("virtual device closed")
    }

    private fun create(): Any {
        val association = association() ?: error("no companion association")
        val binder = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java)
            .invoke(null, "virtualdevice") as IBinder
        val service = Class.forName("android.companion.virtual.IVirtualDeviceManager\$Stub")
            .getMethod("asInterface", IBinder::class.java).invoke(null, binder)
        // Built by hand: the system-service instance has no context as the shell.
        val vdm = Class.forName("android.companion.virtual.VirtualDeviceManager")
            .getDeclaredConstructor(Class.forName("android.companion.virtual.IVirtualDeviceManager"), Context::class.java)
            .apply { isAccessible = true }.newInstance(service, FakeContext.instance)
        val paramsClass = "android.companion.virtual.VirtualDeviceParams"
        val builder = Class.forName("$paramsClass\$Builder").getConstructor().newInstance()
        call(builder, "setLockState", Class.forName(paramsClass).getField("LOCK_STATE_ALWAYS_UNLOCKED").get(null))
        runCatching { call(builder, "setName", "Nearside") }
        val d = call(vdm, "createVirtualDevice", association, call(builder, "build"))!!
        deviceId = call(d, "getDeviceId") as Int
        Log.d("virtual device $deviceId (association $association)")
        watchClipboard()
        return d
    }

    @Synchronized
    fun createDisplay(name: String, w: Int, h: Int, dpi: Int, surface: Surface, flags: Int): VirtualDisplay? {
        val d = device ?: return null
        return runCatching {
            val config = VirtualDisplayConfig.Builder(name, w, h, dpi).setSurface(surface).setFlags(flags).build()
            call(d, "createVirtualDisplay", config, executor, null) as VirtualDisplay
        }.onFailure { Log.d("virtual device display failed: ${it.cause ?: it}") }.getOrNull()
    }

    /** A keyboard on [displayId]; its keys are read with its own layout (unlike injected keys). */
    @Synchronized
    fun createKeyboard(name: String, displayId: Int): Any? {
        val d = device ?: return null
        return runCatching {
            val builder = Class.forName("android.hardware.input.VirtualKeyboardConfig\$Builder").getConstructor().newInstance()
            call(builder, "setInputDeviceName", name)
            call(builder, "setVendorId", 0x18d1)
            call(builder, "setProductId", 0x4154)
            call(builder, "setAssociatedDisplayId", displayId)
            call(d, "createVirtualKeyboard", call(builder, "build"))
        }.onFailure { Log.d("virtual keyboard failed: ${it.cause ?: it}") }.getOrNull()
    }

    private val keyEventClass by lazy { Class.forName("android.hardware.input.VirtualKeyEvent") }
    private val keyDown by lazy { keyEventClass.getField("ACTION_DOWN").get(null) }
    private val keyUp by lazy { keyEventClass.getField("ACTION_UP").get(null) }

    fun sendKey(keyboard: Any, keyCode: Int, down: Boolean) {
        val builder = Class.forName("android.hardware.input.VirtualKeyEvent\$Builder").getConstructor().newInstance()
        call(builder, "setKeyCode", keyCode)
        call(builder, "setAction", if (down) keyDown else keyUp)
        call(keyboard, "sendKeyEvent", call(builder, "build"))
    }

    fun closeInput(input: Any) { runCatching { call(input, "close") } }

    // MARK: Clipboard

    /** The device's own clipboard: a context that says it's on the device. */
    private var clipboard: ClipboardManager? = null
    @Volatile private var lastSet: String? = null

    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener {
        val clip = clipboard?.primaryClip ?: return@OnPrimaryClipChangedListener
        if (clip.itemCount == 0) return@OnPrimaryClipChangedListener
        if (clip.description.extras?.getBoolean("android.content.extra.IS_SENSITIVE") == true) return@OnPrimaryClipChangedListener
        val text = clip.getItemAt(0).text?.toString() ?: return@OnPrimaryClipChangedListener
        if (text == lastSet) return@OnPrimaryClipChangedListener // ours (a paste from the Mac)
        lastSet = text // Android fires twice per copy
        Log.d("copied in a phone-app window (${text.length} chars)")
        onCopied?.invoke(text)
    }

    private fun watchClipboard() {
        val id = deviceId
        val context = object : ContextWrapper(FakeContext.instance) {
            override fun getDeviceId() = id
        }
        clipboard = runCatching {
            ClipboardManager::class.java.getDeclaredConstructor(Context::class.java, Handler::class.java)
                .apply { isAccessible = true }.newInstance(context, Handler(Looper.getMainLooper()))
        }.onFailure { Log.d("device clipboard unavailable: ${it.cause ?: it}") }.getOrNull()
        clipboard?.addPrimaryClipChangedListener(clipListener)
    }

    /** Sets the device's clipboard (no echo to the Mac); false: no device clipboard. */
    fun setClip(text: String): Boolean {
        val c = clipboard ?: return false
        lastSet = text
        return runCatching { c.setPrimaryClip(ClipData.newPlainText("Nearside", text)); true }
            .onFailure { Log.d("device clipboard set failed: ${it.cause ?: it}") }.getOrDefault(false)
    }

    fun getClip(): String? = runCatching { clipboard?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString() }.getOrNull()

    val hasClipboard get() = clipboard != null
}
