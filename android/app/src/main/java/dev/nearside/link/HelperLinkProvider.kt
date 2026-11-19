package dev.nearside.link

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle

/**
 * Receives the helper's Binder. The helper runs as shell, which apps can't reach over sockets
 * (SELinux), but binder calls to and from shell are allowed. So the helper calls us:
 *   call("attach", extras = {"helper": IHelper}) → {"app": IAppCallback}
 * after which both sides hold a Binder to the other. Only the shell uid may call.
 */
class HelperLinkProvider : ContentProvider() {
    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        if (Binder.getCallingUid() != HelperConnection.SHELL_UID) throw SecurityException("shell only")
        if (method != "attach") return null
        val binder = extras?.getBinder("helper") ?: return null
        HelperConnection.attached(IHelper.Stub.asInterface(binder), context!!.applicationContext)
        return Bundle().apply { putBinder("app", HelperConnection.callback) }
    }

    override fun onCreate() = true
    override fun query(uri: Uri, p: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<out String>?) = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<out String>?) = 0
}
