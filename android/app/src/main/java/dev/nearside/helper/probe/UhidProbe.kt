// Gate A probe (throwaway): a UHID keyboard bound to one display, typing a word after a delay.
// Adapted from scrcpy (Apache-2.0, Genymobile): server/.../control/UhidManager.java,
// HID keyboard report descriptor from app/src/hid/hid_keyboard.c.
//   app_process / dev.nearside.helper.probe.UhidProbe <displayId> <delaySec> <word>
package dev.nearside.helper.probe

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.display.DisplayManager
import android.os.IBinder
import android.os.Looper
import android.system.Os
import android.system.OsConstants
import dev.nearside.helper.FakeContext
import dev.nearside.helper.Workarounds
import java.nio.ByteBuffer
import java.nio.ByteOrder

@SuppressLint("PrivateApi", "DiscouragedPrivateApi")
object UhidProbe {
    private const val EVENT_SIZE = 4380
    private val DESCRIPTOR = byteArrayOf(
        0x05, 0x01, 0x09, 0x06, 0xA1.toByte(), 0x01, 0x05, 0x07, 0x19, 0xE0.toByte(), 0x29, 0xE7.toByte(),
        0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95.toByte(), 0x08, 0x81.toByte(), 0x02, 0x75, 0x08,
        0x95.toByte(), 0x01, 0x81.toByte(), 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x75, 0x01,
        0x95.toByte(), 0x05, 0x91.toByte(), 0x02, 0x75, 0x03, 0x95.toByte(), 0x01, 0x91.toByte(), 0x01,
        0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x15, 0x00, 0x25, 0x65, 0x75, 0x08, 0x95.toByte(), 0x06,
        0x81.toByte(), 0x00, 0xC0.toByte(),
    )

    @JvmStatic
    fun main(args: Array<String>) {
        Looper.prepareMainLooper()
        Workarounds.apply()
        val displayId = args[0].toInt()
        val delay = args.getOrElse(1) { "5" }.toLong()
        val word = args.getOrElse(2) { "hello" }
        val phys = "nearside:${Os.getpid()}"

        val fd = Os.open("/dev/uhid", OsConstants.O_RDWR, 0)
        val create = ByteBuffer.allocate(EVENT_SIZE).order(ByteOrder.nativeOrder())
        create.putInt(11) // UHID_CREATE2
        create.put("Nearside Keyboard".toByteArray().copyOf(128))
        create.put(phys.toByteArray().copyOf(64))
        create.put(ByteArray(64)) // uniq
        create.putShort(DESCRIPTOR.size.toShort())
        create.putShort(0x06) // BUS_VIRTUAL
        create.putInt(0x18d1); create.putInt(0x0001); create.putInt(0); create.putInt(0)
        create.put(DESCRIPTOR)
        Os.write(fd, create.array(), 0, EVENT_SIZE)
        println("uhid created phys=$phys")

        // Bind the keyboard to the display.
        val dmCtor = DisplayManager::class.java.getDeclaredConstructor(Context::class.java).apply { isAccessible = true }
        val display = (dmCtor.newInstance(FakeContext.instance) as DisplayManager).getDisplay(displayId)
        val uniqueId = display.javaClass.getMethod("getUniqueId").invoke(display) as String
        val binder = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java)
            .invoke(null, "input") as IBinder
        val im = Class.forName("android.hardware.input.IInputManager\$Stub").getMethod("asInterface", IBinder::class.java)
            .invoke(null, binder)!!
        im.javaClass.getMethod("addUniqueIdAssociationByPort", String::class.java, String::class.java)
            .invoke(im, phys, uniqueId)
        println("associated with $uniqueId")

        Thread.sleep(delay * 1000)
        for (c in word) {
            val usage = when (c) {
                in 'a'..'z' -> 0x04 + (c - 'a')
                ' ' -> 0x2c
                else -> continue
            }
            report(fd, usage)
            Thread.sleep(30)
            report(fd, 0)
            Thread.sleep(30)
        }
        println("typed '$word'")
        Thread.sleep(2000)
        val destroy = ByteBuffer.allocate(EVENT_SIZE).order(ByteOrder.nativeOrder()).putInt(1) // UHID_DESTROY
        Os.write(fd, destroy.array(), 0, EVENT_SIZE)
        Os.close(fd)
        println("done")
    }

    private fun report(fd: java.io.FileDescriptor, usage: Int) {
        val e = ByteBuffer.allocate(EVENT_SIZE).order(ByteOrder.nativeOrder())
        e.putInt(12) // UHID_INPUT2
        e.putShort(8)
        e.put(byteArrayOf(0, 0, usage.toByte(), 0, 0, 0, 0, 0))
        Os.write(fd, e.array(), 0, EVENT_SIZE)
    }
}
