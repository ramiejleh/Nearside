// Throwaway: a text field that logs every key it gets (device, key code, character).
package dev.nearside.helper.probe

import android.app.Activity
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.KeyEvent
import android.widget.EditText

class KeyTestActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val field = object : EditText(this) {
            override fun dispatchKeyEvent(event: KeyEvent): Boolean {
                android.util.Log.i("KeyTest", "key action=${event.action} code=${event.keyCode} meta=${Integer.toHexString(event.metaState)} " +
                    "device=${event.deviceId} char=${event.unicodeChar.toChar()} flags=${Integer.toHexString(event.flags)}")
                return super.dispatchKeyEvent(event)
            }
        }
        field.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: Editable?) { android.util.Log.i("KeyTest", "text=\"$s\"") }
        })
        if (intent.getBooleanExtra("animate", false)) {
            // Changes every frame (frame-rate and bitrate tests): moving bars and a frame counter.
            setContentView(object : android.view.View(this) {
                var n = 0
                val paint = android.graphics.Paint().apply { textSize = 120f; color = android.graphics.Color.WHITE }
                override fun onDraw(canvas: android.graphics.Canvas) {
                    n++
                    canvas.drawColor(android.graphics.Color.HSVToColor(floatArrayOf((n * 3 % 360).toFloat(), 0.6f, 0.5f)))
                    for (i in 0 until 12) {
                        paint.color = android.graphics.Color.HSVToColor(floatArrayOf((i * 30f + n) % 360, 0.8f, 0.9f))
                        val x = ((n * (i + 2) * 7) % (width + 200)) - 100f
                        canvas.drawRect(x, i * height / 12f, x + 160, (i + 1) * height / 12f, paint)
                    }
                    paint.color = android.graphics.Color.WHITE
                    canvas.drawText("$n", 60f, 200f, paint)
                    postInvalidateOnAnimation()
                }
            })
        } else setContentView(field)
        field.requestFocus()
        if (intent.hasExtra("tone")) playTone(intent.getIntExtra("tone", 8))
        // `--ei pending_display N`: a PendingIntent (as a notification's) opened on display N via the helper.
        if (intent.hasExtra("pending_display")) {
            val target = android.app.PendingIntent.getActivity(this, 1,
                android.content.Intent.makeMainSelectorActivity(android.content.Intent.ACTION_MAIN, android.content.Intent.CATEGORY_APP_CALCULATOR).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK),
                android.app.PendingIntent.FLAG_IMMUTABLE)
            val ok = runCatching { dev.nearside.link.HelperConnection.helper?.sendIntentOnDisplay(target, intent.getIntExtra("pending_display", -1)) }
            android.util.Log.i("KeyTest", "pending intent on display ${intent.getIntExtra("pending_display", -1)}: $ok")
            finish()
        }
    }

    /**
     * A 440 Hz media tone for [seconds] (audio-capture tests), with a media session that says it's
     * playing and stops the tone on pause (tests that closing a window pauses its sound).
     */
    private fun playTone(seconds: Int) = Thread {
        val rate = 48000
        val pcm = ShortArray(rate * seconds) { (Math.sin(2 * Math.PI * 440 * it / rate) * 12000).toInt().toShort() }
        val track = android.media.AudioTrack.Builder()
            .setAudioAttributes(android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setAudioFormat(android.media.AudioFormat.Builder().setSampleRate(rate).setEncoding(android.media.AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(android.media.AudioFormat.CHANNEL_OUT_MONO).build())
            .setTransferMode(android.media.AudioTrack.MODE_STATIC).setBufferSizeInBytes(pcm.size * 2).build()
        track.write(pcm, 0, pcm.size)
        val session = android.media.session.MediaSession(this, "KeyTestTone")
        val done = java.util.concurrent.CountDownLatch(1)
        session.setCallback(object : android.media.session.MediaSession.Callback() {
            override fun onPause() {
                android.util.Log.i("KeyTest", "tone paused by media session")
                track.pause()
                done.countDown()
            }
        }, android.os.Handler(android.os.Looper.getMainLooper()))
        session.setPlaybackState(android.media.session.PlaybackState.Builder()
            .setActions(android.media.session.PlaybackState.ACTION_PAUSE)
            .setState(android.media.session.PlaybackState.STATE_PLAYING, 0, 1f).build())
        session.isActive = true
        track.play()
        android.util.Log.i("KeyTest", "tone playing (session ${track.audioSessionId})")
        done.await(seconds * 1000L + 200, java.util.concurrent.TimeUnit.MILLISECONDS)
        session.release()
        track.release()
    }.start()
}
