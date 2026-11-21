package dev.nearside.phone

import android.app.PendingIntent
import android.content.ClipData
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import dev.nearside.link.HelperConnection
import org.json.JSONObject
import java.io.File

/**
 * Files dropped on a Mac window go to the app in it, as if shared to it on the phone. The Mac
 * pushes them into our `files/shared` folder (adb may write there); this provider serves them to
 * that one app (a read grant per share), and [share] opens the app's share screen on the window's
 * display through the helper (apps can't start activities from the background).
 */
class DroppedFiles : ContentProvider() {
    companion object {
        private const val AUTHORITY = "dev.nearside.dropped"
        private const val TAG = "Nearside"
        private const val KEEP_MS = 24 * 3600 * 1000L

        private fun folder(context: Context) = File(context.getExternalFilesDir(null), "shared")

        /**
         * Made by us, so it's ours: a folder the shell made there would be the shell's, and closed
         * to us. The Mac (adb) may write into ours.
         */
        fun prepare(context: Context) {
            runCatching { folder(context).mkdirs() }.onFailure { Log.w(TAG, "drop folder: $it") }
        }

        private fun mime(name: String) =
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase()) ?: "application/octet-stream"

        /** Shares [names] (in our folder) with [pkg] on [display]; tells the Mac if the app can't take them. */
        fun share(context: Context, names: List<String>, pkg: String, display: Int) {
            val dir = folder(context)
            val files = names.filter { it.isNotEmpty() && '/' !in it && it != "." && it != ".." }.map { File(dir, it) }.filter { it.isFile }
            if (files.isEmpty()) { Log.w(TAG, "dropped files not found in $dir: $names (${dir.list()?.toList()})"); return }
            dir.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > KEEP_MS }?.forEach { it.delete() } // older drops
            val uris = files.map { Uri.Builder().scheme("content").authority(AUTHORITY).appendPath(it.name).build() }
            val types = files.map { mime(it.name) }.distinct()
            val type = types.singleOrNull() ?: types.map { it.substringBefore('/') }.distinct().singleOrNull()?.let { "$it/*" } ?: "*/*"
            val intent = (if (uris.size == 1) Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris[0])
                else Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris)))
                .setType(type)
                .setPackage(pkg)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            intent.clipData = ClipData.newRawUri(null, uris[0]).apply { uris.drop(1).forEach { addItem(ClipData.Item(it)) } }
            val accepts = context.packageManager.queryIntentActivities(intent, 0).isNotEmpty()
            val sent = accepts && runCatching {
                // Our PendingIntent: the read grant is ours to give; the helper puts it on the display.
                val pending = PendingIntent.getActivity(context, uris.hashCode(), intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                HelperConnection.helper?.sendIntentOnDisplay(pending, display) == true
            }.onFailure { Log.w(TAG, "share failed: $it") }.getOrDefault(false)
            Log.i(TAG, "dropped ${files.size} file(s) ($type) to $pkg: accepts $accepts, sent $sent")
            if (!sent) {
                HelperConnection.send(JSONObject().put("t", "display-share-failed").put("pkg", pkg).put("accepts", accepts))
            }
        }
    }

    private fun file(uri: Uri): File? {
        val name = uri.lastPathSegment ?: return null
        if ('/' in name || name == "." || name == "..") return null
        return File(folder(context!!), name).takeIf { it.isFile }
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        if (mode != "r") throw SecurityException("read only")
        val f = file(uri) ?: throw java.io.FileNotFoundException(uri.toString())
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun query(uri: Uri, projection: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor? {
        val f = file(uri) ?: return null
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns, 1).apply {
            addRow(columns.map { c -> when (c) { OpenableColumns.DISPLAY_NAME -> f.name; OpenableColumns.SIZE -> f.length(); else -> null } })
        }
    }

    override fun getType(uri: Uri): String? = file(uri)?.let { mime(it.name) }
    override fun onCreate() = true
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<out String>?) = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<out String>?) = 0
}
