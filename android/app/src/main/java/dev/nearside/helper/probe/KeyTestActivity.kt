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
        setContentView(field)
        field.requestFocus()
        if (intent.hasExtra("tone")) playTone(intent.getIntExtra("tone", 8))
    }

    /** A 440 Hz media tone for [seconds] (audio-capture tests). */
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
        track.play()
        android.util.Log.i("KeyTest", "tone playing (session ${track.audioSessionId})")
        Thread.sleep(seconds * 1000L + 200)
        track.release()
    }.start()
}
