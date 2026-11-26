// Enter sends a message in a phone app's window, as it does in chat apps on a computer.
//
// Android apps get Enter as a key, and a chat app's message box takes it as a new line. So when the
// computer marks an Enter as "send" (Settings → Phone apps → Enter sends messages; Shift+Enter
// stays a new line), the helper looks, through Android's accessibility API, at the text field
// that has the focus on that window's display and taps the Send button beside it. It reads only
// that field's surroundings, only then, and keeps nothing; it logs no content. No Send button
// found: Enter is pressed as before. The connection to the accessibility API is made on the first
// such Enter and closed after a minute without one, so it isn't on while nobody types.
package dev.nearside.helper.display

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.UiAutomation
import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import dev.nearside.helper.FakeContext
import dev.nearside.helper.Log

object EnterSends {
    /** In a KEY message's meta state: this Enter sends if it can (not a real Android meta bit). */
    const val SEND_META = 0x4000_0000
    private const val IDLE_MS = 60_000L
    private const val MAX_NODES = 300
    /** Exact labels only: "Send a like" (Messenger's thumbs-up) must not match. */
    private val SEND_LABELS = setOf("send", "send message", "senden", "sende", "envoyer", "enviar", "invia", "verzenden", "skicka", "wyślij")

    private val thread = HandlerThread("nearside-enter-sends").apply { start() }
    private val handler = Handler(thread.looper)
    private var automation: UiAutomation? = null
    private var lastUse = 0L

    /** The Send button by the focused field on [displayId], tapped: true if it was (or the field
     *  was empty, so there's nothing to send or break onto a new line). False: press Enter. */
    @Synchronized
    fun send(displayId: Int): Boolean = runCatching {
        val ui = connect() ?: return false
        lastUse = SystemClock.uptimeMillis()
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed(::disconnectIfIdle, IDLE_MS)
        val windows = ui.windowsOnAllDisplays.get(displayId) ?: return false
        for (window in windows) {
            if (window.type != AccessibilityWindowInfo.TYPE_APPLICATION) continue
            val field = window.root?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: continue
            if (!field.isEditable) continue
            if (field.text.isNullOrEmpty() || field.isShowingHintText) return true
            val button = sendButton(field) ?: return false
            return button.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        }
        false
    }.onFailure { Log.d("enter sends: ${it.cause ?: it}") }.getOrDefault(false)

    /** The nearest Send button: around the field first, then further out (a few levels). */
    private fun sendButton(field: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        var around = field.parent
        repeat(5) {
            val scope = around ?: return null
            find(scope)?.let { return clickable(it) }
            around = scope.parent
        }
        return null
    }

    private fun find(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        val queue = ArrayDeque(listOf(root))
        var seen = 0
        while (queue.isNotEmpty() && seen++ < MAX_NODES) {
            val node = queue.removeFirst()
            if (node.isVisibleToUser && node.isEnabled && !node.isEditable && isSend(node)) return node
            for (i in 0 until node.childCount) node.getChild(i)?.let(queue::addLast)
        }
        return null
    }

    /** By its id ("…:id/send", "send_button", WhatsApp's and most apps'), else its label. */
    private fun isSend(node: AccessibilityNodeInfo): Boolean {
        val id = node.viewIdResourceName?.substringAfter(":id/")?.lowercase()
        if (id != null && id.split('_', '-').any { it == "send" || it == "sendbutton" }) return true
        return listOfNotNull(node.contentDescription, node.text).any {
            val label = it.toString().trim().lowercase()
            label in SEND_LABELS
        }
    }

    /** Compose and custom buttons are often a clickable parent around an icon. */
    private fun clickable(node: AccessibilityNodeInfo): AccessibilityNodeInfo {
        var n: AccessibilityNodeInfo? = node
        repeat(3) {
            val current = n ?: return node
            if (current.isClickable) return current
            n = current.parent
        }
        return node
    }

    private fun connect(): UiAutomation? {
        automation?.let { return it }
        val connection = Class.forName("android.app.UiAutomationConnection").getDeclaredConstructor().newInstance()
        val connectionType = Class.forName("android.app.IUiAutomationConnection")
        val ui = runCatching {
            UiAutomation::class.java.getDeclaredConstructor(Looper::class.java, connectionType)
                .apply { isAccessible = true }.newInstance(thread.looper, connection)
        }.getOrElse {
            UiAutomation::class.java.getDeclaredConstructor(Context::class.java, connectionType)
                .apply { isAccessible = true }.newInstance(FakeContext.instance, connection)
        }
        // Leaves the phone's own accessibility services (TalkBack...) running.
        UiAutomation::class.java.getDeclaredMethod("connect", Int::class.javaPrimitiveType)
            .invoke(ui, UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        ui.serviceInfo = ui.serviceInfo.apply {
            flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS
        }
        automation = ui
        Log.d("enter sends: on")
        return ui
    }

    @Synchronized
    private fun disconnectIfIdle() {
        val ui = automation ?: return
        if (SystemClock.uptimeMillis() - lastUse < IDLE_MS) return
        runCatching { UiAutomation::class.java.getDeclaredMethod("disconnect").invoke(ui) }
        automation = null
        Log.d("enter sends: off")
    }
}
