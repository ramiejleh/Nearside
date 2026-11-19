package dev.nearside.helper

import android.annotation.SuppressLint
import android.app.ActivityOptions
import android.app.PendingIntent
import android.content.AttributionSource
import android.content.Intent
import android.content.pm.ProviderInfo
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.RemoteException
import dev.nearside.link.IAppCallback
import dev.nearside.link.IHelper
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Hands the Nearside app a Binder to us (Shizuku-style): we look up the app's
 * ContentProvider through ActivityManager and call "attach" with our [IHelper]; the app
 * answers with its [IAppCallback]. Re-attaches when the app process dies.
 *
 * Trust: the provider must belong to our package, and only that package's uid may call us.
 */
@SuppressLint("PrivateApi", "DiscouragedPrivateApi")
object AppLink {
    private const val PACKAGE = "dev.nearside"
    private const val AUTHORITY = "dev.nearside.link"
    private const val MAX_MESSAGE = 1 shl 20
    /** Message types the helper owns; the app may not send these to the Mac. */
    private val RESERVED = setOf("clip", "hello", "challenge", "auth", "hello-mac", "app", "file-ready")
    /** Shared files wait here (shell-owned) until the Mac has pulled them over adb. */
    private val STAGING = File("/data/local/tmp/nearside-out")
    private val files = Executors.newSingleThreadExecutor()

    /** Relays to the Mac; false when no Mac is connected. Set by [Main]. */
    lateinit var toMac: (JSONObject) -> Boolean
    lateinit var macConnected: () -> Boolean

    @Volatile private var app: IAppCallback? = null
    @Volatile private var appUid = -1
    private val scheduler = Executors.newSingleThreadScheduledExecutor()

    val isLinked get() = app != null

    fun start() {
        STAGING.deleteRecursively() // leftovers from a previous run
        STAGING.mkdirs()
        scheduler.execute(::attach)
    }

