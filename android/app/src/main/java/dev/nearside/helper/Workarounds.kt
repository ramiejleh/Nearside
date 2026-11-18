// Adapted from scrcpy (Apache-2.0, Copyright (C) Genymobile):
// server/src/main/java/com/genymobile/scrcpy/Workarounds.java and FakeContext.java.
// A process started with `app_process` has no Android Context. These hacks give it a
// system context that identifies as the shell package, so system services treat the
// helper like `adb shell` (uid 2000), which may read the clipboard in the background.
package dev.nearside.helper

import android.annotation.SuppressLint
import android.annotation.TargetApi
import android.app.Application
import android.app.Instrumentation
import android.content.AttributionSource
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ApplicationInfo

@SuppressLint("PrivateApi", "DiscouragedPrivateApi", "SoonBlockedPrivateApi", "BlockedPrivateApi")
object Workarounds {
    private val activityThreadClass: Class<*> = Class.forName("android.app.ActivityThread")
    private val activityThread: Any

    init {
        val ctor = activityThreadClass.getDeclaredConstructor().apply { isAccessible = true }
        activityThread = ctor.newInstance()
        activityThreadClass.getDeclaredField("sCurrentActivityThread").apply { isAccessible = true }
            .set(null, activityThread)
        activityThreadClass.getDeclaredField("mSystemThread").apply { isAccessible = true }
            .setBoolean(activityThread, true)
    }

    fun apply() {
        // Must precede the app context, which needs a valid system context.
        tryLog("configuration controller") {
            val ccClass = Class.forName("android.app.ConfigurationController")
            val atiClass = Class.forName("android.app.ActivityThreadInternal")
            val cc = ccClass.getDeclaredConstructor(atiClass).apply { isAccessible = true }
                .newInstance(activityThread)
            activityThreadClass.getDeclaredField("mConfigurationController").apply { isAccessible = true }
                .set(activityThread, cc)
        }
        tryLog("app info") {
            val bindDataClass = Class.forName("android.app.ActivityThread\$AppBindData")
            val bindData = bindDataClass.getDeclaredConstructor().apply { isAccessible = true }.newInstance()
            val info = ApplicationInfo().apply { packageName = FakeContext.PACKAGE_NAME }
            bindDataClass.getDeclaredField("appInfo").apply { isAccessible = true }.set(bindData, info)
            activityThreadClass.getDeclaredField("mBoundApplication").apply { isAccessible = true }
                .set(activityThread, bindData)
        }
        tryLog("app context") {
            val app = Instrumentation.newApplication(Application::class.java, FakeContext.instance)
            activityThreadClass.getDeclaredField("mInitialApplication").apply { isAccessible = true }
                .set(activityThread, app)
        }
    }

    fun systemContext(): Context =
        activityThreadClass.getDeclaredMethod("getSystemContext").invoke(activityThread) as Context

    private inline fun tryLog(what: String, block: () -> Unit) {
        try {
            block()
        } catch (t: Throwable) {
            // These are workarounds; failing one is not fatal.
            Log.d("workaround '$what' failed: $t")
        }
    }
}

class FakeContext private constructor() : ContextWrapper(Workarounds.systemContext()) {
    companion object {
        const val PACKAGE_NAME = "com.android.shell"
        private const val SHELL_UID = 2000
        val instance: FakeContext by lazy { FakeContext() }
    }

    override fun getPackageName(): String = PACKAGE_NAME
    override fun getOpPackageName(): String = PACKAGE_NAME
    override fun getApplicationContext(): Context = this

    @TargetApi(31)
    override fun getAttributionSource(): AttributionSource =
        AttributionSource.Builder(SHELL_UID).setPackageName(PACKAGE_NAME).build()

    override fun getSystemService(name: String): Any? {
        val service = super.getSystemService(name) ?: return null
        if (name == CLIPBOARD_SERVICE) {
            // The manager caches the context it was created with; point it at us so calls
            // are attributed to the shell package.
            service.javaClass.getDeclaredField("mContext").apply { isAccessible = true }.set(service, this)
        }
        return service
    }
}
