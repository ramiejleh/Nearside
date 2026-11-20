// Input-milestone probe (throwaway): what keyboard layout a UHID keyboard gets, whether the shell
// can change it, and which characters its key map can produce.
//   app_process / dev.nearside.helper.probe.KeyboardProbe [layoutLabel]
package dev.nearside.helper.probe

import android.annotation.SuppressLint
import android.os.IBinder
import android.os.Looper
import android.system.Os
import android.system.OsConstants
import android.view.InputDevice
import android.view.KeyCharacterMap
import dev.nearside.helper.Workarounds
import java.nio.ByteBuffer
import java.nio.ByteOrder

@SuppressLint("PrivateApi", "DiscouragedPrivateApi")
object KeyboardProbe {
    @JvmStatic
    fun main(args: Array<String>) {
        Looper.prepareMainLooper()
        Workarounds.apply()
        val want = args.getOrElse(0) { "Danish" }
        if (want == "type") {
            // type <deviceName prefix|virtual> <displayId> <text>: as Keyboard.type, from outside.
            val d = InputDevice.getDeviceIds().map { InputDevice.getDevice(it)!! }.firstOrNull { it.name.startsWith(args[1]) }
            val id = d?.id ?: KeyCharacterMap.VIRTUAL_KEYBOARD
            val kcm = KeyCharacterMap.load(id)
            val events = kcm.getEvents(args[3].toCharArray()) ?: return println("no events")
            val im = Class.forName("android.hardware.input.InputManagerGlobal").getMethod("getInstance").invoke(null)!!
            val inject = im.javaClass.getMethod("injectInputEvent", android.view.InputEvent::class.java, Int::class.java)
            val setDisplay = android.view.InputEvent::class.java.getMethod("setDisplayId", Int::class.java)
            for (e in events) {
                val now = android.os.SystemClock.uptimeMillis()
                val flags = args.getOrNull(4)?.toInt() ?: 0
                val k = android.view.KeyEvent(now, now, e.action, e.keyCode, 0, e.metaState, id, 0, flags, InputDevice.SOURCE_KEYBOARD)
                setDisplay.invoke(k, args[2].toInt())
                println("${e.keyCode}/${Integer.toHexString(e.metaState)} ${if (e.action == 0) "down" else "up"} -> ${inject.invoke(im, k, 0)}")
            }
            return
        }
        if (want == "subtype") {
            // subtype <deviceName prefix> [layout label]: the layout Android gives the device for the
            // current IME + subtype (what IMEs see), and optionally set it there.
            val d = InputDevice.getDeviceIds().map { InputDevice.getDevice(it)!! }.first { it.name.startsWith(args[1]) }
            val im = Class.forName("android.hardware.input.IInputManager\$Stub").getMethod("asInterface", IBinder::class.java)
                .invoke(null, Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java).invoke(null, "input") as IBinder)!!
            val identifier = d.javaClass.getMethod("getIdentifier").invoke(d)!!
            val imm = dev.nearside.helper.FakeContext.instance.getSystemService(android.content.Context.INPUT_METHOD_SERVICE)
                as android.view.inputmethod.InputMethodManager
            val info = imm.inputMethodList.first { it.id.startsWith("com.google.android.inputmethod.latin") }
            val subtype = runCatching { imm.currentInputMethodSubtype }.getOrNull()
            println("ime ${info.id} subtype ${subtype?.languageTag} ${subtype?.mode} hint=${runCatching { subtype?.physicalKeyboardHintLanguageTag }.getOrNull()}")
            val get = im.javaClass.methods.first { it.name == "getKeyboardLayoutForInputDevice" }
            println("layout for subtype: " + runCatching { get.invoke(im, identifier, 0, info, subtype) }.getOrElse { "${it.cause ?: it}" })
            args.getOrNull(2)?.let { label ->
                @Suppress("UNCHECKED_CAST")
                val all = im.javaClass.getMethod("getKeyboardLayouts").invoke(im) as Array<Any>
                val l = all.first { it.javaClass.getMethod("getLabel").invoke(it) == label }
                val desc = l.javaClass.getMethod("getDescriptor").invoke(l) as String
                val set = im.javaClass.methods.first { it.name == "setKeyboardLayoutForInputDevice" }
                println("set: " + runCatching { set.invoke(im, identifier, 0, info, subtype, desc); "ok" }.getOrElse { "${it.cause ?: it}" })
                println("layout for subtype now: " + runCatching { get.invoke(im, identifier, 0, info, subtype) }.getOrElse { "${it.cause ?: it}" })
            }
            return
        }
        if (want == "check") {
            // An existing keyboard, from a fresh process: which characters does its map give?
            val ids = InputDevice.getDeviceIds()
            ids.map { InputDevice.getDevice(it)!! }.filter { it.name.startsWith(args[1]) }.forEach { d ->
                val kcm = KeyCharacterMap.load(d.id)
                println("${d.id} ${d.name}: æ=${kcm.getEvents(charArrayOf('æ'))?.size} code39+0=${kcm.get(39, 0).toChar()} code74=${kcm.get(74, 0).toChar()}")
            }
            return
        }
        val binder = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java)
            .invoke(null, "input") as IBinder
        val im = Class.forName("android.hardware.input.IInputManager\$Stub").getMethod("asInterface", IBinder::class.java)
            .invoke(null, binder)!!
        im.javaClass.methods.filter { "ayout" in it.name }.forEach { m ->
            println("method ${m.name}(${m.parameterTypes.joinToString { it.simpleName }})")
        }

        val fd = Os.open("/dev/uhid", OsConstants.O_RDWR, 0)
        val create = ByteBuffer.allocate(4380).order(ByteOrder.nativeOrder())
        create.putInt(11)
        create.put("Nearside Probe Keyboard".toByteArray().copyOf(128))
        create.put("nearside:probe".toByteArray().copyOf(64))
        create.put(ByteArray(64))
        val desc = byteArrayOf(0x05, 0x01, 0x09, 0x06, 0xA1.toByte(), 0x01, 0x05, 0x07, 0x19, 0xE0.toByte(), 0x29, 0xE7.toByte(),
            0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95.toByte(), 0x08, 0x81.toByte(), 0x02, 0x75, 0x08,
            0x95.toByte(), 0x01, 0x81.toByte(), 0x01, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x15, 0x00, 0x25, 0x65,
            0x75, 0x08, 0x95.toByte(), 0x06, 0x81.toByte(), 0x00, 0xC0.toByte())
        create.putShort(desc.size.toShort()); create.putShort(0x06)
        create.putInt(0x18d1); create.putInt(0x0001); create.putInt(0); create.putInt(0)
        create.put(desc)
        Os.write(fd, create.array(), 0, 4380)
        Thread.sleep(1500)

        val ids = im.javaClass.getMethod("getInputDeviceIds").invoke(im) as IntArray
        val dev = ids.map { im.javaClass.getMethod("getInputDevice", Int::class.java).invoke(im, it) as InputDevice }
            .firstOrNull { it.name == "Nearside Probe Keyboard" }
        println("device ${dev?.id} ${dev?.descriptor} keyboardType=${dev?.keyboardType}")
        if (dev == null) return
        val identifier = dev.javaClass.getMethod("getIdentifier").invoke(dev)!!

        fun show(label: String) {
            val kcm = KeyCharacterMap.load(dev.id)
            val probe = "a@{[|æøåé€~"
            println("$label: " + probe.map { c ->
                val ev = kcm.getEvents(charArrayOf(c))
                "$c=" + (ev?.joinToString("+") { "${it.keyCode}/${Integer.toHexString(it.metaState)}${if (it.action == 0) "↓" else "↑"}" }?.let { "${ev.size / 2}keys" } ?: "none")
            }.joinToString(" "))
        }
        show("initial")

        @Suppress("UNCHECKED_CAST")
        val layouts = runCatching { im.javaClass.getMethod("getKeyboardLayouts").invoke(im) as Array<Any> }.getOrDefault(emptyArray())
        println("${layouts.size} layouts")
        val match = layouts.firstOrNull { it.javaClass.getMethod("getLabel").invoke(it) == want }
        val descriptor = match?.javaClass?.getMethod("getDescriptor")?.invoke(match) as String?
        println("$want -> $descriptor")
        layouts.take(80).joinToString { it.javaClass.getMethod("getLabel").invoke(it) as String }.let { println("labels: $it") }
        if (descriptor != null) {
            val set = im.javaClass.methods.firstOrNull { it.name == "setKeyboardLayoutOverrideForInputDevice" }
            if (set != null) {
                println("override: " + runCatching { set.invoke(im, identifier, descriptor); "ok" }.getOrElse { "${it.cause ?: it}" })
                Thread.sleep(1500)
                show("after override")
            } else println("no override method")
        }
        val destroy = ByteBuffer.allocate(4380).order(ByteOrder.nativeOrder()).putInt(1)
        Os.write(fd, destroy.array(), 0, 4380)
        Os.close(fd)
    }
}
