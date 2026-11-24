package dev.nearside

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.Toast
import dev.nearside.link.HelperConnection

/** "Send to computer" in the share sheet. No UI: hands the files to the helper and closes. */
class ShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uris = sharedUris(intent).filter(::isForeign)
        val helper = HelperConnection.helper
        val message = when {
            uris.isEmpty() -> "Nothing to send"
            helper == null || !HelperConnection.macConnected -> "Your ${Desktop.name(this)} isn't connected"
            else -> {
                val sent = uris.count { uri ->
                    runCatching {
                        contentResolver.openFileDescriptor(uri, "r")?.use { fd -> helper.sendFile(displayName(uri), fd) } == true
                    }.onFailure { android.util.Log.w("Nearside", "can't send $uri: $it") }.getOrDefault(false)
                }
                when (sent) {
                    0 -> "Couldn't send to your ${Desktop.name(this)}"
                    1 -> "Sending to your ${Desktop.name(this)}…"
                    else -> "Sending $sent files to your ${Desktop.name(this)}…"
                }
            }
        }
        android.util.Log.i("Nearside", "share: $message")
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
        finish()
    }

    /**
     * Only content shared *by another app*. A file:// path or one of our own providers would
     * let any app make us read and send Nearside's private files (a confused deputy).
     */
    private fun isForeign(uri: Uri): Boolean {
        if (uri.scheme != "content") return false
        val authority = uri.authority ?: return false
        val owner = runCatching { packageManager.resolveContentProvider(authority, 0)?.packageName }.getOrNull()
        return owner != null && owner != packageName
    }

    @Suppress("DEPRECATION")
    private fun sharedUris(intent: Intent): List<Uri> = when (intent.action) {
        Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra(Intent.EXTRA_STREAM))
        Intent.ACTION_SEND_MULTIPLE -> intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
        else -> emptyList()
    }

    private fun displayName(uri: Uri): String =
        runCatching {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        }.getOrNull() ?: uri.lastPathSegment?.substringAfterLast('/') ?: "file"
}
