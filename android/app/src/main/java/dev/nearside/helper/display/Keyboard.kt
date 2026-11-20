// The Mac's keyboard on one phone-app display.
//
// The Mac decides *what* is typed (its own layout, dead keys and input methods, so what appears is
// what the Mac would type) and sends text; keys that aren't text (arrows, Return, shortcuts) come
// as key codes. Here the text is turned into the key presses that produce it, pressed on a keyboard
// tied to this display (so it counts as that display's hardware keyboard, not the phone's) with
// the Android layout matching the Mac's: the virtual device's VirtualKeyboard, or, without a
// virtual device, a UHID keyboard. Mac layouts and Android's PC-style
// layouts put symbols on different keys (Danish: @ { } [ ]), which is why positions aren't sent.
// What the layout can't produce directly is composed from its dead keys (é = ´ then e); the rest
// (emoji, CJK) is pasted through the virtual device's clipboard, which is put back afterwards.
// UHID setup adapted from scrcpy (Apache-2.0, Genymobile): server/.../control/UhidManager.java.
package dev.nearside.helper.display

import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import android.view.InputDevice
import android.view.KeyCharacterMap
import android.view.KeyEvent
import dev.nearside.helper.FakeContext
import dev.nearside.helper.Log
import java.io.FileDescriptor
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.text.Normalizer

/** The phone's clipboard, set up by the helper's main (which also keeps it from echoing to the Mac). */
object PhoneClipboard {
    @Volatile var set: ((String) -> Unit)? = null
    @Volatile var get: (() -> String?)? = null
}

class Keyboard(private val displayId: Int, sessionId: String, private val phone: PhoneDevice?) {
    private companion object {
        const val EVENT_SIZE = 4380 // sizeof(struct uhid_event)
        const val UHID_CREATE2 = 11
        const val UHID_DESTROY = 1
        const val UHID_INPUT2 = 12
        /** Android key code → HID keyboard usage (the inverse of Generic.kl and the kernel's table). */
        val HID_USAGES: Map<Int, Int> = HashMap<Int, Int>().apply {
            for (i in 0..25) put(KeyEvent.KEYCODE_A + i, 0x04 + i)
            for (i in 1..9) put(KeyEvent.KEYCODE_1 + i - 1, 0x1E + i - 1)
            put(KeyEvent.KEYCODE_0, 0x27)
            putAll(listOf(KeyEvent.KEYCODE_ENTER to 0x28, KeyEvent.KEYCODE_ESCAPE to 0x29, KeyEvent.KEYCODE_DEL to 0x2A,
                KeyEvent.KEYCODE_TAB to 0x2B, KeyEvent.KEYCODE_SPACE to 0x2C, KeyEvent.KEYCODE_MINUS to 0x2D,
                KeyEvent.KEYCODE_EQUALS to 0x2E, KeyEvent.KEYCODE_LEFT_BRACKET to 0x2F, KeyEvent.KEYCODE_RIGHT_BRACKET to 0x30,
                KeyEvent.KEYCODE_BACKSLASH to 0x31, KeyEvent.KEYCODE_SEMICOLON to 0x33, KeyEvent.KEYCODE_APOSTROPHE to 0x34,
                KeyEvent.KEYCODE_GRAVE to 0x35, KeyEvent.KEYCODE_COMMA to 0x36, KeyEvent.KEYCODE_PERIOD to 0x37,
                KeyEvent.KEYCODE_SLASH to 0x38, KeyEvent.KEYCODE_MOVE_HOME to 0x4A, KeyEvent.KEYCODE_PAGE_UP to 0x4B,
                KeyEvent.KEYCODE_FORWARD_DEL to 0x4C, KeyEvent.KEYCODE_MOVE_END to 0x4D, KeyEvent.KEYCODE_PAGE_DOWN to 0x4E,
                KeyEvent.KEYCODE_DPAD_RIGHT to 0x4F, KeyEvent.KEYCODE_DPAD_LEFT to 0x50, KeyEvent.KEYCODE_DPAD_DOWN to 0x51,
                KeyEvent.KEYCODE_DPAD_UP to 0x52, KeyEvent.KEYCODE_NUMPAD_ENTER to 0x58))
            for (i in 0..11) put(KeyEvent.KEYCODE_F1 + i, 0x3A + i)
        }
        // A boot keyboard: modifier byte, reserved byte, six keys (scrcpy's hid_keyboard.c).
        val DESCRIPTOR = byteArrayOf(
            0x05, 0x01, 0x09, 0x06, 0xA1.toByte(), 0x01, 0x05, 0x07, 0x19, 0xE0.toByte(), 0x29, 0xE7.toByte(),
            0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95.toByte(), 0x08, 0x81.toByte(), 0x02, 0x75, 0x08,
            0x95.toByte(), 0x01, 0x81.toByte(), 0x01, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x15, 0x00, 0x25, 0x65,
            0x75, 0x08, 0x95.toByte(), 0x06, 0x81.toByte(), 0x00, 0xC0.toByte(),
        )
        val CTRL = KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON
    }

