package dev.nearside

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.os.Handler
import android.os.HandlerThread
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.SmsManager
import dev.nearside.link.HelperConnection
import org.json.JSONArray
import org.json.JSONObject

/**
 * SMS for the Mac's Messages window, over the helper link. Plain SMS only: Google Messages
 * keeps RCS chats in its own private store, and MMS (group chats, pictures) comes later.
 *   ← {"t":"sms-threads","req"}              → {"t":"sms-threads","req","threads":[…]}
 *   ← {"t":"sms-thread","req","thread"}      → {"t":"sms-thread","req","thread","messages":[…]}
 *   ← {"t":"sms-send","req","address","text"} → {"t":"sms-sent","req","ok","error"?}
 *   ← {"t":"sms-read","req","thread"}        → {"t":"sms-read","req","thread","updated"}  (seen on the Mac)
 *   → {"t":"sms-changed"}                    the SMS store changed (new text, read, sent…)
 *   → {"t":"sms-error","req","reason":"permission"}
 * Permissions (READ_SMS, SEND_SMS, READ_CONTACTS) are granted by the Mac over adb, plus the
 * WRITE_SMS app-op: Android silently ignores SMS writes (like marking read) from anything but
 * the default SMS app unless that op is allowed.
 */
object SmsBridge {
    private const val MAX_THREADS = 60
    private const val SCAN = 3000 // newest messages scanned to build the conversation list
    private const val PAGE = 150

    private val worker = HandlerThread("sms").apply { start() }
    private val handler = Handler(worker.looper)
    /** Contact name by the last 8 digits of each number: one query instead of one per thread. */
    private var names: Map<String, String> = emptyMap()
    private var namesLoadedAt = 0L
    @Volatile private var observing = false

    fun handle(context: Context, msg: JSONObject) {
        handler.post {
            val req = msg.opt("req")
            val reply = runCatching {
                if (!allowed(context, Manifest.permission.READ_SMS)) {
                    return@runCatching JSONObject().put("t", "sms-error").put("req", req).put("reason", "permission")
                }
                observe(context)
                when (msg.optString("t")) {
                    "sms-threads" -> JSONObject().put("t", "sms-threads").put("req", req).put("threads", threads(context))
                    "sms-thread" -> {
                        val thread = msg.optLong("thread")
                        JSONObject().put("t", "sms-thread").put("req", req).put("thread", thread)
                            .put("messages", messages(context, thread))
                    }
                    "sms-send" -> send(context, msg.optString("address"), msg.optString("text")).put("req", req)
                    "sms-read" -> {
                        val thread = msg.optLong("thread")
                        JSONObject().put("t", "sms-read").put("req", req).put("thread", thread)
                            .put("updated", markRead(context, thread))
                    }
                    else -> null
                }
            }.getOrElse { JSONObject().put("t", "sms-error").put("req", req).put("reason", it.message ?: "failed") }
            reply?.let(HelperConnection::send)
        }
    }

