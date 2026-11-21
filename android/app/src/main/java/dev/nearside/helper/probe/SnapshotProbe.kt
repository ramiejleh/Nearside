// Probe (throwaway): can the shell take task snapshots (for the phone window's Recents)?
//   app_process / dev.nearside.helper.probe.SnapshotProbe <taskId>
package dev.nearside.helper.probe

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.os.Looper
import dev.nearside.helper.Workarounds

@SuppressLint("PrivateApi")
object SnapshotProbe {
    @JvmStatic
    fun main(args: Array<String>) {
        Looper.prepareMainLooper()
        Workarounds.apply()
        val atm = Class.forName("android.app.ActivityTaskManager").getMethod("getService").invoke(null)!!
        atm.javaClass.methods.filter { it.name.contains("Snapshot") }.forEach { m ->
            println("method ${m.name}(${m.parameterTypes.joinToString { it.simpleName }})")
        }
        val task = args[0].toInt()
        val manager = atm.javaClass.getMethod("getTaskSnapshotManager").invoke(atm)!!
        manager.javaClass.methods.filter { it.declaringClass.name.contains("Snapshot") }.forEach { m ->
            println("manager ${m.name}(${m.parameterTypes.joinToString { it.simpleName }})")
        }
        if (args.getOrNull(2) == "take") {
            val t = manager.javaClass.methods.first { it.name == "takeUserTaskSnapshot" }
            val started0 = System.currentTimeMillis()
            val r = runCatching { t.invoke(manager, task) }.getOrElse { "failed: ${it.cause ?: it}" }
            println("take: ${r.toString().take(160)} in ${System.currentTimeMillis() - started0} ms")
            val hw = r?.javaClass?.methods?.firstOrNull { it.name == "wrapToBitmap" && it.parameterCount == 0 }?.invoke(r) as Bitmap?
            println("take bitmap: ${hw?.width}x${hw?.height}")
            return
        }
        val m = manager.javaClass.methods.first { it.name == "getTaskSnapshot" }
        val a = arrayOfNulls<Any?>(m.parameterCount)
        a[0] = task
        m.parameterTypes.forEachIndexed { i, t ->
            if (i > 0) a[i] = when (t) { Boolean::class.java -> i == 1; Long::class.java -> 0L; Int::class.java -> args.getOrNull(1)?.toInt() ?: 0; else -> null }
        }
        val started = System.currentTimeMillis()
        val snapshot = runCatching { m.invoke(manager, *a) }.getOrElse { println("failed: ${it.cause ?: it}"); null }
        println("snapshot: $snapshot in ${System.currentTimeMillis() - started} ms")
        snapshot?.javaClass?.methods?.filter { it.declaringClass == snapshot.javaClass && it.parameterCount <= 1 }?.forEach {
            println("snap ${it.name}(${it.parameterTypes.joinToString { t -> t.simpleName }}): ${it.returnType.simpleName}")
        }
        if (snapshot != null) {
            val hw = snapshot.javaClass.getMethod("wrapToBitmap").invoke(snapshot) as Bitmap?
            println("wrapped: ${hw?.width}x${hw?.height} config=${hw?.config} in ${System.currentTimeMillis() - started} ms")
            if (args.getOrNull(2) == "reader") {
                val w = snapshot.javaClass.getMethod("getHardwareBufferWidth").invoke(snapshot) as Int
                val h = snapshot.javaClass.getMethod("getHardwareBufferHeight").invoke(snapshot) as Int
                val reader = android.media.ImageReader.newInstance(w, h, android.graphics.PixelFormat.RGBA_8888, 1)
                snapshot.javaClass.getMethod("attachAndQueueBufferWithColorSpace", android.view.Surface::class.java).invoke(snapshot, reader.surface)
                Thread.sleep(100)
                val image = reader.acquireLatestImage()
                println("reader image: ${image?.width}x${image?.height} planes=${image?.planes?.size}")
            } else {
                val bitmap = hw!!.copy(Bitmap.Config.ARGB_8888, false)
                val out = java.io.ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.JPEG, 80, out)
                println("bitmap ${bitmap.width}x${bitmap.height}, jpeg ${out.size()} bytes in ${System.currentTimeMillis() - started} ms")
            }
        }
    }
}
