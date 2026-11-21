// Reflection wrappers for the hidden system APIs the display feature uses, as the shell user.
// Adapted from scrcpy (Apache-2.0, Copyright (C) Genymobile): server/.../wrappers/*.java.
package dev.nearside.helper.display

import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.os.Bundle
import android.os.IBinder
import android.view.InputEvent
import android.view.MotionEvent
import dev.nearside.helper.FakeContext
import dev.nearside.helper.Log

@SuppressLint("PrivateApi", "DiscouragedPrivateApi")
object Hidden {
    private fun service(name: String, stub: String): Any {
        val binder = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java)
            .invoke(null, name) as IBinder
        return Class.forName("$stub\$Stub").getMethod("asInterface", IBinder::class.java).invoke(null, binder)!!
    }

    /** A DisplayManager bound to the shell's identity (so its virtual displays are ours). */
    val displayManager: DisplayManager by lazy {
        DisplayManager::class.java.getDeclaredConstructor(Context::class.java).apply { isAccessible = true }
            .newInstance(FakeContext.instance) as DisplayManager
    }

    private val activityTasks by lazy { service("activity_task", "android.app.IActivityTaskManager") }
    private val activityManager by lazy { service("activity", "android.app.IActivityManager") }
    private val inputManager: Any by lazy {
        Class.forName("android.hardware.input.InputManagerGlobal").getMethod("getInstance").invoke(null)!!
    }
    private val injectMethod by lazy {
        inputManager.javaClass.getMethod("injectInputEvent", InputEvent::class.java, Int::class.java)
    }
    private val setDisplayIdMethod by lazy { InputEvent::class.java.getMethod("setDisplayId", Int::class.java) }

    /** Injects an input event onto a display, without waiting for it to be handled. */
    fun inject(event: InputEvent, displayId: Int): Boolean {
        setDisplayIdMethod.invoke(event, displayId)
        return injectMethod.invoke(inputManager, event, 0) as Boolean // INJECT_INPUT_EVENT_MODE_ASYNC
    }

    private val setActionButtonMethod by lazy { MotionEvent::class.java.getMethod("setActionButton", Int::class.java) }

    /** BUTTON_PRESS/RELEASE events need their button set, which only a hidden setter does. */
    fun setActionButton(event: MotionEvent, button: Int): Boolean = runCatching {
        setActionButtonMethod.invoke(event, button); true
    }.onFailure { Log.d("MotionEvent.setActionButton failed: ${it.cause ?: it}") }.getOrDefault(false)

    /** Starts an activity as the shell, with options (e.g. a launch display). */
    fun startActivity(intent: Intent, options: Bundle): Boolean {
        try {
            val m = activityManager.javaClass.methods.first { it.name == "startActivityAsUserWithFeature" }
            // (caller, callingPackage, callingFeatureId, intent, resolvedType, resultTo, resultWho,
            //  requestCode, flags, profilerInfo, options, userId)
            val result = m.invoke(activityManager, null, FakeContext.PACKAGE_NAME, null, intent, null, null, null,
                0, 0, null, options, 0) as Int
            if (result >= 0) return true
            Log.d("startActivity returned $result")
        } catch (t: Throwable) {
            Log.d("startActivity via binder failed: ${t.cause ?: t}")
        }
        return false
    }

    /**
     * Keeps one display's power group awake (and wakes it). A virtual display with
     * OWN_DISPLAY_GROUP gets its own group, which sleeps after the screen timeout like a phone
     * screen would; then the app stops drawing. A screen wake lock tied to the display keeps it on
     * without touching the phone's own screen. (Hidden PowerManager.newWakeLock(flags, tag, displayId).)
     */
    @Suppress("DEPRECATION")
    fun keepAwake(displayId: Int, tag: String): android.os.PowerManager.WakeLock? = runCatching {
        val pm = FakeContext.instance.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        val flags = android.os.PowerManager.SCREEN_BRIGHT_WAKE_LOCK or android.os.PowerManager.ACQUIRE_CAUSES_WAKEUP
        val lock = pm.javaClass.getMethod("newWakeLock", Int::class.java, String::class.java, Int::class.java)
            .invoke(pm, flags, tag, displayId) as android.os.PowerManager.WakeLock
        lock.setReferenceCounted(false)
        lock.acquire()
        lock
    }.onFailure { Log.d("keeping display $displayId awake failed: ${it.cause ?: it}") }.getOrNull()

    // MARK: Keyboards

    private val inputService by lazy { service("input", "android.hardware.input.IInputManager") }
    private val windowService by lazy { service("window", "android.view.IWindowManager") }

    private fun inputCall(name: String, vararg args: Any?): Any? =
        inputService.javaClass.methods.first { it.name == name && it.parameterCount == args.size }.invoke(inputService, *args)

    /** Input devices on that port (UHID `phys`) belong to the display, not the phone's screen. */
    fun associateInputPort(port: String, displayUniqueId: String): Boolean = runCatching {
        inputCall("addUniqueIdAssociationByPort", port, displayUniqueId); true
    }.onFailure { Log.d("addUniqueIdAssociationByPort failed: ${it.cause ?: it}") }.getOrDefault(false)

    fun removeInputPortAssociation(port: String) {
        runCatching { inputCall("removeUniqueIdAssociationByPort", port) }
            .onFailure { Log.d("removeUniqueIdAssociationByPort failed: ${it.cause ?: it}") }
    }

    fun displayUniqueId(displayId: Int): String? = runCatching {
        val display = displayManager.getDisplay(displayId)
        display.javaClass.getMethod("getUniqueId").invoke(display) as String
    }.getOrNull()

    fun inputDevice(name: String): android.view.InputDevice? = runCatching {
        (inputCall("getInputDeviceIds") as IntArray).asSequence()
            .mapNotNull { inputCall("getInputDevice", it) as? android.view.InputDevice }
            .firstOrNull { it.name == name }
    }.getOrNull()

    /** A keyboard layout Android ships: (label, descriptor, languages). */
    class Layout(val label: String, val descriptor: String, val languages: List<String>)

    val keyboardLayouts: List<Layout> by lazy {
        runCatching {
            (inputCall("getKeyboardLayouts") as Array<*>).filterNotNull().map { l ->
                fun get(m: String) = l.javaClass.getMethod(m).invoke(l)
                val locales = runCatching { get("getLocales") as android.os.LocaleList }.getOrNull()
                Layout(get("getLabel") as String, get("getDescriptor") as String,
                    (0 until (locales?.size() ?: 0)).map { locales!![it].language })
            }
        }.onFailure { Log.d("getKeyboardLayouts failed: ${it.cause ?: it}") }.getOrDefault(emptyList())
    }

    fun setKeyboardLayout(device: android.view.InputDevice, descriptor: String): Boolean = runCatching {
        inputCall("setKeyboardLayoutOverrideForInputDevice", device.javaClass.getMethod("getIdentifier").invoke(device), descriptor)
        true
    }.onFailure { Log.d("setKeyboardLayoutOverrideForInputDevice failed: ${it.cause ?: it}") }.getOrDefault(false)

    /** DISPLAY_IME_POLICY_HIDE (2): no on-screen keyboard for that display, on it or the phone's. */
    fun hideImeOn(displayId: Int) {
        runCatching {
            windowService.javaClass.getMethod("setDisplayImePolicy", Int::class.java, Int::class.java).invoke(windowService, displayId, 2)
        }.onFailure { Log.d("setDisplayImePolicy failed: ${it.cause ?: it}") }
    }

    /** A root task as the system reports it. */
    data class RootTask(val taskId: Int, val displayId: Int, val packageName: String?, val visible: Boolean)

    private fun rootTask(info: Any): RootTask {
        fun field(name: String): Any? = generateSequence<Class<*>>(info.javaClass) { it.superclass }
            .firstNotNullOfOrNull { c -> runCatching { c.getDeclaredField(name).apply { isAccessible = true } }.getOrNull() }
            ?.get(info)
        val component = (field("baseActivity") ?: field("topActivity")) as? ComponentName
        return RootTask(field("taskId") as Int, field("displayId") as Int, component?.packageName,
            field("visible") as? Boolean ?: (field("isVisible") as? Boolean ?: false))
    }

    /** Every root task, on every display. */
    fun rootTasks(): List<RootTask> = runCatching {
        (activityTasks.javaClass.getMethod("getAllRootTaskInfos").invoke(activityTasks) as List<*>)
            .filterNotNull().map(::rootTask)
    }.onFailure { Log.d("getAllRootTaskInfos failed: ${it.cause ?: it}") }.getOrDefault(emptyList())

    /** Ends a task (as swiping it away in Recents does). */
    fun removeTask(taskId: Int): Boolean = runCatching {
        activityTasks.javaClass.getMethod("removeTask", Int::class.java).invoke(activityTasks, taskId) as Boolean
    }.onFailure { Log.d("removeTask failed: ${it.cause ?: it}") }.getOrDefault(false)

    /** Brings a task to the front where it is, as picking it in Recents does. */
    fun taskToFront(taskId: Int): Boolean = runCatching {
        val result = activityTasks.javaClass.getMethod("startActivityFromRecents", Int::class.java, Bundle::class.java)
            .invoke(activityTasks, taskId, null) as Int
        result >= 0
    }.onFailure { Log.d("startActivityFromRecents failed: ${it.cause ?: it}") }.getOrDefault(false)

    /** Moves a task to a display; onTop=false slides it under whatever is showing there. */
    fun moveTask(taskId: Int, displayId: Int, onTop: Boolean): Boolean {
        try {
            activityTasks.javaClass.getMethod("moveRootTaskToDisplayOnTopOrBottom", Int::class.java,
                Int::class.java, Boolean::class.java).invoke(activityTasks, taskId, displayId, onTop)
            return true
        } catch (t: Throwable) {
            Log.d("moveRootTaskToDisplayOnTopOrBottom failed: ${t.cause ?: t}")
        }
        return runCatching {
            activityTasks.javaClass.getMethod("moveRootTaskToDisplay", Int::class.java, Int::class.java)
                .invoke(activityTasks, taskId, displayId)
            true
        }.onFailure { Log.d("moveRootTaskToDisplay failed: ${it.cause ?: it}") }.getOrDefault(false)
    }
}
