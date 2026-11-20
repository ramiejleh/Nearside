// The phone's media sessions (what's playing), as the shell sees them.
package dev.nearside.helper.display

import android.annotation.SuppressLint
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.IBinder
import dev.nearside.helper.FakeContext
import dev.nearside.helper.Log

@SuppressLint("PrivateApi", "DiscouragedPrivateApi")
object Media {
    /**
     * The active sessions, straight from the media_session service: MediaSessionManager can't be
     * made in app_process (its service registry is only set up in app processes). The shell may
     * read and control any session (MEDIA_CONTENT_CONTROL), as `cmd media_session` does.
     */
    private fun sessions(): List<MediaController> {
        val binder = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java)
            .invoke(null, "media_session") as IBinder
        val service = Class.forName("android.media.session.ISessionManager\$Stub")
            .getMethod("asInterface", IBinder::class.java).invoke(null, binder)!!
        // (ComponentName, userId), then (…, package) on Android 17. A package narrows the list to
        // that package's own sessions (the shell's: none), so it's left out (measured, MediaProbe).
        val getSessions = service.javaClass.methods.first { it.name == "getSessions" }
        val args = arrayOfNulls<Any?>(getSessions.parameterCount).also { it[1] = 0 }
        @Suppress("UNCHECKED_CAST")
        val tokens = getSessions.invoke(service, *args) as List<MediaSession.Token>
        return tokens.map { MediaController(FakeContext.instance, it) }
    }

    /** Pauses anything [packages] are playing; true if something was paused. */
    fun pause(packages: Set<String>): Boolean = runCatching {
        if (packages.isEmpty()) return false
        val playing = sessions().filter { it.packageName in packages && it.playbackState?.state == PlaybackState.STATE_PLAYING }
        playing.forEach { it.transportControls.pause() }
        if (playing.isNotEmpty()) Log.d("paused ${playing.joinToString { it.packageName }} before stopping its sound")
        playing.isNotEmpty()
    }.onFailure { Log.d("couldn't pause media: ${it.cause ?: it}") }.getOrDefault(false)
}