    private val name = "Nearside Keyboard ${sessionId.take(8)}"
    private val port = "nearside:${sessionId.take(16)}"
    private var fd: FileDescriptor? = null
    /** The virtual device's keyboard; null: UHID ([fd]). */
    @Volatile private var virtualKeyboard: Any? = null
    @Volatile private var device: InputDevice? = null
    @Volatile private var kcm: KeyCharacterMap = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD)
    @Volatile private var deadKeys: Map<Int, Pair<Int, Int>> = emptyMap()
    @Volatile private var layoutHint: String? = null
    @Volatile private var closed = false
    private val lock = Object()

    /** Call before the app opens, so it starts with the keyboard already there (no config change). */
    fun create() {
        Hidden.hideImeOn(displayId)
        virtualKeyboard = phone?.createKeyboard(name, displayId)
        if (virtualKeyboard != null) {
            Thread({ awaitDevice() }, "keyboard-$displayId").start()
            return
        }
        val uniqueId = Hidden.displayUniqueId(displayId) ?: return Log.d("keyboard: display $displayId has no unique id")
        if (!Hidden.associateInputPort(port, uniqueId)) return
        try {
            val f = Os.open("/dev/uhid", OsConstants.O_RDWR, 0)
            val e = ByteBuffer.allocate(EVENT_SIZE).order(ByteOrder.nativeOrder())
            e.putInt(UHID_CREATE2)
            e.put(name.toByteArray().copyOf(128))
            e.put(port.toByteArray().copyOf(64))
            e.put(ByteArray(64)) // uniq
            e.putShort(DESCRIPTOR.size.toShort())
            e.putShort(0x06) // BUS_VIRTUAL
            e.putInt(0x18d1); e.putInt(0x0001); e.putInt(0); e.putInt(0)
            e.put(DESCRIPTOR)
            Os.write(f, e.array(), 0, EVENT_SIZE)
            fd = f
        } catch (t: Throwable) {
            Log.d("keyboard: uhid failed ($t); typing with the virtual keyboard")
            Hidden.removeInputPortAssociation(port)
            return
        }
        Thread({ awaitDevice() }, "keyboard-$displayId").start()
    }

    private fun awaitDevice() {
        val deadline = SystemClock.uptimeMillis() + 3000
        while (!closed && SystemClock.uptimeMillis() < deadline) {
            Hidden.inputDevice(name)?.let { d ->
                synchronized(lock) { device = d }
                Log.d("keyboard: device ${d.id} on display $displayId")
                applyLayout()
                return
            }
            Thread.sleep(50)
        }
        Log.d("keyboard: device didn't appear; typing with the virtual keyboard")
    }

    /** "name\nlanguage" of the Mac's keyboard layout, e.g. "Danish\nda", "U.S.\nen". */
    fun setLayout(hint: String) {
        layoutHint = hint
        Thread({ applyLayout() }, "keyboard-layout").start()
    }

    private fun applyLayout() = synchronized(lock) {
        val d = device ?: return
        val layout = pickLayout(layoutHint)
        if (layout != null && Hidden.setKeyboardLayout(d, layout.descriptor)) {
            Log.d("keyboard: layout ${layout.label} for Mac \"${layoutHint?.replace('\n', '/')}\"")
            Thread.sleep(300) // the input reader reloads the key map
        }
        val map = KeyCharacterMap.load(d.id)
        deadKeys = deadKeysOf(map)
        kcm = map
    }

    private fun pickLayout(hint: String?): Hidden.Layout? {
        val layouts = Hidden.keyboardLayouts
        val (macName, language) = (hint ?: "").split('\n').let { it.getOrElse(0) { "" } to it.getOrElse(1) { "" } }
        val alias = mapOf("U.S." to "English (US)", "ABC" to "English (US)", "US Extended" to "English (US)",
            "ABC – Extended" to "English (US)", "British" to "English (UK)", "British – PC" to "English (UK)",
            "Canadian English" to "English (Canada)", "Canadian French - CSA" to "French (Canada)")
        val wanted = alias[macName] ?: macName.removeSuffix(" – PC")
        return layouts.firstOrNull { it.label.equals(wanted, ignoreCase = true) }
            ?: layouts.firstOrNull { language.isNotEmpty() && it.languages.firstOrNull() == language && "style" !in it.label }
            ?: layouts.firstOrNull { it.label == "English (US)" }
    }

    /** Combining accent → (key code, meta state) of the dead key that types it. */
    private fun deadKeysOf(map: KeyCharacterMap): Map<Int, Pair<Int, Int>> {
        val metas = intArrayOf(0, KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON,
            KeyEvent.META_ALT_ON or KeyEvent.META_ALT_RIGHT_ON,
            KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON or KeyEvent.META_ALT_ON or KeyEvent.META_ALT_RIGHT_ON)
        val out = HashMap<Int, Pair<Int, Int>>()
        for (code in 1..KeyEvent.getMaxKeyCode()) for (meta in metas) {
            val u = map.get(code, meta)
            if (u and KeyCharacterMap.COMBINING_ACCENT != 0) out.putIfAbsent(u and KeyCharacterMap.COMBINING_ACCENT_MASK, code to meta)
        }
        return out
    }

    // MARK: Typing
    //
    // Keys go out as HID reports from the keyboard itself. Injected key events won't do for text:
    // Android re-labels them as the virtual keyboard's (device -1, a fixed US map), so æ's key
    // came out as ';' whatever this keyboard's layout (measured, input milestone). Injection stays
    // for the moments before Android has the keyboard, where the virtual map is also what [kcm] is.

    /** A key that isn't text (or a shortcut): pressed and released. */
    fun press(keyCode: Int, meta: Int) {
        if (keyCode !in 1..KeyEvent.getMaxKeyCode()) return
        if (!virtualPress(keyCode, meta) && !hidPress(keyCode, meta)) injectPress(keyCode, meta)
    }

    /** On the virtual keyboard: the modifiers' keys around the key, as a person presses them. */
    private fun virtualPress(keyCode: Int, meta: Int): Boolean {
        val k = virtualKeyboard ?: return false
        if (device == null) return false // Android doesn't have it yet
        val modifiers = modifierKeys(meta)
        return runCatching {
            synchronized(reportLock) {
                modifiers.forEach { PhoneDevice.sendKey(k, it, true) }
                PhoneDevice.sendKey(k, keyCode, true)
                PhoneDevice.sendKey(k, keyCode, false)
                modifiers.asReversed().forEach { PhoneDevice.sendKey(k, it, false) }
            }
            true
        }.onFailure { Log.d("keyboard: virtual key $keyCode failed: ${it.cause ?: it}") }.getOrDefault(false)
    }

    private fun modifierKeys(meta: Int): List<Int> = buildList {
        if (meta and KeyEvent.META_CTRL_RIGHT_ON != 0) add(KeyEvent.KEYCODE_CTRL_RIGHT)
        else if (meta and KeyEvent.META_CTRL_ON != 0) add(KeyEvent.KEYCODE_CTRL_LEFT)
        if (meta and KeyEvent.META_SHIFT_RIGHT_ON != 0) add(KeyEvent.KEYCODE_SHIFT_RIGHT)
        else if (meta and KeyEvent.META_SHIFT_ON != 0) add(KeyEvent.KEYCODE_SHIFT_LEFT)
        if (meta and KeyEvent.META_ALT_RIGHT_ON != 0) add(KeyEvent.KEYCODE_ALT_RIGHT)
        else if (meta and KeyEvent.META_ALT_ON != 0) add(KeyEvent.KEYCODE_ALT_LEFT)
        if (meta and KeyEvent.META_META_ON != 0) add(KeyEvent.KEYCODE_META_LEFT)
    }

    private fun hidPress(keyCode: Int, meta: Int): Boolean {
        val f = fd ?: return false
        if (device == null) return false // Android doesn't have it yet: the report would be lost
        val usage = HID_USAGES[keyCode] ?: return false
        val mods = modifierBits(meta)
        synchronized(reportLock) {
            if (mods != 0) report(f, mods, 0)
            report(f, mods, usage)
            report(f, mods, 0)
            if (mods != 0) report(f, 0, 0)
        }
        return true
    }

    private val reportLock = Object()

    private fun report(f: FileDescriptor, modifiers: Int, usage: Int) {
        val e = ByteBuffer.allocate(EVENT_SIZE).order(ByteOrder.nativeOrder())
        e.putInt(UHID_INPUT2)
        e.putShort(8)
        e.put(byteArrayOf(modifiers.toByte(), 0, usage.toByte(), 0, 0, 0, 0, 0))
        Os.write(f, e.array(), 0, EVENT_SIZE)
    }

    /** Android meta state → HID modifier byte (AltGr is the right Alt). */
    private fun modifierBits(meta: Int): Int {
        var m = 0
        if (meta and KeyEvent.META_CTRL_RIGHT_ON != 0) m = m or 0x10
        else if (meta and KeyEvent.META_CTRL_ON != 0) m = m or 0x01
        if (meta and KeyEvent.META_SHIFT_RIGHT_ON != 0) m = m or 0x20
        else if (meta and KeyEvent.META_SHIFT_ON != 0) m = m or 0x02
        if (meta and KeyEvent.META_ALT_RIGHT_ON != 0) m = m or 0x40
        else if (meta and KeyEvent.META_ALT_ON != 0) m = m or 0x04
        if (meta and KeyEvent.META_META_ON != 0) m = m or 0x08
        return m
    }

    /**
     * Types [text]. Each character, in order of preference: this keyboard's layout (its key
     * presses); its dead keys (é = ´ then e, ~ = ~ then space); the virtual US map (injected: any
     * ASCII the layout puts on keys a keyboard can't press); and last the clipboard (emoji, CJK).
     * Only without a virtual device, with the phone locked, are those last ones dropped.
     */
    fun type(text: String) {
        val leftover = StringBuilder()
        var i = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            val s = String(Character.toChars(cp))
            i += s.length
            if (s.length == 1 && typeChar(s[0])) {
                flushLeftover(leftover)
            } else {
                leftover.append(s)
            }
        }
        flushLeftover(leftover)
    }

    private fun flushLeftover(leftover: StringBuilder) {
        if (leftover.isEmpty()) return
        if (phone?.hasClipboard != true && phoneLocked()) Log.d("keyboard: ${leftover.codePointCount(0, leftover.length)} character(s) can't be typed while the phone is locked")
        else paste(leftover.toString(), restore = true)
        leftover.clear()
    }

    private fun typeChar(c: Char): Boolean {
        val map = kcm
        map.getEvents(charArrayOf(c))?.let { if (pressable(it)) return pressAll(it) }
        // A dead key: the accent alone (dead key, then space), or composed with a letter.
        deadKeys[c.code]?.let { dead ->
            press(dead.first, dead.second)
            press(KeyEvent.KEYCODE_SPACE, 0)
            return true
        }
        val parts = Normalizer.normalize(c.toString(), Normalizer.Form.NFD)
        if (parts.length == 2) {
            val base = map.getEvents(charArrayOf(parts[0]))?.takeIf(::pressable)
            val accent = deadKeys.keys.firstOrNull { KeyCharacterMap.getDeadChar(it, parts[0].code) == c.code }
            if (base != null && accent != null) {
                val dead = deadKeys.getValue(accent)
                press(dead.first, dead.second)
                return pressAll(base)
            }
        }
        virtualMap.getEvents(charArrayOf(c))?.let { events ->
            keyDowns(events).forEach { injectPress(it.keyCode, it.metaState) }
            return true
        }
        return false
    }

    private val virtualMap: KeyCharacterMap by lazy { KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD) }

    private fun keyDowns(events: Array<KeyEvent>) =
        events.filter { it.action == KeyEvent.ACTION_DOWN && !KeyEvent.isModifierKey(it.keyCode) }

    /** Every key of it exists on our keyboard (and Android has the keyboard). */
    /** Every key of it is one a real keyboard has (Danish puts < > \ on PLUS, which none has: a
     *  virtual keyboard's PLUS types +), and Android has our keyboard. */
    private fun pressable(events: Array<KeyEvent>) = device != null && keyDowns(events).all { HID_USAGES.containsKey(it.keyCode) }

    /** getEvents() wraps each key in its modifiers' presses; the key's own DOWN carries the meta. */
    private fun pressAll(events: Array<KeyEvent>): Boolean {
        keyDowns(events).forEach { press(it.keyCode, it.metaState) }
        return true
    }

    private fun injectPress(keyCode: Int, meta: Int) {
        val now = SystemClock.uptimeMillis()
        inject(now, KeyEvent.ACTION_DOWN, keyCode, meta)
        inject(now, KeyEvent.ACTION_UP, keyCode, meta)
    }

    private fun phoneLocked(): Boolean = runCatching {
        (FakeContext.instance.getSystemService(android.content.Context.KEYGUARD_SERVICE) as android.app.KeyguardManager).isDeviceLocked
    }.getOrDefault(true)

    /**
     * ⌘V and characters no key types: [text] goes on the clipboard and Ctrl+V pastes it (set first,
     * then pasted, so it can't paste a stale clip); [restore] puts the previous clip back after.
     * The virtual device's clipboard works while the phone is locked; without one, the phone's
     * clipboard is used, which Android refuses while locked, so ⌘V types the text then.
     */
    fun paste(text: String?, restore: Boolean) {
        val phone = phone
        if (phone != null && phone.hasClipboard) {
            val previous = if (restore) phone.getClip() else null
            if (text != null) phone.setClip(text)
            press(KeyEvent.KEYCODE_V, CTRL)
            if (previous != null) Thread({
                Thread.sleep(800) // the app reads the clip as it handles the paste
                phone.setClip(previous)
            }, "clip-restore").start()
            return
        }
        if (phoneLocked()) {
            if (text != null && !restore) type(text)
            return
        }
        val previous = if (restore) runCatching { PhoneClipboard.get?.invoke() }.getOrNull() else null
        if (text != null) PhoneClipboard.set?.invoke(text)
        press(KeyEvent.KEYCODE_V, CTRL)
        if (restore && previous != null) Thread({
            Thread.sleep(800)
            PhoneClipboard.set?.invoke(previous)
        }, "clip-restore").start()
    }

    private fun inject(time: Long, action: Int, keyCode: Int, meta: Int) {
        val event = KeyEvent(time, time, action, keyCode, 0, meta, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_KEYBOARD)
        if (!runCatching { Hidden.inject(event, displayId) }.getOrDefault(false)) {
            Log.d("keyboard: injecting key $keyCode failed")
        }
    }

    fun close() {
        closed = true
        virtualKeyboard?.let { PhoneDevice.closeInput(it); virtualKeyboard = null; return }
        fd?.let { f ->
            runCatching {
                Os.write(f, ByteBuffer.allocate(EVENT_SIZE).order(ByteOrder.nativeOrder()).putInt(UHID_DESTROY).array(), 0, EVENT_SIZE)
                Os.close(f)
            }
        }
        fd = null
        Hidden.removeInputPortAssociation(port)
    }
}
