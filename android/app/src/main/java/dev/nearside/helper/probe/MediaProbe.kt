// Probe (throwaway): which getSessions arguments see an app's media session as the shell?
//   app_process / dev.nearside.helper.probe.MediaProbe
package dev.nearside.helper.probe

import android.annotation.SuppressLint
import android.os.IBinder
import android.os.Looper
import dev.nearside.helper.Workarounds

@SuppressLint("PrivateApi")
object MediaProbe {
    @JvmStatic
    fun main(args: Array<String>) {
        Looper.prepareMainLooper()
        Workarounds.apply()
        val binder = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java)
            .invoke(null, "media_session") as IBinder
        val service = Class.forName("android.media.session.ISessionManager\$Stub")
            .getMethod("asInterface", IBinder::class.java).invoke(null, binder)!!
        val m = service.javaClass.methods.first { it.name == "getSessions" }
        for (user in listOf(0, -1)) for (pkg in listOf("com.android.shell", "android", null)) {
            println("user=$user pkg=$pkg -> " + runCatching { (m.invoke(service, null, user, pkg) as List<*>).size.toString() }
                .getOrElse { "${it.cause ?: it}" })
        }
        val ctx = dev.nearside.helper.FakeContext.instance
        println("MEDIA_CONTENT_CONTROL granted: " + ctx.checkSelfPermission("android.permission.MEDIA_CONTENT_CONTROL"))
    }
}