    private val helperBinder = object : IHelper.Stub() {
        override fun sendToMac(json: String): Boolean {
            if (Binder.getCallingUid() != appUid) throw SecurityException("not the Nearside app")
            if (json.length > MAX_MESSAGE) return false
            val msg = runCatching { JSONObject(json) }.getOrNull() ?: return false
            if (msg.optString("t").isEmpty() || msg.optString("t") in RESERVED) return false
            return toMac(msg)
        }

        override fun isMacConnected(): Boolean {
            if (Binder.getCallingUid() != appUid) throw SecurityException("not the Nearside app")
            return macConnected()
        }

        override fun sendFile(name: String, fd: ParcelFileDescriptor): Boolean {
            if (Binder.getCallingUid() != appUid) throw SecurityException("not the Nearside app")
            if (!macConnected()) return false
            val id = UUID.randomUUID().toString()
            val safe = safeName(name)
            val copy = ParcelFileDescriptor.dup(fd.fileDescriptor) // the app closes its fd on return
            files.execute {
                val staged = File(STAGING, id)
                runCatching {
                    ParcelFileDescriptor.AutoCloseInputStream(copy).use { input ->
                        staged.outputStream().use { input.copyTo(it, 256 * 1024) }
                    }
                    toMac(JSONObject().put("t", "file-ready").put("id", id).put("name", safe)
                        .put("size", staged.length()).put("path", staged.path))
                }.onFailure {
                    Log.d("staging $safe failed: $it")
                    staged.delete()
                }
            }
            return true
        }

        override fun sendIntent(intent: PendingIntent, fillIn: Intent?): Boolean {
            if (Binder.getCallingUid() != appUid) throw SecurityException("not the Nearside app")
            val options = when {
                Build.VERSION.SDK_INT >= 36 -> ActivityOptions.makeBasic()
                    .setPendingIntentBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOW_ALWAYS)
                    .toBundle()
                Build.VERSION.SDK_INT >= 34 -> ActivityOptions.makeBasic()
                    .setPendingIntentBackgroundActivityStartMode(@Suppress("DEPRECATION") ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED)
                    .toBundle()
                else -> null
            }
            return runCatching {
                intent.send(FakeContext.instance, 0, fillIn, null, null, null, options)
            }.onFailure { Log.d("sendIntent failed: $it") }.isSuccess
        }
    }

    /** A Mac message the helper doesn't handle itself goes to the app. */
    fun deliver(msg: JSONObject) {
        if (msg.optString("t") == "file-pulled") { // ours, not the app's
            val id = msg.optString("id")
            if (id.matches(Regex("[0-9a-f-]{36}"))) File(STAGING, id).delete()
            return
        }
        val target = app
        if (target == null) Log.d("Mac → app: ${msg.optString("t")} dropped, app not linked")
        try {
            target?.onMessage(msg.toString())
        } catch (e: RemoteException) {
            Log.d("Mac → app failed: $e")
        }
        if (target != null) wake()
    }

    /**
     * Android 17 freezes the app even while it's a bound notification listener, and then
     * new-notification callbacks just queue up (nothing reached the Mac within 30 s in testing).
     * Shell may pin a process unfrozen for its lifetime; we re-run this for every new app
     * process (each re-link). An idle unfrozen process is asleep, so this costs no battery.
     */
    private fun keepUnfrozen() {
        runCatching {
            val p = ProcessBuilder("cmd", "activity", "unfreeze", "--sticky", PACKAGE).redirectErrorStream(true).start()
            val out = p.inputStream.bufferedReader().readText().trim()
            p.waitFor()
            if (out.isNotEmpty()) Log.d("unfreeze: $out")
        }.onFailure { Log.d("unfreeze failed: $it") }
    }

    /**
     * Backup for [keepUnfrozen]: Android 17 freezes the app even while it's a bound notification listener; our oneway
     * calls then wait in its queue. Delivering a broadcast always thaws the receiver, so the
     * queued calls run right away.
     */
    private fun wake() {
        val intent = Intent("dev.nearside.WAKE")
            .setPackage(PACKAGE)
            .addFlags(Intent.FLAG_RECEIVER_FOREGROUND)
        runCatching { FakeContext.instance.sendBroadcast(intent) }
            .onFailure { Log.d("wake broadcast failed: $it") }
    }

    fun macConnectionChanged(connected: Boolean) {
        try {
            app?.onMacConnectionChanged(connected)
        } catch (_: RemoteException) {
        }
    }

    private fun attach() {
        val result = runCatching { tryAttach() }
        val linked = result.getOrDefault(false)
        if (!linked) {
            Log.d("app link failed (${result.exceptionOrNull()?.let { it.cause ?: it } ?: "no provider"}); retrying in 30 s")
            scheduler.schedule(::attach, 30, TimeUnit.SECONDS)
        }
    }

    private fun tryAttach(): Boolean {
        val am = Class.forName("android.app.ActivityManager").getMethod("getService").invoke(null)!!
        val token: IBinder = Binder()
        val holder = am.javaClass
            .getMethod("getContentProviderExternal", String::class.java, Int::class.javaPrimitiveType, IBinder::class.java, String::class.java)
            .invoke(am, AUTHORITY, 0, token, "nearside") ?: return false
        try {
            val info = field(holder, "info") as ProviderInfo
            if (info.packageName != PACKAGE) {
                Log.d("provider $AUTHORITY belongs to ${info.packageName}; refusing")
                return false
            }
            val provider = field(holder, "provider")!!
            val extras = Bundle().apply { putBinder("helper", helperBinder) }
            val reply = call(provider, "attach", extras) ?: return false
            val binder = reply.getBinder("app") ?: return false
            appUid = info.applicationInfo.uid
            val callback = IAppCallback.Stub.asInterface(binder)
            binder.linkToDeath({
                if (app === callback) {
                    app = null
                    Log.d("app died; re-linking")
                    toMac(JSONObject().put("t", "app").put("linked", false))
                    scheduler.schedule(::attach, 3, TimeUnit.SECONDS)
                }
            }, 0)
            app = callback
            Log.d("linked to app (uid $appUid)")
            keepUnfrozen()
            toMac(JSONObject().put("t", "app").put("linked", true))
            callback.onMacConnectionChanged(macConnected())
            return true
        } finally {
            // Don't keep a reference that would pin the app process in memory.
            runCatching {
                am.javaClass.getMethod("removeContentProviderExternal", String::class.java, IBinder::class.java)
                    .invoke(am, AUTHORITY, token)
            }
        }
    }

    /** IContentProvider.call; its signature changed in Android 11 and 12. */
    private fun call(provider: Any, method: String, extras: Bundle): Bundle? {
        val s = String::class.java
        val b = Bundle::class.java
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            provider.javaClass.getMethod("call", AttributionSource::class.java, s, s, s, b)
                .invoke(provider, FakeContext.instance.attributionSource, AUTHORITY, method, null, extras)
        } else {
            provider.javaClass.getMethod("call", s, s, s, s, s, b)
                .invoke(provider, FakeContext.PACKAGE_NAME, null, AUTHORITY, method, null, extras)
        } as Bundle?
    }

    /** A plain file name: no directories, no control characters, not hidden. */
    private fun safeName(name: String): String {
        val base = name.substringAfterLast('/').filter { it >= ' ' }.trim().trimStart('.').take(200)
        return base.ifEmpty { "file" }
    }

    private fun field(obj: Any, name: String): Any? =
        obj.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(obj)
}
