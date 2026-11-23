package dev.nearside

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.provider.MediaStore
import android.util.Base64
import android.util.Size
import dev.nearside.link.HelperConnection
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * The phone's newest photos and screenshots, for the Mac's panel. Only while the Mac asks:
 *   Mac → {"t":"photos-watch","on":true|false}
 *   us  → {"t":"photos","items":[{id,name,path,date,screenshot,w,h,size}]}  (newest 12, again on change)
 *   Mac → {"t":"photos-thumbs","ids":[…]}
 *   us  → {"t":"photo-thumb","id","jpeg"} one per id (Binder messages are limited to about 1 MB)
 * The Mac pulls a full file itself (adb sync) by its `path` under /sdcard, only when the user
 * takes it. Needs READ_MEDIA_IMAGES, which the Mac grants or revokes with its setting.
 */
object PhotoFeed {
    private const val COUNT = 12
    private const val THUMB_PX = 240

    private val thread = HandlerThread("photos").apply { start() }
    private val handler = Handler(thread.looper)
    private var observer: ContentObserver? = null // on `thread` only

    fun handle(context: Context, msg: JSONObject) = handler.post {
        when (msg.optString("t")) {
            "photos-watch" -> if (msg.optBoolean("on")) watch(context) else stop(context)
            "photos-thumbs" -> {
                val ids = msg.optJSONArray("ids") ?: JSONArray()
                for (i in 0 until minOf(ids.length(), COUNT)) thumbnail(context, ids.optLong(i))
            }
        }
    }

    /** The Mac went away: stop watching (it asks again when it's back). */
    fun macDisconnected(context: Context) = handler.post { stop(context) }

    private fun watch(context: Context) {
        if (observer == null) {
            observer = object : ContentObserver(handler) {
                override fun onChange(selfChange: Boolean) {
                    // A burst (a photo is inserted, then updated): send once it settles.
                    handler.removeCallbacks(sendLater)
                    handler.postDelayed(sendLater, 700)
                }
            }.also { runCatching { context.contentResolver.registerContentObserver(collection, true, it) } }
            sendLater = Runnable { sendList(context) }
        }
        sendList(context)
    }

    private fun stop(context: Context) {
        observer?.let { runCatching { context.contentResolver.unregisterContentObserver(it) } }
        observer = null
        handler.removeCallbacks(sendLater)
    }

    private var sendLater = Runnable {}

    private val collection: Uri = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)

    private fun allowed(context: Context) =
        context.checkSelfPermission(Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED

    private fun sendList(context: Context) {
        if (!allowed(context)) {
            HelperConnection.send(JSONObject().put("t", "photos").put("denied", true).put("items", JSONArray()))
            return
        }
        val items = JSONArray()
        val columns = arrayOf(
            MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.RELATIVE_PATH,
            MediaStore.Images.Media.DATE_ADDED, MediaStore.Images.Media.WIDTH, MediaStore.Images.Media.HEIGHT,
            MediaStore.Images.Media.SIZE,
        )
        val args = Bundle().apply {
            putStringArray(android.content.ContentResolver.QUERY_ARG_SORT_COLUMNS, arrayOf(MediaStore.Images.Media.DATE_ADDED))
            putInt(android.content.ContentResolver.QUERY_ARG_SORT_DIRECTION, android.content.ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
            putInt(android.content.ContentResolver.QUERY_ARG_LIMIT, COUNT)
        }
        runCatching {
            context.contentResolver.query(collection, columns, args, null)?.use { c ->
                while (c.moveToNext()) {
                    val name = c.getString(1) ?: continue
                    val folder = c.getString(2) ?: continue
                    items.put(JSONObject()
                        .put("id", c.getLong(0))
                        .put("name", name)
                        .put("path", "/sdcard/$folder$name")
                        .put("date", c.getLong(3) * 1000)
                        .put("screenshot", folder.contains("Screenshots", ignoreCase = true))
                        .put("w", c.getInt(4)).put("h", c.getInt(5)).put("size", c.getLong(6)))
                }
            }
        }.onFailure { android.util.Log.i("Nearside", "photos: query failed: $it") }
        HelperConnection.send(JSONObject().put("t", "photos").put("items", items))
    }

    private fun thumbnail(context: Context, id: Long) {
        if (!allowed(context)) return
        val jpeg = runCatching {
            val bitmap = context.contentResolver.loadThumbnail(ContentUris.withAppendedId(collection, id), Size(THUMB_PX, THUMB_PX), null)
            ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG, 80, it) }.toByteArray()
        }.onFailure { android.util.Log.i("Nearside", "photos: no thumbnail for $id: $it") }.getOrNull() ?: return
        if (!HelperConnection.send(JSONObject().put("t", "photo-thumb").put("id", id)
            .put("jpeg", Base64.encodeToString(jpeg, Base64.NO_WRAP)))) {
            android.util.Log.i("Nearside", "photos: thumbnail $id (${jpeg.size} bytes) not sent")
        }
    }
}