    private fun allowed(context: Context, permission: String) =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /** Newest message per conversation, with unread counts and contact names. */
    private fun threads(context: Context): JSONArray {
        data class Thread(val id: Long, val address: String, val snippet: String, val date: Long, val outgoing: Boolean, var unread: Int)
        val threads = LinkedHashMap<Long, Thread>()
        context.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms.THREAD_ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE,
                Telephony.Sms.TYPE, Telephony.Sms.READ),
            null, null, "${Telephony.Sms.DATE} DESC LIMIT $SCAN",
        )?.use { c ->
            while (c.moveToNext()) {
                val id = c.getLong(0)
                val incoming = c.getInt(4) == Telephony.Sms.MESSAGE_TYPE_INBOX
                val unread = incoming && c.getInt(5) == 0
                val existing = threads[id]
                if (existing == null) {
                    if (threads.size >= MAX_THREADS) continue
                    threads[id] = Thread(id, c.getString(1).orEmpty(), c.getString(2).orEmpty(), c.getLong(3), !incoming, if (unread) 1 else 0)
                } else if (unread) {
                    existing.unread++
                }
            }
        }
        return JSONArray().apply {
            threads.values.forEach { t ->
                put(JSONObject().put("thread", t.id).put("address", t.address).put("name", name(context, t.address))
                    .put("snippet", t.snippet.take(200)).put("date", t.date).put("out", t.outgoing).put("unread", t.unread))
            }
        }
    }

    /** The newest messages of one conversation, oldest first. */
    private fun messages(context: Context, thread: Long): JSONArray {
        val list = ArrayList<JSONObject>()
        context.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms._ID, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE),
            "${Telephony.Sms.THREAD_ID} = ?", arrayOf(thread.toString()), "${Telephony.Sms.DATE} DESC LIMIT $PAGE",
        )?.use { c ->
            while (c.moveToNext()) {
                val type = c.getInt(3)
                list.add(JSONObject().put("id", c.getLong(0)).put("body", c.getString(1).orEmpty()).put("date", c.getLong(2))
                    .put("out", type != Telephony.Sms.MESSAGE_TYPE_INBOX)
                    .put("failed", type == Telephony.Sms.MESSAGE_TYPE_FAILED)
                    .put("pending", type == Telephony.Sms.MESSAGE_TYPE_OUTBOX || type == Telephony.Sms.MESSAGE_TYPE_QUEUED))
            }
        }
        return JSONArray().apply { list.asReversed().forEach { put(it) } }
    }

    /** Marks a conversation's incoming texts read. Returns how many changed (0 if not allowed). */
    private fun markRead(context: Context, thread: Long): Int {
        val values = android.content.ContentValues().apply {
            put(Telephony.Sms.READ, 1)
            put(Telephony.Sms.SEEN, 1)
        }
        val updated = context.contentResolver.update(
            Telephony.Sms.CONTENT_URI, values,
            "${Telephony.Sms.THREAD_ID} = ? AND ${Telephony.Sms.READ} = 0", arrayOf(thread.toString()),
        )
        android.util.Log.i("Nearside", "marked $updated texts read")
        return updated
    }

    /** Sends a text. As a non-default SMS app, Android records it in the conversation itself. */
    private fun send(context: Context, address: String, text: String): JSONObject {
        val result = JSONObject().put("t", "sms-sent")
        if (!allowed(context, Manifest.permission.SEND_SMS)) return result.put("ok", false).put("error", "permission")
        if (address.isBlank() || text.isBlank()) return result.put("ok", false).put("error", "empty")
        val sms = context.getSystemService(SmsManager::class.java)
        val parts = sms.divideMessage(text)
        if (parts.size == 1) sms.sendTextMessage(address, null, text, null, null)
        else sms.sendMultipartTextMessage(address, null, parts, null, null)
        Status.lastEvent = "sent an SMS from the Mac"
        return result.put("ok", true)
    }

    private fun name(context: Context, address: String): String? {
        val key = digitsKey(address) ?: return null
        if (!allowed(context, Manifest.permission.READ_CONTACTS)) return null
        val now = System.currentTimeMillis()
        if (now - namesLoadedAt > 10 * 60_000) {
            names = loadNames(context)
            namesLoadedAt = now
        }
        return names[key]
    }

    private fun loadNames(context: Context): Map<String, String> {
        val map = HashMap<String, String>()
        runCatching {
            context.contentResolver.query(
                ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                arrayOf(ContactsContract.CommonDataKinds.Phone.NUMBER, ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME),
                null, null, null,
            )?.use { c ->
                while (c.moveToNext()) {
                    val key = digitsKey(c.getString(0).orEmpty()) ?: continue
                    map.putIfAbsent(key, c.getString(1) ?: continue)
                }
            }
        }
        return map
    }

    /** "+45 12 34 56 78" → "12345678"; null for names like "Netflix" or short codes. */
    private fun digitsKey(address: String): String? {
        val digits = address.filter(Char::isDigit)
        return if (digits.length >= 6) digits.takeLast(8) else null
    }

    /** Tell the Mac when anything changes, at most every 500 ms. */
    private fun observe(context: Context) {
        if (observing) return
        observing = true
        val notify = Runnable { HelperConnection.send(JSONObject().put("t", "sms-changed")) }
        context.contentResolver.registerContentObserver(Telephony.Sms.CONTENT_URI, true, object : ContentObserver(handler) {
            override fun onChange(selfChange: Boolean) {
                handler.removeCallbacks(notify)
                handler.postDelayed(notify, 500)
            }
        })
    }
}
