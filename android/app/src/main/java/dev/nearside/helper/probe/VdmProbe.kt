// Probe (throwaway): can phone-app windows live on a VirtualDevice instead of plain virtual
// displays? Runs every check the move depends on and prints one "RESULT" line per check.
// Creates a shell-owned app-streaming companion association first and removes it at the end.
//   app_process / dev.nearside.helper.probe.VdmProbe [apps|input|audio|wake|clip|all]
package dev.nearside.helper.probe

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.Context
import android.graphics.PixelFormat
import android.hardware.display.VirtualDisplay
import android.hardware.display.VirtualDisplayConfig
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import dev.nearside.helper.FakeContext
import dev.nearside.helper.Workarounds
import dev.nearside.helper.display.Hidden
import java.util.concurrent.Executors

@SuppressLint("PrivateApi", "WrongConstant", "DiscouragedPrivateApi")
object VdmProbe {
    private const val W = 1080
    private const val H = 2160
    private const val DPI = 420
    private const val MAC = "02:00:00:a7:00:02"
    private val executor = Executors.newSingleThreadExecutor()

    private fun result(key: String, value: Any?) = println("RESULT $key: $value")
    private fun sh(cmd: String): String {
        val p = Runtime.getRuntime().exec(arrayOf("sh", "-c", cmd))
        val out = p.inputStream.bufferedReader().readText() + p.errorStream.bufferedReader().readText()
        p.waitFor()
        return out
    }
    private fun service(name: String, stub: String): Any =
        Class.forName("$stub\$Stub").getMethod("asInterface", IBinder::class.java)
            .invoke(null, Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java).invoke(null, name))!!
    private fun call(o: Any, name: String, vararg a: Any?): Any? =
        o.javaClass.methods.first { it.name == name && it.parameterCount == a.size }.invoke(o, *a)
    private fun const(cls: String, name: String): Any = Class.forName(cls).getField(name).get(null)!!
    private fun build(cls: String, vararg ctor: Any?, setup: (Any) -> Unit = {}): Any {
        val b = Class.forName("$cls\$Builder").constructors.first { it.parameterCount == ctor.size }.newInstance(*ctor)
        setup(b)
        return call(b, "build")!!
    }

    // Frames: brightness of the newest one, sampled.
    @Volatile private var frames = 0
    @Volatile private var luma = 0
    private fun meanLuma(reader: ImageReader) {
        val image = reader.acquireLatestImage() ?: return
        try {
            val plane = image.planes[0]
            val buf = plane.buffer
            var sum = 0L; var n = 0
            for (y in 0 until image.height step image.height / 40) for (x in 0 until image.width step image.width / 20) {
                val i = y * plane.rowStride + x * plane.pixelStride
                sum += maxOf(buf.get(i).toInt() and 0xff, buf.get(i + 1).toInt() and 0xff, buf.get(i + 2).toInt() and 0xff); n++
            }
            luma = (sum / n).toInt()
            frames++
        } finally { image.close() }
    }

    @JvmStatic
    fun main(args: Array<String>) {
        Looper.prepareMainLooper()
        Workarounds.apply()
        val what = args.getOrElse(0) { "all" }
        sh("cmd companiondevice associate 0 com.android.shell $MAC android.app.role.COMPANION_DEVICE_APP_STREAMING")
        val association = Regex("mId=(\\d+), mUserId=0, mPackageName='com.android.shell'").find(sh("cmd companiondevice list 0"))
            ?.groupValues?.get(1)?.toInt()
        result("association", association)
        if (association == null) return
        try {
            run(association, what)
        } catch (t: Throwable) {
            result("aborted", "${t.cause ?: t}")
        } finally {
            println(sh("cmd companiondevice disassociate 0 com.android.shell $MAC").trim().ifEmpty { "association removed" })
            System.exit(0)
        }
    }

    private fun run(association: Int, what: String) {
        // The device: always unlocked (its own lock state, independent of the phone's).
        val vdm = Class.forName("android.companion.virtual.VirtualDeviceManager")
            .getDeclaredConstructor(Class.forName("android.companion.virtual.IVirtualDeviceManager"), Context::class.java)
            .apply { isAccessible = true }.newInstance(service("virtualdevice", "android.companion.virtual.IVirtualDeviceManager"), FakeContext.instance)
        val params = build("android.companion.virtual.VirtualDeviceParams") { b ->
            runCatching { call(b, "setLockState", const("android.companion.virtual.VirtualDeviceParams", "LOCK_STATE_ALWAYS_UNLOCKED")) }
                .onFailure { result("setLockState", "${it.cause ?: it}") }
            runCatching { call(b, "setName", "Nearside") }
        }
        val device = call(vdm, "createVirtualDevice", association, params)!!
        val deviceId = call(device, "getDeviceId") as Int
        result("device", deviceId)

        // The display, with the flags the plain displays use.
        val thread = HandlerThread("frames").apply { start() }
        val reader = ImageReader.newInstance(W, H, PixelFormat.RGBA_8888, 3)
        reader.setOnImageAvailableListener({ meanLuma(it) }, Handler(thread.looper))
        val flags = (1 shl 0) or (1 shl 3) or (1 shl 6) or (1 shl 10) or (1 shl 11) or (1 shl 12) or (1 shl 13) or (1 shl 14)
        val display = try {
            call(device, "createVirtualDisplay",
                VirtualDisplayConfig.Builder("nearside-vdm", W, H, DPI).setSurface(reader.surface).setFlags(flags).build(), executor, null)
                as VirtualDisplay
        } catch (t: Throwable) {
            result("display (full flags)", "${t.cause ?: t}")
            call(device, "createVirtualDisplay",
                VirtualDisplayConfig.Builder("nearside-vdm", W, H, DPI).setSurface(reader.surface)
                    .setFlags((1 shl 3) or (1 shl 6) or (1 shl 10) or (1 shl 14)).build(), executor, null) as VirtualDisplay
        }
        val displayId = display.display.displayId
        result("display", "$displayId flags=0x${Integer.toHexString(display.display.flags)}")
        result("phone locked", sh("dumpsys window | grep -m1 isKeyguardShowing").trim())
        val wake = Hidden.keepAwake(displayId, "Nearside:vdm-probe")
        result("wake lock", wake != null)
        Hidden.hideImeOn(displayId)

        if (what == "all" || what == "apps") apps(displayId)
        if (what == "all" || what == "input") input(device, displayId)
        if (what == "all" || what == "clip") clip(displayId, deviceId)
        if (what == "all" || what == "audio") audio(device, display, displayId)
        if (what == "all" || what == "wake") wake(displayId)

        runCatching { wake?.release() }
        Hidden.rootTasks().filter { it.displayId == displayId }.forEach { Hidden.moveTask(it.taskId, 0, onTop = false) }
        display.release()
        call(device, "close")
    }

    // MARK: Apps: launch each, check it lands here, is visible and draws (not black).

    private fun apps(displayId: Int) {
        val apps = listOf("com.android.chrome", "com.google.android.apps.messaging", "com.google.android.apps.maps",
            "com.google.android.youtube", "com.google.android.gm", "com.spotify.music", "com.whatsapp",
            "dk.nordea.mobilebank", "com.android.settings", "com.google.android.apps.photos", "com.instagram.android")
        var ok = 0
        for (pkg in apps) {
            val component = sh("cmd package resolve-activity --brief -c android.intent.category.LAUNCHER -a android.intent.action.MAIN $pkg")
                .lines().lastOrNull { '/' in it }?.trim()
            val before = frames
            val out = sh("am start --display $displayId -n '$component'")
            Thread.sleep(4500)
            val task = Hidden.rootTasks().firstOrNull { it.packageName == pkg }
            val here = task?.displayId == displayId
            val drew = frames - before
            val pass = here && task?.visible == true && drew > 0
            if (pass) ok++
            result("app $pkg", "onDisplay=$here visible=${task?.visible} frames=$drew luma=$luma" +
                (if (!here) " (task on ${task?.displayId}; am: ${out.lines().firstOrNull { "Error" in it || "Warning" in it }})" else ""))
            task?.let { Hidden.moveTask(it.taskId, 0, onTop = false) }
            Thread.sleep(800)
        }
        result("apps summary", "$ok/${apps.size} opened, visible and drawing on the virtual device's display")
    }

    // MARK: Input: our injection (touch + UHID keys) and the VDM's own input devices.

    private fun keyTestText(): String =
        Regex("text=\"(.*)\"").findAll(sh("logcat -d -s KeyTest")).lastOrNull()?.groupValues?.get(1) ?: "<none>"

    private fun input(device: Any, displayId: Int) {
        sh("logcat -c")
        sh("am start --activity-clear-task --display $displayId -n dev.nearside/.helper.probe.KeyTestActivity")
        Thread.sleep(2500)

        // 1. Injected touch, synchronous so failures show (mode 2 = WAIT_FOR_FINISH).
        val im = Class.forName("android.hardware.input.InputManagerGlobal").getMethod("getInstance").invoke(null)!!
        val inject = im.javaClass.getMethod("injectInputEvent", android.view.InputEvent::class.java, Int::class.java)
        val props = arrayOf(MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER })
        val coords = arrayOf(MotionEvent.PointerCoords().apply { x = W / 2f; y = H / 3f; pressure = 1f; size = 1f })
        val t = SystemClock.uptimeMillis()
        val results = listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP).map { action ->
            val e = MotionEvent.obtain(t, SystemClock.uptimeMillis(), action, 1, props, coords, 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
            android.view.InputEvent::class.java.getMethod("setDisplayId", Int::class.java).invoke(e, displayId)
            inject.invoke(im, e, 2) as Boolean
        }
        result("injected touch (sync)", results)

        // 2. Injected key (as today's fallback): reaches the app?
        val k = KeyEvent(t, t, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_X, 0)
        android.view.InputEvent::class.java.getMethod("setDisplayId", Int::class.java).invoke(k, displayId)
        inject.invoke(im, k, 2)
        val ku = KeyEvent(t, t, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_X, 0)
        android.view.InputEvent::class.java.getMethod("setDisplayId", Int::class.java).invoke(ku, displayId)
        inject.invoke(im, ku, 2)
        Thread.sleep(500)
        result("injected key x", keyTestText())

        // 3. The VDM's own keyboard with a Danish layout: does keycode SEMICOLON type æ?
        runCatching {
            val config = build("android.hardware.input.VirtualKeyboardConfig") { b ->
                call(b, "setInputDeviceName", "Nearside VDM Keyboard")
                call(b, "setVendorId", 0x18d1); call(b, "setProductId", 0x0002)
                call(b, "setAssociatedDisplayId", displayId)
                call(b, "setLanguageTag", "da-DK"); call(b, "setLayoutType", "qwerty")
            }
            val keyboard = call(device, "createVirtualKeyboard", config)!!
            Thread.sleep(800)
            for (code in listOf(KeyEvent.KEYCODE_SEMICOLON, KeyEvent.KEYCODE_APOSTROPHE, KeyEvent.KEYCODE_LEFT_BRACKET)) {
                for (action in listOf("ACTION_DOWN", "ACTION_UP")) {
                    val ev = build("android.hardware.input.VirtualKeyEvent") { b ->
                        call(b, "setKeyCode", code)
                        call(b, "setAction", const("android.hardware.input.VirtualKeyEvent", action))
                    }
                    call(keyboard, "sendKeyEvent", ev)
                }
            }
            Thread.sleep(600)
            result("VDM keyboard (da-DK) æøå keys", keyTestText())
            val dev = InputDevice.getDeviceIds().map { InputDevice.getDevice(it) }.firstOrNull { it?.name == "Nearside VDM Keyboard" }
            result("VDM keyboard device", "${dev?.id} kcm74=${dev?.keyCharacterMap?.get(74, 0)?.toChar()}")
            // Its automatic layout ignores the hint; our override (as with UHID), then again.
            val danish = Hidden.keyboardLayouts.first { it.label == "Danish" }
            result("VDM keyboard Danish override", dev?.let { Hidden.setKeyboardLayout(it, danish.descriptor) })
            Thread.sleep(800)
            for (code in listOf(KeyEvent.KEYCODE_SEMICOLON, KeyEvent.KEYCODE_APOSTROPHE, KeyEvent.KEYCODE_LEFT_BRACKET)) {
                for (action in listOf("ACTION_DOWN", "ACTION_UP")) {
                    call(keyboard, "sendKeyEvent", build("android.hardware.input.VirtualKeyEvent") { b ->
                        call(b, "setKeyCode", code)
                        call(b, "setAction", const("android.hardware.input.VirtualKeyEvent", action))
                    })
                }
            }
            Thread.sleep(600)
            result("VDM keyboard after override", keyTestText())
            result("phone keyboard config", Regex("(-keyb|qwerty|nokeys)[^ ]*").find(sh("dumpsys window | grep -m1 mGlobalConfiguration"))?.value)
            call(keyboard, "close")
        }.onFailure { result("VDM keyboard", "${it.cause ?: it}") }

        // 4. The VDM's own touchscreen: a tap.
        runCatching {
            val config = build("android.hardware.input.VirtualTouchscreenConfig", W, H) { b ->
                call(b, "setInputDeviceName", "Nearside VDM Touch")
                call(b, "setVendorId", 0x18d1); call(b, "setProductId", 0x0003)
                call(b, "setAssociatedDisplayId", displayId)
            }
            val touch = call(device, "createVirtualTouchscreen", config)!!
            Thread.sleep(500)
            val sent = listOf("ACTION_DOWN", "ACTION_UP").map { action ->
                val ev = build("android.hardware.input.VirtualTouchEvent") { b ->
                    call(b, "setX", W / 2f); call(b, "setY", H / 3f); call(b, "setPointerId", 0)
                    call(b, "setToolType", const("android.hardware.input.VirtualTouchEvent", "TOOL_TYPE_FINGER"))
                    call(b, "setAction", const("android.hardware.input.VirtualTouchEvent", action))
                    call(b, "setPressure", if (action == "ACTION_DOWN") 255f else 0f)
                    call(b, "setMajorAxisSize", 1f)
                }
                call(touch, "sendTouchEvent", ev) as? Boolean
            }
            result("VDM touchscreen tap", sent)
            call(touch, "close")
        }.onFailure { result("VDM touchscreen", "${it.cause ?: it}") }
        Hidden.rootTasks().filter { it.displayId == displayId }.forEach { Hidden.moveTask(it.taskId, 0, onTop = false) }
    }

    // MARK: Clipboard: both directions on the device's silo, phone locked.

    private fun clip(displayId: Int, deviceId: Int) {
        sh("logcat -c")
        sh("am start --activity-clear-task --display $displayId -n dev.nearside/.helper.probe.KeyTestActivity")
        Thread.sleep(2500)
        val clipboard = service("clipboard", "android.content.IClipboard")
        val set = clipboard.javaClass.methods.first { it.name == "setPrimaryClip" }
        val get = clipboard.javaClass.methods.first { it.name == "getPrimaryClip" }
        set.invoke(clipboard, ClipData.newPlainText("p", "fromMac"), "com.android.shell", null, 0, deviceId)
        sh("input -d $displayId keycombination KEYCODE_CTRL_LEFT KEYCODE_V")
        Thread.sleep(700)
        result("paste into app (device clipboard)", keyTestText())
        sh("input -d $displayId text Copied")
        sh("input -d $displayId keycombination KEYCODE_CTRL_LEFT KEYCODE_A")
        sh("input -d $displayId keycombination KEYCODE_CTRL_LEFT KEYCODE_C")
        Thread.sleep(700)
        val clip = runCatching { get.invoke(clipboard, "com.android.shell", null, 0, deviceId) as ClipData? }.getOrNull()
        result("copy from app (device clipboard)", clip?.getItemAt(0)?.text)
        Hidden.rootTasks().filter { it.displayId == displayId }.forEach { Hidden.moveTask(it.taskId, 0, onTop = false) }
    }

    // MARK: Audio: the VDM's audio capture of apps on its display; is the phone silent?

    private fun audio(device: Any, display: VirtualDisplay, displayId: Int) {
        runCatching {
            val audioDevice = call(device, "createVirtualAudioDevice", display, executor, null)!!
            val format = android.media.AudioFormat.Builder().setSampleRate(48000).setEncoding(android.media.AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(android.media.AudioFormat.CHANNEL_IN_MONO).build()
            val capture = call(audioDevice, "startAudioCapture", format)!!
            call(capture, "startRecording")
            sh("logcat -c")
            sh("am start --activity-clear-task --display $displayId -n dev.nearside/.helper.probe.KeyTestActivity --ei tone 6")
            val buf = ShortArray(4800)
            val readShorts = capture.javaClass.methods.first { it.name == "read" && it.parameterTypes.firstOrNull() == ShortArray::class.java && it.parameterCount == 3 }
            var peak = 0; var sumSq = 0.0; var n = 0L
            val until = SystemClock.uptimeMillis() + 5000
            var phoneOut = ""
            while (SystemClock.uptimeMillis() < until) {
                val read = readShorts.invoke(capture, buf, 0, buf.size) as Int
                for (i in 0 until maxOf(read, 0)) { val v = buf[i].toInt(); peak = maxOf(peak, kotlin.math.abs(v)); sumSq += v.toDouble() * v; n++ }
                if (phoneOut.isEmpty() && SystemClock.uptimeMillis() > until - 2500) {
                    phoneOut = sh("dumpsys audio | grep -A1 -iE 'usage=USAGE_MEDIA.*dev.nearside|uid/pid:10353' | head -4").trim()
                }
            }
            result("VDM audio capture", "samples=$n peak=$peak rms=${if (n > 0) Math.sqrt(sumSq / n).toInt() else 0} (tone amplitude 12000)")
            result("tone player routing", phoneOut.replace('\n', ' ').take(300))
            result("speaker output", sh("dumpsys media.audio_flinger | grep -iE 'Standby:|Output devices' | head -6").replace('\n', ' '))
            call(capture, "stop")
            call(audioDevice, "close")
        }.onFailure { result("VDM audio", "${it.cause ?: it}") }
        Hidden.rootTasks().filter { it.displayId == displayId }.forEach { Hidden.moveTask(it.taskId, 0, onTop = false) }
    }

    // MARK: Wake: does the display keep drawing past the phone's screen timeout?

    private fun wake(displayId: Int) {
        sh("am start --display $displayId -n com.google.android.youtube/com.google.android.youtube.app.honeycomb.Shell\\\$HomeActivity")
        Thread.sleep(3000)
        val timeout = sh("settings get system screen_off_timeout").trim().toLongOrNull() ?: 60000
        result("wake test", "idle for ${(timeout + 30000) / 1000} s (screen timeout ${timeout / 1000} s)")
        Thread.sleep(timeout + 30000)
        val before = frames
        val state = sh("dumpsys display | grep -A3 'mDisplayId=$displayId' | grep -oE 'state [A-Z]+|mState=[A-Z]+' | head -2").trim()
        sh("input -d $displayId swipe 540 1500 540 600 200")
        Thread.sleep(2000)
        result("after timeout", "display ${state.replace('\n', ' ')}; frames after a swipe: ${frames - before}")
        Hidden.rootTasks().filter { it.displayId == displayId }.forEach { Hidden.moveTask(it.taskId, 0, onTop = false) }
    }
}
